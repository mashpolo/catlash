package mobile

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sort"
	"sync"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/geodata/router"
	"github.com/metacubex/mihomo/component/sniffer"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

type routingConfiguration struct {
	inspection             runtimeInspection
	allowDeferredResources bool
	deferredProviders      map[string]bool
	sniffer                *sniffer.Dispatcher
	dnsHijack              dnsHijackRules
	domainRulesEnabled     bool
	subRules               map[string][]C.Rule
	stateRoot              string
	geo                    *geoRuntime
	healthJobs             []healthJob
	providerHealthJobs     []healthJob
	healthCancels          map[*sessionProvider]context.CancelFunc
	providerOwned          map[string][]io.Closer
	groupOwned             []io.Closer
	selections             map[string]string
	referencedNodes        map[string]bool
	hotProviders           map[string]bool
	resources              map[resourceKey][]byte
	proxyProviders         map[string]P.ProxyProvider
	ruleProviders          map[string]P.RuleProvider
	mu                     sync.Mutex
	mode                   string
	proxies                map[string]C.Proxy
	groups                 map[string]outboundgroup.ProxyGroup
	groupTestURLs          map[string]string
	disableUDP             map[string]bool
	dns                    *dnsRuntime
	session                *Session
	warnings               []string
	rules                  []C.Rule
	owned                  []io.Closer
}

func NewYAMLSession(value, selectionsJSON string, mtu int32) (*Session, error) {
	return NewYAMLSessionWithResources(value, selectionsJSON, "", mtu)
}
func NewYAMLSessionWithResources(value, selectionsJSON, resourceRoot string, mtu int32) (*Session, error) {
	return NewYAMLSessionWithStorage(value, selectionsJSON, resourceRoot, "", mtu)
}
func NewYAMLSessionWithStorage(value, selectionsJSON, resourceRoot, stateRoot string, mtu int32) (*Session, error) {
	return newYAMLSessionWithStorage(value, selectionsJSON, resourceRoot, stateRoot, mtu, false)
}

func NewYAMLSessionWithDeferredResources(value, selectionsJSON, resourceRoot, stateRoot string, mtu int32) (*Session, error) {
	return newYAMLSessionWithStorage(value, selectionsJSON, resourceRoot, stateRoot, mtu, true)
}

func newYAMLSessionWithStorage(value, selectionsJSON, resourceRoot, stateRoot string, mtu int32, allowDeferred bool) (*Session, error) {
	resources, err := loadResourceBundle(resourceRoot)
	if err != nil {
		return nil, err
	}

	config, err := parseYAML(value)
	if err != nil {
		return nil, err
	}
	hotProviders := loadHotProviders(sha256.Sum256([]byte(value)), config, resources, stateRoot, resourceRoot)
	if len(selectionsJSON) > 1024*1024 {
		return nil, errors.New("selections exceed 1 MiB")
	}
	selections := map[string]string{}
	if err := json.Unmarshal([]byte(selectionsJSON), &selections); err != nil {
		return nil, errors.New("selections must be a JSON object of strings")
	}
	return newPacketSession(mtu, defaultUDPIdleTimeout, func(session *Session) error {
		session.configureKeepAlive(config.Raw)
		if err := session.configureHosts(config.Raw); err != nil {
			return err
		}
		if err := session.loadApplicationProxyProviders(config, resources, selections, stateRoot, hotProviders); err != nil {
			return err
		}
		session.providerResources = map[resourceKey][]byte{}
		for key, data := range resources {
			if key.kind == "proxy-provider" || key.kind == "proxy-file" {
				session.providerResources[key] = data
			}
		}
		runtime := &routingConfiguration{mode: config.Mode, proxies: map[string]C.Proxy{}, groups: map[string]outboundgroup.ProxyGroup{}, disableUDP: map[string]bool{}}
		session.routing = runtime
		runtime.session = session
		runtime.hotProviders = hotProviders
		runtime.stateRoot = stateRoot
		runtime.dnsHijack = config.DNSHijack
		runtime.warnings = config.Warnings
		runtime.allowDeferredResources = allowDeferred
		runtime.resources = resources
		runtime.geo = &geoRuntime{resources: resources, mode: config.Raw.GeodataMode, algorithm: config.Raw.GeositeMatcher, ipMatchers: map[string]router.IPMatcher{}, siteMatchers: map[string]router.DomainMatcher{}}
		runtime.owned = append(runtime.owned, runtime.geo)

		buildErr := runtime.build(config)
		if buildErr == nil {
			runtime.inspection.sourceHash = sha256.Sum256([]byte(value))
			runtime.inspection.resourceRoot = resourceRoot
			runtime.captureProviders(config)
		}
		runtime.resources = nil
		runtime.geo.resources = nil
		if buildErr != nil {
			return buildErr
		}
		for group, member := range selections {
			if err := runtime.selectProxy(group, member); err != nil && !runtime.removedProviderMember(group, member) {
				return err
			}
		}
		return nil
	})
}

