package mobile

import (
	"context"
	"errors"
	"net/netip"
	"runtime/debug"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/component/keepalive"
	MConfig "github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	tun "github.com/metacubex/sing-tun"
)

const defaultUDPIdleTimeout = 30 * time.Second
const packetIPv4CIDR = "198.18.0.1/30"
const packetIPv6CIDR = "fd00:198:18::1/126"

var sessionOwner struct {
	sync.Mutex
	active *Session
}

type Session struct {
	providerUpdateMu  sync.Mutex
	providerResources map[resourceKey][]byte
	exitIPMu          sync.Mutex
	exitIPCancel      context.CancelFunc
	exitIPGeneration  uint64
	exitIPRequestID   int64
	ipQualityCache    ipQualityCache
	sharingMu         sync.Mutex
	sharing           *sharingServer
	telemetry         *runtimeTelemetry
	device            *packetDevice
	stack             tun.Stack
	proxy             C.Proxy
	routing           *routingConfiguration
	dnsOwner          *dnsOwner
	testContext       context.Context
	cancelTests       context.CancelFunc
	testSlots         chan struct{}
	udpIdleTimeout    time.Duration
	ctx               context.Context
	cancel            context.CancelFunc
	mu                sync.Mutex
	closed            bool
	tasks             sync.WaitGroup
	flows             map[flowKey]*udpFlow
	closeOnce         sync.Once
	closeErr          error
	restoreKeepAlive  func()
	resourcesPending  bool
}

func (s *Session) ResourcesPending() bool { return s.resourcesPending }

func Version() string {
	return "mihomo 024245dc72bc92f48237f865119afe0cd53ac9e6 / phase2 session YAML"
}

// NewSession starts only an in-memory DIRECT fixture, never a host TUN or listener.
func NewSession(mtu int32) (*Session, error) {
	return newSession(mtu, map[string]any{"name": "DIRECT", "type": "direct"}, defaultUDPIdleTimeout)
}

func newSession(mtu int32, options map[string]any, udpIdleTimeout time.Duration) (*Session, error) {
	return newPacketSession(mtu, udpIdleTimeout, func(s *Session) error { var err error; s.proxy, err = adapter.ParseProxy(options); return err })
}

func newPacketSession(mtu int32, udpIdleTimeout time.Duration, prepare func(*Session) error) (*Session, error) {
	if mtu < 1280 || mtu > 9000 {
		return nil, errors.New("MTU must be between 1280 and 9000")
	}
	sessionOwner.Lock()
	defer sessionOwner.Unlock()
	if sessionOwner.active != nil {
		return nil, errors.New("a packet session is already active")
	}
	ctx, cancel := context.WithCancel(context.Background())
	session := &Session{device: newPacketDevice(int(mtu)), ctx: ctx, cancel: cancel, udpIdleTimeout: udpIdleTimeout, flows: make(map[flowKey]*udpFlow), testSlots: make(chan struct{}, 4)}
	session.telemetry = newRuntimeTelemetry()
	session.testContext, session.cancelTests = context.WithCancel(ctx)
	session.initializeDNSOwner()
	err := prepare(session)
	if err == nil {
		session.stack, err = tun.NewStack("mips", tun.StackOptions{
			Context: ctx, Tun: session.device,
			TunOptions: tun.Options{MTU: uint32(mtu), Inet4Address: []netip.Prefix{netip.MustParsePrefix(packetIPv4CIDR)}, Inet6Address: []netip.Prefix{netip.MustParsePrefix(packetIPv6CIDR)}},
			UDPTimeout: udpIdleTimeout, ICMPTimeout: 5 * time.Second, Handler: &sessionHandler{session: session}, Logger: log.SingLogger,
		})
		if err == nil {
			err = session.stack.Start()
		}
	}
	if err != nil {
		cancel()
		_ = session.device.Close()
		if session.stack != nil {
			_ = session.stack.Close()
		}
		session.tasks.Wait()
		session.dnsOwner.scope.Close()
		session.dnsOwner.runtime.Load().resolvers.ResetConnection()
		_ = session.closeProxies()
		if session.restoreKeepAlive != nil {
			session.restoreKeepAlive()
		}
		session.telemetry.addLog("error", "Packet session failed: "+err.Error())
		session.telemetry.stopLogs()
		session.releaseClosedState()
		return nil, err
	}

	session.telemetry.addLog("info", "Packet session started")
	session.startHealthChecks()
	sessionOwner.active = session
	return session, nil
}

func (s *Session) closeProxies() error {
	if s.routing != nil {
		return s.routing.Close()
	}
	if s.proxy != nil {
		return s.proxy.Close()
	}
	return nil
}

func (s *Session) configureKeepAlive(raw *MConfig.RawConfig) {
	idle, interval, disabled := keepalive.KeepAliveIdle(), keepalive.KeepAliveInterval(), keepalive.DisableKeepAlive()
	s.restoreKeepAlive = func() {
		keepalive.SetKeepAliveIdle(idle)
		keepalive.SetKeepAliveInterval(interval)
		keepalive.SetDisableKeepAlive(disabled)
	}
	keepalive.SetKeepAliveIdle(time.Duration(raw.KeepAliveIdle) * time.Second)
	keepalive.SetKeepAliveInterval(time.Duration(raw.KeepAliveInterval) * time.Second)
	keepalive.SetDisableKeepAlive(raw.DisableKeepAlive)
}

func (s *Session) route(metadata *C.Metadata) (C.Proxy, error) {
	if s.routing != nil {
		return s.routing.route(metadata)
	}
	return s.proxy, nil
}

// SubmitPacket accepts a packet from the system tunnel. Congestion and malformed
// input are local packet drops. A closed device still terminates the data pump.
func (s *Session) SubmitPacket(packet []byte) error {
	err := s.device.inject(packet)
	if _, invalid := err.(invalidPacketError); invalid || err == errQueueFull {
		return nil
	}
	return err
}

// WritePacket reports individual delivery and validation errors to diagnostics.
func (s *Session) WritePacket(packet []byte) error { return s.device.inject(packet) }
func (s *Session) ReadPacket() ([]byte, error)     { return s.device.receive() }

func (s *Session) Close() error {
	s.closeOnce.Do(func() {
		sessionOwner.Lock()
		defer sessionOwner.Unlock()
		s.mu.Lock()
		s.closed = true
		s.mu.Unlock()
		s.cancel()
		s.sharingMu.Lock()
		s.stopSharingLocked()
		s.sharingMu.Unlock()
		_ = s.device.Close()
		s.closeErr = s.stack.Close()
		s.tasks.Wait()
		s.dnsOwner.scope.Close()
		s.dnsOwner.runtime.Load().resolvers.ResetConnection()
		s.closeErr = errors.Join(s.closeErr, s.closeProxies())
		if s.restoreKeepAlive != nil {
			s.restoreKeepAlive()
		}
		s.telemetry.addLog("info", "Packet session stopped")
		s.telemetry.stopLogs()
		sessionOwner.active = nil
		s.releaseClosedState()
		debug.FreeOSMemory()
	})
	return s.closeErr
}

// All session tasks and owned connections have stopped before these references
// are dropped. Language bridges may retain the closed Session for much longer.
func (s *Session) releaseClosedState() {
	activeDNSOwner.CompareAndSwap(s.dnsOwner, nil)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.routing = nil
	s.proxy = nil
	s.stack = nil
	s.dnsOwner = nil
	s.providerResources = nil
	s.flows = nil
}
