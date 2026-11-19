package mobile

import (
	"bufio"
	"context"
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

func TestSessionResourcePreparationKeepsCurrentOwnerAndRules(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "payload: ['example.invalid']\n") }))
	defer server.Close()
	port := exitIPProxy(t, "selected")
	config := fmt.Sprintf("sniffer: {enable: true}\nproxies: [{name: chosen, type: socks5, server: 127.0.0.1, port: %d}]\nrule-providers: {remote: {type: http, behavior: domain, proxy: DIRECT, url: '%s'}}\nrules: ['RULE-SET,remote,REJECT','MATCH,chosen']\n", port, server.URL)
	session, err := NewYAMLSessionWithDeferredResources(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	preparation, err := session.NewResourcePreparation(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err = preparation.Prepare(); err != nil {
		t.Fatal(err)
	}
	if preparation.ResourceCount() != 1 {
		t.Fatal("downloaded provider missing")
	}
	if len(session.routing.rules) != 1 || len(session.routing.ruleProviders) != 0 || !session.ResourcesPending() {
		t.Fatal("preparation replaced live routing tables")
	}
	result, err := session.exitIPJSON("http://198.51.100.9/", "http://198.51.100.9/v6", "http://198.51.100.9/")
	if err != nil || !strings.Contains(result, `"route":"selected"`) {
		t.Fatalf("active proxy unavailable after preparation: %v", err)
	}
	if another, err := NewSession(1280); err == nil {
		another.Close()
		t.Fatal("preparation released the active owner")
	}
}

func TestSessionResourcePreparationGeoUsesCurrentProxy(t *testing.T) {
	geo := geoIPFixture(t)
	port, done := interopTCPServer(t, func(conn net.Conn) error {
		_, command, _, err := socks5.ServerHandshake(conn, nil)
		if err != nil {
			return err
		}
		if command != socks5.CmdConnect {
			return errors.New("wrong proxy command")
		}
		request, err := http.ReadRequest(bufio.NewReader(conn))
		if err != nil {
			return err
		}
		request.Body.Close()
		_, err = fmt.Fprintf(conn, "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(geo), geo)
		return err
	})
	config := fmt.Sprintf("profile: {store-selected: false}\ngeodata-mode: true\ngeox-url: {geoip: 'http://unreachable.invalid/geo'}\nproxies: [{name: chosen, type: socks5, server: 127.0.0.1, port: %d}]\nproxy-groups: [{name: Final, type: select, proxies: [REJECT,chosen]}]\nrules: ['GEOIP,TEST,REJECT','MATCH,Final']\n", port)
	session, err := NewYAMLSessionWithDeferredResources(config, `{"Final":"chosen"}`, "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	preparation, err := session.NewResourcePreparation(config, `{"Final":"chosen"}`, "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err = preparation.Prepare(); err != nil {
		t.Fatal(err)
	}
	if preparation.ResourceCount() != 1 || len(session.routing.rules) != 1 {
		t.Fatal("Geo download missing or live routes changed")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestSessionResourcePreparationCloseCancelsAndJoinsDownload(t *testing.T) {
	entered := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(entered); <-r.Context().Done() }))
	defer server.Close()
	config := fmt.Sprintf("rule-providers: {remote: {type: http, behavior: domain, proxy: DIRECT, url: '%s'}}\nrules: ['MATCH,DIRECT']\n", server.URL)
	session, err := NewYAMLSessionWithDeferredResources(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	preparation, err := session.NewResourcePreparation(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- preparation.Prepare() }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("download did not start")
	}
	closed := make(chan struct{})
	go func() { session.Close(); close(closed) }()
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("close failed to join preparation")
	}
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("closed session download returned %v", err)
	}
	if _, err := session.NewResourcePreparation(config, "{}", "", "", 1280); err == nil {
		t.Fatal("closed session accepted a preparation")
	}
	next, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	next.Close()
}

func TestSessionResourcePreparationFailureKeepsVPNUsable(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusServiceUnavailable) }))
	defer server.Close()
	port := exitIPProxy(t, "selected")
	config := fmt.Sprintf("sniffer: {enable: true}\nproxies: [{name: chosen, type: socks5, server: 127.0.0.1, port: %d}]\nrule-providers: {remote: {type: http, behavior: domain, proxy: DIRECT, url: '%s'}}\nrules: ['RULE-SET,remote,REJECT','MATCH,chosen']\n", port, server.URL)
	session, err := NewYAMLSessionWithDeferredResources(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	preparation, err := session.NewResourcePreparation(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err = preparation.Prepare(); err == nil || !strings.Contains(err.Error(), "503") {
		t.Fatalf("download failure was lost: %v", err)
	}
	result, err := session.exitIPJSON("http://198.51.100.9/", "http://198.51.100.9/v6", "http://198.51.100.9/")
	if err != nil || !strings.Contains(result, `"route":"selected"`) {
		t.Fatalf("failed preparation stopped the active route: %v", err)
	}
	if !session.ResourcesPending() || len(session.routing.rules) != 1 || session.ctx.Err() != nil {
		t.Fatal("failed preparation changed active session state")
	}
}

func TestResourceDownloadMemoryBudgetPreservesOnlineSession(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.(http.Flusher).Flush()
		fmt.Fprint(w, "payload: ['example.invalid']")
	}))
	defer server.Close()
	config := fmt.Sprintf("rule-providers: {remote: {type: http, behavior: domain, url: '%s'}}\nrules: ['RULE-SET,remote,REJECT','MATCH,DIRECT']\n", server.URL)
	session, err := NewYAMLSessionWithDeferredResources(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	p, err := session.NewResourcePreparation(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	p.SetMemoryBudget(8)
	if err := p.Prepare(); err == nil || !strings.Contains(err.Error(), "memory budget") {
		t.Fatalf("unexpected download result: %v", err)
	}
	if _, err := session.RuntimeSnapshotJSON(); err != nil {
		t.Fatalf("active session stopped: %v", err)
	}
}
