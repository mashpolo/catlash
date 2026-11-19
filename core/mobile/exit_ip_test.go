package mobile

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/transport/socks5"
)

func exitIPProxy(t *testing.T, label string) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				conn.SetDeadline(time.Now().Add(3 * time.Second))
				_, command, _, err := socks5.ServerHandshake(conn, nil)
				if err != nil || command != socks5.CmdConnect {
					return
				}
				request, err := http.ReadRequest(bufio.NewReader(conn))
				if err != nil {
					return
				}
				request.Body.Close()
				if request.URL.Path != "/" && request.URL.Path != "/203.0.113.1" {
					t.Errorf("quality lookup used wrong address: %s", request.URL.Path)
					return
				}
				body := fmt.Sprintf(`{"ip":"203.0.113.1","route":%q,"isp":{"org":%q},"risk":{"is_mobile":true}}`, label, label)
				fmt.Fprintf(conn, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
			}()
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port
}

func TestExitIPUsesCurrentRouteForEveryQuery(t *testing.T) {
	a, b := exitIPProxy(t, "rule"), exitIPProxy(t, "global")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, `{"ip":"203.0.113.1","route":"direct"}`) }))
	defer server.Close()
	yaml := fmt.Sprintf("proxies: [{name: a, type: socks5, server: 127.0.0.1, port: %d}, {name: b, type: socks5, server: 127.0.0.1, port: %d}]\nrules: ['MATCH,a']", a, b)
	s, err := NewYAMLSession(yaml, `{"GLOBAL":"b"}`, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, mode := range []string{"rule", "global", "direct", "rule"} {
		if err = s.SetMode(mode); err != nil {
			t.Fatal(err)
		}
		value, err := s.exitIPJSON(server.URL, server.URL+"/v6", server.URL+"/")
		if err != nil {
			t.Fatal(err)
		}
		var result struct{ Route string }
		if err = json.Unmarshal([]byte(value), &result); err != nil || result.Route != mode {
			t.Fatalf("mode %s: %s %v", mode, value, err)
		}
	}
	s.Close()
	if _, err := s.ExitIPJSON(); err == nil {
		t.Fatal("closed session queried")
	}
}

func TestExitIPRejectsUnusableResponses(t *testing.T) {
	s, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, tc := range []struct {
		name, body string
		status     int
	}{
		{"status", `{"ip":"1.1.1.1"}`, 429},
		{"invalid", "{", 200},
		{"missing", `{"location":{}}`, 200},
		{"invalid-ip", `{"ip":"not an ip"}`, 200},
		{"ipv6", `{"ip":"2001:db8::1"}`, 200},
		{"mapped-ipv6", `{"ip":"::ffff:203.0.113.1"}`, 200},
		{"error", `{"ip":"1.1.1.1","error":"rate limited"}`, 200},
		{"oversize", `{"ip":"1.1.1.1","padding":"` + strings.Repeat("a", 65536) + `"}`, 200},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/v6" {
					http.Error(w, "no IPv6", 503)
					return
				}
				w.WriteHeader(tc.status)
				fmt.Fprint(w, tc.body)
			}))
			defer server.Close()
			if _, err := s.exitIPJSON(server.URL, server.URL+"/v6", server.URL+"/"); err == nil {
				t.Fatal("accepted invalid response")
			}
		})
	}
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { t.Error("followed redirect") }))
	defer target.Close()
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, 302) }))
	defer redirect.Close()
	if _, err := s.exitIPJSON(redirect.URL, redirect.URL+"/v6", target.URL+"/"); err == nil {
		t.Fatal("accepted redirect")
	}
}

func TestExitIPReplacementAndCloseCancelOnlyLookup(t *testing.T) {
	started := make(chan struct{}, 3)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/fast") {
			fmt.Fprint(w, `{"ip":"1.1.1.1"}`)
			return
		}
		started <- struct{}{}
		<-r.Context().Done()
	}))
	defer server.Close()
	s, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	old := make(chan error, 1)
	go func() { _, err := s.exitIPJSON(server.URL, server.URL+"/v6", server.URL+"/"); old <- err }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("first query did not start")
	}
	if _, err := s.exitIPJSON(server.URL+"/fast", server.URL+"/v6", server.URL+"/fast/"); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-old:
		if err == nil {
			t.Fatal("replaced query succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("old query not cancelled")
	}
	if s.testContext.Err() != nil {
		t.Fatal("query cancelled latency tests")
	}
	for _, closeSession := range []bool{false, true} {
		done := make(chan error, 1)
		go func() { _, err := s.exitIPJSON(server.URL, server.URL+"/v6", server.URL+"/"); done <- err }()
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("query did not start")
		}
		if closeSession {
			s.Close()
		} else {
			s.CancelExitIP()
		}
		select {
		case err := <-done:
			if err == nil {
				t.Fatal("cancelled query succeeded")
			}
		case <-time.After(time.Second):
			t.Fatal("query not cancelled")
		}
	}
}

