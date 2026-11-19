package mobile

import (
	"context"
	"errors"
	"fmt"
	"sort"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
)

// loadApplicationProxyProviders runs before the session is published or its packet
// stack starts. Each HTTP request uses its configured proxy, never a fallback.
func (s *Session) loadApplicationProxyProviders(config *yamlConfiguration, resources map[resourceKey][]byte, selections map[string]string, stateRoot string, hotProviders map[string]bool) error {
	pending := []string{}
	for name, mapping := range config.ProxyProviders {
		if mapping["type"] != "inline" && resources[resourceKey{"proxy-provider", name}] == nil {
			if mapping["type"] != "http" {
				return &missingProviderResource{kind: "proxy-provider", name: name}
			}
			pending = append(pending, name)
		}
	}
	if len(pending) == 0 {
		return nil
	}
	sort.Strings(pending)
	ctx, cancel := context.WithCancel(s.ctx)
	defer cancel()
	p := &ResourcePreparation{ctx: ctx, cancel: cancel, config: config, resources: resources, stateRoot: stateRoot, selections: selections}
	if err := p.configureBootstrapDNS(s); err != nil {
		return err
	}
	for len(pending) > 0 {
		remaining := []string{}
		for _, name := range pending {
			mapping := config.ProxyProviders[name]
			proxy, _ := mapping["proxy"].(string)
			if proxy == "" {
				proxy = "DIRECT"
			}
			subset, ready, err := providerDownloadConfiguration(config, resources, proxy)
			if err != nil {
				return err
			}
			if !ready {
				remaining = append(remaining, name)
				continue
			}
			r := &routingConfiguration{hotProviders: hotProviders, mode: config.Mode, session: s, stateRoot: stateRoot, resources: resources, proxies: map[string]C.Proxy{}, groups: map[string]outboundgroup.ProxyGroup{}, disableUDP: map[string]bool{}}
			s.routing = r
			err = r.buildProxyGraph(subset)
			if err == nil {
				for group, member := range selections {
					if group == "GLOBAL" && proxy != "GLOBAL" {
						continue // The temporary download graph contains only the requested proxy.
					}
					if r.groups[group] != nil {
						if err = r.selectProxy(group, member); err != nil {
							if r.removedProviderMember(group, member) {
								err = nil
								continue
							}
							break
						}
					}
				}
			}
			var data []byte
			if err == nil {
				data, err = p.downloadProvider(s, resourceKey{"proxy-provider", name}, mapping)
			}
			r.Close()
			s.routing = nil
			if err != nil {
				return fmt.Errorf("proxy-provider %s download failed: %w", name, err)
			}
			if err = p.addResource(resourceKey{"proxy-provider", name}, data); err != nil {
				return err
			}
		}
		if len(remaining) == len(pending) {
			return errors.New("proxy-provider download dependencies are unavailable or circular")
		}
		pending = remaining
	}
	return nil
}

// Build only the dependencies of a provider's explicit download proxy. A group
// requiring an undownloaded provider waits for another iteration.
func providerDownloadConfiguration(config *yamlConfiguration, resources map[resourceKey][]byte, target string) (*yamlConfiguration, bool, error) {
	subset := *config
	subset.Proxies = nil
	subset.Groups = nil
	subset.ProxyProviders = map[string]map[string]any{}
	visited := map[string]bool{}
	var visit func(string) (bool, error)
	addProvider := func(name string) (bool, error) {
		mapping, ok := config.ProxyProviders[name]
		if !ok {
			return false, fmt.Errorf("unknown proxy-provider %s", name)
		}
		if mapping["type"] != "inline" && resources[resourceKey{"proxy-provider", name}] == nil {
			return false, nil
		}
		subset.ProxyProviders[name] = mapping
		return true, nil
	}
	visit = func(name string) (bool, error) {
		if name == "DIRECT" || name == "REJECT" || name == "REJECT-DROP" {
			return true, nil
		}
		if visited[name] {
			return true, nil
		}
		visited[name] = true
		for _, mapping := range config.Proxies {
			if mapping["name"] != name {
				continue
			}
			if dependency, ok := mapping["dialer-proxy"].(string); ok {
				if ready, err := visit(dependency); !ready || err != nil {
					return ready, err
				}
			}
			subset.Proxies = append(subset.Proxies, mapping)
			return true, nil
		}
		for _, group := range config.Groups {
			if group.Name != name {
				continue
			}
			for _, provider := range group.Use {
				if ready, err := addProvider(provider); !ready || err != nil {
					return ready, err
				}
			}
			if group.IncludeAll || group.IncludeAllProviders {
				for provider := range config.ProxyProviders {
					if ready, err := addProvider(provider); !ready || err != nil {
						return ready, err
					}
				}
			}
			members := append([]string{}, group.Proxies...)
			if group.IncludeAll || group.IncludeAllProxies {
				for _, mapping := range config.Proxies {
					member, _ := mapping["name"].(string)
					members = append(members, member)
				}
			}
			for _, member := range members {
				if ready, err := visit(member); !ready || err != nil {
					return ready, err
				}
			}
			subset.Groups = append(subset.Groups, group)
			return true, nil
		}
		return false, fmt.Errorf("unknown resource download proxy %s", name)
	}
	ready, err := visit(target)
	return &subset, ready, err
}
