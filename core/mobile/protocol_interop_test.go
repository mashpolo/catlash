package mobile

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"

	MN "github.com/metacubex/mihomo/common/net"
	"github.com/metacubex/mihomo/component/auth"
	C "github.com/metacubex/mihomo/constant"
	listenerAuth "github.com/metacubex/mihomo/listener/auth"
	listenerHTTP "github.com/metacubex/mihomo/listener/http"
	"github.com/metacubex/mihomo/listener/sing"
	"github.com/metacubex/mihomo/listener/sing_vless"
	SS "github.com/metacubex/mihomo/transport/shadowsocks/core"
	"github.com/metacubex/mihomo/transport/socks5"
	"github.com/metacubex/sing/common/buf"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
)

const interopTarget = "203.0.113.77:443"
const interopUUID = "2a15235b-baf9-4c60-8490-3b6cb8426621"

func interopTCPServer(t *testing.T, handle func(net.Conn) error) (int, <-chan error) {
	t.Helper()
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	listener.SetDeadline(time.Now().Add(3 * time.Second))
	done := make(chan struct{})
	result := make(chan error, 1)
	go func() {
		defer close(done)
		conn, err := listener.AcceptTCP()
		if err == nil {
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(3 * time.Second))
			err = handle(conn)
		}
		result <- err
	}()
	t.Cleanup(func() { listener.Close(); <-done })
	return listener.Addr().(*net.TCPAddr).Port, result
}

func interopEcho(conn net.Conn, target string) error {
	if target != interopTarget {
		return fmt.Errorf("unexpected target %s", target)
	}
	payload := make([]byte, 5)
	if _, err := io.ReadFull(conn, payload); err != nil {
		return err
	}
	if string(payload) != "hello" {
		return fmt.Errorf("unexpected payload %q", payload)
	}
	_, err := conn.Write([]byte("proxy:hello"))
	return err
}

type interopHTTPTunnel struct{ result chan error }

func (h *interopHTTPTunnel) HandleTCPConn(conn net.Conn, metadata *C.Metadata) {
	h.result <- interopEcho(conn, metadata.RemoteAddress())
}
func (h *interopHTTPTunnel) HandleUDPPacket(packet C.UDPPacket, _ *C.Metadata) { packet.Drop() }
func (h *interopHTTPTunnel) NatTable() C.NatTable                              { return nil }

func interopSession(t *testing.T, proxy string, port int) *Session {
	t.Helper()
	yaml := fmt.Sprintf("proxies:\n  - {name: fixture, server: 127.0.0.1, port: %d, %s}\nrules: ['MATCH,fixture']\n", port, proxy)
	session, err := NewYAMLSession(yaml, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { session.Close() })
	return session
}

func interopPackets(t *testing.T, session *Session, udp bool) {
	t.Helper()
	destination := netip.MustParseAddr("203.0.113.77")
	if udp {
		if err := session.WritePacket(udpPacket(destination, 443, []byte("hello"))); err != nil {
			t.Fatal(err)
		}
		reply := readWithDeadline(t, session)
		if len(reply) < 28 || string(reply[28:]) != "proxy:hello" {
			t.Fatalf("unexpected UDP response %x", reply)
		}
		return
	}
	if err := session.WritePacket(tcpPacket(destination, 443, 1000, 0, 2, nil)); err != nil {
		t.Fatal(err)
	}
	reply := readWithDeadline(t, session)
	if len(reply) < 40 || reply[9] != 6 || reply[33]&0x12 != 0x12 {
		t.Fatalf("expected SYN-ACK, got %x", reply)
	}
	ack := binary.BigEndian.Uint32(reply[24:28]) + 1
	for _, packet := range [][]byte{tcpPacket(destination, 443, 1001, ack, 0x10, nil), tcpPacket(destination, 443, 1001, ack, 0x18, []byte("hello"))} {
		if err := session.WritePacket(packet); err != nil {
			t.Fatal(err)
		}
	}
	for range 8 {
		reply = readWithDeadline(t, session)
		if len(reply) < 40 {
			t.Fatalf("truncated TCP reply %x", reply)
		}
		header := int(reply[0]&0xf)*4 + int(reply[32]>>4)*4
		if header >= len(reply) {
			continue
		}
		if string(reply[header:]) != "proxy:hello" {
			t.Fatalf("unexpected TCP payload %x", reply)
		}
		return
	}
	t.Fatal("no TCP payload")
}

func interopRejected(t *testing.T, session *Session) error {
	t.Helper()
	metadata := &C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("203.0.113.77"), DstPort: 443}
	proxy, err := session.route(metadata)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	conn, err := proxy.DialContext(ctx, metadata)
	if err == nil {
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(2 * time.Second))
		_, err = conn.Write([]byte("hello"))
		if err == nil {
			_, err = conn.Read(make([]byte, 32))
		}
	}
	if err == nil {
		t.Fatal("invalid credentials returned application data")
	}
	if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatalf("authentication stalled instead of rejecting: %v", err)
	}
	return err
}

