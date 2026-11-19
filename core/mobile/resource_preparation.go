package mobile

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"runtime/debug"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/geodata/router"
	MConfig "github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	M "github.com/metacubex/mihomo/dns"
)

type PreparedResource struct {
	Kind string
	Name string
	Data []byte
}
type ResourcePreparation struct {
	hotUpdate          bool
	subscriptionHeader string
	sourceHash         [32]byte
	resourceRoot       string
	target             *resourceKey
	session            *Session
	ctx                context.Context
	cancel             context.CancelFunc
	config             *yamlConfiguration
	selections         map[string]string
	resources          map[resourceKey][]byte
	stateRoot          string
	mtu                int32
	mu                 sync.Mutex
	started            bool
	items              []*PreparedResource
	memoryBudget       atomic.Int64
}

// SetMemoryBudget limits retained input bytes while optional rules load in a live tunnel.
func (p *ResourcePreparation) SetMemoryBudget(bytes int64) { p.memoryBudget.Store(bytes) }

func (s *Session) NewResourcePreparation(value, selectionsJSON, resourceRoot, stateRoot string, mtu int32) (*ResourcePreparation, error) {
	p, err := NewYAMLResourcePreparation(value, selectionsJSON, resourceRoot, stateRoot, mtu)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	p.cancel()
	if s.closed {
		return nil, errors.New("session is closed")
	}
	if s.routing == nil {
		return nil, errors.New("resource preparation requires a YAML session")
	}
	p.ctx, p.cancel = context.WithCancel(s.ctx)
	p.session = s
	for key, data := range s.providerResources {
		if p.resources[key] == nil {
			p.resources[key] = data
		}
	}
	return p, nil
}

func NewYAMLResourcePreparation(value, selectionsJSON, resourceRoot, stateRoot string, mtu int32) (*ResourcePreparation, error) {
	config, err := parseYAML(value)
	if err != nil {
		return nil, err
	}
	resources, err := loadResourceBundle(resourceRoot)
	if err != nil {
		return nil, err
	}
	sourceHash := sha256.Sum256([]byte(value))
	loadHotProviders(sourceHash, config, resources, stateRoot, resourceRoot)
	selections := map[string]string{}
	if len(selectionsJSON) > 1024*1024 || json.Unmarshal([]byte(selectionsJSON), &selections) != nil {
		return nil, errors.New("selections must be a JSON object of strings")
	}
	ctx, cancel := context.WithCancel(context.Background())
	return &ResourcePreparation{sourceHash: sourceHash, resourceRoot: resourceRoot, ctx: ctx, cancel: cancel, config: config, selections: selections, resources: resources, stateRoot: stateRoot, mtu: mtu}, nil
}

// RefreshProvider restricts a bound preparation to replacing one named HTTP resource.
func (p *ResourcePreparation) RefreshProvider(kind, name string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.started || p.session == nil || (p.hotUpdate && p.target != nil) {
		return errors.New("a running YAML session is required")
	}
	var mapping map[string]any
	switch kind {
	case "proxy-provider":
		mapping = p.config.ProxyProviders[name]
	case "rule-provider":
		mapping = p.config.RuleProviders[name]
	}
	if mapping == nil || mapping["type"] != "http" {
		return errors.New("provider is not a configured HTTP source")
	}
	key := resourceKey{kind, name}
	p.target = &key
	return nil
}

func (p *ResourcePreparation) Cancel() { p.cancel() }
func (p *ResourcePreparation) ResourceCount() int32 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return int32(len(p.items))
}
func (p *ResourcePreparation) ResourceAt(index int32) (*PreparedResource, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if index < 0 || int(index) >= len(p.items) {
		return nil, errors.New("resource index is out of range")
	}
	return p.items[index], nil
}

