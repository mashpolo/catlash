package mobile

import (
	"fmt"
	"maps"
	"slices"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
)

// Provider updates are serialized; normal traffic and selection changes continue
// against the published graph while nodes and their groups are being parsed.
func (s *Session) prepareHotProxy(p *ResourcePreparation, key resourceKey, data []byte) (commit func(), discard func(), err error) {
	live := s.routing
	next := &routingConfiguration{
		session: s, stateRoot: live.stateRoot, resources: s.providerResources,
		proxyProviders: maps.Clone(live.proxyProviders), proxies: maps.Clone(live.proxies),
		groups: map[string]outboundgroup.ProxyGroup{}, disableUDP: map[string]bool{},
		hotProviders: maps.Clone(live.hotProviders),
	}
	if next.hotProviders == nil {
		next.hotProviders = make(map[string]bool)
	}
	next.hotProviders[key.name] = true
	for name := range live.groups {
		delete(next.proxies, name)
	}
	old := live.proxyProviders[key.name]
	for _, node := range old.Proxies() {
		delete(next.proxies, node.Name())
	}
	for _, job := range live.providerHealthJobs {
		if job.provider != old {
			next.healthJobs = append(next.healthJobs, job)
		}
	}

	definitions, err := next.parseProxyProvider(key.name, p.config.ProxyProviders[key.name], data, live)
	if err != nil {
		return nil, nil, err
	}
	discard = func() { _ = next.Close() }
	next.providerHealthJobs = slices.Clone(next.healthJobs)
	config := *p.config
	config.Proxies = slices.Clone(config.Proxies)
	for _, name := range slices.Sorted(maps.Keys(next.proxyProviders)) {
		if name == key.name {
			config.Proxies = append(config.Proxies, definitions...)
			continue
		}
		for _, node := range next.proxyProviders[name].Proxies() {
			definition := map[string]any{"name": node.Name()}
			if target := node.ProxyInfo().DialerProxy; target != "" {
				definition["dialer-proxy"] = target
			}
			config.Proxies = append(config.Proxies, definition)
		}
	}
	if err = next.buildGroupsAndNodes(&config, p.config.Proxies, live); err != nil {
		discard()
		return nil, nil, err
	}
	for name := range live.referencedNodes {
		if next.proxies[name] == nil {
			discard()
			return nil, nil, fmt.Errorf("provider update removes referenced proxy %s", name)
		}
	}

	return func() {
		live.mu.Lock()
		for name, group := range live.groups {
			member := live.selections[name]
			if group.Type() == C.Selector {
				member = group.Now()
			}
			if member != "" {
				// An unavailable choice falls back to the rebuilt group's default.
				_ = next.selectProxy(name, member)
			}
		}
		retiredGroups := live.groupOwned
		retiredProvider := live.providerOwned[key.name]
		live.proxies, live.groups, live.groupOwned = next.proxies, next.groups, next.groupOwned
		live.selections = next.selections
		live.hotProviders = next.hotProviders
		live.proxyProviders = next.proxyProviders
		live.providerOwned[key.name] = next.providerOwned[key.name]
		live.providerHealthJobs, live.healthJobs = next.providerHealthJobs, next.healthJobs
		s.providerResources[key] = data
		live.mu.Unlock()
		s.startHealthChecks()
		for _, closer := range retiredGroups {
			_ = closer.Close()
		}
		// Mihomo adapters keep a self-reference on each established TCP/UDP
		// connection. Dropping our reference lets their finalizers close them
		// after the last live connection is done, as in Mihomo's own refresh.
		for _, closer := range retiredProvider {
			if _, isNode := closer.(C.Proxy); !isNode {
				_ = closer.Close()
			}
		}
	}, discard, nil
}
