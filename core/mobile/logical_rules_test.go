package mobile

import (
	"net/netip"
	"strings"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	D "github.com/miekg/dns"
)

func TestLogicalRulesRouteWithNestedPredicates(t *testing.T) {
	config := `rules:
 - 'AND,((NETWORK,TCP),(OR,((IP-CIDR,203.0.113.0/24,no-resolve),(DST-PORT,443)))),REJECT'
 - 'NOT,((NETWORK,TCP)),REJECT'
 - 'MATCH,DIRECT'
`
	s, err := NewYAMLSession(config, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, tc := range []struct {
		network C.NetWork
		ip      string
		port    uint16
		target  string
	}{
		{C.TCP, "203.0.113.8", 80, "REJECT"}, {C.TCP, "192.0.2.8", 443, "REJECT"}, {C.TCP, "192.0.2.8", 80, "DIRECT"}, {C.UDP, "192.0.2.8", 80, "REJECT"},
	} {
		proxy, err := s.route(&C.Metadata{NetWork: tc.network, DstIP: netip.MustParseAddr(tc.ip), DstPort: tc.port})
		if err != nil || proxy.Name() != tc.target {
			t.Fatalf("route %v %v", proxy, err)
		}
	}
}

func TestSubRulesRouteAndRejectReferenceCycles(t *testing.T) {
	config := `sub-rules:
 first: ['SUB-RULE,(DST-PORT,443),second', 'MATCH,DIRECT']
 second: ['IP-CIDR,203.0.113.0/24,REJECT,no-resolve']
rules: ['SUB-RULE,(NETWORK,TCP),first', 'MATCH,DIRECT']
`
	s, err := NewYAMLSession(config, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	proxy, err := s.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("203.0.113.8"), DstPort: 443})
	s.Close()
	if err != nil || proxy.Name() != "REJECT" {
		t.Fatalf("sub route %v %v", proxy, err)
	}
	for _, value := range []string{
		"sub-rules: {unused: ['SUB-RULE,(NETWORK,TCP),unused']}\nmode: direct",
		"sub-rules: {a: ['SUB-RULE,(NETWORK,TCP),b'], b: ['SUB-RULE,(NETWORK,TCP),a']}\nmode: direct",
		"rules: ['SUB-RULE,(NETWORK,TCP),missing']",
		"sub-rules: {a: ['MATCH,missing']}\nmode: direct",
		"rules: ['AND,((PROCESS-NAEM,anything)),DIRECT']",
		"rules: ['AND,((IP-CIDR,203.0.113.0/24,unknown)),DIRECT']",
	} {
		if s, err := NewYAMLSession(value, "{}", 1280); err == nil {
			s.Close()
			t.Fatalf("accepted invalid logical rule %s", value)
		}
	}
}

func TestLogicalGeoProviderAndUnusedSubRuleRequireBoundResource(t *testing.T) {
	root := bundleFixture(t, "geoip-dat", "default", geoIPFixture(t))
	config := `geodata-mode: true
rule-providers:
 local: {type: inline, behavior: classical, payload: ['AND,((GEOIP,TEST,no-resolve),(NETWORK,TCP))']}
rules: ['RULE-SET,local,REJECT', 'MATCH,DIRECT']
`
	s, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	proxy, err := s.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("203.0.113.9"), DstPort: 443})
	s.Close()
	if err != nil || proxy.Name() != "REJECT" {
		t.Fatalf("provider route %v %v", proxy, err)
	}
	_, err = NewYAMLSession("geodata-mode: true\nsub-rules: {unused: ['AND,((GEOIP,TEST)),DIRECT']}\nmode: direct", "{}", 1280)
	if err == nil || !strings.Contains(err.Error(), "geoip-dat") {
		t.Fatalf("missing resource diagnostic: %v", err)
	}
}