func (p *ResourcePreparation) Prepare() (result error) {
	p.mu.Lock()
	if p.hotUpdate || p.started {
		p.mu.Unlock()
		return errors.New("invalid or already started resource preparation")
	}
	p.started = true
	p.mu.Unlock()
	defer func() {
		// Preparation is single use; only the successful result items remain
		// readable. In particular, this handle must not retain an old Session.
		p.resources = nil
		p.config = nil
		p.selections = nil
		p.session = nil
		if result != nil {
			debug.FreeOSMemory()
		}
	}()
	defer p.cancel()
	if err := p.ctx.Err(); err != nil {
		return err
	}
	if p.session != nil {
		return p.prepareBoundSession()
	}
	if !p.needsDownload() {
		return p.finishResources()
	}
	stopCancel := func() bool { return true }
	defer func() { stopCancel() }()
	session, err := newPacketSession(p.mtu, defaultUDPIdleTimeout, func(s *Session) error {
		stopCancel = context.AfterFunc(p.ctx, s.cancel)
		if err := p.ctx.Err(); err != nil {
			return err
		}
		s.configureKeepAlive(p.config.Raw)
		if err := s.configureHosts(p.config.Raw); err != nil {
			return err
		}
		r, err := p.newPreparationRouting(s)
		if err != nil {
			return err
		}
		s.routing = r
		if err := p.configureBootstrapDNS(s); err != nil {
			return err
		}
		r.healthJobs = nil
		return nil
	})
	if err != nil {
		return err
	}
	defer session.Close()
	return p.prepareUsingSession(session, session.routing)
}

func (p *ResourcePreparation) prepareBoundSession() error {
	s := p.session
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return context.Canceled
	}
	s.tasks.Add(1)
	s.mu.Unlock()
	defer s.tasks.Done()
	if key := p.target; key != nil {
		mapping := p.config.RuleProviders[key.name]
		if key.kind == "proxy-provider" {
			mapping = p.config.ProxyProviders[key.name]
		}
		data, err := p.downloadProvider(s, *key, mapping)
		if err != nil {
			return err
		}
		if err = p.addResource(*key, data); err != nil {
			return err
		}
		if err = p.ctx.Err(); err != nil {
			return err
		}
		return p.finishResources()
	}
	r, err := p.newPreparationRouting(s)
	if err != nil {
		return err
	}
	defer r.Close()
	return p.prepareUsingSession(s, r)
}

func (p *ResourcePreparation) newPreparationRouting(s *Session) (*routingConfiguration, error) {
	r := &routingConfiguration{mode: p.config.Mode, session: s, stateRoot: p.stateRoot, resources: p.resources, proxies: map[string]C.Proxy{}, groups: map[string]outboundgroup.ProxyGroup{}, disableUDP: map[string]bool{}}
	r.geo = &geoRuntime{resources: p.resources, mode: p.config.Raw.GeodataMode, algorithm: p.config.Raw.GeositeMatcher, ipMatchers: map[string]router.IPMatcher{}, siteMatchers: map[string]router.DomainMatcher{}}
	r.owned = append(r.owned, r.geo)
	if err := r.buildProxyGraph(p.config); err != nil {
		r.Close()
		return nil, fmt.Errorf("resource download proxy dependency cannot be prepared: %w", err)
	}
	for group, member := range p.selections {
		if err := r.selectProxy(group, member); err != nil {
			r.Close()
			return nil, err
		}
	}
	return r, nil
}

func (p *ResourcePreparation) prepareUsingSession(session *Session, validation *routingConfiguration) error {
	for name, mapping := range p.config.RuleProviders {
		key := resourceKey{"rule-provider", name}
		if mapping["type"] == "inline" || p.resources[key] != nil {
			continue
		}
		if mapping["type"] != "http" {
			return fmt.Errorf("rule-provider %s has no verified resource snapshot", name)
		}
		data, err := p.downloadProvider(session, key, mapping)
		if err != nil {
			if p.ctx.Err() != nil {
				return p.ctx.Err()
			}
			return fmt.Errorf("rule-provider %s download failed: %w", name, err)
		}
		if err := p.addResource(key, data); err != nil {
			return err
		}
	}
	if err := p.prepareRuleGeodata(session, validation); err != nil {
		return err
	}
	if err := p.ctx.Err(); err != nil {
		return err
	}
	return p.finishResources()
}

func (p *ResourcePreparation) finishResources() error {
	var total int
	keys := make([]resourceKey, 0, len(p.resources))
	for key, data := range p.resources {
		total += len(data)
		keys = append(keys, key)
	}
	if total > maximumResourceBundleBytes {
		return errors.New("resource bundle exceeds 64 MiB")
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].kind == keys[j].kind {
			return keys[i].name < keys[j].name
		}
		return keys[i].kind < keys[j].kind
	})
	items := make([]*PreparedResource, 0, len(keys))
	for _, key := range keys {
		items = append(items, &PreparedResource{Kind: key.kind, Name: key.name, Data: p.resources[key]})
	}
	p.mu.Lock()
	p.items = items
	p.mu.Unlock()
	return nil
}

