package mobile

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func qualityTestOptions(server *httptest.Server) qualityLookupOptions {
	return qualityLookupOptions{endpoint: func(source, ip string) string { return server.URL + "/" + source }, timeout: time.Second, hedge: 20 * time.Millisecond}
}

func TestIPQualitySixSourceParsers(t *testing.T) {
	for _, tc := range []struct {
		source, body, kind, organization string
		asn                              int
		tor, abuser, vpn, proxy          bool
	}{
		{"identMe", `{"ip":"203.0.113.9","type":"isp","aso":"Broadband","asn":64500,"cc":"GB"}`, "residential", "Broadband", 64500, false, false, false, false},
		{"ipApiCom", `{"status":"success","org":"Cloud","as":"AS64501 Cloud","hosting":true,"proxy":true}`, "hosting", "Cloud", 64501, false, false, false, true},
		{"ipQuery", `{"ip":"203.0.113.9","isp":{"asn":"AS64502","org":"Mobile"},"risk":{"is_mobile":true,"is_tor":true}}`, "mobile", "Mobile", 64502, true, false, false, false},
		{"ipLocate", `{"asn":{"asn":"AS64503","type":"isp"},"company":{"name":"Leasing","type":"hosting"},"privacy":{"is_hosting":true}}`, "hosting", "Leasing", 64503, false, false, false, false},
		{"ipApiIs", `{"is_datacenter":true,"is_tor":true,"is_abuser":true,"company":{"name":"VPS","type":"business"},"asn":{"asn":36352}}`, "hosting", "VPS", 36352, true, true, false, false},
		{"proxyCheck", `{"status":"ok","203.0.113.9":{"network":{"asn":"AS64504","organisation":"Business","type":"Business"},"detections":{"vpn":true}}}`, "business", "Business", 64504, false, false, true, false},
	} {
		t.Run(tc.source, func(t *testing.T) {
			var raw map[string]any
			if err := json.Unmarshal([]byte(tc.body), &raw); err != nil {
				t.Fatal(err)
			}
			value, status := parseIPQuality(tc.source, "203.0.113.9", raw)
			if status != "" || value.Quality == nil {
				t.Fatalf("%+v %s", value, status)
			}
			q := value.Quality
			if q.Source != tc.source || q.Type != tc.kind || q.Organization != tc.organization || q.ASN != tc.asn || q.IsTor != tc.tor || q.IsAbuser != tc.abuser || q.IsVPN != tc.vpn || q.IsProxy != tc.proxy || q.Inferred {
				t.Fatalf("unexpected quality: %+v", q)
			}
		})
	}
}

func TestIPQualityExplicitTypeBeatsFastInferredAnswer(t *testing.T) {
	var lateCalls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/ipQuery":
			fmt.Fprint(w, `{"ip":"203.0.113.9","risk":{}}`)
		case "/ipApiCom":
			http.Error(w, "unavailable", 503)
		case "/identMe":
			time.Sleep(10 * time.Millisecond)
			fmt.Fprint(w, `{"ip":"203.0.113.9","type":"business"}`)
		default:
			lateCalls.Add(1)
			http.Error(w, "unavailable", 503)
		}
	}))
	defer server.Close()
	result, err := lookupIPQuality(context.Background(), server.Client(), "203.0.113.9", qualityTestOptions(server))
	if err != nil || result.Quality == nil || result.Quality.Type != "business" || result.Quality.Inferred || lateCalls.Load() != 0 {
		t.Fatalf("%+v %v calls=%d", result, err, lateCalls.Load())
	}
}

func TestIPQualityFailuresAndResidentialFallback(t *testing.T) {
	for _, inferred := range []bool{false, true} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch r.URL.Path {
			case "/identMe":
				fmt.Fprint(w, `{"ip":"203.0.113.8","type":"hosting"}`)
			case "/ipApiCom":
				w.WriteHeader(429)
			case "/ipQuery":
				if inferred {
					fmt.Fprint(w, `{"ip":"203.0.113.9"}`)
				} else {
					fmt.Fprint(w, `{`)
				}
			case "/ipLocate":
				fmt.Fprint(w, `{}`)
			case "/ipApiIs":
				<-r.Context().Done()
			case "/proxyCheck":
				fmt.Fprint(w, `{"status":"denied"}`)
			}
		}))
		options := qualityTestOptions(server)
		options.timeout = 70 * time.Millisecond
		result, err := lookupIPQuality(context.Background(), server.Client(), "203.0.113.9", options)
		server.Close()
		if err != nil {
			t.Fatal(err)
		}
		if inferred {
			if result.Quality == nil || result.Quality.Type != "residential" || !result.Quality.Inferred {
				t.Fatalf("%+v", result)
			}
			continue
		}
		want := map[string]string{"identMe": "ipMismatch", "ipApiCom": "rateLimited", "ipQuery": "failed", "ipLocate": "noType", "ipApiIs": "timeout", "proxyCheck": "rateLimited"}
		if result.Quality != nil || len(result.Failures) != len(want) {
			t.Fatalf("%+v", result)
		}
		for _, failure := range result.Failures {
			if want[failure.Source] != failure.Status {
				t.Fatalf("%+v", failure)
			}
		}
	}
}