func (r *routingConfiguration) build(config *yamlConfiguration) error {
	if err := r.buildProxyGraph(config); err != nil {
		return err
	}
	if err := r.loadRuleProviders(config); err != nil {
		return err
	}
	if err := r.buildSniffer(config); err != nil {
		return err
	}
	if err := r.session.buildDNS(config); err != nil {
		return err
	}
	return r.buildRules(config)
}

func (r *routingConfiguration) buildProxyGraph(config *yamlConfiguration) error {
	r.domainRulesEnabled = config.Raw.DNS.Enable || config.Raw.Sniffer.Enable
	r.groupTestURLs = make(map[string]string, len(config.Groups))
	for _, group := range config.Groups {
		r.groupTestURLs[group.Name] = group.URL
	}
	for index, mapping := range config.Proxies {
		if err := r.hydrateProxyFiles(mapping, fmt.Sprintf("proxies[%d]", index)); err != nil {
			return err
		}
	}
	originalProxies := append([]map[string]any{}, config.Proxies...)
	if err := r.loadProxyProviders(config); err != nil {
		return err
	}
	r.providerHealthJobs = append([]healthJob(nil), r.healthJobs...)
	return r.buildGroupsAndNodes(config, originalProxies, r)
}

func (r *routingConfiguration) buildGroupsAndNodes(config *yamlConfiguration, originalProxies []map[string]any, live *routingConfiguration) error {
	definitions := map[string]map[string]any{
		"DIRECT":      {"name": "DIRECT", "type": "direct"},
		"REJECT":      {"name": "REJECT", "type": "reject"},
		"REJECT-DROP": {"name": "REJECT-DROP", "type": "reject-drop"},
	}
	groupDefinitions := map[string]groupConfiguration{}
	names := []string{}
	for index, mapping := range config.Proxies {
		name, ok := mapping["name"].(string)
		if !ok || name == "" {
			return fmt.Errorf("proxies[%d].name must be a nonempty string", index)
		}
		if _, exists := definitions[name]; exists || name == "GLOBAL" {
			return fmt.Errorf("proxies[%d].name is duplicated or reserved", index)
		}
		definitions[name] = mapping
		names = append(names, name)
	}
	for index, group := range config.Groups {
		if group.Interval < 0 || group.Interval > 86400 || group.Timeout < 0 || group.Timeout > 60000 {
			return fmt.Errorf("proxy-groups[%d] has invalid interval or timeout", index)
		}
		if group.IncludeAll || group.IncludeAllProxies {
			for _, proxy := range originalProxies {
				if name, ok := proxy["name"].(string); ok {
					group.Proxies = append(group.Proxies, name)
				}
			}
		}
		if group.IncludeAll || group.IncludeAllProviders {
			group.Use = nil
			for name := range r.proxyProviders {
				group.Use = append(group.Use, name)
			}
			sort.Strings(group.Use)
		}

		if group.Name == "" {
			return fmt.Errorf("proxy-groups[%d].name is required", index)
		}
		if _, exists := definitions[group.Name]; exists || group.Name == "GLOBAL" {
			return fmt.Errorf("proxy-groups[%d].name is duplicated or reserved", index)
		}
		if _, exists := groupDefinitions[group.Name]; exists {
			return fmt.Errorf("proxy-groups[%d].name is duplicated", index)
		}
		if len(group.Proxies) == 0 && len(group.Use) == 0 {
			return fmt.Errorf("proxy-groups[%d].proxies must not be empty", index)
		}
		groupDefinitions[group.Name] = group
		names = append(names, group.Name)
	}
	names = append(names, "DIRECT", "REJECT", "REJECT-DROP")
	groupDefinitions["GLOBAL"] = groupConfiguration{Name: "GLOBAL", Type: "select", Proxies: names}
	visited := map[string]uint8{}
	var build func(string) error
	build = func(name string) error {
		if visited[name] == 2 {
			return nil
		}
		if visited[name] == 1 {
			return fmt.Errorf("proxy reference cycle involving %s", name)
		}
		visited[name] = 1
		if group, ok := groupDefinitions[name]; ok {
			members := append([]string{}, group.Proxies...)
			for _, name := range group.Use {
				pd, ok := r.proxyProviders[name]
				if !ok {
					return fmt.Errorf("unknown proxy-provider %s", name)
				}
				for _, proxy := range pd.Proxies() {
					members = append(members, proxy.Name())
				}
			}
			for _, member := range members {
				if err := build(member); err != nil {
					return err
				}
			}
			if err := r.buildGroup(group, live); err != nil {
				return err
			}
		} else if mapping, ok := definitions[name]; ok {
			if dialer, exists := mapping["dialer-proxy"]; exists {
				target, ok := dialer.(string)
				if !ok || target == "" {
					return fmt.Errorf("proxy %s has invalid dialer-proxy", name)
				}
				if err := build(target); err != nil {
					return err
				}
			}
			if _, ok := r.proxies[name]; ok {
				visited[name] = 2
				return nil
			}
			stateDirectory, err := r.identityDirectory(mapping, "")
			if err != nil {
				return fmt.Errorf("proxy %s: %w", name, err)
			}
			var proxy C.Proxy
			if name == "REJECT-DROP" {
				proxy = adapter.NewProxy(outbound.NewRejectDrop())
			} else {
				proxy, err = adapter.ParseProxy(mapping, adapter.WithTunnelForAPI(&sessionTunnel{routing: r}), adapter.WithMobileStateDirectory(stateDirectory), adapter.WithMobileContext(r.session.ctx))
			}
			if err != nil {
				return fmt.Errorf("proxy %s: invalid %s options", name, mapping["type"])
			}
			r.proxies[name] = proxy
			r.owned = append(r.owned, proxy)
		} else {
			return fmt.Errorf("unknown proxy reference %s", name)
		}
		visited[name] = 2
		return nil
	}
	if err := build("REJECT"); err != nil {
		return err
	}
	for _, name := range names {
		if err := build(name); err != nil {
			return err
		}
	}
	if err := build("GLOBAL"); err != nil {
		return err
	}
	return nil
}