func TestProtocolInteropHTTPConnect(t *testing.T) {
	for _, valid := range []bool{true, false} {
		t.Run(fmt.Sprintf("credentials-%t", valid), func(t *testing.T) {
			tunnel := &interopHTTPTunnel{result: make(chan error, 1)}
			store := listenerAuth.NewAuthStore(auth.NewAuthenticator([]auth.AuthUser{{User: "fixture", Pass: "secret"}}))
			port, done := interopTCPServer(t, func(conn net.Conn) error { listenerHTTP.HandleConn(conn, tunnel, store); return nil })
			password := "secret"
			if !valid {
				password = "wrong"
			}
			session := interopSession(t, "type: http, username: fixture, password: "+password, port)
			if valid {
				interopPackets(t, session, false)
				if err := <-tunnel.result; err != nil {
					t.Fatal(err)
				}
			} else {
				if err := interopRejected(t, session); !strings.Contains(err.Error(), "403") {
					t.Fatalf("expected HTTP 403, got %v", err)
				}
				select {
				case <-tunnel.result:
					t.Fatal("HTTP rejected user reached target handler")
				default:
				}
			}
			if err := <-done; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestProtocolInteropShadowsocksAEAD(t *testing.T) {
	for _, mode := range []string{"tcp", "udp", "bad-password"} {
		t.Run(mode, func(t *testing.T) {
			cipher, err := SS.PickCipher("aes-128-gcm", nil, "secret")
			if err != nil {
				t.Fatal(err)
			}
			var port int
			var done <-chan error
			if mode == "udp" {
				udp, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
				if err != nil {
					t.Fatal(err)
				}
				udp.SetDeadline(time.Now().Add(3 * time.Second))
				packet := cipher.PacketConn(MN.NewEnhancePacketConn(udp))
				result := make(chan error, 1)
				stopped := make(chan struct{})
				go func() {
					defer close(stopped)
					buffer := make([]byte, 1280)
					n, source, err := packet.ReadFrom(buffer)
					if err == nil {
						address := socks5.SplitAddr(buffer[:n])
						if address.String() != interopTarget || string(buffer[len(address):n]) != "hello" {
							err = fmt.Errorf("invalid SS UDP target/payload")
						} else {
							_, err = packet.WriteTo(append(append([]byte{}, address...), []byte("proxy:hello")...), source)
						}
					}
					result <- err
				}()
				t.Cleanup(func() { udp.Close(); <-stopped })
				port = udp.LocalAddr().(*net.UDPAddr).Port
				done = result
			} else {
				port, done = interopTCPServer(t, func(raw net.Conn) error {
					conn := cipher.StreamConn(raw)
					address, err := socks5.ReadAddr0(conn)
					if err != nil {
						return err
					}
					return interopEcho(conn, address.String())
				})
			}
			password := "secret"
			if mode == "bad-password" {
				password = "wrong"
			}
			session := interopSession(t, "type: ss, cipher: aes-128-gcm, password: "+password+", udp: true", port)
			if mode == "bad-password" {
				interopRejected(t, session)
				if err := <-done; err == nil || !strings.Contains(err.Error(), "authentication failed") {
					t.Fatalf("expected AEAD rejection, got %v", err)
				}
			} else {
				interopPackets(t, session, mode == "udp")
				if err := <-done; err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestProtocolInteropVLESS(t *testing.T) {
	for _, mode := range []string{"tcp", "udp", "bad-uuid"} {
		t.Run(mode, func(t *testing.T) {
			handled := make(chan error, 1)
			service := sing_vless.NewService[string](sing.FnHandler{
				NewConnectionFn: func(_ context.Context, conn net.Conn, metadata M.Metadata) error {
					return interopEcho(conn, metadata.Destination.String())
				},
				NewPacketConnectionFn: func(_ context.Context, conn N.PacketConn, metadata M.Metadata) (err error) {
					defer func() { handled <- err }()
					buffer := buf.NewPacket()
					defer buffer.Release()
					destination, err := conn.ReadPacket(buffer)
					if err != nil {
						return err
					}
					if metadata.Destination.String() != interopTarget || destination.String() != interopTarget || string(buffer.Bytes()) != "hello" {
						return fmt.Errorf("invalid VLESS UDP target/payload")
					}
					headroom := N.CalculateFrontHeadroom(conn)
					reply := buf.NewSize(headroom + len("proxy:hello"))
					reply.Resize(headroom, 0)
					reply.Write([]byte("proxy:hello"))
					return conn.WritePacket(reply, destination)
				},
			})
			service.UpdateUsers([]string{"fixture"}, []string{interopUUID}, []string{""})
			port, done := interopTCPServer(t, func(conn net.Conn) error { return service.NewConnection(context.Background(), conn, M.Metadata{}) })
			uuid := interopUUID
			if mode == "bad-uuid" {
				uuid = "d7a8ff97-3d03-4a53-a48a-9138a5e4b884"
			}
			session := interopSession(t, "type: vless, uuid: "+uuid+", udp: true", port)
			if mode == "bad-uuid" {
				interopRejected(t, session)
				if err := <-done; err == nil || !strings.Contains(err.Error(), "unknown UUID") {
					t.Fatalf("expected UUID rejection, got %v", err)
				}
			} else {
				interopPackets(t, session, mode == "udp")
				if mode == "udp" {
					if err := <-handled; err != nil {
						t.Fatal(err)
					}
					session.Close()
					if err := <-done; err == nil || !strings.Contains(err.Error(), "EOF") {
						t.Fatalf("expected closed XUDP stream, got %v", err)
					}
				} else if err := <-done; err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}