func TestIPQualityWinnerCancelsAndJoinsOtherSources(t *testing.T) {
	started := make(chan struct{}, 2)
	var stopped atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/identMe" {
			<-started
			<-started
			fmt.Fprint(w, `{"ip":"203.0.113.9","type":"hosting"}`)
			return
		}
		started <- struct{}{}
		<-r.Context().Done()
		stopped.Add(1)
	}))
	defer server.Close()
	result, err := lookupIPQuality(context.Background(), server.Client(), "203.0.113.9", qualityTestOptions(server))
	if err != nil || result.Quality == nil {
		t.Fatalf("%+v %v", result, err)
	}
	deadline := time.Now().Add(time.Second)
	for stopped.Load() != 2 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if stopped.Load() != 2 {
		t.Fatal("losing requests remained active")
	}
}

func TestIPQualityCacheExpiryPersistenceAndFailures(t *testing.T) {
	var cache ipQualityCache
	directory := t.TempDir()
	now := time.Unix(1_800_000_000, 0)
	value := exitIPQualityResult{IP: "203.0.113.9", Quality: &ipQuality{Source: "identMe", Type: "hosting"}, CheckedAt: now.Unix()}
	cache.put(value, directory, now)
	var reopened ipQualityCache
	if got, ok := reopened.get(value.IP, directory, now.Add(71*time.Hour)); !ok || !got.Cached || got.Quality.Type != "hosting" {
		t.Fatalf("%+v %v", got, ok)
	}
	if _, ok := reopened.get(value.IP, directory, now.Add(72*time.Hour)); ok {
		t.Fatal("expired success reused")
	}
	if _, ok := reopened.get(value.IP, directory, now.Add(-time.Second)); ok {
		t.Fatal("future record reused")
	}
	failure := exitIPQualityResult{IP: "203.0.113.8", Failures: []ipQualityFailure{{Source: "identMe", Status: "failed"}}, CheckedAt: now.Unix()}
	cache.put(failure, directory, now)
	if _, ok := cache.get(failure.IP, directory, now.Add(4*time.Minute)); !ok {
		t.Fatal("failure cooldown missing")
	}
	if _, ok := cache.get(failure.IP, directory, now.Add(5*time.Minute)); ok {
		t.Fatal("failure cooldown did not expire")
	}
	var another ipQualityCache
	if _, ok := another.get(failure.IP, directory, now); ok {
		t.Fatal("failure persisted")
	}
}

func TestIPQualityBoundaryRejectsWrongIPAndMalformedData(t *testing.T) {
	for _, tc := range []struct {
		body, status string
		code         int
	}{
		{`{"ip":"203.0.113.8","risk":{"is_mobile":true}}`, "ipMismatch", 200},
		{`{"ip":[],"risk":{"is_mobile":true}}`, "ipMismatch", 200},
		{`{"error":"quota"}`, "failed", 200},
		{`null`, "failed", 200},
		{`[]`, "failed", 200},
		{`{"padding":"` + strings.Repeat("a", 65536) + `"}`, "failed", 200},
		{`{}`, "failed", 302},
		{`{}`, "rateLimited", 429},
	} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(tc.code); fmt.Fprint(w, tc.body) }))
		_, status := queryIPQuality(context.Background(), server.Client(), "ipQuery", "203.0.113.9", qualityTestOptions(server))
		server.Close()
		if status != tc.status {
			t.Fatalf("got %s want %s", status, tc.status)
		}
	}
}