func (r *routingConfiguration) buildGroup(config groupConfiguration, live *routingConfiguration) error {
	members := make([]C.Proxy, 0, len(config.Proxies))
	for _, name := range config.Proxies {
		members = append(members, r.proxies[name])
	}
	providers := []P.ProxyProvider{}
	if len(members) > 0 {
		hc := provider.NewHealthCheck(members, "", 0, 0, true, nil)
		pd, err := provider.NewCompatibleProvider(config.Name, members, hc)
		if err != nil {
			return errors.New("invalid group provider")
		}
		r.groupOwned = append(r.groupOwned, pd)
		providers = append(providers, pd)
	}
	for _, name := range config.Use {
		providers = append(providers, r.proxyProviders[name])
	}
	options := outboundgroup.GroupCommonOption{Name: config.Name, Type: config.Type, URL: config.URL, DisableUDP: config.DisableUDP, Filter: config.Filter, ExcludeFilter: config.ExcludeFilter, ExcludeType: config.ExcludeType}
	if options.URL == "" {
		for _, pd := range providers {
			if pd.HealthCheckURL() != "" {
				options.URL = pd.HealthCheckURL()
				break
			}
		}
	}
	if options.URL == "" {
		options.URL = C.DefaultTestURL
	}
	if config.Interval > 0 {
		lazy := true
		if config.Lazy != nil {
			lazy = *config.Lazy
		}
		timeout := config.Timeout
		if timeout == 0 {
			timeout = 5000
		}
		for i, pd := range providers {
			wrapped, err := r.configureHealth(pd, map[string]any{"enable": true, "url": options.URL, "interval": config.Interval, "timeout": timeout, "lazy": lazy, "expected-status": config.ExpectedStatus})
			if err != nil {
				return fmt.Errorf("proxy-group %s: %w", config.Name, err)
			}
			providers[i] = wrapped
		}
	}
	options.ExpectedStatus = config.ExpectedStatus
	fallback := r.proxies["REJECT"]
	var err error
	var group outboundgroup.ProxyGroup
	switch config.Type {
	case "select":
		group, err = outboundgroup.NewSelector(options, outboundgroup.SelectorOption{DefaultSelected: config.DefaultSelected}, fallback, providers)
	case "url-test":
		group, err = outboundgroup.NewURLTest(options, outboundgroup.URLTestOption{Tolerance: config.Tolerance}, fallback, providers)
	case "fallback":
		group, err = outboundgroup.NewFallback(options, outboundgroup.FallbackOption{}, fallback, providers)
	case "load-balance":
		group, err = outboundgroup.NewLoadBalance(options, outboundgroup.LoadBalanceOption{Strategy: config.Strategy}, fallback, providers)
	default:
		return fmt.Errorf("proxy-group %s has unsupported type", config.Name)
	}
	if err != nil {
		return fmt.Errorf("proxy-group %s has invalid options", config.Name)
	}
	matching := group.Proxies()
	explicitReject := false
	for _, name := range config.Proxies {
		if name == "REJECT" {
			explicitReject = true
		}
	}
	if len(matching) == 0 || (len(matching) == 1 && matching[0] == fallback && !explicitReject) {
		return fmt.Errorf("proxy-group %s has no matching member", config.Name)
	}
	r.groups[config.Name] = group
	r.disableUDP[config.Name] = config.DisableUDP
	wrapped := adapter.NewProxy(&sessionGroup{ProxyGroup: group, routing: live})
	r.proxies[config.Name] = wrapped
	r.groupOwned = append(r.groupOwned, wrapped)
	if config.DefaultSelected != "" {
		err := r.selectProxy(config.Name, config.DefaultSelected)
		if err != nil && !r.removedProviderMember(config.Name, config.DefaultSelected) {
			return err
		}
	}
	return nil
}

