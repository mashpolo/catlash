package mobile

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	M "github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"
)

func TestDNSHistoryRealQueryCacheClearAndSessionIsolation(t *testing.T) {
	var requests atomic.Int32
	socket, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &D.Server{PacketConn: socket, Handler: D.HandlerFunc(func(w D.ResponseWriter, q *D.Msg) {
		requests.Add(1)
		r := new(D.Msg)
		r.SetReply(q)
		r.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: q.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 300}, A: net.ParseIP("203.0.113.42")}}
		_ = w.WriteMsg(r)
	})}
	done := make(chan struct{})
	go func() { defer close(done); _ = server.ActivateAndServe() }()
	defer func() { _ = server.Shutdown(); _ = socket.Close(); <-done }()
	s, err := NewYAMLSession(dnsYAML(socket.LocalAddr().String(), "redir-host"), "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	query := func() {
		t.Helper()
		if err := s.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "history.invalid.", D.TypeA))); err != nil {
			t.Fatal(err)
		}
		dnsAnswer(t, readWithDeadline(t, s)[28:])
	}
	query()
	query()
	state := dnsHistorySnapshot(t, s)
	if len(state.DNSQueries) != 2 || state.DNSQueries[0].Cached || !state.DNSQueries[1].Cached {
		t.Fatalf("cache history: %+v", state.DNSQueries)
	}
	first := state.DNSQueries[0]
	if first.Initiator != "app" {
		t.Fatalf("packet DNS source lost: %q", first.Initiator)
	}
	if first.Domain != "history.invalid" || first.Type != "A" || first.Status != "success" || len(first.Answers) != 1 || first.Upstream == "" || first.DurationMS < 0 {
		t.Fatalf("query details: %+v", first)
	}
	if requests.Load() != 1 {
		t.Fatalf("cache missed: %d", requests.Load())
	}
	if err := s.ClearDNSCache("foreign"); err == nil {
		t.Fatal("foreign session cleared cache")
	}
	if err := s.ClearDNSCache(state.SessionID); err != nil {
		t.Fatal(err)
	}
	query()
	if requests.Load() != 2 {
		t.Fatalf("cache was not cleared: %d", requests.Load())
	}
	if len(dnsHistorySnapshot(t, s).DNSQueries) != 3 {
		t.Fatal("clearing cache removed history")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if err := s.ClearDNSCache(state.SessionID); err == nil {
		t.Fatal("closed session accepted cache clear")
	}
	next, err := NewYAMLSession(dnsYAML(socket.LocalAddr().String(), "redir-host"), "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	if len(dnsHistorySnapshot(t, next).DNSQueries) != 0 {
		t.Fatal("DNS history leaked across sessions")
	}
	if err := next.ClearDNSCache(state.SessionID); err == nil {
		t.Fatal("stale session accepted cache clear")
	}
}

