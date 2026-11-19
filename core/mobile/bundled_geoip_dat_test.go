package mobile

import (
	"bytes"
	"encoding/binary"
	"net/netip"
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/component/geodata"
	G "github.com/metacubex/mihomo/component/geodata/router"
	C "github.com/metacubex/mihomo/constant"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
)

func TestBundledGeoIPDATRoutesCNAndPreservesDNSFallback(t *testing.T) {
	old := bundledGeoIPPath.Swap(nil)
	defer bundledGeoIPPath.Store(old)
	path, err := filepath.Abs("../../Resources/Geo/Country.mmdb")
	if err != nil {
		t.Fatal(err)
	}
	if err = SetBundledGeoIPPath(path); err != nil {
		t.Fatal(err)
	}
	address := dnsFixture(t)
	yaml := dnsYAML(address, "redir-host") + " fallback: ['" + address + "']\n fallback-filter: {geoip: true, geoip-code: CN}\ngeodata-mode: true\nrules: ['GEOIP,CN,REJECT,no-resolve','MATCH,DIRECT']"
	session, err := NewYAMLSessionWithDeferredResources(yaml, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if session.ResourcesPending() {
		t.Fatal("bundled DAT was incorrectly deferred by rule or DNS dependency discovery")
	}
	for address, want := range map[string]string{"223.5.5.5": "REJECT", "8.8.8.8": "DIRECT"} {
		proxy, err := session.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr(address), DstPort: 443})
		if err != nil || proxy.Name() != want {
			t.Fatalf("bundled CN route: %s got %v want %s (%v)", address, proxy, want, err)
		}
	}
}

func TestBundledGeoIPDATExplicitResourceWins(t *testing.T) {
	old := bundledGeoIPPath.Swap(nil)
	defer bundledGeoIPPath.Store(old)
	path, err := filepath.Abs("../../Resources/Geo/Country.mmdb")
	if err != nil {
		t.Fatal(err)
	}
	if err = SetBundledGeoIPPath(path); err != nil {
		t.Fatal(err)
	}
	data, err := proto.Marshal(&G.GeoIPList{Entry: []*G.GeoIP{{CountryCode: "CN", Cidr: []*G.CIDR{{Ip: netip.MustParseAddr("203.0.113.0").AsSlice(), Prefix: 24}}}}})
	if err != nil {
		t.Fatal(err)
	}
	session, err := NewYAMLSessionWithDeferredResources("geodata-mode: true\nrules: ['GEOIP,CN,REJECT,no-resolve','MATCH,DIRECT']", "{}", bundleFixture(t, "geoip-dat", "default", data), "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	for address, want := range map[string]string{"223.5.5.5": "DIRECT", "203.0.113.9": "REJECT"} {
		proxy, err := session.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr(address), DstPort: 443})
		if err != nil || proxy.Name() != want {
			t.Fatalf("explicit DAT precedence: %s got %v want %s (%v)", address, proxy, want, err)
		}
	}
}

func TestBundledGeoIPDATMissingFileRemainsDeferredDNSDependency(t *testing.T) {
	old := bundledGeoIPPath.Swap(nil)
	defer bundledGeoIPPath.Store(old)
	path := filepath.Join(t.TempDir(), "Country.mmdb")
	if err := os.WriteFile(path, mobileMMDBFixture("sing-geoip", mobileMMDBString("cn")), 0600); err != nil {
		t.Fatal(err)
	}
	if err := SetBundledGeoIPPath(path); err != nil {
		t.Fatal(err)
	}
	address := dnsFixture(t)
	yaml := dnsYAML(address, "redir-host") + " fallback: ['" + address + "']\n fallback-filter: {geoip: true, geoip-code: CN}\ngeodata-mode: true\nrules: ['MATCH,DIRECT']"
	session, err := NewYAMLSessionWithDeferredResources(yaml, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if !session.ResourcesPending() {
		t.Fatal("missing bundled DAT was not reported as a deferred DNS dependency")
	}
}

func TestGeoIPDiskReaderSkipsLargeUnrelatedEntriesAndClosesFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "GeoIP.dat")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	name := protowire.AppendString([]byte{0x0a}, "UNRELATED")
	paddingSize := 17 << 20
	paddingTag := protowire.AppendTag(nil, 99, protowire.BytesType)
	paddingHeader := binary.AppendUvarint(paddingTag, uint64(paddingSize))
	header := binary.AppendUvarint([]byte{0x0a}, uint64(len(name)+len(paddingHeader)+paddingSize))
	for _, part := range [][]byte{header, name, paddingHeader} {
		if _, err = file.Write(part); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = file.Seek(int64(paddingSize), 1); err != nil {
		t.Fatal(err)
	}
	if _, err = file.Write(geoIPFixture(t)); err != nil {
		t.Fatal(err)
	}
	if err = file.Close(); err != nil {
		t.Fatal(err)
	}
	matcher, err := geodata.NewMobileGeoIPMatcherFromFile(path, "TEST")
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if !matcher.Match(netip.MustParseAddr("203.0.113.9")) || matcher.Match(netip.MustParseAddr("8.8.8.8")) {
		t.Fatal("disk matcher did not retain the requested entry")
	}
}

func TestGeoIPDiskReaderRejectsCorruptDuplicateOrMissingEntries(t *testing.T) {
	fixture := geoIPFixture(t)
	for _, data := range [][]byte{{0x0a, 0xff}, fixture[:len(fixture)-1], append(bytes.Clone(fixture), fixture...), {0x0a, 0x00}} {
		path := filepath.Join(t.TempDir(), "GeoIP.dat")
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := geodata.NewMobileGeoIPMatcherFromFile(path, "TEST"); err == nil {
			t.Fatal("accepted a corrupt, duplicate or missing disk entry")
		}
	}
}