func TestExitIPReplacedRequestCannotClearNewCancellation(t *testing.T) {
	started := make(chan struct{}, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started <- struct{}{}
		<-r.Context().Done()
	}))
	defer server.Close()
	s, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	first, second := make(chan error, 1), make(chan error, 1)
	go func() { _, err := s.exitIPJSON(server.URL, server.URL+"/v6", server.URL+"/"); first <- err }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("first request did not start")
	}
	go func() { _, err := s.exitIPJSON(server.URL, server.URL+"/v6", server.URL+"/"); second <- err }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("second request did not start")
	}
	select {
	case err := <-first:
		if err == nil {
			t.Fatal("replaced request succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("first request did not finish")
	}
	s.CancelExitIP()
	select {
	case err := <-second:
		if err == nil {
			t.Fatal("cancelled request succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("old cleanup removed current cancel function")
	}
}

func TestExitIPQualityMustMatchIPv4AndFailuresKeepAddress(t *testing.T) {
	s, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, tc := range []struct {
		name, body string
		status     int
	}{
		{"success", `{"ip":"203.0.113.1","isp":{"org":"test"}}`, 200},
		{"mismatch", `{"ip":"203.0.113.2","isp":{"org":"wrong address"}}`, 200},
		{"ipv6", `{"ip":"2001:db8::1"}`, 200},
		{"mapped-ipv6", `{"ip":"::ffff:203.0.113.1"}`, 200},
		{"status", `{"ip":"203.0.113.1"}`, 429},
		{"invalid", "{", 200},
		{"error", `{"ip":"203.0.113.1","error":"rate limited"}`, 200},
		{"oversize", `{"ip":"203.0.113.1","padding":"` + strings.Repeat("a", 65536) + `"}`, 200},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/address" {
					fmt.Fprint(w, `{"ip":"203.0.113.1"}`)
					return
				}
				if r.URL.Path != "/quality/203.0.113.1" || r.URL.Query().Get("format") != "json" {
					t.Errorf("wrong quality target: %s", r.URL)
				}
				w.WriteHeader(tc.status)
				fmt.Fprint(w, tc.body)
			}))
			defer server.Close()
			value, err := s.exitIPJSON(server.URL+"/address", server.URL+"/v6", server.URL+"/quality/")
			if err != nil {
				t.Fatal(err)
			}
			expected := `{"ip":"203.0.113.1"}`
			if tc.name == "success" {
				expected = tc.body
			}
			if value != expected {
				t.Fatalf("got %s, want %s", value, expected)
			}
		})
	}
}

func TestExitIPQualityCancellationCannotReturnFallbackSuccess(t *testing.T) {
	s, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	started := make(chan struct{}, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/address" {
			fmt.Fprint(w, `{"ip":"203.0.113.1"}`)
			return
		}
		started <- struct{}{}
		<-r.Context().Done()
	}))
	defer server.Close()
	for _, closeSession := range []bool{false, true} {
		done := make(chan error, 1)
		go func() {
			_, err := s.exitIPJSON(server.URL+"/address", server.URL+"/v6", server.URL+"/quality/")
			done <- err
		}()
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("quality query did not start")
		}
		if closeSession {
			s.Close()
		} else {
			s.CancelExitIP()
		}
		select {
		case err := <-done:
			if err == nil {
				t.Fatal("cancelled quality returned fallback success")
			}
		case <-time.After(time.Second):
			t.Fatal("quality query not cancelled")
		}
	}
}

func TestExitIPOlderRequestCannotCancelNewerRequest(t *testing.T) {
	started := make(chan struct{}, 1)
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/address" {
			started <- struct{}{}
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
		}
		fmt.Fprint(w, `{"ip":"203.0.113.1"}`)
	}))
	defer server.Close()
	s, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	done := make(chan error, 1)
	go func() {
		_, err := s.exitIPJSONForRequest(2, server.URL+"/address", server.URL+"/v6", server.URL+"/quality/")
		done <- err
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("newer request did not start")
	}
	if _, err := s.exitIPJSONForRequest(1, server.URL+"/address", server.URL+"/v6", server.URL+"/quality/"); err == nil {
		t.Fatal("accepted old request")
	}
	close(release)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal("older request cancelled newer request", err)
		}
	case <-time.After(time.Second):
		t.Fatal("newer request did not finish")
	}
	if _, err := s.ExitIPJSONForRequest(2); err == nil {
		t.Fatal("reused request ID")
	}
}

