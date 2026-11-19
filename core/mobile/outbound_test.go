package mobile

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"testing"
	"time"

	"github.com/metacubex/mihomo/transport/socks5"
)

func socksFixture(t *testing.T) (*net.TCPListener, string) {
	t.Helper()
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	listener.SetDeadline(time.Now().Add(3 * time.Second))
	return listener, fmt.Sprintf(`{"version":1,"mtu":1280,"outbound":{"type":"socks5","server":"127.0.0.1","port":%d}}`, listener.Addr().(*net.TCPAddr).Port)
}

func TestConfiguredSessionTCPUsesSOCKS5(t *testing.T) {
	listener, configuration := socksFixture(t)
	observed := make(chan error, 1)
	closed := make(chan error, 1)
	go func() {
		conn, err := listener.AcceptTCP()
		if err != nil {
			observed <- err
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		address, command, _, err := socks5.ServerHandshake(conn, nil)
		if err == nil && (command != socks5.CmdConnect || address.String() != "203.0.113.1:443") {
			err = fmt.Errorf("unexpected command/target %d %s", command, address)
		}
		if err == nil {
			payload := make([]byte, 5)
			_, err = io.ReadFull(conn, payload)
			if err == nil {
				_, err = conn.Write(append([]byte("proxy:"), payload...))
			}
		}
		observed <- err
		_, err = io.Copy(io.Discard, conn)
		closed <- err
	}()
	session, err := NewConfiguredSession(configuration)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	destination := netip.MustParseAddr("203.0.113.1")
	session.WritePacket(tcpPacket(destination, 443, 1000, 0, 2, nil))
	synack := readWithDeadline(t, session)
	ack := binary.BigEndian.Uint32(synack[24:28]) + 1
	session.WritePacket(tcpPacket(destination, 443, 1001, ack, 0x10, nil))
	session.WritePacket(tcpPacket(destination, 443, 1001, ack, 0x18, []byte("hello")))
	for range 8 {
		packet := readWithDeadline(t, session)
		header := int(packet[0]&0xf)*4 + int(packet[32]>>4)*4
		if len(packet) == header {
			continue
		}
		if string(packet[header:]) != "proxy:hello" {
			t.Fatalf("unexpected proxy reply %x", packet)
		}
		if err := <-observed; err != nil {
			t.Fatal(err)
		}
		if err := session.Close(); err != nil {
			t.Fatal(err)
		}
		select {
		case err := <-closed:
			if err != nil {
				t.Fatal(err)
			}
		case <-time.After(time.Second):
			t.Fatal("active TCP socket remains open after Close")
		}
		return
	}
	t.Fatal("no proxy reply")
}

func TestConfiguredSessionUDPUsesSOCKS5AndClosesAssociation(t *testing.T) {
	listener, configuration := socksFixture(t)
	udp, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: listener.Addr().(*net.TCPAddr).Port})
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	udp.SetDeadline(time.Now().Add(3 * time.Second))
	closed := make(chan error, 1)
	go func() {
		conn, err := listener.AcceptTCP()
		if err != nil {
			closed <- err
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		_, command, _, err := socks5.ServerHandshake(conn, nil)
		if err == nil && command != socks5.CmdUDPAssociate {
			err = fmt.Errorf("unexpected command %d", command)
		}
		if err != nil {
			closed <- err
			return
		}
		_, err = io.Copy(io.Discard, conn)
		closed <- err
	}()
	received := make(chan error, 1)
	go func() {
		buffer := make([]byte, 1280)
		n, source, err := udp.ReadFromUDP(buffer)
		if err == nil {
			address, payload, decodeErr := socks5.DecodeUDPPacket(buffer[:n])
			err = decodeErr
			if err == nil && (address.String() != "203.0.113.1:53" || string(payload) != "hello") {
				err = fmt.Errorf("unexpected UDP target/payload %s %q", address, payload)
			}
			if err == nil {
				reply, _ := socks5.EncodeUDPPacket(address, []byte("proxy:hello"))
				_, err = udp.WriteToUDP(reply, source)
			}
		}
		received <- err
	}()
	session, err := NewConfiguredSession(configuration)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	session.WritePacket(udpPacket(netip.MustParseAddr("203.0.113.1"), 53, []byte("hello")))
	reply := readWithDeadline(t, session)
	if !bytes.Equal(reply[28:], []byte("proxy:hello")) {
		t.Fatalf("unexpected UDP reply %x", reply)
	}
	if err := <-received; err != nil {
		t.Fatal(err)
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("SOCKS association remains open after Close")
	}
}

