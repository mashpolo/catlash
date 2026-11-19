package mobile

import (
	"context"
	"encoding/binary"
	"errors"
	"go.yaml.in/yaml/v3"
	"io"
	"net"
	"net/netip"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/component/fakeip"
	"github.com/metacubex/mihomo/component/resolver"
	MConfig "github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	M "github.com/metacubex/mihomo/dns"
	"github.com/metacubex/sing/common/buf"
	SM "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
	D "github.com/miekg/dns"
)

type dnsOwner struct {
	scope   *M.SessionScope
	runtime atomic.Pointer[dnsRuntime]
	hosts   atomic.Pointer[sessionHostEntries]
}

var activeDNSOwner atomic.Pointer[dnsOwner]

type dnsRequest struct {
	packet      *buf.Buffer
	destination SM.Socksaddr
	writer      N.PacketWriter
}
type dnsRuntime struct {
	system      bool
	scope       *M.SessionScope
	resolvers   M.Resolvers
	mapper      *M.ResolverEnhancer
	service     *M.Service
	enabled     bool
	requests    chan dnsRequest
	fakeIPState *fakeIPState
}

func init() {
	parseNameservers := M.ParseNameServer
	M.ParseNameServer = func(values []string) ([]M.NameServer, error) {
		servers, err := parseNameservers(values)
		if err != nil {
			return nil, errors.New("invalid outbound DNS nameservers")
		}
		for _, server := range servers {
			if server.Net == "dhcp" {
				return nil, errors.New("outbound DNS dhcp discovery is unsupported on iOS")
			}
		}
		return servers, nil
	}
	resolver.DisableIPv6 = false
	M.ContextProvider = func() context.Context {
		if owner := activeDNSOwner.Load(); owner != nil {
			return owner.scope.Context()
		}
		return nil
	}
	resolver.DefaultResolver = &sessionResolver{}
	resolver.DefaultHosts = sessionHosts{}
	resolver.ProxyServerHostResolver = &sessionResolver{kind: 1}
	resolver.DirectHostResolver = &sessionResolver{kind: 2}
}

func (s *Session) initializeDNSOwner() {
	s.dnsOwner = &dnsOwner{scope: M.NewSessionScope(M.WithQueryNotify(s.ctx, s.telemetry.addDNS))}
	system := M.NewResolver(M.Config{Context: s.dnsOwner.scope.Context(), Main: []M.NameServer{{Net: "system"}}, IPv6: true})
	s.dnsOwner.runtime.Store(&dnsRuntime{scope: s.dnsOwner.scope, resolvers: system, system: true})
	activeDNSOwner.Store(s.dnsOwner)
}

