package mobile

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	D "github.com/miekg/dns"
)

func TestHotRuleProviderChangesRunningRouteAndPreservesLastGood(t *testing.T) {
	var body atomic.Value
	body.Store("+.new.example\n+.another.example\n")
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sequence := calls.Add(1)
		w.Header().Set("Subscription-Userinfo", fmt.Sprintf("download=%d", 33+sequence))
		fmt.Fprint(w, body.Load().(string))
	}))
	defer server.Close()
	root := bundleFixture(t, "rule-provider", "domains", []byte("+.old.example\n"))
	state := t.TempDir()
	address := dnsFixture(t)
	dns := strings.Replace(dnsYAML(address, "fake-ip"), " enhanced-mode: fake-ip", " fake-ip-filter: ['rule-set:domains']\n enhanced-mode: fake-ip", 1)
	config := dns + fmt.Sprintf("rule-providers: {domains: {type: http, behavior: domain, format: text, url: '%s'}}\nrules: ['RULE-SET,domains,REJECT','MATCH,DIRECT']", server.URL)
	s, err := NewYAMLSessionWithStorage(config, "{}", root, state, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	route := func(host, want string) {
		t.Helper()
		got, err := s.route(&C.Metadata{NetWork: C.TCP, SniffHost: host, DstPort: 443})
		if err != nil || got.Name() != want {
			t.Fatalf("route %s = %v, %v; want %s", host, got, err, want)
		}
	}
	update := func() error {
		p, err := s.NewProviderUpdate(config, root, state, "rule-provider", "domains")
		if err != nil {
			return err
		}
		return p.UpdateProvider()
	}
	realDNS := func(host string) bool {
		t.Helper()
		if err := s.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, host+".", D.TypeA))); err != nil {
			t.Fatal(err)
		}
		answer := dnsAnswer(t, readWithDeadline(t, s)[28:])
		return answer.Answer[0].(*D.A).A.String() == "203.0.113.9"
	}
	if !realDNS("before.old.example") || realDNS("before.new.example") {
		t.Fatal("initial DNS policy does not match initial provider")
	}
	route("old.example", "REJECT")
	route("new.example", "DIRECT")
	if err := update(); err != nil {
		t.Fatal(err)
	}
	if realDNS("after.old.example") || !realDNS("after.new.example") {
		t.Fatal("DNS policy still uses old rule set")
	}
	route("old.example", "DIRECT")
	route("new.example", "REJECT")
	catalog, _ := s.ProvidersJSON()
	var rows []runtimeProvider
	if err := json.Unmarshal([]byte(catalog), &rows); err != nil || len(rows) != 1 || rows[0].UpdatedAt == nil || rows[0].Count == nil || *rows[0].Count != 2 || rows[0].Subscription["download"] != 34 {
		t.Fatal(catalog, err)
	}
	generation := s.routing.ruleProviders["domains"].(*liveRuleProvider).current.Load()
	if err := update(); err != nil {
		t.Fatal(err)
	}
	if generation != s.routing.ruleProviders["domains"].(*liveRuleProvider).current.Load() {
		t.Fatal("unchanged rule set was rebuilt")
	}
	catalog, _ = s.ProvidersJSON()
	if !strings.Contains(catalog, `"download":35`) {
		t.Fatal("new subscription usage missing", catalog)
	}
	body.Store("https://invalid.example/bad\n")
	if err := update(); err == nil {
		t.Fatal("invalid rule replaced active provider")
	}
	route("new.example", "REJECT")
	after, _ := s.ProvidersJSON()
	if after != catalog {
		t.Fatal("failed refresh altered provider metadata", after)
	}
	if _, err := s.NewProviderUpdate(strings.Replace(config, "MATCH,DIRECT", "MATCH,REJECT", 1), root, state, "rule-provider", "domains"); err == nil {
		t.Fatal("accepted another source configuration")
	}
	if calls.Load() != 3 {
		t.Fatalf("unexpected HTTP requests %d", calls.Load())
	}
}

func TestHotProviderCancellationKeepsSessionUsable(t *testing.T) {
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
	}))
	defer server.Close()
	root := bundleFixture(t, "rule-provider", "ips", []byte("192.0.2.0/24\n"))
	config := fmt.Sprintf("rule-providers: {ips: {type: http, behavior: ipcidr, format: text, url: '%s'}}\nrules: ['RULE-SET,ips,REJECT','MATCH,DIRECT']", server.URL)
	s, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	p, err := s.NewProviderUpdate(config, root, "", "rule-provider", "ips")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- p.UpdateProvider() }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		p.Cancel()
		t.Fatal("update did not reach source")
	}
	before, _ := s.ProvidersJSON()
	second, err := s.NewProviderUpdate(config, root, "", "rule-provider", "ips")
	if err != nil {
		t.Fatal(err)
	}
	if err = second.UpdateProvider(); err == nil {
		t.Fatal("concurrent refresh unexpectedly succeeded")
	}
	p.Cancel()
	select {
	case err = <-done:
		if err == nil {
			t.Fatal("cancelled update unexpectedly succeeded")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled refresh did not return")
	}
	after, err := s.ProvidersJSON()
	if err != nil || before != after {
		t.Fatal("active provider catalog lost on cancellation", after, err)
	}
}