func (r *routingConfiguration) route(metadata *C.Metadata) (C.Proxy, error) {
	proxy, _, err := r.routeWithRule(metadata)
	return proxy, err
}

func (r *routingConfiguration) routeWithRule(metadata *C.Metadata) (C.Proxy, string, error) {
	r.mu.Lock()
	mode := r.mode
	r.mu.Unlock()
	matchedRule := mode
	if r.dns != nil && metadata.SniffHost == "" {
		if err := r.dns.restore(metadata); err != nil {
			return nil, matchedRule, err
		}
	}
	target := ""
	switch mode {
	case "direct":
		target = "DIRECT"
	case "global":
		target = "GLOBAL"
	default:
		var resolveErr error
		helper := C.RuleMatchHelper{ResolveIP: func() {
			if r.dns != nil {
				resolveErr = r.dns.resolve(metadata)
			}
		}, FindProcess: func() {}}
		for _, rule := range r.rules {
			if matched, name := rule.Match(metadata, helper); matched {
				target = name
				matchedRule = fmt.Sprintf("%s,%s,%s", rule.RuleType().String(), rule.Payload(), name)
				break
			}
		}
		if resolveErr != nil {
			return nil, matchedRule, resolveErr
		}
	}
	if target == "" {
		return nil, matchedRule, errors.New("no routing rule matched")
	}
	r.mu.Lock()
	proxy := r.resolveLocked(target, metadata, true)
	r.mu.Unlock()
	if proxy == nil {
		return nil, matchedRule, errors.New("UDP is disabled for this proxy group")
	}
	return proxy, matchedRule, nil
}