func TestIPQualitySessionCacheRedetectsAddressAndManualRefreshBypassesCache(t *testing.T) {
	var addressCalls, qualityCalls atomic.Int32
	var lastAddress atomic.Value
	lastAddress.Store("203.0.113.9")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/address" {
			addressCalls.Add(1)
			fmt.Fprintf(w, `{"ip":%q}`, lastAddress.Load())
			return
		}
		qualityCalls.Add(1)
		if r.URL.Path == "/identMe" {
			fmt.Fprintf(w, `{"ip":%q,"type":"business"}`, lastAddress.Load())
			return
		}
		http.Error(w, "unavailable", 503)
	}))
	defer server.Close()
	directory := t.TempDir()
	s, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	lookup := func(id int64, force bool) exitIPQualityResult {
		t.Helper()
		data, err := s.exitIPQualityJSONForRequest(id, force, directory, server.URL+"/address", server.URL+"/v6", qualityTestOptions(server))
		if err != nil {
			t.Fatal(err)
		}
		var result exitIPQualityResult
		if err := json.Unmarshal([]byte(data), &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	if result := lookup(1, false); result.Cached || result.Quality == nil {
		t.Fatalf("%+v", result)
	}
	firstCalls := qualityCalls.Load()
	if result := lookup(2, false); !result.Cached || qualityCalls.Load() != firstCalls || addressCalls.Load() != 2 {
		t.Fatalf("cache %+v", result)
	}
	if result := lookup(3, true); result.Cached || qualityCalls.Load() <= firstCalls || addressCalls.Load() != 3 {
		t.Fatalf("forced %+v", result)
	}
	lastAddress.Store("203.0.113.10")
	if result := lookup(4, false); result.Cached || result.IP != "203.0.113.10" || addressCalls.Load() != 4 {
		t.Fatalf("new route %+v", result)
	}
	s.Close()
	s, err = NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if result := lookup(1, false); !result.Cached || result.IP != "203.0.113.10" {
		t.Fatalf("reopened %+v", result)
	}
}

func TestIPQualityCacheCorruptionAndBounds(t *testing.T) {
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "ip-quality.json"), []byte("{"), 0600); err != nil {
		t.Fatal(err)
	}
	var cache ipQualityCache
	now := time.Now()
	if _, ok := cache.get("203.0.113.9", directory, now); ok {
		t.Fatal("invalid cache accepted")
	}
	for i := 0; i < maximumQualityCacheEntries+10; i++ {
		cache.put(exitIPQualityResult{IP: fmt.Sprintf("2001:db8::%x", i), Quality: &ipQuality{Source: "identMe", Type: "hosting"}, CheckedAt: now.Unix()}, "", now)
	}
	if len(cache.entries) != maximumQualityCacheEntries {
		t.Fatal("unbounded memory cache")
	}
	now = now.Add(time.Second)
	cache.put(exitIPQualityResult{IP: "203.0.113.9", Quality: &ipQuality{Source: "identMe", Type: "business"}, CheckedAt: now.Unix()}, filepath.Join(directory, "ip-quality.json", "not-a-directory"), now)
	if _, ok := cache.get("203.0.113.9", "", now); !ok {
		t.Fatal("failed cache persistence discarded result")
	}
}

func TestIPQualityScopedCancellationAndClose(t *testing.T) {
	started := make(chan struct{}, 6)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/address" {
			fmt.Fprint(w, `{"ip":"203.0.113.9"}`)
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
	lookup := func(id int64) <-chan error {
		done := make(chan error, 1)
		go func() {
			_, err := s.exitIPQualityJSONForRequest(id, true, "", server.URL+"/address", server.URL+"/v6", qualityTestOptions(server))
			done <- err
		}()
		return done
	}
	done := lookup(2)
	for i := 0; i < 3; i++ {
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("quality query did not begin")
		}
	}
	s.CancelExitIPForRequest(1)
	select {
	case <-done:
		t.Fatal("old cancellation stopped newer request")
	default:
	}
	s.CancelExitIPForRequest(2)
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled query returned success")
		}
	case <-time.After(time.Second):
		t.Fatal("query cancellation stalled")
	}
	s.CancelExitIPForRequest(3)
	if err := <-lookup(3); err == nil {
		t.Fatal("request began after its cancellation")
	}
	done = lookup(4)
	for i := 0; i < 3; i++ {
		select {
		case <-started:
		case <-time.After(time.Second):
			t.Fatal("new query did not begin")
		}
	}
	s.Close()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("closed session returned success")
		}
	case <-time.After(time.Second):
		t.Fatal("close did not join query")
	}
}

func TestIPQualityUsesSessionRuleGlobalAndDirectRoutes(t *testing.T) {
	a, b := exitIPProxy(t, "rule"), exitIPProxy(t, "global")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"ip":"203.0.113.1","isp":{"org":"direct"},"risk":{"is_mobile":true}}`)
	}))
	defer server.Close()
	yaml := fmt.Sprintf("proxies: [{name: a, type: socks5, server: 127.0.0.1, port: %d}, {name: b, type: socks5, server: 127.0.0.1, port: %d}]\nrules: ['MATCH,a']", a, b)
	s, err := NewYAMLSession(yaml, `{"GLOBAL":"b"}`, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	options := qualityTestOptions(server)
	options.endpoint = func(source, ip string) string { return server.URL + "/" + ip }
	for i, mode := range []string{"rule", "global", "direct", "rule"} {
		if err := s.SetMode(mode); err != nil {
			t.Fatal(err)
		}
		data, err := s.exitIPQualityJSONForRequest(int64(i+1), true, "", server.URL, server.URL+"/v6", options)
		if err != nil {
			t.Fatal(err)
		}
		var result exitIPQualityResult
		if err := json.Unmarshal([]byte(data), &result); err != nil {
			t.Fatal(err)
		}
		if result.IP != "203.0.113.1" || result.Organization != mode || result.Quality == nil || result.Quality.Type != "mobile" {
			t.Fatalf("mode %s: %s", mode, data)
		}
	}
}