func (p *ResourcePreparation) downloadProvider(session *Session, key resourceKey, mapping map[string]any) ([]byte, error) {
	return p.downloadWithReceipt(session, mapping, false, &key)
}

func (p *ResourcePreparation) downloadWithRoute(session *Session, mapping map[string]any, useCurrentRoute bool) ([]byte, error) {
	return p.downloadWithReceipt(session, mapping, useCurrentRoute, nil)
}
func (p *ResourcePreparation) downloadWithReceipt(session *Session, mapping map[string]any, useCurrentRoute bool, key *resourceKey) ([]byte, error) {
	rawURL, _ := mapping["url"].(string)
	parsed, err := url.Parse(rawURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Hostname() == "" {
		return nil, errors.New("resource URL must be HTTP or HTTPS")
	}
	proxyName, _ := mapping["proxy"].(string)
	if proxyName == "" {
		proxyName = "DIRECT"
	}
	session.routing.mu.Lock()
	proxy := session.routing.proxies[proxyName]
	session.routing.mu.Unlock()
	if proxy == nil && !useCurrentRoute {
		return nil, fmt.Errorf("unknown resource download proxy %s", proxyName)
	}
	ctx, cancel := context.WithTimeout(p.ctx, 60*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return nil, errors.New("invalid resource request")
	}
	if rawHeaders, exists := mapping["header"]; exists {
		headers, ok := rawHeaders.(map[string]any)
		if !ok {
			return nil, errors.New("resource headers must be a mapping")
		}
		for name, value := range headers {
			var values []any
			switch typed := value.(type) {
			case string:
				values = []any{typed}
			case []any:
				values = typed
			default:
				return nil, errors.New("resource header values must be strings")
			}
			for _, value := range values {
				text, ok := value.(string)
				if !ok {
					return nil, errors.New("resource header values must be strings")
				}
				request.Header.Add(name, text)
			}
		}
	}

	if request.Header.Get("User-Agent") == "" {
		agent := p.config.GlobalUA
		if agent == "" {
			agent = "Clash/FlClash-iOS"
		}
		request.Header.Set("User-Agent", agent)
	}
	transport := &http.Transport{DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		metadata := &C.Metadata{NetWork: C.TCP, Type: C.INNER}
		if err := metadata.SetRemoteAddress(address); err != nil {
			return nil, err
		}
		selected := proxy
		if useCurrentRoute {
			var err error
			selected, err = session.route(metadata)
			if err != nil {
				return nil, err
			}
		}
		return selected.DialContext(ctx, metadata)
	}}
	defer transport.CloseIdleConnections()
	response, err := (&http.Client{Transport: transport}).Do(request)
	if err != nil {
		var networkError net.Error
		switch {
		case errors.Is(err, context.Canceled):
			return nil, errors.New("resource HTTP request cancelled")
		case errors.Is(err, context.DeadlineExceeded), errors.As(err, &networkError) && networkError.Timeout():
			return nil, errors.New("resource HTTP request timed out")
		case errors.Is(err, io.EOF):
			return nil, errors.New("resource proxy connection closed")
		}
		return nil, errors.New("resource HTTP request failed")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("resource HTTP status %d", response.StatusCode)
	}
	maximum := maximumResourceBytes
	if limit, exists := mapping["size-limit"]; exists {
		value, ok := limit.(int)
		if !ok || value < 0 {
			return nil, errors.New("invalid resource size-limit")
		}
		if value > 0 && value < maximum {
			maximum = value
		}
	}
	limit := int64(maximum)
	if budget := p.memoryBudget.Load(); budget > 0 {
		for _, entry := range p.resources {
			budget -= int64(len(entry))
		}
		if budget <= 0 || response.ContentLength > budget {
			return nil, errors.New("resource download exceeds tunnel memory budget")
		}
		limit = min(limit, budget)
	}
	if response.ContentLength > limit {
		return nil, errors.New("resource exceeds size limit")
	}
	var data []byte
	if response.ContentLength >= 0 {
		// net/http bounds this body to the advertised Content-Length. Allocate
		// once so large providers do not occupy multiple temporary buffers.
		data = make([]byte, int(response.ContentLength))
		_, err = io.ReadFull(response.Body, data)
	} else {
		data, err = io.ReadAll(io.LimitReader(response.Body, limit+1))
	}
	if err != nil {
		return nil, err
	}
	if len(data) > maximum {
		return nil, errors.New("resource exceeds size limit")
	}
	if int64(len(data)) > limit {
		return nil, errors.New("resource download exceeds tunnel memory budget")
	}
	if p.hotUpdate {
		p.subscriptionHeader = response.Header.Get("Subscription-Userinfo")
	} else if key != nil {
		saveProviderReceipt(p.stateRoot, *key, mapping, data, response.Header.Get("Subscription-Userinfo"))
	}
	return data, nil
}