func (s *Session) buildDNS(config *yamlConfiguration) error {
	if s.routing.allowDeferredResources {
		filtered, pending, err := s.routing.deferredDNSConfiguration(config)
		if err != nil {
			return err
		}
		if pending {
			// Save only the effective DNS fields changed during deferred startup.
			var effective yaml.Node
			if err := effective.Encode(&filtered.Raw.DNS); err != nil {
				return err
			}
			s.routing.inspection.deferredDNS = &effective
		}
		config = filtered
		s.resourcesPending = s.resourcesPending || pending
	}
	if !config.Raw.Profile.StoreFakeIP {
		if _, err := openFakeIPState(s.routing.stateRoot, false, [2]*fakeip.Pool{}, nil); err != nil {
			return err
		}
	}
	if !config.Raw.DNS.Enable {
		return nil
	}
	parsed, err := MConfig.ParseMobileDNS(config.Raw, s.routing.ruleProviders, s.routing)
	if err != nil {
		var missing *missingGeoResource
		if errors.As(err, &missing) {
			return missing
		}
		return errors.New("dns: invalid resolver, policy or fake-IP options")
	}
	r := s.routing
	bind := func(servers []M.NameServer) error {
		for index := range servers {
			ns := &servers[index]
			if ns.Net == "dhcp" {
				return errors.New("dns nameserver dhcp discovery is unsupported on iOS")
			}
			if ns.ProxyName == "" {
				continue
			}
			if ns.ProxyName == M.RespectRules {
				ns.ProxyAdapter = &dnsRoutingProxy{Base: outbound.NewBase(outbound.BaseOption{Name: "DNS", Type: C.Direct, UDP: true}), routing: r}
			} else {
				_, ok := r.proxies[ns.ProxyName]
				if !ok {
					return errors.New("dns nameserver references an unknown proxy")
				}
				r.requireNode(ns.ProxyName)
				ns.ProxyAdapter = &dnsRoutingProxy{Base: outbound.NewBase(outbound.BaseOption{Name: "DNS", Type: C.Direct, UDP: true}), routing: r, target: ns.ProxyName}
			}
			ns.ProxyName = ""
		}
		return nil
	}
	for _, servers := range [][]M.NameServer{parsed.NameServer, parsed.Fallback, parsed.DefaultNameserver, parsed.ProxyServerNameserver, parsed.DirectNameServer} {
		if err := bind(servers); err != nil {
			return err
		}
	}
	for _, policies := range [][]M.Policy{parsed.NameServerPolicy, parsed.ProxyServerPolicy} {
		for _, policy := range policies {
			if err := bind(policy.NameServers); err != nil {
				return err
			}
		}
	}
	rs := M.NewResolver(M.Config{Context: s.dnsOwner.scope.Context(), Main: parsed.NameServer, Fallback: parsed.Fallback, Default: parsed.DefaultNameserver, ProxyServer: parsed.ProxyServerNameserver, DirectServer: parsed.DirectNameServer, DirectFollowPolicy: parsed.DirectFollowPolicy, IPv6: parsed.IPv6, IPv6Timeout: parsed.IPv6Timeout, FallbackIPFilter: parsed.FallbackIPFilter, FallbackDomainFilter: parsed.FallbackDomainFilter, FallbackLazyQuery: parsed.FallbackLazyQuery, Policy: parsed.NameServerPolicy, ProxyServerPolicy: parsed.ProxyServerPolicy, CacheAlgorithm: parsed.CacheAlgorithm, CacheMaxSize: parsed.CacheMaxSize})
	var state *fakeIPState
	if config.Raw.Profile.StoreFakeIP && (parsed.FakeIPPool != nil || parsed.FakeIPPool6 != nil) {
		state, err = openFakeIPState(r.stateRoot, config.Raw.Profile.StoreFakeIP, [2]*fakeip.Pool{parsed.FakeIPPool, parsed.FakeIPPool6}, func(message string) { s.telemetry.addLog("error", message) })
		if err != nil {
			rs.ResetConnection()
			return err
		}
		if state != nil {
			r.owned = append(r.owned, state)
		}
	}
	mapper := M.NewEnhancer(M.EnhancerConfig{IPv6: parsed.IPv6, EnhancedMode: parsed.EnhancedMode, FakeIPPool: parsed.FakeIPPool, FakeIPPool6: parsed.FakeIPPool6, FakeIPSkipper: parsed.FakeIPSkipper, FakeIPTTL: parsed.FakeIPTTL, UseHosts: parsed.UseHosts})
	runtime := &dnsRuntime{scope: s.dnsOwner.scope, resolvers: rs, mapper: mapper, service: M.NewService(rs.Resolver, mapper), enabled: true, requests: make(chan dnsRequest, 64), fakeIPState: state}
	previous := s.dnsOwner.runtime.Swap(runtime)
	previous.resolvers.ResetConnection()
	r.dns = runtime
	for range 4 {
		s.tasks.Add(1)
		go func() { defer s.tasks.Done(); runtime.servePackets() }()
	}
	return nil
}

func (d *dnsRuntime) servePackets() {
	for {
		select {
		case <-d.scope.Context().Done():
			for {
				select {
				case request := <-d.requests:
					request.packet.Release()
				default:
					return
				}
			}
		case request := <-d.requests:
			response, err := d.answer(request.packet.Bytes())
			request.packet.Release()
			if err == nil {
				buffer := buf.NewSize(len(response))
				_, _ = buffer.Write(response)
				_ = request.writer.WritePacket(buffer, request.destination)
			}
		}
	}
}
func (d *dnsRuntime) answer(packet []byte) ([]byte, error) {
	request := new(D.Msg)
	if err := request.Unpack(packet); err != nil {
		return nil, errors.New("invalid DNS request")
	}
	ctx, cancel := context.WithTimeout(d.scope.Context(), 5*time.Second)
	defer cancel()
	response, err := d.service.ServeMsg(ctx, request)
	if err != nil {
		response = new(D.Msg)
		response.SetRcode(request, D.RcodeServerFailure)
	}
	if err := d.fakeIPState.save(); err != nil {
		return nil, err
	}
	return response.Pack()
}
func (d *dnsRuntime) serveStream(conn net.Conn) error {
	defer conn.Close()
	closed := make(chan struct{})
	stop := context.AfterFunc(d.scope.Context(), func() { _ = conn.Close(); close(closed) })
	defer func() {
		if !stop() {
			<-closed
		}
	}()
	header := make([]byte, 2)
	for {
		if _, err := io.ReadFull(conn, header); err != nil {
			return err
		}
		packet := make([]byte, int(binary.BigEndian.Uint16(header)))
		if _, err := io.ReadFull(conn, packet); err != nil {
			return err
		}
		response, err := d.answer(packet)
		if err != nil {
			return err
		}
		binary.BigEndian.PutUint16(header, uint16(len(response)))
		if _, err = conn.Write(append(header, response...)); err != nil {
			return err
		}
	}
}

