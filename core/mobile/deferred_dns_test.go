package mobile

import (
	"bytes"
	"fmt"
	"net/netip"
	"reflect"
	"strings"
	"testing"

	D "github.com/miekg/dns"
	"go.yaml.in/yaml/v3"
)

func TestDeferredDNSStartsWithMissingPoliciesAndFallbackGeo(t *testing.T) {
	address := dnsFixture(t)
	config := dnsYAML(address, "redir-host") + fmt.Sprintf(` fallback: ['%s']
 fallback-filter: {geoip: true, geoip-code: TEST, geosite: [test]}
 nameserver-policy: {'geosite:test': ['%s'], 'rule-set:remote': ['%s'], 'bridge.invalid': ['%s']}
 proxy-server-nameserver: ['%s']
 proxy-server-nameserver-policy: {'rule-set:remote': ['%s']}
rule-providers: {remote: {type: http, behavior: domain, url: 'https://never.invalid/rules'}}
rules: ['MATCH,REJECT']
`, address, address, address, address, address, address)
	if session, err := NewYAMLSession(config, "{}", 1280); err == nil {
		session.Close()
		t.Fatal("strict entry accepted missing DNS resources")
	}
	session, err := NewYAMLSessionWithDeferredResources(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if !session.ResourcesPending() {
		t.Fatal("missing DNS resources were not reported")
	}
	if err := session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "bridge.invalid.", D.TypeA))); err != nil {
		t.Fatal(err)
	}
	answer := dnsAnswer(t, readWithDeadline(t, session)[28:])
	if answer.Answer[0].(*D.A).A.String() != "203.0.113.9" {
		t.Fatal("configured DNS did not answer", answer)
	}
}

func TestDeferredDNSFakeIPDefersWholeLogicalFilter(t *testing.T) {
	for _, filter := range []string{
		" fake-ip-filter: ['geosite:test', 'rule-set:remote']\n",
		" fake-ip-filter-mode: rule\n fake-ip-filter: ['NOT,((GEOSITE,test)),real-ip', 'NOT,((RULE-SET,remote)),real-ip', 'MATCH,fake-ip']\n",
	} {
		config := dnsYAML(dnsFixture(t), "fake-ip") + filter + "rule-providers: {remote: {type: http, behavior: domain, url: 'https://never.invalid/rules'}}\nrules: ['MATCH,REJECT']"
		session, err := NewYAMLSessionWithDeferredResources(config, "{}", "", "", 1280)
		if err != nil {
			t.Fatal(err)
		}
		if err := session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "bridge.invalid.", D.TypeA))); err != nil {
			t.Fatal(err)
		}
		answer := dnsAnswer(t, readWithDeadline(t, session)[28:])
		if !strings.HasPrefix(answer.Answer[0].(*D.A).A.String(), "198.18.") {
			t.Fatal("missing dependency changed NOT into a matching real-IP filter", answer)
		}
		session.Close()
	}
}

func TestDeferredDNSAvailableGeoPreservesPolicyAndFakeIPFilter(t *testing.T) {
	address := dnsFixture(t)
	config := dnsYAML(address, "fake-ip") + fmt.Sprintf(" nameserver-policy: {'geosite:test': ['%s']}\n fake-ip-filter: ['geosite:test']\nrules: ['MATCH,REJECT']", address)
	root := bundleFixture(t, "geosite-dat", "default", geoSiteFixture(t))
	session, err := NewYAMLSessionWithDeferredResources(config, "{}", root, "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if session.ResourcesPending() {
		t.Fatal("available resources or unused default fallback marked pending")
	}
	if err := session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "sub.example.invalid.", D.TypeA))); err != nil {
		t.Fatal(err)
	}
	answer := dnsAnswer(t, readWithDeadline(t, session)[28:])
	if answer.Answer[0].(*D.A).A.String() != "203.0.113.9" {
		t.Fatal("available filter was discarded", answer)
	}
}

func TestDeferredDNSOnlyChangesPrivateDependencyCopy(t *testing.T) {
	config, err := parseYAML(`dns:
 enable: true
 enhanced-mode: fake-ip
 nameserver: ['https://1.1.1.1/dns-query#Final']
 default-nameserver: [1.1.1.1]
 proxy-server-nameserver: [8.8.8.8]
 nameserver-policy: {'geosite:test': [1.1.1.1], 'rule-set:remote': [1.1.1.1], 'example.invalid': [8.8.8.8]}
 proxy-server-nameserver-policy: {'rule-set:remote': [1.1.1.1], 'bootstrap.invalid': [8.8.8.8]}
 fake-ip-filter: ['geosite:test', 'rule-set:remote', '*.lan']
 fallback: [9.9.9.9]
 fallback-filter: {geoip: true, geosite: [test], domain: ['+.local'], ipcidr: [240.0.0.0/4]}
`)
	if err != nil {
		t.Fatal(err)
	}
	before, err := yaml.Marshal(config.Raw)
	if err != nil {
		t.Fatal(err)
	}
	routing := &routingConfiguration{geo: &geoRuntime{}, deferredProviders: map[string]bool{"remote": true}}
	filtered, pending, err := routing.deferredDNSConfiguration(config)
	if err != nil || !pending {
		t.Fatalf("deferred copy: pending=%v error=%v", pending, err)
	}
	after, err := yaml.Marshal(config.Raw)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("deferred startup modified original configuration", err)
	}
	original, actual := config.Raw.DNS, filtered.Raw.DNS
	if !reflect.DeepEqual(actual.NameServer, original.NameServer) || !reflect.DeepEqual(actual.ProxyServerNameserver, original.ProxyServerNameserver) || actual.EnhancedMode != original.EnhancedMode {
		t.Fatal("deferred startup changed configured DNS proxy, bootstrap servers or mode")
	}
	if actual.NameServerPolicy.Len() != 1 || actual.ProxyServerNameserverPolicy.Len() != 1 || !reflect.DeepEqual(actual.FakeIPFilter, []string{"*.lan"}) {
		t.Fatal("local DNS policies or fake-IP filter were discarded")
	}
	if actual.FallbackFilter.GeoIP || len(actual.FallbackFilter.GeoSite) != 0 || !reflect.DeepEqual(actual.FallbackFilter.Domain, original.FallbackFilter.Domain) || !reflect.DeepEqual(actual.FallbackFilter.IPCIDR, original.FallbackFilter.IPCIDR) {
		t.Fatal("fallback copy did not preserve resource-independent filters")
	}
}

func TestDeferredDNSRejectsUnknownPolicyProvider(t *testing.T) {
	config := dnsYAML(dnsFixture(t), "redir-host") + " nameserver-policy: {'rule-set:unknown': [1.1.1.1]}\nrules: ['MATCH,REJECT']"
	if session, err := NewYAMLSessionWithDeferredResources(config, "{}", "", "", 1280); err == nil {
		session.Close()
		t.Fatal("unknown provider was treated as a pending download")
	}
}
