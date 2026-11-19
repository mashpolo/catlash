package mobile

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gofrs/uuid/v5"
	"github.com/metacubex/mihomo/adapter/inbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/sing"
	"github.com/metacubex/mihomo/transport/socks5"
	"github.com/metacubex/mihomo/transport/tuic"
	"github.com/metacubex/quic-go"
	"github.com/metacubex/quic-go/qlogwriter"
	"github.com/metacubex/sing-quic/hysteria2"
	"github.com/metacubex/sing/common/buf"
	"github.com/metacubex/sing/common/logger"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
	"github.com/metacubex/tls"
)

type interopQUICTrace struct {
	done chan struct{}
	once sync.Once
}

func (w *interopQUICTrace) Write(p []byte) (int, error) { return len(p), nil }
func (w *interopQUICTrace) Close() error                { w.once.Do(func() { close(w.done) }); return nil }

type interopQUICFixture struct {
	udp       *net.UDPConn
	tls       *tls.Config
	pin       string
	ctx       context.Context
	cancel    context.CancelFunc
	config    *quic.Config
	mu        sync.Mutex
	traces    []*interopQUICTrace
	handled   chan error
	stop      func() error
	serveDone <-chan error
}

func newInteropQUICFixture(t *testing.T) *interopQUICFixture {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	certificate := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{"localhost"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	privateKey, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	pair, err := tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateKey}))
	if err != nil {
		t.Fatal(err)
	}
	udp, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	f := &interopQUICFixture{udp: udp, tls: &tls.Config{Certificates: []tls.Certificate{pair}, NextProtos: []string{"h3"}, MinVersion: tls.VersionTLS13}, pin: fmt.Sprintf("%x", sha256.Sum256(der)), ctx: ctx, cancel: cancel, handled: make(chan error, 4)}
	f.config = &quic.Config{EnableDatagrams: true, MaxIncomingStreams: 16, MaxIncomingUniStreams: 16, MaxIdleTimeout: 30 * time.Second, HandshakeIdleTimeout: time.Second, DisablePathMTUDiscovery: true, Tracer: func(_ context.Context, _ bool, _ quic.ConnectionID) qlogwriter.Trace {
		trace := &interopQUICTrace{done: make(chan struct{})}
		f.mu.Lock()
		f.traces = append(f.traces, trace)
		f.mu.Unlock()
		writer := qlogwriter.NewFileSeq(trace)
		go writer.Run()
		return writer
	}}
	t.Cleanup(func() {
		cancel()
		if f.stop != nil {
			if err := f.stop(); err != nil {
				t.Errorf("server.Close: %v", err)
			}
		}
		udp.Close()
		if f.serveDone != nil {
			select {
			case <-f.serveDone:
			case <-time.After(2 * time.Second):
				t.Error("TUIC Serve did not exit")
			}
		}
		f.mu.Lock()
		traces := append([]*interopQUICTrace(nil), f.traces...)
		f.mu.Unlock()
		if len(traces) == 0 {
			t.Error("no native server QUIC connection observed")
		}
		for _, trace := range traces {
			select {
			case <-trace.done:
			case <-time.After(3 * time.Second):
				t.Error("server QUIC connection did not exit")
			}
		}
		t.Logf("server shutdown observed: %d QUIC connection(s), context cancelled", len(traces))
	})
	return f
}

func (f *interopQUICFixture) port() int { return f.udp.LocalAddr().(*net.UDPAddr).Port }

func (f *interopQUICFixture) tcp(conn net.Conn, target string) error {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	err := interopEcho(conn, target)
	f.handled <- err
	return err
}

func (f *interopQUICFixture) packet(conn N.PacketConn, metadata M.Metadata) error {
	defer conn.Close()
	input := buf.NewPacket()
	defer input.Release()
	target, err := conn.ReadPacket(input)
	if err == nil && (target.String() != interopTarget || metadata.Destination.String() != interopTarget || string(input.Bytes()) != "hello") {
		err = fmt.Errorf("unexpected QUIC UDP target or payload")
	}
	if err == nil {
		headroom := N.CalculateFrontHeadroom(conn)
		output := buf.NewSize(headroom + len("proxy:hello"))
		output.Resize(headroom, 0)
		output.Write([]byte("proxy:hello"))
		err = conn.WritePacket(output, target)
	}
	f.handled <- err
	return err
}

