package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestProxyDelayMeasuresResponseAndPreservesSelection(t *testing.T) {
	methods := make(chan string, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		methods <- r.Method
		select {
		case <-time.After(80 * time.Millisecond):
			w.WriteHeader(http.StatusNoContent)
		case <-r.Context().Done():
		}
	}))
	defer server.Close()
	session, err := NewYAMLSession("proxy-groups: [{name: pick, type: select, proxies: [REJECT, DIRECT]}]\nrules: ['MATCH,pick']", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	started := time.Now()
	delay, err := session.TestProxy("DIRECT", server.URL, 2000)
	if err != nil {
		t.Fatal(err)
	}
	if delay < 60 || delay > time.Since(started).Milliseconds()+1 {
		t.Fatalf("response delay not measured: %d ms", delay)
	}
	if method := <-methods; method != http.MethodHead {
		t.Fatalf("method = %s", method)
	}
	catalog, err := session.ProxiesJSON()
	if err != nil {
		t.Fatal(err)
	}
	var status struct {
		Proxies []proxyStatus `json:"proxies"`
	}
	if err := json.Unmarshal([]byte(catalog), &status); err != nil {
		t.Fatal(err)
	}
	foundNode, foundGroup := false, false
	for _, proxy := range status.Proxies {
		if proxy.Name == "DIRECT" {
			foundNode = true
			if proxy.Delay == nil || int64(*proxy.Delay) != delay {
				t.Fatalf("catalog delay mismatch: %+v", proxy)
			}
		}
		if proxy.Name == "pick" {
			foundGroup = true
			if proxy.Now != "REJECT" {
				t.Fatalf("test changed selection: %s", proxy.Now)
			}
		}
	}
	if !foundNode || !foundGroup {
		t.Fatal("catalog missing node or group")
	}
}

func TestProxyDelayTimeoutFailureAndInputErrors(t *testing.T) {
	started := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started <- struct{}{}
		<-r.Context().Done()
	}))
	defer server.Close()
	session, err := NewYAMLSession("mode: direct", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	delay, err := session.TestProxy("DIRECT", server.URL, 100)
	if delay != 0 || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("timeout: delay=%d err=%v", delay, err)
	}
	select {
	case <-started:
	default:
		t.Fatal("timeout occurred before reaching controlled endpoint")
	}
	for _, test := range []struct {
		name, url string
		timeout   int32
		message   string
	}{
		{"REJECT", server.URL, 1000, "proxy URL test failed"},
		{"missing", server.URL, 1000, "unknown proxy"},
		{"DIRECT", server.URL, 0, "timeout"},
		{"DIRECT", server.URL, 60001, "timeout"},
		{"DIRECT", "file:///private/test", 1000, "HTTP or HTTPS"},
	} {
		delay, err := session.TestProxy(test.name, test.url, test.timeout)
		if delay != 0 || err == nil || !strings.Contains(err.Error(), test.message) {
			t.Fatalf("unexpected failure result: delay=%d err=%v", delay, err)
		}
	}
}

func TestProxyDelaySessionCloseCancelsPendingRequest(t *testing.T) {
	started := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started <- struct{}{}
		<-r.Context().Done()
	}))
	defer server.Close()
	session, err := NewYAMLSession("mode: direct", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	result := make(chan error, 1)
	go func() { _, err := session.TestProxy("DIRECT", server.URL, 5000); result <- err }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("request did not reach endpoint")
	}
	closed := make(chan error, 1)
	go func() { closed <- session.Close() }()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("session close waited for test timeout")
	}
	if err := <-result; !errors.Is(err, context.Canceled) {
		t.Fatalf("close result: %v", err)
	}
	if _, err := session.TestProxy("DIRECT", server.URL, 1000); err == nil || !strings.Contains(err.Error(), "closed") {
		t.Fatalf("closed session test: %v", err)
	}
}

func TestProxyDelayResultDistinguishesTimeoutAndFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/timeout" {
			<-r.Context().Done()
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	session, err := NewYAMLSession("proxy-groups: [{name: pick, type: select, proxies: [REJECT, DIRECT], url: '"+server.URL+"'}]\nrules: ['MATCH,pick']", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	for _, test := range []struct{ node, path, status string }{
		{"DIRECT", "/ok", "success"}, {"DIRECT", "/timeout", "timeout"}, {"REJECT", "/ok", "failed"},
	} {
		value, err := session.TestProxyResultJSON(test.node, server.URL+test.path, 100)
		if err != nil {
			t.Fatal(err)
		}
		var result struct {
			Status string `json:"status"`
		}
		if err := json.Unmarshal([]byte(value), &result); err != nil || result.Status != test.status {
			t.Fatalf("unexpected typed result: %s %v", value, err)
		}
	}
	catalog, _ := session.ProxiesJSON()
	if !strings.Contains(catalog, `"testURL":"`+server.URL+`"`) {
		t.Fatal("group test URL missing from catalog")
	}
}

func TestProxyDelayTypedCancellationAndInvalidParameters(t *testing.T) {
	started := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started <- struct{}{}
		<-r.Context().Done()
	}))
	defer server.Close()
	session, err := NewYAMLSession("mode: direct", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	response := make(chan string, 1)
	go func() { value, _ := session.TestProxyResultJSON("DIRECT", server.URL, 5000); response <- value }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("request did not start")
	}
	session.CancelTests()
	select {
	case value := <-response:
		if !strings.Contains(value, `"status":"cancelled"`) {
			t.Fatal(value)
		}
	case <-time.After(time.Second):
		t.Fatal("typed cancellation did not finish")
	}
	for _, timeout := range []int32{0, 60001} {
		value, err := session.TestProxyResultJSON("DIRECT", server.URL, timeout)
		if err != nil || !strings.Contains(value, `"status":"failed"`) {
			t.Fatalf("invalid timeout: %s %v", value, err)
		}
	}
	value, err := session.TestProxyResultJSON("DIRECT", "https://user:sensitive@example.com", 1000)
	if err != nil || !strings.Contains(value, `"status":"failed"`) || strings.Contains(value, "sensitive") {
		t.Fatalf("invalid URL: %s %v", value, err)
	}
}