func TestDomainRegexCommaAndDNSLogicalFakeIPFilter(t *testing.T) {
	root := bundleFixture(t, "geosite-dat", "default", geoSiteFixture(t))
	config := dnsYAML(dnsFixture(t), "fake-ip") + "rules: ['DOMAIN-REGEX,^host[0-9]{1,3}\\.invalid$,REJECT','MATCH,DIRECT']"
	config = strings.Replace(config, " enhanced-mode: fake-ip", " fake-ip-filter-mode: rule\n fake-ip-filter: ['AND,((GEOSITE,TEST),(NOT,((DOMAIN,except.example.invalid)))),real-ip', 'MATCH,fake-ip']\n enhanced-mode: fake-ip", 1)
	s, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	proxy, err := s.route(&C.Metadata{NetWork: C.TCP, Host: "host12.invalid", DstPort: 443})
	if err != nil || proxy.Name() != "REJECT" {
		t.Fatalf("regex route %v %v", proxy, err)
	}
	for _, tc := range []struct {
		name string
		fake bool
	}{{"sub.example.invalid.", false}, {"except.example.invalid.", true}} {
		if err := s.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, tc.name, D.TypeA))); err != nil {
			t.Fatal(err)
		}
		answer := dnsAnswer(t, readWithDeadline(t, s)[28:])
		address := answer.Answer[0].(*D.A).A.String()
		if strings.HasPrefix(address, "198.18.") != tc.fake {
			t.Fatalf("DNS %s got %s", tc.name, address)
		}
	}
}

func TestDNSLogicalRuleSetUsesSessionProvider(t *testing.T) {
	config := dnsYAML(dnsFixture(t), "fake-ip") + "rule-providers: {domains: {type: inline, behavior: domain, payload: ['+.example.invalid']}}\nrules: ['MATCH,DIRECT']"
	config = strings.Replace(config, " enhanced-mode: fake-ip", " fake-ip-filter-mode: rule\n fake-ip-filter: ['AND,((RULE-SET,domains),(DOMAIN-SUFFIX,example.invalid)),real-ip', 'MATCH,fake-ip']\n enhanced-mode: fake-ip", 1)
	s, err := NewYAMLSession(config, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "sub.example.invalid.", D.TypeA))); err != nil {
		s.Close()
		t.Fatal(err)
	}
	answer := dnsAnswer(t, readWithDeadline(t, s)[28:])
	s.Close()
	if address := answer.Answer[0].(*D.A).A.String(); address != "203.0.113.9" {
		t.Fatalf("nested RuleSet did not use session provider: %s", address)
	}
	invalid := strings.Replace(config, "(DOMAIN-SUFFIX,example.invalid)", "(IP-CIDR,203.0.113.0/24)", 1)
	if session, err := NewYAMLSession(invalid, "{}", 1280); err == nil {
		session.Close()
		t.Fatal("accepted IP predicate in DNS domain policy")
	}
}

func TestLogicalRuleLimitsAndClassicalRestrictions(t *testing.T) {
	deep := "NOT," + strings.Repeat("(", 65) + "NETWORK,TCP" + strings.Repeat(")", 65) + ",DIRECT"
	if s, err := NewYAMLSession("rules: ['"+deep+"']", "{}", 1280); err == nil {
		s.Close()
		t.Fatal("accepted excessive logical nesting")
	} else if !strings.Contains(err.Error(), "limit") {
		t.Fatalf("wrong limit error: %v", err)
	}
	for _, payload := range []string{"AND,((RULE-SET,other))", "AND,((MATCH,DIRECT))", "AND,((SUB-RULE,(NETWORK,TCP),other))"} {
		config := "rule-providers: {local: {type: inline, behavior: classical, payload: ['" + payload + "']}}\nrules: ['MATCH,DIRECT']"
		if s, err := NewYAMLSession(config, "{}", 1280); err == nil {
			s.Close()
			t.Fatalf("accepted classical predicate %s", payload)
		}
	}
}
