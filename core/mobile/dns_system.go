package mobile

import (
	"context"
	"net"
	"net/netip"

	"github.com/metacubex/mihomo/component/resolver"
)

// Apple exposes network DNS through its resolver API, not a usable resolv.conf.
// Keep other DNS operations on the existing resolver; address lookups use the
// platform resolver only while no explicit YAML DNS runtime is active.
type platformSystemResolver struct{ resolver.Resolver }

func (*platformSystemResolver) LookupIP(ctx context.Context, host string) ([]netip.Addr, error) {
	return net.DefaultResolver.LookupNetIP(ctx, "ip", host)
}
func (*platformSystemResolver) LookupIPv4(ctx context.Context, host string) ([]netip.Addr, error) {
	return net.DefaultResolver.LookupNetIP(ctx, "ip4", host)
}
func (*platformSystemResolver) LookupIPv6(ctx context.Context, host string) ([]netip.Addr, error) {
	return net.DefaultResolver.LookupNetIP(ctx, "ip6", host)
}