func (r *routingConfiguration) resolveLocked(name string, metadata *C.Metadata, touch bool) C.Proxy {
	proxy := r.proxies[name]
	for proxy != nil {
		group, ok := r.groups[proxy.Name()]
		if !ok {
			return proxy
		}
		if metadata != nil && metadata.NetWork == C.UDP && r.disableUDP[proxy.Name()] {
			return nil
		}
		proxy = group.Unwrap(metadata, touch)
	}
	return nil
}

func (r *routingConfiguration) removedProviderMember(group, member string) bool {
	g := r.groups[group]
	if g == nil || r.proxies[member] != nil || len(r.hotProviders) == 0 {
		return false
	}
	if group == "GLOBAL" {
		return true
	}
	for _, provider := range g.Providers() {
		if r.hotProviders[provider.Name()] && provider.VehicleType() != P.Compatible {
			return true
		}
	}
	return false
}

func (r *routingConfiguration) requireNode(name string) {
	if r.referencedNodes == nil {
		r.referencedNodes = make(map[string]bool)
	}
	r.referencedNodes[name] = true
}

func (r *routingConfiguration) selectProxy(name, member string) error {
	group, ok := r.groups[name]
	if !ok {
		return errors.New("unknown proxy group")
	}
	selector, ok := group.(interface{ ForceSet(string) })
	if !ok {
		return errors.New("this group does not allow manual selection")
	}
	for _, proxy := range group.Proxies() {
		if proxy.Name() == member {
			selector.ForceSet(member)
			if r.selections == nil {
				r.selections = make(map[string]string)
			}
			r.selections[name] = member
			return nil
		}
	}
	return errors.New("proxy is not a member of the group")
}

func (r *routingConfiguration) Close() error {
	var result error
	for _, closers := range r.providerOwned {
		r.owned = append(r.owned, closers...)
	}
	r.owned = append(r.owned, r.groupOwned...)
	for i := len(r.owned) - 1; i >= 0; i-- {
		result = errors.Join(result, r.owned[i].Close())
	}
	// Native proxy/transport handles can outlive Close. They retain this
	// routing object, so detach its complete rule and resource graph here.
	r.mu.Lock()
	r.owned = nil
	r.groupOwned = nil
	r.providerOwned = nil
	r.providerHealthJobs = nil
	r.healthCancels = nil
	r.rules = nil
	r.subRules = nil
	r.ruleProviders = nil
	r.proxyProviders = nil
	r.proxies = nil
	r.groups = nil
	r.healthJobs = nil
	r.geo = nil
	r.dns = nil
	r.sniffer = nil
	r.resources = nil
	r.session = nil
	r.mu.Unlock()
	return result
}

type proxyStatus struct {
	Name    string   `json:"name"`
	Type    string   `json:"type"`
	All     []string `json:"all,omitempty"`
	Now     string   `json:"now,omitempty"`
	Delay   *uint16  `json:"delay"`
	TestURL string   `json:"testURL,omitempty"`
}

