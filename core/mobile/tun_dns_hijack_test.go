package mobile

import (
	"bytes"
	"fmt"
	"net/netip"
	"strings"
	"testing"

	D "github.com/miekg/dns"
)

func TestTUNDNSHijackMatchesProtocolAddressAndPort(t *testing.T) {
	config, err := parseYAML("tun: {auto-route: true, auto-detect-interface: true, dns-hijack: ['udp://any:5353', 'tcp://[2001:db8::1]:53']}\n")
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range []struct {
		network, destination string
		want                 bool
	}{
		{"udp", "203.0.113.1:5353", true}, {"tcp", "203.0.113.1:5353", false},
		{"udp", "203.0.113.1:53", false}, {"tcp", "[2001:db8::1]:53", true},
		{"udp", "[2001:db8::1]:53", false}, {"tcp", "[2001:db8::2]:53", false},
		{"tcp", "198.18.0.1:53", true}, {"udp", "[fd00:198:18::1]:53", true},
	} {
		if got := config.DNSHijack.matches(item.network, netip.MustParseAddrPort(item.destination)); got != item.want {
			t.Errorf("%s %s: %v", item.network, item.destination, got)
		}
	}
	for _, yaml := range []string{"tun: {dns-hijack: ['https://any:53']}", "tun: {dns-hijack: ['any:0']}", "tun: {dns-hijack: ['example.com:53']}"} {
		if _, err := parseYAML(yaml); err == nil {
			t.Errorf("accepted unsupported mapping: %s", yaml)
		}
	}
}

func TestTUNDNSHijackEmptyListKeepsOnlySystemDNS(t *testing.T) {
	for _, item := range []struct {
		yaml     string
		external bool
	}{
		{"mode: rule", true}, {"tun: {dns-hijack: []}", false},
	} {
		config, err := parseYAML(item.yaml)
		if err != nil {
			t.Fatal(err)
		}
		for _, network := range []string{"tcp", "udp"} {
			if config.DNSHijack.matches(network, netip.MustParseAddrPort("203.0.113.1:53")) != item.external {
				t.Fatalf("incorrect explicit/default hijack: %s", item.yaml)
			}
			if !config.DNSHijack.matches(network, netip.MustParseAddrPort("198.18.0.1:53")) {
				t.Fatal("system DNS lost")
			}
		}
	}
}

func TestTUNDNSHijackDoesNotInterceptOtherDestination(t *testing.T) {
	address := dnsFixture(t)
	port := udpSOCKSFixture(t, "forwarded")
	for _, network := range []string{"tcp", "udp"} {
		t.Run(network, func(t *testing.T) {
			yaml := dnsYAML(address, "fake-ip") + fmt.Sprintf("tun: {dns-hijack: ['%s://203.0.113.1:53']}\nproxies: [{name: fixture, type: socks5, server: 127.0.0.1, port: %d, udp: true}]\nrules: ['MATCH,fixture']\n", network, port)
			s, err := NewYAMLSession(yaml, "{}", 1280)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			query := dnsQuery(t, "hijack.invalid.", D.TypeA)
			if err := s.WritePacket(udpPacket(netip.MustParseAddr("203.0.113.1"), 53, query)); err != nil {
				t.Fatal(err)
			}
			reply := readWithDeadline(t, s)[28:]
			if network == "tcp" {
				if !bytes.Equal(reply, append([]byte("forwarded:"), query...)) {
					t.Fatal("nonmatching UDP was intercepted")
				}
				return
			}
			answer := dnsAnswer(t, reply).Answer[0].(*D.A).A.String()
			if !strings.HasPrefix(answer, "198.18.") {
				t.Fatalf("matching UDP was not intercepted: %s", answer)
			}
		})
	}
}
