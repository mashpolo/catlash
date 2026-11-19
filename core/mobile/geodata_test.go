package mobile

import (
	"net"
	"net/netip"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/geodata"
	G "github.com/metacubex/mihomo/component/geodata/router"
	C "github.com/metacubex/mihomo/constant"
	D "github.com/miekg/dns"
	"google.golang.org/protobuf/proto"
)

func geoIPFixture(t *testing.T) []byte {
	t.Helper()
	data, err := proto.Marshal(&G.GeoIPList{Entry: []*G.GeoIP{{CountryCode: "TEST", Cidr: []*G.CIDR{{Ip: netip.MustParseAddr("203.0.113.0").AsSlice(), Prefix: 24}, {Ip: netip.MustParseAddr("2001:db8::").AsSlice(), Prefix: 32}}}}})
	if err != nil {
		t.Fatal(err)
	}
	return data
}
func geoSiteFixture(t *testing.T) []byte {
	t.Helper()
	data, err := proto.Marshal(&G.GeoSiteList{Entry: []*G.GeoSite{{CountryCode: "TEST", Domain: []*G.Domain{{Type: G.Domain_Domain, Value: "example.invalid", Attribute: []*G.Domain_Attribute{{Key: "tag"}}}, {Type: G.Domain_Full, Value: "exact.invalid"}, {Type: G.Domain_Plain, Value: "keyword"}, {Type: G.Domain_Regex, Value: "^regex[0-9]+\\.invalid$"}}}}})
	if err != nil {
		t.Fatal(err)
	}
	return data
}
func TestGeoIPDatRoutesIPv4IPv6AndSource(t *testing.T) {
	root := bundleFixture(t, "geoip-dat", "default", geoIPFixture(t))
	for _, rule := range []string{"GEOIP,TEST,REJECT,no-resolve", "SRC-GEOIP,TEST,REJECT"} {
		session, err := NewYAMLSessionWithResources("geodata-mode: true\nrules: ['"+rule+"','MATCH,DIRECT']", "{}", root, 1280)
		if err != nil {
			t.Fatal(err)
		}
		for _, address := range []string{"203.0.113.8", "2001:db8::9"} {
			ip := netip.MustParseAddr(address)
			proxy, err := session.route(&C.Metadata{NetWork: C.TCP, SrcIP: ip, DstIP: ip, DstPort: 443})
			if err != nil || proxy.Name() != "REJECT" {
				t.Fatalf("geo route %v %v", proxy, err)
			}
		}
		session.Close()
	}
}
func TestGeoSiteDatDNSAndAttributeRule(t *testing.T) {
	root := bundleFixture(t, "geosite-dat", "default", geoSiteFixture(t))
	address := dnsFixture(t)
	config := dnsYAML(address, "fake-ip") + "rules: ['GEOSITE,test@tag,REJECT','MATCH,DIRECT']"
	config = strings.Replace(config, " enhanced-mode: fake-ip", " nameserver-policy: {'geosite:test': ['"+address+"']}\n fake-ip-filter: ['geosite:test']\n enhanced-mode: fake-ip", 1)
	session, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "sub.example.invalid.", D.TypeA)))
	answer := dnsAnswer(t, readWithDeadline(t, session)[28:])
	ip, _ := netip.AddrFromSlice(answer.Answer[0].(*D.A).A)
	if ip.Unmap().String() != "203.0.113.9" {
		t.Fatal("geosite fake-IP filter ignored")
	}
	proxy, err := session.route(&C.Metadata{NetWork: C.TCP, DstIP: ip.Unmap(), DstPort: 443})
	if err != nil || proxy.Name() != "REJECT" {
		t.Fatalf("geo site route %v %v", proxy, err)
	}
}
func TestGeoResourcesAreRequiredOnlyForRelevantRules(t *testing.T) {
	for _, config := range []string{"geodata-mode: true\nmode: direct", "geodata-mode: false\nrules: ['GEOIP,LAN,DIRECT','MATCH,REJECT']"} {
		s, err := NewYAMLSession(config, "{}", 1280)
		if err != nil {
			t.Fatal(err)
		}
		s.Close()
	}
	s, err := NewYAMLSession("geodata-mode: true\nrules: ['GEOIP,TEST,DIRECT']", "{}", 1280)
	if err == nil {
		s.Close()
		t.Fatal("missing GeoIP accepted")
	}
	if !strings.Contains(err.Error(), "geoip-dat") {
		t.Fatal(err)
	}
}

