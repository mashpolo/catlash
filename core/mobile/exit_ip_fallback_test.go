package mobile

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/metacubex/mihomo/transport/socks5"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestIPIPFallbackAcceptsNativePublicAddresses(t *testing.T) {
	for _, address := range []string{"8.8.8.8", "2606:4700:4700::1111"} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprintf(w, `{"ret":"ok","data":{"ip":%q,"location":["test"]}}`, address)
		}))
		got, err := detectIPIPExitIP(context.Background(), server.Client(), server.URL)
		server.Close()
		if err != nil || got != address {
			t.Fatalf("got %q, %v; want %q", got, err, address)
		}
	}
}

func TestIPIPFallbackRejectsInvalidAndNonPublicResponses(t *testing.T) {
	bodies := []string{`{`, `{"ret":"error","data":{"ip":"8.8.8.8"}}`, `{"ret":"ok","ip":"8.8.8.8"}`}
	for _, ip := range []string{"bad", "::ffff:8.8.8.8", "fe80::1%en0", "127.0.0.1", "10.0.0.1", "100.64.0.1", "192.0.2.1", "198.18.0.1", "0.0.0.0", "240.0.0.1", "::", "::1", "fc00::1", "ff02::1", "2001:db8::1"} {
		bodies = append(bodies, fmt.Sprintf(`{"ret":"ok","data":{"ip":%q}}`, ip))
	}
	for _, body := range bodies {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, body) }))
		_, err := detectIPIPExitIP(context.Background(), server.Client(), server.URL)
		server.Close()
		if err == nil {
			t.Fatalf("accepted %s", body)
		}
	}
}

func TestIPIPFallbackOrderAndBothExitAPIs(t *testing.T) {
	for _, quality := range []bool{false, true} {
		for _, preferred := range []string{"v4", "v6", "ipip"} {
			t.Run(fmt.Sprintf("quality=%t/%s", quality, preferred), func(t *testing.T) {
				calls := make(chan string, 16)
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					calls <- r.URL.Path
					switch r.URL.Path {
					case "/v4", "/v6":
						if r.URL.Path != "/"+preferred {
							http.Error(w, "unavailable", 503)
							return
						}
						address := "8.8.8.8"
						if preferred == "v6" {
							address = "2606:4700:4700::1111"
						}
						fmt.Fprintf(w, `{"ip":%q}`, address)
					case "/ipip":
						fmt.Fprint(w, `{"ret":"ok","data":{"ip":"8.8.8.8"}}`)
					default:
						http.Error(w, "quality unavailable", 503)
					}
				}))
				defer server.Close()
				s, err := NewSession(1280)
				if err != nil {
					t.Fatal(err)
				}
				defer s.Close()
				var data string
				if quality {
					data, err = s.exitIPQualityJSONForRequest(1, true, "", server.URL+"/v4", server.URL+"/v6", qualityTestOptions(server), server.URL+"/ipip")
				} else {
					data, err = s.exitIPJSON(server.URL+"/v4", server.URL+"/v6", server.URL+"/quality/", server.URL+"/ipip")
				}
				var result struct {
					IP string `json:"ip"`
				}
				if err != nil || json.Unmarshal([]byte(data), &result) != nil {
					t.Fatalf("%s %v", data, err)
				}
				want := "8.8.8.8"
				if preferred == "v6" {
					want = "2606:4700:4700::1111"
				}
				if result.IP != want {
					t.Fatalf("IP=%s want=%s", result.IP, want)
				}
				if got := <-calls; got != "/v4" {
					t.Fatal(got)
				}
				if preferred != "v4" {
					if got := <-calls; got != "/v6" {
						t.Fatal(got)
					}
				}
				if preferred == "ipip" {
					if got := <-calls; got != "/ipip" {
						t.Fatal(got)
					}
				}
				for len(calls) > 0 {
					if got := <-calls; got == "/ipip" || got == "/v6" {
						t.Fatalf("unexpected fallback: %s", got)
					}
				}
			})
		}
	}
}

func TestIPIPFallbackCancellationStopsBothExitAPIs(t *testing.T) {
	for _, quality := range []bool{false, true} {
		started := make(chan struct{}, 1)
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Path {
			case "/v4", "/v6":
				http.Error(w, "unavailable", 503)
			case "/ipip":
				started <- struct{}{}
				<-r.Context().Done()
			default:
				t.Error("cancelled fallback entered quality stage")
			}
		}))
		s, err := NewSession(1280)
		if err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() {
			var err error
			if quality {
				_, err = s.exitIPQualityJSONForRequest(1, true, "", server.URL+"/v4", server.URL+"/v6", qualityTestOptions(server), server.URL+"/ipip")
			} else {
				_, err = s.exitIPJSON(server.URL+"/v4", server.URL+"/v6", server.URL+"/quality/", server.URL+"/ipip")
			}
			done <- err
		}()
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("fallback did not start")
		}
		s.CancelExitIP()
		select {
		case err := <-done:
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("%v", err)
			}
		case <-time.After(time.Second):
			t.Fatal("fallback did not cancel")
		}
		s.Close()
		server.Close()
	}
}

func TestExitIPQualityBudgetKeepsAddressBeforeParentDeadline(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 800*time.Millisecond)
	defer cancel()
	result, err := lookupExitIPQualityWithinBudget(ctx, server.Client(), "8.8.8.8", qualityTestOptions(server))
	if err != nil || result.IP != "8.8.8.8" || len(result.Failures) != 6 || ctx.Err() != nil {
		t.Fatalf("result=%+v err=%v parent=%v", result, err, ctx.Err())
	}
	for _, failure := range result.Failures {
		if failure.Status != "timeout" {
			t.Fatalf("%+v", failure)
		}
	}
	cancel()
	if _, err = lookupExitIPQualityWithinBudget(ctx, server.Client(), "8.8.8.8", qualityTestOptions(server)); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel returned success: %v", err)
	}
}

func TestIPIPFallbackUsesConfiguredProxy(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	paths := make(chan string, 32)
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
				paths <- request.URL.Path
				status, body := "503 Service Unavailable", "unavailable"
				if request.URL.Path == "/ipip" {
					status = "200 OK"
					body = `{"ret":"ok","data":{"ip":"9.9.9.9"}}`
				}
				fmt.Fprintf(conn, "HTTP/1.1 %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", status, len(body), body)
			}()
		}
	}()
	yaml := fmt.Sprintf("proxies: [{name: outbound, type: socks5, server: 127.0.0.1, port: %d}]\nrules: ['MATCH,outbound']", listener.Addr().(*net.TCPAddr).Port)
	s, err := NewYAMLSession(yaml, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	endpoint := "http://exit.invalid"
	for _, quality := range []bool{false, true} {
		var result string
		if quality {
			options := qualityLookupOptions{endpoint: func(source, ip string) string { return endpoint + "/" + source }, timeout: time.Second, hedge: time.Millisecond}
			result, err = s.exitIPQualityJSONForRequest(2, true, "", endpoint+"/v4", endpoint+"/v6", options, endpoint+"/ipip")
		} else {
			result, err = s.exitIPJSON(endpoint+"/v4", endpoint+"/v6", endpoint+"/quality/", endpoint+"/ipip")
		}
		if err != nil || !strings.Contains(result, `"ip":"9.9.9.9"`) {
			t.Fatalf("result=%s error=%v", result, err)
		}
	}
	count := 0
	for len(paths) > 0 {
		if <-paths == "/ipip" {
			count++
		}
	}
	if count != 2 {
		t.Fatalf("IPIP did not use configured proxy for both APIs: %d", count)
	}
}
