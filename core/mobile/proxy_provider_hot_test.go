package mobile

import (
	"context"
	"fmt"
	C "github.com/metacubex/mihomo/constant"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestHotProxyReplacesProviderGroupsAndRetainsSelection(t *testing.T) {
	var payload atomic.Value
	payload.Store("proxies: [{name: old, type: direct}, {name: stable, type: direct}]")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, payload.Load().(string)) }))
	defer server.Close()
	value := fmt.Sprintf(`proxy-providers:
  remote: {type: http, url: %q, proxy: DIRECT}
  other: {type: inline, payload: [{name: local, type: direct}]}
proxy-groups:
- {name: Selection, type: select, use: [remote]}
- {name: Explicit, type: select, proxies: [stable]}
- {name: All, type: select, include-all-providers: true}
rules: ['MATCH,Selection']`, server.URL)
	root := t.TempDir()
	s, err := NewYAMLSessionWithStorage(value, `{"Selection":"old","GLOBAL":"stable"}`, "", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	refresh := func(body string) error {
		payload.Store(body)
		p, err := s.NewProviderUpdate(value, "", root, "proxy-provider", "remote")
		if err != nil {
			return err
		}
		return p.UpdateProvider()
	}
	before := s.routing.proxies["local"]
	oldStable := s.routing.proxies["stable"]
	peer := netip.MustParseAddrPort(server.Listener.Addr().String())
	metadata := &C.Metadata{NetWork: C.TCP, DstIP: peer.Addr(), DstPort: peer.Port()}
	flow, err := oldStable.DialContext(context.Background(), metadata)
	if err != nil {
		t.Fatal(err)
	}
	defer flow.Close()
	_ = flow.SetDeadline(time.Now().Add(4 * time.Second))
	if err := refresh("proxies: [{name: new, type: direct}, {name: stable, type: reject}]"); err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(flow, "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"); err != nil {
		t.Fatal(err)
	}
	reply, err := io.ReadAll(flow)
	if err != nil || !strings.Contains(string(reply), "HTTP/1.1 200") {
		t.Fatalf("old provider connection lost: %s %v", reply, err)
	}
	if s.routing.groups["Explicit"].Proxies()[0].Type() != C.Reject {
		t.Fatal("new traffic did not use replacement node")
	}
	if s.routing.proxies["old"] != nil || s.routing.proxies["local"] != before || s.routing.proxies["stable"] == oldStable {
		t.Fatal("incorrect provider replacement")
	}
	if s.routing.groups["Selection"].Now() != "new" || s.routing.groups["GLOBAL"].Now() != "stable" {
		t.Fatal("invalid selection after replacement")
	}
	if s.routing.groups["Explicit"].Proxies()[0] != s.routing.proxies["stable"] {
		t.Fatal("explicit group kept old adapter")
	}
	for _, name := range []string{"All", "GLOBAL"} {
		if err := s.SelectProxy(name, "new"); err != nil {
			t.Fatal(err)
		}
	}
	if err := refresh("proxies: [{name: bad, type: direct}]"); err == nil {
		t.Fatal("accepted a provider missing an explicit member")
	}
	if s.routing.proxies["stable"] == nil || s.routing.groups["All"].Now() != "new" {
		t.Fatal("failed replacement changed active graph")
	}
	s.Close()
	reopened, err := NewYAMLSessionWithStorage(value, `{"Selection":"old"}`, "", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if reopened.routing.groups["Selection"].Now() != "new" {
		t.Fatal("cached update did not survive reopen")
	}
}

// A group-level health check must follow the replaced provider. An older job may
// have just finished its initial pass and otherwise sleep for the whole interval.
func TestHotProxyHealthChecksUseNewNodes(t *testing.T) {
	checked := make(chan struct{}, 4)
	var payload atomic.Value
	payload.Store("proxies: [{name: withheld, type: reject}]")
	httpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/health" {
			select {
			case checked <- struct{}{}:
			default:
			}
			w.WriteHeader(204)
			return
		}
		io.WriteString(w, payload.Load().(string))
	}))
	defer httpServer.Close()
	value := fmt.Sprintf(`proxy-providers:
  remote: {type: http, url: %q}
proxy-groups:
- {name: Monitor, type: url-test, use: [remote], interval: 86400, url: %q}
rules: ['MATCH,Monitor']`, httpServer.URL, httpServer.URL+"/health")
	s, err := NewYAMLSessionWithStorage(value, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	payload.Store("proxies: [{name: replacement, type: direct}]")
	p, err := s.NewProviderUpdate(value, "", "", "proxy-provider", "remote")
	if err != nil {
		t.Fatal(err)
	}
	if err = p.UpdateProvider(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-checked:
	case <-time.After(4 * time.Second):
		t.Fatal("health check did not reach the replacement node")
	}
	if s.routing.groups["Monitor"].Now() != "replacement" {
		t.Fatal("automatic choice kept the retired proxy")
	}
}