func (p *ResourcePreparation) prepareRuleGeodata(session *Session, validation *routingConfiguration) error {
	urls := map[string]string{"geoip-dat": p.config.Raw.GeoXUrl.GeoIp, "geosite-dat": p.config.Raw.GeoXUrl.GeoSite, "geoip-mmdb": p.config.Raw.GeoXUrl.Mmdb, "asn-mmdb": p.config.Raw.GeoXUrl.ASN}
	for {
		validation.rules = nil
		err := validation.loadMissingRuleProviders(p.config)
		if err == nil && p.config.Raw.DNS.Enable {
			_, err = MConfig.ParseMobileDNS(p.config.Raw, validation.ruleProviders, validation)
		}
		if err == nil {
			err = validation.buildRules(p.config)
		}
		if err == nil {
			return nil
		}
		var missing *missingGeoResource
		if !errors.As(err, &missing) {
			return err
		}
		key := resourceKey{missing.kind, "default"}
		if p.resources[key] != nil || urls[missing.kind] == "" {
			return err
		}
		data, downloadErr := p.downloadWithRoute(session, map[string]any{"url": urls[missing.kind], "proxy": "DIRECT"}, p.session != nil)
		if downloadErr != nil {
			if p.ctx.Err() != nil {
				return p.ctx.Err()
			}
			return fmt.Errorf("%s download failed: %w", missing.kind, downloadErr)
		}
		if err := p.addResource(key, data); err != nil {
			return err
		}
	}
}

func (p *ResourcePreparation) configureBootstrapDNS(s *Session) error {
	raw := p.config.Raw.DNS
	if !raw.Enable {
		return nil
	}
	if raw.ProxyServerNameserverPolicy != nil && raw.ProxyServerNameserverPolicy.Len() > 0 {
		return errors.New("resource bootstrap DNS does not support proxy-server-nameserver-policy")
	}
	parse := func(values []string) ([]M.NameServer, error) {
		servers, err := M.ParseNameServer(values)
		if err != nil {
			return nil, errors.New("invalid resource bootstrap nameserver")
		}
		for _, server := range servers {
			if server.ProxyName != "" && server.ProxyName != "DIRECT" {
				return nil, errors.New("resource bootstrap DNS cannot depend on a proxy or routing rules")
			}
		}
		for index := range servers {
			servers[index].ProxyName = ""
		}
		return servers, nil
	}
	servers := raw.ProxyServerNameserver
	if len(servers) == 0 {
		servers = raw.NameServer
	}
	main, err := parse(servers)
	if err != nil {
		return err
	}
	defaults, err := parse(raw.DefaultNameserver)
	if err != nil {
		return err
	}
	direct, err := parse(raw.DirectNameServer)
	if err != nil {
		return err
	}
	rs := M.NewResolver(M.Config{Context: s.dnsOwner.scope.Context(), Main: main, Default: defaults, ProxyServer: main, DirectServer: direct, IPv6: raw.IPv6})
	previous := s.dnsOwner.runtime.Swap(&dnsRuntime{scope: s.dnsOwner.scope, resolvers: rs})
	previous.resolvers.ResetConnection()
	return nil
}

func (p *ResourcePreparation) needsDownload() bool {
	for name, mapping := range p.config.ProxyProviders {
		if mapping["type"] != "inline" && p.resources[resourceKey{"proxy-provider", name}] == nil {
			return true
		}
	}
	for name, mapping := range p.config.RuleProviders {
		if mapping["type"] != "inline" && p.resources[resourceKey{"rule-provider", name}] == nil {
			return true
		}
	}
	return false
}
func (p *ResourcePreparation) addResource(key resourceKey, data []byte) error {
	total := len(data)
	for existing, value := range p.resources {
		if existing != key {
			total += len(value)
		}
	}
	if total > maximumResourceBundleBytes {
		return errors.New("resource bundle exceeds 64 MiB")
	}
	p.resources[key] = data
	return nil
}