func (d *dnsRuntime) restore(metadata *C.Metadata) error {
	if host, ok := d.mapper.FindHostByIP(metadata.DstIP); ok {
		metadata.Host = host
		metadata.DNSMode = C.DNSMapping
		if d.mapper.IsFakeIP(metadata.DstIP) {
			metadata.DstIP = netip.Addr{}
			metadata.DNSMode = C.DNSFakeIP
		}
	} else if d.mapper.IsFakeIP(metadata.DstIP) {
		return errors.New("fake-IP mapping no longer exists")
	}
	return nil
}
func (d *dnsRuntime) resolve(metadata *C.Metadata) error {
	if metadata.DstIP.IsValid() || metadata.Host == "" {
		return nil
	}
	ip, err := resolver.ResolveIPWithResolver(d.scope.Context(), metadata.Host, d.resolvers.Resolver)
	if err == nil {
		metadata.DstIP = ip
	}
	return err
}

type sessionResolver struct{ kind int }

func (s *sessionResolver) current(ctx context.Context) (resolver.Resolver, context.Context, func(), error) {
	if err := ctx.Err(); err != nil {
		return nil, ctx, func() {}, err
	}
	owner := activeDNSOwner.Load()
	if owner == nil {
		return resolver.SystemResolver, ctx, func() {}, nil
	}
	if err := owner.scope.Context().Err(); err != nil {
		return nil, ctx, func() {}, err
	}
	runtime := owner.runtime.Load()
	var selected resolver.Resolver = runtime.resolvers.Resolver
	if runtime.system {
		selected = &platformSystemResolver{Resolver: selected}
	}
	if s.kind == 1 && runtime.resolvers.ProxyResolver != nil {
		selected = runtime.resolvers.ProxyResolver
	}
	if s.kind == 2 && runtime.resolvers.DirectResolver != nil {
		selected = runtime.resolvers.DirectResolver
	}
	ctx, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(owner.scope.Context(), cancel)
	return selected, ctx, func() { stop(); cancel() }, nil
}
func (s *sessionResolver) LookupIP(ctx context.Context, host string) ([]netip.Addr, error) {
	if ip, err := netip.ParseAddr(host); err == nil {
		return []netip.Addr{ip.Unmap()}, nil
	}
	r, ctx, done, err := s.current(ctx)
	defer done()
	if err != nil {
		return nil, err
	}
	return r.LookupIP(ctx, host)
}
func (s *sessionResolver) LookupIPv4(ctx context.Context, host string) ([]netip.Addr, error) {
	if ip, err := netip.ParseAddr(host); err == nil {
		if ip.Unmap().Is4() {
			return []netip.Addr{ip.Unmap()}, nil
		}
		return nil, resolver.ErrIPVersion
	}
	r, ctx, done, err := s.current(ctx)
	defer done()
	if err != nil {
		return nil, err
	}
	return r.LookupIPv4(ctx, host)
}
func (s *sessionResolver) LookupIPv6(ctx context.Context, host string) ([]netip.Addr, error) {
	if ip, err := netip.ParseAddr(host); err == nil {
		if ip.Is6() && !ip.Is4In6() {
			return []netip.Addr{ip}, nil
		}
		return nil, resolver.ErrIPVersion
	}
	r, ctx, done, err := s.current(ctx)
	defer done()
	if err != nil {
		return nil, err
	}
	return r.LookupIPv6(ctx, host)
}
func (s *sessionResolver) ResolveECH(ctx context.Context, host string) ([]byte, error) {
	r, ctx, done, err := s.current(ctx)
	defer done()
	if err != nil {
		return nil, err
	}
	return r.ResolveECH(ctx, host)
}
func (s *sessionResolver) ExchangeContext(ctx context.Context, msg *D.Msg) (*D.Msg, error) {
	r, ctx, done, err := s.current(ctx)
	defer done()
	if err != nil {
		return nil, err
	}
	return r.ExchangeContext(ctx, msg)
}
func (s *sessionResolver) Invalid() bool    { return true }
func (s *sessionResolver) ClearCache()      {}
func (s *sessionResolver) ResetConnection() {}

type dnsRoutingProxy struct {
	*outbound.Base
	routing *routingConfiguration
	target  string
}

func (p *dnsRoutingProxy) DialContext(ctx context.Context, metadata *C.Metadata) (C.Conn, error) {
	proxy, err := p.resolve(metadata)
	if err != nil {
		return nil, err
	}
	return proxy.DialContext(ctx, metadata)
}
func (p *dnsRoutingProxy) ListenPacketContext(ctx context.Context, metadata *C.Metadata) (C.PacketConn, error) {
	proxy, err := p.resolve(metadata)
	if err != nil {
		return nil, err
	}
	return proxy.ListenPacketContext(ctx, metadata)
}

var _ C.ProxyAdapter = (*dnsRoutingProxy)(nil)

func (p *dnsRoutingProxy) resolve(metadata *C.Metadata) (C.Proxy, error) {
	if p.target == "" {
		return p.routing.route(metadata)
	}
	p.routing.mu.Lock()
	proxy := p.routing.resolveLocked(p.target, metadata, true)
	p.routing.mu.Unlock()
	if proxy == nil {
		return nil, errors.New("UDP is disabled for DNS proxy group")
	}
	return proxy, nil
}
