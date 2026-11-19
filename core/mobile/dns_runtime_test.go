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

	C "github.com/metacubex/mihomo/constant"
	M "github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/transport/socks5"
	SM "github.com/metacubex/sing/common/metadata"
	D "github.com/miekg/dns"
)

func dnsFixture(t *testing.T) string {
	t.Helper()
	socket, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	server := &D.Server{PacketConn: socket, Handler: D.HandlerFunc(func(w D.ResponseWriter, request *D.Msg) {
		response := new(D.Msg)
		response.SetReply(request)
		if len(request.Question) == 1 {
			question := request.Question[0]
			switch question.Qtype {
			case D.TypeA:
				response.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: question.Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60}, A: net.ParseIP("203.0.113.9")}}
			case D.TypeAAAA:
				response.Answer = []D.RR{&D.AAAA{Hdr: D.RR_Header{Name: question.Name, Rrtype: D.TypeAAAA, Class: D.ClassINET, Ttl: 60}, AAAA: net.ParseIP("2001:db8::9")}}
			}
		}
		_ = w.WriteMsg(response)
	})}
	go func() { defer close(done); _ = server.ActivateAndServe() }()
	t.Cleanup(func() { _ = server.Shutdown(); _ = socket.Close(); <-done })
	return socket.LocalAddr().String()
}

func dnsYAML(address, mode string) string {
	return fmt.Sprintf("ipv6: true\ndns:\n enable: true\n ipv6: true\n enhanced-mode: %s\n fake-ip-range6: fdfe:dcba:9876::1/64\n nameserver: ['%s']\n default-nameserver: ['%s']\n", mode, address, address)
}
func dnsQuery(t *testing.T, name string, kind uint16) []byte {
	t.Helper()
	query := new(D.Msg)
	query.SetQuestion(name, kind)
	bytes, err := query.Pack()
	if err != nil {
		t.Fatal(err)
	}
	return bytes
}
func dnsAnswer(t *testing.T, bytes []byte) *D.Msg {
	t.Helper()
	answer := new(D.Msg)
	if err := answer.Unpack(bytes); err != nil {
		t.Fatal(err)
	}
	if answer.Rcode != D.RcodeSuccess || len(answer.Answer) != 1 {
		t.Fatalf("DNS answer: %s", answer)
	}
	return answer
}
func udp6Packet(destination netip.Addr, port uint16, payload []byte) []byte {
	source := netip.MustParseAddr("fd00:198:18::2").AsSlice()
	target := destination.AsSlice()
	udp := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint16(udp, 41000)
	binary.BigEndian.PutUint16(udp[2:], port)
	binary.BigEndian.PutUint16(udp[4:], uint16(len(udp)))
	copy(udp[8:], payload)
	pseudo := append(append([]byte{}, source...), target...)
	pseudo = append(pseudo, 0, 0, byte(len(udp)>>8), byte(len(udp)), 0, 0, 0, 17)
	binary.BigEndian.PutUint16(udp[6:], checksum(append(pseudo, udp...)))
	packet := make([]byte, 40+len(udp))
	packet[0], packet[6], packet[7] = 0x60, 17, 64
	binary.BigEndian.PutUint16(packet[4:], uint16(len(udp)))
	copy(packet[8:24], source)
	copy(packet[24:40], target)
	copy(packet[40:], udp)
	return packet
}
func TestYAMLDNSPacketBridgeIPv4IPv6AndTCP(t *testing.T) {
	session, err := NewYAMLSession(dnsYAML(dnsFixture(t), "redir-host")+"rules: ['MATCH,REJECT']", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	for _, ipv6 := range []bool{false, true} {
		query := dnsQuery(t, "bridge.invalid.", D.TypeA)
		packet := udpPacket(netip.MustParseAddr("198.18.0.1"), 53, query)
		offset := 28
		if ipv6 {
			query = dnsQuery(t, "bridge.invalid.", D.TypeAAAA)
			packet = udp6Packet(netip.MustParseAddr("fd00:198:18::1"), 53, query)
			offset = 48
		}
		if err := session.WritePacket(packet); err != nil {
			t.Fatal(err)
		}
		answer := dnsAnswer(t, readWithDeadline(t, session)[offset:])
		if ipv6 {
			if answer.Answer[0].(*D.AAAA).AAAA.String() != "2001:db8::9" {
				t.Fatal(answer)
			}
		} else if answer.Answer[0].(*D.A).A.String() != "203.0.113.9" {
			t.Fatal(answer)
		}
	}
	client, server := net.Pipe()
	defer client.Close()
	client.SetDeadline(time.Now().Add(time.Second))
	done := make(chan error, 1)
	go func() {
		done <- (&sessionHandler{session: session}).NewConnection(context.Background(), server, SM.Metadata{Destination: SM.ParseSocksaddr("198.18.0.1:53")})
	}()
	query := dnsQuery(t, "tcp.invalid.", D.TypeA)
	frame := make([]byte, 2+len(query))
	binary.BigEndian.PutUint16(frame, uint16(len(query)))
	copy(frame[2:], query)
	if _, err := client.Write(frame); err != nil {
		t.Fatal(err)
	}
	header := make([]byte, 2)
	if _, err := io.ReadFull(client, header); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, binary.BigEndian.Uint16(header))
	if _, err := io.ReadFull(client, response); err != nil {
		t.Fatal(err)
	}
	dnsAnswer(t, response)
	session.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("TCP DNS stream survived Close")
	}
}

