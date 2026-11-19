package mobile

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	M "github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"
)

func TestDirectExampleUsesPlatformDNSWhenPOSIXNameserversUnavailable(t *testing.T) {
	packet, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	dns := &D.Server{PacketConn: packet, Handler: D.HandlerFunc(func(w D.ResponseWriter, q *D.Msg) {
		answer := new(D.Msg)
		answer.SetReply(q)
		if q.Question[0].Qtype == D.TypeA {
			answer.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: q.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60}, A: net.ParseIP("127.0.0.1")}}
		}
		w.WriteMsg(answer)
	})}
	go dns.ActivateAndServe()
	defer dns.Shutdown()
	previous := net.DefaultResolver
	net.DefaultResolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "udp", packet.LocalAddr().String())
	}}
	defer func() { net.DefaultResolver = previous }()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, `{"ip":"203.0.113.7"}`) }))
	defer server.Close()
	endpoint := strings.Replace(server.URL, "127.0.0.1", "direct.example.invalid", 1)
	control := &http.Client{Transport: &http.Transport{DisableKeepAlives: true}}
	response, err := control.Get(endpoint)
	if err != nil {
		t.Fatal("platform lookup control failed", err)
	}
	response.Body.Close()
	value := `mode: rule
proxies: []
proxy-groups:
- {name: 默认出口, type: select, proxies: [DIRECT, REJECT]}
rules: ['MATCH,默认出口']`
	s, err := NewYAMLSession(value, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	// iOS has no usable POSIX resolv.conf; model that empty Mihomo client list.
	old := s.dnsOwner.runtime.Load().resolvers
	s.dnsOwner.runtime.Load().resolvers = M.NewResolver(M.Config{Context: s.dnsOwner.scope.Context(), IPv6: true})
	old.ResetConnection()
	result, err := s.exitIPJSON(endpoint, endpoint+"/v6", endpoint+"/")
	if err != nil || !strings.Contains(result, "203.0.113.7") {
		t.Fatalf("DIRECT ignored working platform DNS: %v", err)
	}
}
