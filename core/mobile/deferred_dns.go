package mobile

import (
	"strings"

	"github.com/metacubex/mihomo/common/orderedmap"
	C "github.com/metacubex/mihomo/constant"
	RC "github.com/metacubex/mihomo/rules/common"
)

// Only the startup copy omits unavailable dependencies. The complete configuration
// is applied through the normal session entry after resource preparation finishes.
func (r *routingConfiguration) deferredDNSConfiguration(config *yamlConfiguration) (*yamlConfiguration, bool, error) {
	if !config.Raw.DNS.Enable {
		return config, false, nil
	}
	copy := *config
	raw := *config.Raw
	copy.Raw = &raw
	dns := &raw.DNS
	pending := false
	for _, policy := range []**orderedmap.OrderedMap[string, any]{&dns.NameServerPolicy, &dns.ProxyServerNameserverPolicy} {
		filtered, deferred, err := r.deferredDNSPolicy(*policy)
		if err != nil {
			return nil, false, err
		}
		*policy = filtered
		pending = pending || deferred
	}
	if dns.EnhancedMode == C.DNSFakeIP {
		filters := make([]string, 0, len(dns.FakeIPFilter))
		for _, value := range dns.FakeIPFilter {
			var deferred bool
			var err error
			if dns.FakeIPFilterMode == C.FilterRule {
				kind, payload, target, params := RC.ParseRulePayload(value, true)
				_, err = r.ParseDNSRule(kind, payload, target, params)
				deferred = isMissingResource(err)
			} else {
				deferred, err = r.deferredDNSDomain(value)
			}
			if deferred {
				pending = true
				continue
			}
			if err != nil {
				return nil, false, err
			}
			filters = append(filters, value)
		}
		dns.FakeIPFilter = filters
	}
	if len(dns.Fallback) != 0 {
		if dns.FallbackFilter.GeoIP {
			_, err := r.NewGeoIP(dns.FallbackFilter.GeoIPCode, "", false, true)
			if isMissingResource(err) {
				dns.FallbackFilter.GeoIP = false
				pending = true
			} else if err != nil {
				return nil, false, err
			}
		}
		sites := make([]string, 0, len(dns.FallbackFilter.GeoSite))
		for _, site := range dns.FallbackFilter.GeoSite {
			_, err := r.NewGeoSite(site, "")
			if isMissingResource(err) {
				pending = true
				continue
			}
			if err != nil {
				return nil, false, err
			}
			sites = append(sites, site)
		}
		dns.FallbackFilter.GeoSite = sites
	}
	return &copy, pending, nil
}

func (r *routingConfiguration) deferredDNSPolicy(policy *orderedmap.OrderedMap[string, any]) (*orderedmap.OrderedMap[string, any], bool, error) {
	if policy == nil {
		return nil, false, nil
	}
	filtered := orderedmap.New[string, any]()
	pending := false
	for pair := policy.Oldest(); pair != nil; pair = pair.Next() {
		deferred, err := r.deferredDNSDomain(pair.Key)
		if err != nil {
			return nil, false, err
		}
		if deferred {
			pending = true
			continue
		}
		filtered.Set(pair.Key, pair.Value)
	}
	return filtered, pending, nil
}

func (r *routingConfiguration) deferredDNSDomain(value string) (bool, error) {
	kind, payload, _ := strings.Cut(value, ":")
	switch strings.ToLower(kind) {
	case "rule-set":
		for _, name := range strings.Split(payload, ",") {
			if r.deferredProviders[name] {
				return true, nil
			}
		}
	case "geosite":
		for _, name := range strings.Split(payload, ",") {
			_, err := r.NewGeoSite(name, "")
			if isMissingResource(err) {
				return true, nil
			}
			if err != nil {
				return false, err
			}
		}
	}
	return false, nil
}