func TestYAMLFakeIPRestoresDomainAndSOCKSTarget(t *testing.T) {
	listener, _ := socksFixture(t)
	observed := make(chan string, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			observed <- err.Error()
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(time.Second))
		address, _, _, err := socks5.ServerHandshake(conn, nil)
		if err != nil {
			observed <- err.Error()
			return
		}
		observed <- address.String()
		_, _ = io.Copy(conn, conn)
	}()
	yaml := dnsYAML(dnsFixture(t), "fake-ip") + fmt.Sprintf("proxies: [{name: node, type: socks5, server: 127.0.0.1, port: %d}]\nrules: ['DOMAIN,example.invalid,node', 'MATCH,REJECT']", listener.Addr().(*net.TCPAddr).Port)
	session, err := NewYAMLSession(yaml, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "example.invalid.", D.TypeA)))
	answer := dnsAnswer(t, readWithDeadline(t, session)[28:])
	fakeIP, _ := netip.AddrFromSlice(answer.Answer[0].(*D.A).A)
	fakeIP = fakeIP.Unmap()
	if !netip.MustParsePrefix("198.18.0.0/16").Contains(fakeIP) {
		t.Fatalf("not fake IP: %s", fakeIP)
	}
	client, server := net.Pipe()
	defer client.Close()
	done := make(chan error, 1)
	go func() {
		done <- (&sessionHandler{session: session}).NewConnection(context.Background(), server, SM.Metadata{Destination: SM.Socksaddr{Addr: fakeIP, Port: 443}})
	}()
	select {
	case target := <-observed:
		if target != "example.invalid:443" {
			t.Fatal(target)
		}
	case <-time.After(time.Second):
		t.Fatal("domain route did not reach SOCKS")
	}
	if _, err := session.route(&C.Metadata{DstIP: netip.MustParseAddr("198.18.255.254"), DstPort: 443, NetWork: C.TCP}); err == nil {
		t.Fatal("unknown fake IP was routed")
	}
	session.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("SOCKS flow survived close")
	}
}

func TestYAMLNetworkSettingsAndDesktopWarnings(t *testing.T) {
	yaml := dnsYAML("127.0.0.1:5353", "fake-ip") + "mixed-port: 7890\nsecret: do-not-echo\nexternal-controller: 127.0.0.1:9090\ntun: {enable: true, device: ignored, stack: mixed}\nrules: ['MATCH,DIRECT']"
	settings, err := YAMLNetworkSettings(yaml)
	if err != nil {
		t.Fatal(err)
	}
	if settings != `{"ipv6":true,"dnsServers":["198.18.0.1"],"ipv4Address":"198.18.0.1","ipv4PrefixLength":30,"ipv6Address":"fd00:198:18::1","ipv6PrefixLength":126}` {
		t.Fatal(settings)
	}
	session, err := NewYAMLSession(yaml, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	catalog, err := session.ProxiesJSON()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(catalog, "mixed-port") || !strings.Contains(catalog, "tun.device") || strings.Contains(catalog, "do-not-echo") {
		t.Fatal(catalog)
	}
}

func TestYAMLFakeIPUDPPreservesReplyAddress(t *testing.T) {
	port := udpSOCKSFixture(t, "domain")
	config := dnsYAML(dnsFixture(t), "fake-ip") + fmt.Sprintf("proxies: [{name: node, type: socks5, server: 127.0.0.1, port: %d, udp: true}]\nrules: ['DOMAIN,udp.invalid,node', 'MATCH,REJECT']", port)
	session, err := NewYAMLSession(config, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "udp.invalid.", D.TypeA)))
	answer := dnsAnswer(t, readWithDeadline(t, session)[28:])
	fakeIP, _ := netip.AddrFromSlice(answer.Answer[0].(*D.A).A)
	fakeIP = fakeIP.Unmap()
	session.WritePacket(udpPacket(fakeIP, 443, []byte("hello")))
	reply := readWithDeadline(t, session)
	source, _ := netip.AddrFromSlice(reply[12:16])
	if source != fakeIP || string(reply[28:]) != "domain:hello" {
		t.Fatalf("wrong fake-IP UDP reply %x", reply)
	}
}

func TestYAMLCloseCancelsPendingDNSAndRestarts(t *testing.T) {
	socket, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	arrived := make(chan struct{})
	go func() { buffer := make([]byte, 2048); _, _, _ = socket.ReadFrom(buffer); close(arrived) }()
	session, err := NewYAMLSession(dnsYAML(socket.LocalAddr().String(), "redir-host")+"rules: ['MATCH,REJECT']", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "pending.invalid.", D.TypeA)))
	select {
	case <-arrived:
	case <-time.After(time.Second):
		t.Fatal("DNS fixture not reached")
	}
	done := make(chan error, 1)
	go func() { done <- session.Close() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Close left pending DNS workers")
	}
	next, err := NewYAMLSession(dnsYAML(dnsFixture(t), "redir-host")+"rules: ['MATCH,REJECT']", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	next.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "new.invalid.", D.TypeA)))
	dnsAnswer(t, readWithDeadline(t, next)[28:])
}

func TestYAMLRejectsDHCPDiscovery(t *testing.T) {
	if _, err := M.ParseNameServer([]string{"dhcp://en0"}); err == nil {
		t.Fatal("outbound accepted DHCP resolver")
	}
	session, err := NewYAMLSession("dns: {enable: true, nameserver: ['dhcp://en0']}\nrules: ['MATCH,DIRECT']", "{}", 1280)
	if err == nil {
		session.Close()
		t.Fatal("accepted unowned DHCP discovery")
	}
	if !strings.Contains(err.Error(), "dhcp") {
		t.Fatal(err)
	}
}