func TestCloseCancelsSOCKSHandshake(t *testing.T) {
	for _, protocol := range []string{"tcp", "udp"} {
		t.Run(protocol, func(t *testing.T) {
			listener, configuration := socksFixture(t)
			accepted := make(chan net.Conn, 1)
			go func() {
				conn, err := listener.Accept()
				if err == nil {
					accepted <- conn
				}
			}()
			session, err := NewConfiguredSession(configuration)
			if err != nil {
				t.Fatal(err)
			}
			defer session.Close()
			destination := netip.MustParseAddr("203.0.113.1")
			if protocol == "udp" {
				session.WritePacket(udpPacket(destination, 53, []byte("hello")))
			} else {
				session.WritePacket(tcpPacket(destination, 443, 1000, 0, 2, nil))
				synack := readWithDeadline(t, session)
				session.WritePacket(tcpPacket(destination, 443, 1001, binary.BigEndian.Uint32(synack[24:28])+1, 0x10, nil))
			}
			var conn net.Conn
			select {
			case conn = <-accepted:
			case <-time.After(3 * time.Second):
				t.Fatal("no SOCKS connection")
			}
			defer conn.Close()
			if protocol == "udp" {
				for range 512 {
					err := session.WritePacket(udpPacket(destination, 53, []byte("queued")))
					if err != nil && !errors.Is(err, errQueueFull) {
						t.Fatal(err)
					}
				}
			}
			stopped := make(chan error, 1)
			go func() { stopped <- session.Close() }()
			select {
			case err := <-stopped:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(time.Second):
				t.Fatal("Close did not cancel SOCKS handshake")
			}
			conn.SetReadDeadline(time.Now().Add(time.Second))
			if _, err = io.Copy(io.Discard, conn); err != nil {
				t.Fatalf("SOCKS handshake socket remains open: %v", err)
			}
		})
	}
}

func TestUDPDownstreamActivityExtendsIdleTimeout(t *testing.T) {
	listener, _ := socksFixture(t)
	port := listener.Addr().(*net.TCPAddr).Port
	udp, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	udp.SetDeadline(time.Now().Add(3 * time.Second))
	closed := make(chan error, 1)
	go func() {
		conn, err := listener.AcceptTCP()
		if err != nil {
			closed <- err
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(3 * time.Second))
		_, _, _, err = socks5.ServerHandshake(conn, nil)
		if err == nil {
			_, err = io.Copy(io.Discard, conn)
		}
		closed <- err
	}()
	sent := make(chan error, 1)
	go func() {
		buffer := make([]byte, 1280)
		n, source, err := udp.ReadFromUDP(buffer)
		if err != nil {
			sent <- err
			return
		}
		address, _, err := socks5.DecodeUDPPacket(buffer[:n])
		if err != nil {
			sent <- err
			return
		}
		ticker := time.NewTicker(80 * time.Millisecond)
		defer ticker.Stop()
		for index := range 6 {
			<-ticker.C
			packet, _ := socks5.EncodeUDPPacket(address, []byte{byte(index)})
			if _, err = udp.WriteToUDP(packet, source); err != nil {
				sent <- err
				return
			}
		}
		sent <- nil
	}()
	session, err := newSession(1280, map[string]any{"name": "fixture", "type": "socks5", "server": "127.0.0.1", "port": port, "udp": true}, 200*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if err = session.WritePacket(udpPacket(netip.MustParseAddr("203.0.113.1"), 53, []byte("subscribe"))); err != nil {
		t.Fatal(err)
	}
	for index := range 6 {
		packet := readWithDeadline(t, session)
		if len(packet) != 29 || packet[28] != byte(index) {
			t.Fatalf("unexpected downstream packet %x", packet)
		}
		select {
		case err := <-closed:
			t.Fatalf("active UDP association closed: %v", err)
		default:
		}
	}
	if err := <-sent; err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("idle UDP association did not close")
	}
}
