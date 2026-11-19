package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestYAMLNetworkSettingsPreservesExcludedRoutes(t *testing.T) {
	value := "ipv6: true\ntun:\n  route-exclude-address: [192.168.50.69/24, 10.1.2.3/32, '2001:db8:1234::1/48', '::/0']\n"
	result, err := YAMLNetworkSettings(value)
	if err != nil {
		t.Fatal(err)
	}
	var settings struct {
		IPv4ExcludedRoutes []struct {
			Address      string `json:"address"`
			PrefixLength int    `json:"prefixLength"`
		} `json:"ipv4ExcludedRoutes"`
		IPv6ExcludedRoutes []struct {
			Address      string `json:"address"`
			PrefixLength int    `json:"prefixLength"`
		} `json:"ipv6ExcludedRoutes"`
	}
	if err := json.Unmarshal([]byte(result), &settings); err != nil {
		t.Fatal(err)
	}
	if len(settings.IPv4ExcludedRoutes) != 2 || len(settings.IPv6ExcludedRoutes) != 2 {
		t.Fatalf("missing exclusions: %s", result)
	}
	v4, host := settings.IPv4ExcludedRoutes[0], settings.IPv4ExcludedRoutes[1]
	v6, all := settings.IPv6ExcludedRoutes[0], settings.IPv6ExcludedRoutes[1]
	if v4.Address != "192.168.50.0" || v4.PrefixLength != 24 || host.Address != "10.1.2.3" || host.PrefixLength != 32 ||
		v6.Address != "2001:db8:1234::" || v6.PrefixLength != 48 || all.Address != "::" || all.PrefixLength != 0 {
		t.Fatalf("incorrect exclusions: %s", result)
	}
}

func TestYAMLRejectsInvalidExcludedRouteCIDRs(t *testing.T) {
	for _, value := range []string{"192.168.1.1", "192.168.1.1/33", "2001:db8::/129", "192.168.001.0/24", "fe80::1%en0/64", "not-a-cidr", "::ffff:192.168.1.0/120"} {
		t.Run(value, func(t *testing.T) {
			_, err := YAMLNetworkSettings("tun:\n  route-exclude-address: ['" + value + "']\n")
			if err == nil || !strings.Contains(err.Error(), "tun.route-exclude-address") {
				t.Fatalf("expected field-specific CIDR rejection, got %v", err)
			}
		})
	}
}
