package mobile

import (
	"errors"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/resolver/hosts"
	MConfig "github.com/metacubex/mihomo/config"
)

type sessionHostEntries struct {
	entries   resolver.Hosts
	useSystem bool
}

func (s *Session) configureHosts(raw *MConfig.RawConfig) error {
	tree, err := MConfig.ParseMobileHosts(raw)
	if err != nil {
		return errors.New("hosts contains an invalid mapping")
	}
	s.dnsOwner.hosts.Store(&sessionHostEntries{entries: resolver.NewHosts(tree), useSystem: raw.DNS.UseSystemHosts})
	return nil
}

type sessionHosts struct{}

func (sessionHosts) Search(domain string, isDomain bool) (*resolver.HostValue, bool) {
	owner := activeDNSOwner.Load()
	if owner == nil || owner.scope.Context().Err() != nil {
		return nil, false
	}
	configured := owner.hosts.Load()
	if configured == nil {
		return nil, false
	}
	value, found := configured.entries.Search(domain, isDomain)
	if value != nil || isDomain || !configured.useSystem || resolver.DisableSystemHosts {
		return value, found
	}
	addresses, _ := hosts.LookupStaticHost(domain)
	if value, err := resolver.NewHostValue(addresses); err == nil {
		return &value, true
	}
	return nil, false
}
