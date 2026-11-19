package mobile

import (
	"encoding/json"
	"fmt"
	"net"
	"sync/atomic"
	"testing"

	D "github.com/miekg/dns"
)

func TestExplicitSystemDNSUsesCapturedServersForRawQueries(t *testing.T) {
	old := systemDNSSnapshot.Swap(nil)
	defer systemDNSSnapshot.Store(old)
	packet, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var requests atomic.Int32
	server := &D.Server{PacketConn: packet, Handler: D.HandlerFunc(func(w D.ResponseWriter, q *D.Msg) {
		requests.Add(1)
		answer := new(D.Msg)
		answer.SetReply(q)
		if q.Question[0].Qtype == D.TypeTXT {
			answer.Answer = []D.RR{&D.TXT{Hdr: D.RR_Header{Name: q.Question[0].Name, Rrtype: D.TypeTXT, Class: D.ClassINET, Ttl: 1}, Txt: []string{"system-network-answer"}}}
		}
		w.WriteMsg(answer)
	})}
	go server.ActivateAndServe()
	defer server.Shutdown()
	encoded, _ := json.Marshal([]string{packet.LocalAddr().String()})
	if err = SetSystemDNSServersJSON(string(encoded)); err != nil {
		t.Fatal(err)
	}
	s, err := NewYAMLSession(dnsYAML("system://", "redir-host"), "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	// A later startup snapshot must not alter this already-created DNS runtime.
	if err = SetSystemDNSServersJSON("[]"); err != nil {
		t.Fatal(err)
	}
	raw, err := s.routing.dns.answer(dnsQuery(t, "raw-system.invalid.", D.TypeTXT))
	if err != nil {
		t.Fatal(err)
	}
	answer := new(D.Msg)
	if err = answer.Unpack(raw); err != nil {
		t.Fatal(err)
	}
	if len(answer.Answer) != 1 || answer.Answer[0].(*D.TXT).Txt[0] != "system-network-answer" || requests.Load() != 1 {
		t.Fatal("system raw DNS query did not reach captured network")
	}
}

func TestSystemDNSIsNotAddedToOrdinaryNameserversAndHonorsProxy(t *testing.T) {
	old := systemDNSSnapshot.Swap(nil)
	defer systemDNSSnapshot.Store(old)
	packet, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var requests atomic.Int32
	server := &D.Server{PacketConn: packet, Handler: D.HandlerFunc(func(w D.ResponseWriter, q *D.Msg) {
		requests.Add(1)
		reply := new(D.Msg)
		reply.SetReply(q)
		w.WriteMsg(reply)
	})}
	go server.ActivateAndServe()
	defer server.Shutdown()
	encoded, _ := json.Marshal([]string{packet.LocalAddr().String()})
	if err = SetSystemDNSServersJSON(string(encoded)); err != nil {
		t.Fatal(err)
	}
	s, err := NewYAMLSession(dnsYAML(dnsFixture(t), "redir-host"), "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.routing.dns.answer(dnsQuery(t, "ordinary.invalid.", D.TypeA)); err != nil {
		s.Close()
		t.Fatal(err)
	}
	s.Close()
	if requests.Load() != 0 {
		t.Fatal("system DNS was added without system://")
	}
	config := "dns: {enable: true, nameserver: ['system://#REJECT'], default-nameserver: ['127.0.0.1']}\nrules: ['MATCH,DIRECT']"
	s, err = NewYAMLSession(config, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	raw, err := s.routing.dns.answer(dnsQuery(t, "blocked-system.invalid.", D.TypeTXT))
	if err != nil {
		t.Fatal(err)
	}
	reply := new(D.Msg)
	reply.Unpack(raw)
	if reply.Rcode != D.RcodeServerFailure || requests.Load() != 0 {
		t.Fatal("system DNS bypassed its configured proxy")
	}
}

func TestSystemDNSRawQueryRetriesTruncatedUDPOverTCP(t *testing.T) {
	old := systemDNSSnapshot.Swap(nil)
	defer systemDNSSnapshot.Store(old)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	packet, err := net.ListenPacket("udp", listener.Addr().String())
	if err != nil {
		listener.Close()
		t.Fatal(err)
	}
	var udp, tcp atomic.Int32
	datagram := &D.Server{PacketConn: packet, Handler: D.HandlerFunc(func(w D.ResponseWriter, q *D.Msg) {
		udp.Add(1)
		reply := new(D.Msg)
		reply.SetReply(q)
		reply.Truncated = true
		w.WriteMsg(reply)
	})}
	stream := &D.Server{Listener: listener, Handler: D.HandlerFunc(func(w D.ResponseWriter, q *D.Msg) {
		tcp.Add(1)
		reply := new(D.Msg)
		reply.SetReply(q)
		record, _ := D.NewRR(fmt.Sprintf("%s 60 IN TXT \"tcp-system-answer\"", q.Question[0].Name))
		reply.Answer = []D.RR{record}
		w.WriteMsg(reply)
	})}
	go datagram.ActivateAndServe()
	go stream.ActivateAndServe()
	defer datagram.Shutdown()
	defer stream.Shutdown()
	encoded, _ := json.Marshal([]string{listener.Addr().String()})
	if err = SetSystemDNSServersJSON(string(encoded)); err != nil {
		t.Fatal(err)
	}
	s, err := NewYAMLSession(dnsYAML("system://", "redir-host"), "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	raw, err := s.routing.dns.answer(dnsQuery(t, "truncated-system.invalid.", D.TypeTXT))
	if err != nil {
		t.Fatal(err)
	}
	reply := new(D.Msg)
	if err = reply.Unpack(raw); err != nil {
		t.Fatal(err)
	}
	if len(reply.Answer) != 1 || reply.Answer[0].(*D.TXT).Txt[0] != "tcp-system-answer" || udp.Load() != 1 || tcp.Load() != 1 {
		t.Fatal("raw system DNS lost TCP retry")
	}
}

func TestEmptySystemDNSSnapshotDoesNotInventServers(t *testing.T) {
	old := systemDNSSnapshot.Swap(nil)
	defer systemDNSSnapshot.Store(old)
	if err := SetSystemDNSServersJSON("[]"); err != nil {
		t.Fatal(err)
	}
	s, err := NewYAMLSession(dnsYAML("system://", "redir-host"), "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	raw, err := s.routing.dns.answer(dnsQuery(t, "unavailable-system.invalid.", D.TypeTXT))
	if err != nil {
		t.Fatal(err)
	}
	reply := new(D.Msg)
	reply.Unpack(raw)
	if reply.Rcode != D.RcodeServerFailure {
		t.Fatal("empty network DNS snapshot unexpectedly answered")
	}
}
