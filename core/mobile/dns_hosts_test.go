package mobile

import (
	"context"
	"fmt"
	"net/netip"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/resolver/hosts"
	MConfig "github.com/metacubex/mihomo/config"
	D "github.com/miekg/dns"
)

func TestYAMLHostsRejectsAliasCycles(t *testing.T) {
	for _, entries := range []map[string]any{
		{"self.invalid": "self.invalid"},
		{"a.invalid": "b.invalid", "b.invalid": "a.invalid"},
		{"*.wild.invalid": "loop.wild.invalid"},
		{".wild.invalid": "loop.wild.invalid"},
		{"+.wild.invalid": "loop.wild.invalid"},
	} {
		raw := MConfig.DefaultRawConfig()
		raw.Hosts = entries
		if _, err := MConfig.ParseMobileHosts(raw); err == nil {
			t.Fatal("cyclic hosts aliases were accepted")
		}
	}
}

func TestYAMLHostsDNSAndOutboundResolution(t *testing.T) {
	for _, mode := range []string{"redir-host", "fake-ip"} {
		t.Run(mode, func(t *testing.T) {
			yaml := dnsYAML(dnsFixture(t), mode) + "hosts:\n 'mapped.invalid': [192.0.2.42, '2001:db8::42']\n '*.wild.invalid': 192.0.2.43\n 'alias.invalid': mapped.invalid\nrules: ['MATCH,DIRECT']\n"
			session, err := NewYAMLSession(yaml, "{}", 1280)
			if err != nil {
				t.Fatal(err)
			}
			defer session.Close()
			for _, test := range []struct {
				name     string
				kind     uint16
				expected string
			}{
				{"mapped.invalid.", D.TypeA, "192.0.2.42"},
				{"mapped.invalid.", D.TypeAAAA, "2001:db8::42"},
				{"child.wild.invalid.", D.TypeA, "192.0.2.43"},
				{"alias.invalid.", D.TypeA, "192.0.2.42"},
			} {
				if err := session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, test.name, test.kind))); err != nil {
					t.Fatal(err)
				}
				response := dnsAnswer(t, readWithDeadline(t, session)[28:])
				if !strings.HasSuffix(response.Answer[0].String(), "\t"+test.expected) {
					t.Fatal(response)
				}
			}
			ips, err := resolver.LookupIPv4(context.Background(), "mapped.invalid")
			if err != nil || len(ips) != 1 || ips[0].String() != "192.0.2.42" {
				t.Fatalf("outbound hosts lookup: %v %v", ips, err)
			}
		})
	}
}

func TestYAMLHostsUseHostsAndSessionIsolation(t *testing.T) {
	address := dnsFixture(t)
	for _, enabled := range []bool{true, false} {
		yaml := strings.Replace(dnsYAML(address, "redir-host"), " enable: true", fmt.Sprintf(" enable: true\n use-hosts: %t", enabled), 1) + "hosts: {mapped.invalid: 192.0.2.42}\nrules: ['MATCH,DIRECT']"
		session, err := NewYAMLSession(yaml, "{}", 1280)
		if err != nil {
			t.Fatal(err)
		}
		session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "mapped.invalid.", D.TypeA)))
		response := dnsAnswer(t, readWithDeadline(t, session)[28:])
		expected := "203.0.113.9"
		if enabled {
			expected = "192.0.2.42"
		}
		if response.Answer[0].(*D.A).A.String() != expected {
			t.Fatal(response)
		}
		session.Close()
		if value, ok := resolver.DefaultHosts.Search("mapped.invalid", false); value != nil || ok {
			t.Fatal("closed session retained hosts")
		}
	}
	session, err := NewYAMLSession(dnsYAML(address, "redir-host")+"rules: ['MATCH,DIRECT']", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "mapped.invalid.", D.TypeA)))
	if response := dnsAnswer(t, readWithDeadline(t, session)[28:]); response.Answer[0].(*D.A).A.String() != "203.0.113.9" {
		t.Fatal(response)
	}
}

func TestYAMLSystemHostsAndDNSListen(t *testing.T) {
	addresses, _ := hosts.LookupStaticHost("broadcasthost")
	if len(addresses) == 0 {
		t.Skip("system hosts has no broadcasthost fixture")
	}
	for _, enabled := range []bool{true, false} {
		yaml := strings.Replace(dnsYAML(dnsFixture(t), "redir-host"), " enable: true", fmt.Sprintf(" enable: true\n use-system-hosts: %t\n listen: 127.0.0.1:1053", enabled), 1) + "rules: ['MATCH,DIRECT']"
		session, err := NewYAMLSession(yaml, "{}", 1280)
		if err != nil {
			t.Fatal(err)
		}
		session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "broadcasthost.", D.TypeA)))
		response := dnsAnswer(t, readWithDeadline(t, session)[28:])
		expected := "203.0.113.9"
		if enabled {
			expected = addresses[0]
		}
		if response.Answer[0].(*D.A).A.String() != expected {
			t.Fatal(response)
		}
		catalog, err := session.ProxiesJSON()
		if err != nil || !strings.Contains(catalog, "dns.listen") {
			t.Fatalf("listen explanation missing: %v %s", err, catalog)
		}
		session.Close()
	}
}
