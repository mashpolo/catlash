package mobile

import (
	"fmt"
	"net/netip"
	"strings"
)

type dnsHijackRule struct {
	network string
	address netip.AddrPort
}

type dnsHijackRules []dnsHijackRule

func parseDNSHijack(values []string) (dnsHijackRules, error) {
	rules := make(dnsHijackRules, 0, len(values))
	for index, value := range values {
		network := ""
		if before, after, found := strings.Cut(value, "://"); found {
			network, value = before, after
			if network != "tcp" && network != "udp" {
				return nil, fmt.Errorf("tun.dns-hijack[%d] protocol must be tcp or udp", index)
			}
		}
		if strings.HasPrefix(value, "any:") {
			value = "0.0.0.0:" + strings.TrimPrefix(value, "any:")
		}
		address, err := netip.ParseAddrPort(value)
		if err != nil || address.Port() == 0 || address.Addr().Zone() != "" {
			return nil, fmt.Errorf("tun.dns-hijack[%d] must contain an IP address or any and a valid port", index)
		}
		rules = append(rules, dnsHijackRule{network: network, address: address})
	}
	return rules, nil
}

func (rules dnsHijackRules) matches(network string, destination netip.AddrPort) bool {
	if destination.Port() == 53 && (destination.Addr() == netip.MustParsePrefix(packetIPv4CIDR).Addr() || destination.Addr() == netip.MustParsePrefix(packetIPv6CIDR).Addr()) {
		return true
	}
	for _, rule := range rules {
		if (rule.network == "" || rule.network == network) && rule.address.Port() == destination.Port() &&
			(rule.address.Addr().IsUnspecified() || rule.address.Addr().Unmap() == destination.Addr().Unmap()) {
			return true
		}
	}
	return false
}
