package mobile

import (
	C "github.com/metacubex/mihomo/constant"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
)

func TestBundledGeoIPAvailableBeforeVPNAndExplicitResourceWins(t *testing.T) {
	old := bundledGeoIPPath.Swap(nil)
	defer bundledGeoIPPath.Store(old)
	path := filepath.Join(t.TempDir(), "GeoIP.mmdb")
	if os.WriteFile(path, mobileMMDBFixture("sing-geoip", mobileMMDBString("us")), 0600) != nil {
		t.Fatal("fixture write failed")
	}
	if err := SetBundledGeoIPPath(path); err != nil {
		t.Fatal(err)
	}
	for _, explicit := range []bool{false, true} {
		root := ""
		if explicit {
			root = bundleFixture(t, "geoip-mmdb", "default", mobileMMDBFixture("sing-geoip", mobileMMDBString("gb")))
		}
		session, err := NewYAMLSessionWithDeferredResources("rules: ['GEOIP,us,REJECT,no-resolve','MATCH,DIRECT']", "{}", root, "", 1280)
		if err != nil {
			t.Fatal(err)
		}
		if session.ResourcesPending() {
			session.Close()
			t.Fatal("bundled GeoIP incorrectly deferred")
		}
		proxy, err := session.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("10.0.0.9"), DstPort: 443})
		want := "REJECT"
		if explicit {
			want = "DIRECT"
		}
		session.Close()
		if err != nil || proxy.Name() != want {
			t.Fatalf("GeoIP precedence: got %v, want %s (%v)", proxy, want, err)
		}
	}
}