func runInteropQUIC(t *testing.T, f *interopQUICFixture, proxy, mode string) {
	t.Helper()
	password := "secret"
	pin := f.pin
	if mode == "bad-password" {
		password = "wrong"
	}
	if mode == "bad-pin" {
		pin = strings.Repeat("0", 64)
	}
	session := interopSession(t, fmt.Sprintf("%s, password: %s, sni: localhost, fingerprint: '%s'", proxy, password, pin), f.port())
	if strings.HasPrefix(mode, "bad-") {
		err := interopRejected(t, session)
		if mode == "bad-pin" && !strings.Contains(err.Error(), "fingerprints do not match") {
			t.Fatalf("expected pin rejection, got %v", err)
		}
		if mode == "bad-password" {
			expected := "authentication failed, status code: 404"
			if strings.Contains(proxy, "type: tuic") {
				expected = "AuthenticationFailed"
			}
			if !strings.Contains(err.Error(), expected) {
				t.Fatalf("expected native authentication rejection, got %v", err)
			}
			t.Logf("authentication rejected: %v", err)
		}
		select {
		case err := <-f.handled:
			t.Fatalf("rejected client reached payload handler: %v", err)
		default:
		}
	} else {
		interopPackets(t, session, mode == "udp")
		select {
		case err := <-f.handled:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("native QUIC handler did not finish")
		}
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	t.Log("Session.Close completed")
	if !strings.HasPrefix(mode, "bad-") {
		f.mu.Lock()
		traces := append([]*interopQUICTrace(nil), f.traces...)
		f.mu.Unlock()
		if len(traces) == 0 {
			t.Fatal("no established server QUIC connection observed")
		}
		deadline := time.NewTimer(time.Second)
		defer deadline.Stop()
		for _, trace := range traces {
			select {
			case <-trace.done:
			case <-deadline.C:
				t.Fatal("Session.Close left an established QUIC connection alive while the server remained running")
			}
		}
		t.Log("server observed QUIC connection exit before fixture shutdown")
	}
}

func TestProtocolInteropHysteria2QUIC(t *testing.T) {
	for _, mode := range []string{"tcp", "udp", "bad-password", "bad-pin"} {
		t.Run(mode, func(t *testing.T) {
			f := newInteropQUICFixture(t)
			service, err := hysteria2.NewService[string](hysteria2.ServiceOptions{Context: f.ctx, Logger: logger.NOP(), TLSConfig: f.tls, QUICConfig: f.config, UDPTimeout: time.Second, UdpMTU: 1280, Handler: sing.FnHandler{
				NewConnectionFn: func(_ context.Context, conn net.Conn, metadata M.Metadata) error {
					return f.tcp(conn, metadata.Destination.String())
				},
				NewPacketConnectionFn: func(_ context.Context, conn N.PacketConn, metadata M.Metadata) error { return f.packet(conn, metadata) },
			}})
			if err != nil {
				t.Fatal(err)
			}
			service.UpdateUsers([]string{"fixture"}, []string{"secret"})
			if err = service.Start(f.udp); err != nil {
				t.Fatal(err)
			}
			f.stop = service.Close
			runInteropQUIC(t, f, "type: hysteria2", mode)
		})
	}
}

func TestProtocolInteropTUICv5QUIC(t *testing.T) {
	for _, mode := range []string{"tcp", "udp", "bad-password", "bad-pin"} {
		t.Run(mode, func(t *testing.T) {
			f := newInteropQUICFixture(t)
			server, err := tuic.NewServer(&tuic.ServerOption{TlsConfig: f.tls, QuicConfig: f.config, Users: map[[16]byte]string{uuid.Must(uuid.FromString(interopUUID)): "secret"}, AuthenticationTimeout: 500 * time.Millisecond, MaxUdpRelayPacketSize: 1280, CongestionController: "cubic",
				HandleTcpFn: func(conn net.Conn, address socks5.Addr, _ ...inbound.Addition) error {
					return f.tcp(conn, address.String())
				},
				HandleUdpFn: func(address socks5.Addr, packet C.UDPPacket, _ ...inbound.Addition) (err error) {
					defer packet.Drop()
					if address.String() != interopTarget || string(packet.Data()) != "hello" {
						err = fmt.Errorf("unexpected TUIC UDP target or payload")
					} else {
						_, err = packet.WriteBack([]byte("proxy:hello"), address.UDPAddr())
					}
					f.handled <- err
					return err
				},
			}, f.udp)
			if err != nil {
				t.Fatal(err)
			}
			f.stop = server.Close
			done := make(chan error, 1)
			f.serveDone = done
			go func() { done <- server.Serve() }()
			runInteropQUIC(t, f, "type: tuic, uuid: "+interopUUID+", udp-relay-mode: native, congestion-controller: cubic", mode)
		})
	}
}