func TestGeodataBoundedParserAndNativeMatcherSemantics(t *testing.T) {
	data := geoSiteFixture(t)
	for _, algorithm := range []string{"succinct", "mph"} {
		matcher, err := geodata.NewMobileGeoSiteMatcher(data, "test", algorithm)
		if err != nil {
			t.Fatal(err)
		}
		for _, domain := range []string{"sub.example.invalid", "exact.invalid", "has-keyword.invalid", "regex12.invalid"} {
			if !matcher.ApplyDomain(domain) {
				t.Fatalf("%s did not match %s", algorithm, domain)
			}
		}
		tagged, err := geodata.NewMobileGeoSiteMatcher(data, "!test@tag", algorithm)
		if err != nil {
			t.Fatal(err)
		}
		if tagged.ApplyDomain("example.invalid") || !tagged.ApplyDomain("exact.invalid") {
			t.Fatal("attribute/inverse semantics changed")
		}
	}
	for _, bad := range [][]byte{{0x0a, 0xff, 0xff, 0xff, 0xff, 0x7f}, append([]byte{}, data[:len(data)-1]...), make([]byte, (16<<20)+1)} {
		if _, err := geodata.NewMobileGeoSiteMatcher(bad, "test", "succinct"); err == nil {
			t.Fatal("accepted corrupt or oversized geodata")
		}
	}
	invalid, _ := proto.Marshal(&G.GeoSiteList{Entry: []*G.GeoSite{{CountryCode: "TEST", Domain: []*G.Domain{{Type: 99, Value: "ignored.invalid"}}}}})
	if _, err := geodata.NewMobileGeoSiteMatcher(invalid, "test", "succinct"); err == nil {
		t.Fatal("silently skipped unknown domain type")
	}
}
func TestGeoDatDifferentSnapshotsDoNotShareMatchers(t *testing.T) {
	for i, network := range []string{"203.0.113.0", "198.51.100.0"} {
		data, _ := proto.Marshal(&G.GeoIPList{Entry: []*G.GeoIP{{CountryCode: "TEST", Cidr: []*G.CIDR{{Ip: netip.MustParseAddr(network).AsSlice(), Prefix: 24}}}}})
		root := bundleFixture(t, "geoip-dat", "default", data)
		session, err := NewYAMLSessionWithResources("geodata-mode: true\nrules: ['GEOIP,TEST,REJECT,no-resolve','MATCH,DIRECT']", "{}", root, 1280)
		if err != nil {
			t.Fatal(err)
		}
		proxy, err := session.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("203.0.113.9")})
		want := "REJECT"
		if i == 1 {
			want = "DIRECT"
		}
		if err != nil || proxy.Name() != want {
			t.Fatalf("stale matcher %v %v", proxy, err)
		}
		session.Close()
	}
}
func TestGeoIPDNSFallbackUsesBoundMatcher(t *testing.T) {
	root := bundleFixture(t, "geoip-dat", "default", geoIPFixture(t))
	address := dnsFixture(t)
	config := dnsYAML(address, "redir-host") + "geodata-mode: true\nrules: ['MATCH,REJECT']"
	config = strings.Replace(config, " enhanced-mode: redir-host", " fallback: ['"+address+"']\n fallback-filter: {geoip: true, geoip-code: TEST}\n enhanced-mode: redir-host", 1)
	session, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "fallback.invalid.", D.TypeA)))
	dnsAnswer(t, readWithDeadline(t, session)[28:])
}

func TestGeoIPMMDBDefaultModeAndASNRouteOwnership(t *testing.T) {
	for _, test := range []struct {
		kind, db, rule string
		record         []byte
	}{
		{"geoip-mmdb", "sing-geoip", "GEOIP,us,REJECT,no-resolve", mobileMMDBString("us")},
		{"asn-mmdb", "GeoLite2-ASN", "IP-ASN,64512,REJECT,no-resolve", mobileMMDBMap(mobileMMDBString("autonomous_system_number"), mobileMMDBUint(64512), mobileMMDBString("autonomous_system_organization"), mobileMMDBString("test"))},
	} {
		root := bundleFixture(t, test.kind, "default", mobileMMDBFixture(test.db, test.record))
		session, err := NewYAMLSessionWithResources("rules: ['"+test.rule+"','MATCH,DIRECT']", "{}", root, 1280)
		if err != nil {
			t.Fatal(err)
		}
		proxy, err := session.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("10.0.0.9"), DstPort: 443})
		if err != nil || proxy.Name() != "REJECT" {
			t.Fatalf("MMDB route %v %v", proxy, err)
		}
		geo := session.routing.geo
		session.Close()
		var result any
		if geo.ipReader != nil && geo.ipReader.Lookup(net.ParseIP("10.0.0.9"), &result) == nil {
			t.Fatal("IP reader survived session close")
		}
		if geo.asnReader != nil && geo.asnReader.Lookup(net.ParseIP("10.0.0.9"), &result) == nil {
			t.Fatal("ASN reader survived session close")
		}
	}
	datRoot := bundleFixture(t, "geoip-dat", "default", geoIPFixture(t))
	session, err := NewYAMLSessionWithResources("geodata-mode: false\nrules: ['GEOIP,TEST,DIRECT']", "{}", datRoot, 1280)
	if err == nil {
		session.Close()
		t.Fatal("false mode silently substituted dat")
	}
	if !strings.Contains(err.Error(), "geoip-mmdb") {
		t.Fatal(err)
	}
}