func (s *Session) ProxiesJSON() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return "", errors.New("session is closed")
	}
	statuses := []proxyStatus{}
	mode := "direct"
	warnings := []string{}
	if s.routing == nil {
		statuses = append(statuses, proxyStatus{Name: s.proxy.Name(), Type: s.proxy.Type().String()})
	} else {
		r := s.routing
		r.mu.Lock()
		defer r.mu.Unlock()
		mode = r.mode
		warnings = r.warnings
		for name, proxy := range r.proxies {
			status := proxyStatus{Name: name, Type: proxy.Type().String()}
			if group, ok := r.groups[name]; ok {
				status.TestURL = r.groupTestURLs[name]
				status.Now = group.Now()
				for _, member := range group.Proxies() {
					status.All = append(status.All, member.Name())
				}
			}
			history := proxy.DelayHistory()
			if len(history) > 0 {
				value := history[len(history)-1].Delay
				status.Delay = &value
			}
			statuses = append(statuses, status)
		}
	}
	sort.Slice(statuses, func(i, j int) bool { return statuses[i].Name < statuses[j].Name })
	value, err := json.Marshal(struct {
		Mode     string        `json:"mode"`
		Proxies  []proxyStatus `json:"proxies"`
		Warnings []string      `json:"warnings,omitempty"`
	}{mode, statuses, warnings})
	return string(value), err
}

func (s *Session) SetMode(mode string) error {
	switch mode {
	case "rule", "global", "direct":
	default:
		return errors.New("mode must be rule, global or direct")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errors.New("session is closed")
	}
	if s.routing == nil {
		return errors.New("mode switching requires a YAML session")
	}
	s.routing.mu.Lock()
	defer s.routing.mu.Unlock()
	s.routing.mode = mode
	return nil
}

func (s *Session) SelectProxy(group, name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errors.New("session is closed")
	}
	if s.routing == nil {
		return errors.New("session has no proxy groups")
	}
	s.routing.mu.Lock()
	defer s.routing.mu.Unlock()
	return s.routing.selectProxy(group, name)
}

type sessionGroup struct {
	outboundgroup.ProxyGroup
	routing *routingConfiguration
}

func (g *sessionGroup) Unwrap(metadata *C.Metadata, touch bool) C.Proxy {
	g.routing.mu.Lock()
	defer g.routing.mu.Unlock()
	return g.routing.resolveLocked(g.Name(), metadata, touch)
}
func (g *sessionGroup) DialContext(ctx context.Context, metadata *C.Metadata) (C.Conn, error) {
	proxy := g.Unwrap(metadata, true)
	if proxy == nil {
		return nil, errors.New("group disabled this network")
	}
	return proxy.DialContext(ctx, metadata)
}
func (g *sessionGroup) ListenPacketContext(ctx context.Context, metadata *C.Metadata) (C.PacketConn, error) {
	proxy := g.Unwrap(metadata, true)
	if proxy == nil {
		return nil, errors.New("group disabled this network")
	}
	return proxy.ListenPacketContext(ctx, metadata)
}
func (g *sessionGroup) IsL3Protocol(metadata *C.Metadata) bool {
	proxy := g.Unwrap(metadata, false)
	return proxy != nil && proxy.IsL3Protocol(metadata)
}

func (g *sessionGroup) SupportUDP() bool {
	proxy := g.Unwrap(&C.Metadata{NetWork: C.UDP}, false)
	return proxy != nil && proxy.SupportUDP()
}

type sessionTunnel struct{ routing *routingConfiguration }

func (t *sessionTunnel) Proxies() map[string]C.Proxy {
	t.routing.mu.Lock()
	defer t.routing.mu.Unlock()
	return t.routing.proxies
}
func (t *sessionTunnel) HandleTCPConn(conn net.Conn, _ *C.Metadata)        { _ = conn.Close() }
func (t *sessionTunnel) HandleUDPPacket(packet C.UDPPacket, _ *C.Metadata) { packet.Drop() }
func (t *sessionTunnel) NatTable() C.NatTable                              { return nil }
