package mobile

import (
	"encoding/binary"
	"io"
	"net"
	"net/netip"
	"sync"
	"testing"
	"time"
)

func interopBlackholeUDP(t *testing.T) (int, <-chan struct{}) {
	t.Helper()
	socket, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	received := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		var once sync.Once
		buffer := make([]byte, 4096)
		for {
			if _, _, err := socket.ReadFromUDP(buffer); err != nil {
				return
			}
			once.Do(func() { close(received) })
		}
	}()
	t.Cleanup(func() { socket.Close(); <-done })
	return socket.LocalAddr().(*net.UDPAddr).Port, received
}

func interopBlackholeTCP(t *testing.T) (int, <-chan struct{}, <-chan error) {
	t.Helper()
	received := make(chan struct{})
	port, done := interopTCPServer(t, func(conn net.Conn) error {
		conn.SetDeadline(time.Now().Add(6 * time.Second))
		buffer := make([]byte, 4096)
		if _, err := conn.Read(buffer); err != nil {
			return err
		}
		close(received)
		_, err := io.Copy(io.Discard, conn)
		return err
	})
	return port, received, done
}

func interopStartPendingFlow(t *testing.T, session *Session, udp bool) {
	t.Helper()
	destination := netip.MustParseAddr("203.0.113.77")
	if udp {
		if err := session.WritePacket(udpPacket(destination, 443, []byte("hello"))); err != nil {
			t.Fatal(err)
		}
		return
	}
	if err := session.WritePacket(tcpPacket(destination, 443, 1000, 0, 2, nil)); err != nil {
		t.Fatal(err)
	}
	synack := readWithDeadline(t, session)
	if len(synack) < 40 || synack[9] != 6 || synack[33]&0x12 != 0x12 {
		t.Fatalf("expected SYN-ACK, got %x", synack)
	}
	ack := binary.BigEndian.Uint32(synack[24:28]) + 1
	for _, packet := range [][]byte{tcpPacket(destination, 443, 1001, ack, 0x10, nil), tcpPacket(destination, 443, 1001, ack, 0x18, []byte("hello"))} {
		if err := session.WritePacket(packet); err != nil {
			t.Fatal(err)
		}
	}
}

func TestProtocolSessionCloseCancelsPendingHandshake(t *testing.T) {
	for _, protocol := range []struct {
		name, proxy string
		quic        bool
	}{
		{"hysteria2", "type: hysteria2, password: fixture, sni: localhost, handshake-timeout: 30", true},
		{"tuic-v5", "type: tuic, uuid: " + interopUUID + ", password: fixture, sni: localhost, udp-relay-mode: native", true},
		{"trojan-tls", "type: trojan, password: fixture, sni: localhost, udp: true", false},
		{"vmess-aead", "type: vmess, uuid: " + interopUUID + ", alterId: 0, cipher: aes-128-gcm, udp: true", false},
	} {
		for _, udp := range []bool{false, true} {
			network := "tcp"
			if udp {
				network = "udp"
			}
			t.Run(protocol.name+"/"+network, func(t *testing.T) {
				var port int
				var received <-chan struct{}
				var peerClosed <-chan error
				if protocol.quic {
					port, received = interopBlackholeUDP(t)
				} else {
					port, received, peerClosed = interopBlackholeTCP(t)
				}
				session := interopSession(t, protocol.proxy, port)
				interopStartPendingFlow(t, session, udp)
				select {
				case <-received:
				case <-time.After(3 * time.Second):
					t.Fatal("loopback server did not receive handshake bytes")
				}
				closed := make(chan error, 1)
				started := time.Now()
				go func() { closed <- session.Close() }()
				select {
				case err := <-closed:
					if err != nil {
						t.Fatal(err)
					}
				case <-time.After(3 * time.Second):
					t.Fatal("Session.Close did not cancel pending handshake within 3 seconds")
				}
				t.Logf("pending handshake cancelled in %s", time.Since(started))
				if peerClosed != nil {
					select {
					case err := <-peerClosed:
						if err != nil {
							t.Fatalf("client handshake socket remained open: %v", err)
						}
					case <-time.After(time.Second):
						t.Fatal("server did not observe client socket close")
					}
				}
				restarted, err := NewSession(1280)
				if err != nil {
					t.Fatalf("restart after cancelled handshake: %v", err)
				}
				if err = restarted.Close(); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}
