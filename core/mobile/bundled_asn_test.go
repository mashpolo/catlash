package mobile

import (
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

func TestBundledASNRealLookupRoutesWithoutPendingResources(t *testing.T) {
	old := bundledGeoIPPath.Swap(nil)
	defer bundledGeoIPPath.Store(old)
	path, err := filepath.Abs("../../Resources/Geo/Country.mmdb")
	if err != nil {
		t.Fatal(err)
	}
	if err = SetBundledGeoIPPath(path); err != nil {
		t.Fatal(err)
	}
	session, err := NewYAMLSessionWithDeferredResources("rules: ['IP-ASN,15169,REJECT,no-resolve','MATCH,DIRECT']", "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if session.ResourcesPending() {
		t.Fatal("bundled ASN database was unnecessarily deferred for download")
	}
	for address, want := range map[string]string{"8.8.8.8": "REJECT", "2001:4860:4860::8888": "REJECT", "223.5.5.5": "DIRECT"} {
		proxy, err := session.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr(address), DstPort: 443})
		if err != nil || proxy.Name() != want {
			t.Fatalf("ASN route: %s got %v want %s (%v)", address, proxy, want, err)
		}
	}
	reader := session.routing.geo.asnReader
	if asn, name := reader.LookupASN(net.ParseIP("8.8.8.8")); asn != "15169" || name != "GOOGLE" {
		t.Fatalf("ASN lookup got %q %q", asn, name)
	}
	if asn, _ := reader.LookupASN(net.ParseIP("223.5.5.5")); asn != "45102" {
		t.Fatalf("ASN lookup got %q", asn)
	}
	session.Close()
	var result any
	if err = reader.Lookup(net.ParseIP("8.8.8.8"), &result); err == nil {
		t.Fatal("mapped ASN reader survived session close")
	}
}

func TestBundledASNExplicitResourceTakesPrecedence(t *testing.T) {
	old := bundledGeoIPPath.Swap(nil)
	defer bundledGeoIPPath.Store(old)
	path, err := filepath.Abs("../../Resources/Geo/Country.mmdb")
	if err != nil {
		t.Fatal(err)
	}
	if err = SetBundledGeoIPPath(path); err != nil {
		t.Fatal(err)
	}
	root := bundleFixture(t, "asn-mmdb", "default", mobileMMDBFixture("GeoLite2-ASN", mobileMMDBMap(mobileMMDBString("autonomous_system_number"), mobileMMDBUint(64512), mobileMMDBString("autonomous_system_organization"), mobileMMDBString("explicit fixture"))))
	session, err := NewYAMLSessionWithDeferredResources("rules: ['IP-ASN,64512,REJECT,no-resolve','MATCH,DIRECT']", "{}", root, "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	proxy, err := session.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("8.8.8.8"), DstPort: 443})
	if err != nil || proxy.Name() != "REJECT" {
		t.Fatalf("explicit ASN resource lost precedence: %v %v", proxy, err)
	}
}

func TestBundledASNMissingFileDefersButWrongDatabaseFails(t *testing.T) {
	old := bundledGeoIPPath.Swap(nil)
	defer bundledGeoIPPath.Store(old)
	directory := t.TempDir()
	path := filepath.Join(directory, "Country.mmdb")
	country := mobileMMDBFixture("sing-geoip", mobileMMDBString("cn"))
	if err := os.WriteFile(path, country, 0600); err != nil {
		t.Fatal(err)
	}
	if err := SetBundledGeoIPPath(path); err != nil {
		t.Fatal(err)
	}
	config := "rules: ['IP-ASN,15169,REJECT,no-resolve','MATCH,DIRECT']"
	session, err := NewYAMLSessionWithDeferredResources(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if !session.ResourcesPending() {
		session.Close()
		t.Fatal("absent ASN did not retain the existing deferred download path")
	}
	session.Close()
	if err = os.WriteFile(filepath.Join(directory, "ASN.mmdb"), country, 0600); err != nil {
		t.Fatal(err)
	}
	if session, err = NewYAMLSessionWithDeferredResources(config, "{}", "", "", 1280); err == nil {
		session.Close()
		t.Fatal("wrong bundled database format was silently treated as missing")
	}
}