func TestExitIPIPv4PreferredIPv6FallbackOrder(t *testing.T) {
	s, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, tc := range []struct {
		name, v4, v6, quality string
		v4Status              int
		want, paths           string
		fails                 bool
	}{
		{name: "ipv4", v4: `{"ip":"203.0.113.1"}`, v4Status: 200, want: `{"ip":"203.0.113.1","isp":{"org":"test"}}`, paths: "/v4 /quality/203.0.113.1", quality: `{"ip":"203.0.113.1","isp":{"org":"test"}}`},
		{name: "ipv6", v4Status: 503, v6: `{"ip":"2001:db8::1"}`, want: `{"ip":"2001:db8::1","isp":{"org":"test"}}`, paths: "/v4 /v6 /quality/2001:db8::1", quality: `{"ip":"2001:db8::1","isp":{"org":"test"}}`},
		{name: "invalid-v4", v4Status: 200, v4: `{"ip":"2001:db8::99"}`, v6: `{"ip":"2001:db8::1"}`, want: `{"ip":"2001:db8::1"}`, paths: "/v4 /v6 /quality/2001:db8::1"},
		{name: "quality-does-not-trigger-v6", v4: `{"ip":"203.0.113.1"}`, v4Status: 200, want: `{"ip":"203.0.113.1"}`, paths: "/v4 /quality/203.0.113.1"},
		{name: "ipv6-quality-mismatch", v4Status: 503, v6: `{"ip":"2001:db8::1"}`, want: `{"ip":"2001:db8::1"}`, paths: "/v4 /v6 /quality/2001:db8::1", quality: `{"ip":"2001:db8::2","isp":{"org":"wrong"}}`},
		{name: "both-fail", v4Status: 503, paths: "/v4 /v6", fails: true},
		{name: "mapped-v6", v4Status: 503, v6: `{"ip":"::ffff:203.0.113.1"}`, paths: "/v4 /v6", fails: true},
		{name: "zone-v6", v4Status: 503, v6: `{"ip":"fe80::1%en0"}`, paths: "/v4 /v6", fails: true},
		{name: "v4-in-v6-service", v4Status: 503, v6: `{"ip":"203.0.113.1"}`, paths: "/v4 /v6", fails: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			paths := make(chan string, 3)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				paths <- r.URL.Path
				switch r.URL.Path {
				case "/v4":
					w.WriteHeader(tc.v4Status)
					fmt.Fprint(w, tc.v4)
				case "/v6":
					if tc.v6 == "" {
						http.Error(w, "unavailable", 503)
					} else {
						fmt.Fprint(w, tc.v6)
					}
				default:
					if tc.quality == "" {
						http.Error(w, "quality unavailable", 503)
					} else {
						fmt.Fprint(w, tc.quality)
					}
				}
			}))
			defer server.Close()
			value, err := s.exitIPJSON(server.URL+"/v4", server.URL+"/v6", server.URL+"/quality/")
			if tc.fails {
				if err == nil {
					t.Fatal("both detectors should fail")
				}
			} else if err != nil || value != tc.want {
				t.Fatalf("value %s, err %v, want %s", value, err, tc.want)
			}
			var actual []string
			for len(paths) > 0 {
				actual = append(actual, <-paths)
			}
			if strings.Join(actual, " ") != tc.paths {
				t.Fatalf("paths %v, want %s", actual, tc.paths)
			}
		})
	}
}

func TestExitIPIPv4TimeoutLeavesBudgetForIPv6(t *testing.T) {
	s, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v4" {
			<-r.Context().Done()
			return
		}
		fmt.Fprint(w, `{"ip":"2001:db8::1"}`)
	}))
	defer server.Close()
	started := time.Now()
	value, err := s.exitIPJSON(server.URL+"/v4", server.URL+"/v6", server.URL+"/quality/")
	if err != nil || value != `{"ip":"2001:db8::1"}` {
		t.Fatalf("%s %v", value, err)
	}
	if elapsed := time.Since(started); elapsed < 3*time.Second || elapsed > 7*time.Second {
		t.Fatalf("IPv4 fallback budget not applied: %s", elapsed)
	}
}

func TestExitIPCancelDuringIPv6DoesNotQueryQuality(t *testing.T) {
	s, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	started := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v4":
			http.Error(w, "IPv4 unavailable", 503)
		case "/v6":
			started <- struct{}{}
			<-r.Context().Done()
		default:
			t.Error("cancelled lookup entered quality stage")
		}
	}))
	defer server.Close()
	done := make(chan error, 1)
	go func() {
		_, err := s.exitIPJSON(server.URL+"/v4", server.URL+"/v6", server.URL+"/quality/")
		done <- err
	}()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("IPv6 request did not start")
	}
	s.CancelExitIP()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled IPv6 lookup succeeded")
		}
	case <-time.After(time.Second):
		t.Fatal("IPv6 lookup was not cancelled")
	}
}