func TestDNSHistoryHostsFakeIPAndBoundedDetails(t *testing.T) {
	s, err := NewYAMLSession(dnsYAML(dnsFixture(t), "fake-ip")+"hosts: {host.invalid: 203.0.113.7}\n", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, name := range []string{"host.invalid.", "fake.invalid."} {
		_, err := s.routing.dns.answer(dnsQuery(t, name, D.TypeA))
		if err != nil {
			t.Fatal(err)
		}
	}
	state := dnsHistorySnapshot(t, s)
	if len(state.DNSQueries) != 2 || state.DNSQueries[0].Mode != "hosts" || state.DNSQueries[1].Mode != "fakeip" {
		t.Fatalf("short circuit history: %+v", state.DNSQueries)
	}
	before := state.DNSQueries[1].Answers[0]
	if err := s.ClearDNSCache(state.SessionID); err != nil {
		t.Fatal(err)
	}
	_, _ = s.routing.dns.answer(dnsQuery(t, "fake.invalid.", D.TypeA))
	if dnsHistorySnapshot(t, s).DNSQueries[2].Answers[0] != before {
		t.Fatal("cache clear changed fake-IP mapping")
	}
	for i := 0; i < runtimeDNSLimit+5; i++ {
		_, _ = s.routing.dns.answer(dnsQuery(t, fmt.Sprintf("bounded%d.invalid.", i), D.TypeA))
	}
	state = dnsHistorySnapshot(t, s)
	if len(state.DNSQueries) != runtimeDNSLimit || state.DroppedDNSQueries != 8 {
		t.Fatalf("history bounds: %d, dropped %d", len(state.DNSQueries), state.DroppedDNSQueries)
	}
	oldCount := len(state.DNSQueries)
	if _, err := s.routing.dns.answer([]byte{1, 2}); err == nil {
		t.Fatal("invalid DNS packet accepted")
	}
	if len(dnsHistorySnapshot(t, s).DNSQueries) != oldCount {
		t.Fatal("malformed packet fabricated history")
	}
}

func TestDNSHistoryCancelledQueryAndInternalLookup(t *testing.T) {
	socket, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	arrived := make(chan struct{})
	go func() { buffer := make([]byte, 2048); _, _, _ = socket.ReadFrom(buffer); close(arrived) }()
	s, err := NewYAMLSession(dnsYAML(socket.LocalAddr().String(), "redir-host"), "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = (&sessionResolver{}).LookupIPv4(context.Background(), "cancel.invalid")
	}()
	select {
	case <-arrived:
	case <-time.After(time.Second):
		t.Fatal("lookup did not reach DNS endpoint")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("lookup survived session close")
	}
	state := dnsHistorySnapshot(t, s)
	if len(state.DNSQueries) == 0 || state.DNSQueries[0].Status != "cancelled" {
		t.Fatalf("cancel history: %+v", state.DNSQueries)
	}
}

func TestDNSHistoryBoundsAndRedactsUpstream(t *testing.T) {
	tm := newRuntimeTelemetry()
	defer tm.stopLogs()
	msg := new(D.Msg)
	for i := 0; i < 20; i++ {
		msg.Answer = append(msg.Answer, &D.TXT{Hdr: D.RR_Header{Name: "test.invalid.", Rrtype: D.TypeTXT}, Txt: []string{"token=private-value"}})
	}
	tm.addDNS(M.QueryRecord{Question: D.Question{Name: "test.invalid.", Qtype: D.TypeTXT}, Msg: msg, Upstream: "https://user:secret@resolver.invalid/private-path?token=secret", Start: time.Now()})
	data, _ := json.Marshal(tm.dnsQueries)
	if len(tm.dnsQueries[0].Answers) != 8 || tm.dnsQueries[0].OmittedAnswers != 12 || string(data) == "" {
		t.Fatal("answer limit not enforced")
	}
	for _, secret := range []string{"private-value", "private-path", "user:secret", "token=secret"} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("history leaked %s", secret)
		}
	}
	for i := range msg.Answer {
		msg.Answer[i].(*D.TXT).Txt = []string{strings.Repeat("\x01", 100)}
	}
	for range runtimeDNSLimit + 5 {
		tm.addDNS(M.QueryRecord{Question: D.Question{Name: strings.Repeat("\x01", 256), Qtype: D.TypeTXT}, Upstream: strings.Repeat("\x01", 256), Msg: msg, Start: time.Now()})
	}
	encoded, err := (&Session{telemetry: tm}).RuntimeSnapshotJSON()
	if err != nil || len(encoded) > 900_000 {
		t.Fatalf("DNS exceeded control response budget: %d %v", len(encoded), err)
	}
	var state runtimeSnapshotData
	if err := json.Unmarshal([]byte(encoded), &state); err != nil {
		t.Fatal(err)
	}
	if state.DroppedDNSQueries <= 6 || len(state.DNSQueries) == 0 {
		t.Fatal("oversized DNS response did not report omitted records")
	}
}

func dnsHistorySnapshot(t *testing.T, s *Session) runtimeSnapshotData {
	t.Helper()
	value, err := s.RuntimeSnapshotJSON()
	if err != nil {
		t.Fatal(err)
	}
	var state runtimeSnapshotData
	if err := json.Unmarshal([]byte(value), &state); err != nil {
		t.Fatal(err)
	}
	return state
}
