package mobile

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"time"

	C "github.com/metacubex/mihomo/constant"
	tun "github.com/metacubex/sing-tun"
	"github.com/metacubex/sing/common/buf"
	"github.com/metacubex/sing/common/bufio"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
)

type sessionHandler struct{ session *Session }

const maxUDPFlows = 256
const udpFlowQueueSize = 16

type flowKey struct{ source, destination netip.AddrPort }
type udpFlow struct {
	packets chan *buf.Buffer
}

func (h *sessionHandler) NewConnection(_ context.Context, inbound net.Conn, metadata M.Metadata) error {
	s := h.session
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return inbound.Close()
	}
	if s.routing != nil && s.routing.dns != nil && s.routing.dnsHijack.matches("tcp", metadata.Destination.AddrPort()) {
		dns := s.routing.dns
		s.tasks.Add(1)
		s.mu.Unlock()
		defer s.tasks.Done()
		defer inbound.Close()
		return dns.serveStream(inbound)
	}
	s.mu.Unlock()
	return s.forwardTCP(s.ctx, inbound, proxyMetadata(metadata, C.TCP), nil)
}

func (s *Session) forwardTCP(parent context.Context, inbound net.Conn, target *C.Metadata, ready func(error) error) (result error) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return inbound.Close()
	}
	s.tasks.Add(1)
	s.mu.Unlock()
	defer s.tasks.Done()
	defer inbound.Close()
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	tracked := s.telemetry.begin(target, cancel)
	defer func() { tracked.finish(result) }()
	stopInbound := context.AfterFunc(ctx, func() { _ = inbound.Close() })
	defer stopInbound()
	defer func() {
		if result != nil && ready != nil {
			_ = ready(result)
		}
	}()
	stream, err := s.sniffTCP(inbound, target)
	if err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	proxy, rule, err := s.routeWithRule(target)
	if err != nil {
		return err
	}
	if s.routing != nil && s.routing.dns != nil && proxy.IsL3Protocol(target) {
		if err := s.routing.dns.resolve(target); err != nil {
			return err
		}
	}
	tracked.routed(target, proxy.Name(), rule)
	outbound, err := proxy.DialContext(ctx, target)
	if err != nil {
		return err
	}
	defer outbound.Close()
	if ready != nil {
		callback := ready
		ready = nil
		if err := callback(nil); err != nil {
			return err
		}
	}
	return bufio.CopyConn(ctx, &runtimeCountedConn{Conn: stream, count: tracked.countDownload}, &runtimeCountedConn{Conn: outbound, count: tracked.countUpload})
}

func (h *sessionHandler) NewPacket(_ context.Context, _ netip.AddrPort, packet *buf.Buffer, metadata M.Metadata, initialize func(N.PacketConn) N.PacketWriter) {
	s := h.session
	key := flowKey{metadata.Source.AddrPort(), metadata.Destination.AddrPort()}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		packet.Release()
		return
	}
	if s.routing != nil && s.routing.dns != nil && s.routing.dnsHijack.matches("udp", metadata.Destination.AddrPort()) {
		request := dnsRequest{packet: packet, destination: metadata.Destination, writer: initialize(nil)}
		select {
		case s.routing.dns.requests <- request:
		default:
			packet.Release()
		}
		return
	}
	flow := s.flows[key]
	if flow == nil {
		if len(s.flows) == maxUDPFlows {
			packet.Release()
			return
		}
		flow = &udpFlow{packets: make(chan *buf.Buffer, udpFlowQueueSize)}
		s.flows[key] = flow
		s.tasks.Add(1)
		writer := initialize(nil)
		go s.runUDP(key, flow, metadata, writer)
	}
	select {
	case flow.packets <- packet:
	default:
		packet.Release()
	}
}

func (s *Session) runUDP(key flowKey, flow *udpFlow, metadata M.Metadata, writer N.PacketWriter) {
	defer s.tasks.Done()
	defer func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		delete(s.flows, key)
		for {
			select {
			case packet := <-flow.packets:
				packet.Release()
			default:
				return
			}
		}
	}()
	target := proxyMetadata(metadata, C.UDP)
	ctx, cancel := context.WithCancel(s.ctx)
	defer cancel()
	tracked := s.telemetry.begin(target, cancel)
	var result error
	defer func() { tracked.finish(result) }()
	proxy, rule, err := s.routeWithRule(target)
	if err != nil {
		result = err
		return
	}
	tracked.routed(target, proxy.Name(), rule)
	if !proxy.SupportUDP() {
		result = errors.New("proxy does not support UDP")
		return
	}
	if s.routing != nil && s.routing.dns != nil {
		if err := s.routing.dns.resolve(target); err != nil {
			result = err
			return
		}
	}
	outbound, err := proxy.ListenPacketContext(ctx, target)
	if err != nil {
		result = err
		return
	}
	closeDone := make(chan struct{})
	stopClose := context.AfterFunc(ctx, func() {
		_ = outbound.Close()
		close(closeDone)
	})
	defer func() {
		if !stopClose() {
			<-closeDone
		}
	}()
	defer outbound.Close()
	repliesDone := make(chan struct{})
	_ = outbound.SetReadDeadline(time.Now().Add(s.udpIdleTimeout))
	go func() {
		defer close(repliesDone)
		buffer := make([]byte, 65535)
		for {
			n, source, err := outbound.ReadFrom(buffer)
			if err != nil {
				return
			}
			_ = outbound.SetReadDeadline(time.Now().Add(s.udpIdleTimeout))
			packet := buf.NewSize(n)
			_, _ = packet.Write(buffer[:n])
			if err := writer.WritePacket(packet, udpReplySource(source, target, metadata.Destination)); err != nil {
				return
			}
			tracked.countDownload(int64(n))
		}
	}()
	defer func() { _ = outbound.Close(); <-repliesDone }()
	destination := net.UDPAddrFromAddrPort(target.AddrPort())
	for {
		select {
		case <-ctx.Done():
			return
		case <-repliesDone:
			return
		case packet := <-flow.packets:
			deadline := time.Now().Add(s.udpIdleTimeout)
			_ = outbound.SetReadDeadline(deadline)
			_ = outbound.SetWriteDeadline(deadline)
			n, err := outbound.WriteTo(packet.Bytes(), destination)
			tracked.countUpload(int64(n))
			packet.Release()
			if err != nil {
				result = err
				return
			}
		}
	}
}

func proxyMetadata(metadata M.Metadata, network C.NetWork) *C.Metadata {
	return &C.Metadata{NetWork: network, Type: C.TUN, SrcIP: metadata.Source.Addr, SrcPort: metadata.Source.Port, DstIP: metadata.Destination.Addr, DstPort: metadata.Destination.Port}
}

func (h *sessionHandler) PrepareConnection(string, M.Socksaddr, M.Socksaddr, tun.DirectRouteContext, time.Duration) (tun.DirectRouteDestination, error) {
	if h.session.routing != nil {
		return nil, tun.ErrDrop
	}
	return nil, nil
}
func (h *sessionHandler) NewError(_ context.Context, err error) {
	h.session.telemetry.addLog("error", err.Error())
}

func udpReplySource(source net.Addr, target *C.Metadata, original M.Socksaddr) M.Socksaddr {
	address := M.SocksaddrFromNet(source)
	if address.AddrPort() == target.AddrPort() {
		return original
	}
	return address
}
