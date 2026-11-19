package mobile

import (
	"fmt"
	"net/netip"

	"go.yaml.in/yaml/v3"
)

type networkRoute struct {
	Address      string `json:"address"`
	PrefixLength int    `json:"prefixLength"`
}

func validateExcludedRoutes(root *yaml.Node) error {
	for i := 0; i < len(root.Content); i += 2 {
		if root.Content[i].Value != "tun" {
			continue
		}
		tun := root.Content[i+1]
		for j := 0; j+1 < len(tun.Content); j += 2 {
			if tun.Content[j].Value != "route-exclude-address" {
				continue
			}
			routes := tun.Content[j+1]
			if routes.Tag == "!!null" {
				continue
			}
			if routes.Kind != yaml.SequenceNode {
				return fmt.Errorf("tun.route-exclude-address must be a list of CIDRs")
			}
			for index, route := range routes.Content {
				prefix, err := netip.ParsePrefix(route.Value)
				if route.Kind != yaml.ScalarNode || route.Tag != "!!str" || err != nil || prefix.Addr().Is4In6() {
					return fmt.Errorf("tun.route-exclude-address[%d] must be an IPv4 or IPv6 CIDR", index)
				}
			}
		}
	}
	return nil
}

func excludedNetworkRoutes(prefixes []netip.Prefix) (ipv4, ipv6 []networkRoute) {
	for _, prefix := range prefixes {
		prefix = prefix.Masked()
		route := networkRoute{Address: prefix.Addr().String(), PrefixLength: prefix.Bits()}
		if prefix.Addr().Is4() {
			ipv4 = append(ipv4, route)
		} else {
			ipv6 = append(ipv6, route)
		}
	}
	return
}
