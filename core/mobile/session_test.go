package mobile

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"testing"
	"time"
)

func TestSessionEchoAndOwnership(t *testing.T) {
	session, err := NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = session.Close() })
	if _, err = NewSession(1500); err == nil {
		t.Fatal("accepted a concurrent session")
	}
	request := echoPacket()
	if err = session.WritePacket(request); err != nil {
		t.Fatal(err)
	}
	response := readWithDeadline(t, session)
	if response[20] != 0 || !bytes.Equal(response[28:], request[28:]) {
		t.Fatalf("unexpected ICMP response: %x", response)
	}
	if !bytes.Equal(response[12:16], request[16:20]) || !bytes.Equal(response[16:20], request[12:16]) {
		t.Fatal("ICMP reply addresses were not reversed")
	}
}

func TestSessionIPv6Echo(t *testing.T) {
	session, err := NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	source := netip.MustParseAddr("fd00:198:18::2").AsSlice()
	destination := netip.MustParseAddr("2606:4700:4700::1111").AsSlice()
	payload := append([]byte{128, 0, 0, 0, 0, 1, 0, 1}, []byte("ipv6-phase0")...)
	pseudo := append(append([]byte{}, source...), destination...)
	pseudo = append(pseudo, 0, 0, 0, byte(len(payload)), 0, 0, 0, 58)
	binary.BigEndian.PutUint16(payload[2:], checksum(append(pseudo, payload...)))
	request := make([]byte, 40+len(payload))
	request[0], request[6], request[7] = 0x60, 58, 64
	binary.BigEndian.PutUint16(request[4:], uint16(len(payload)))
	copy(request[8:24], source)
	copy(request[24:40], destination)
	copy(request[40:], payload)
	if err = session.WritePacket(request); err != nil {
		t.Fatal(err)
	}
	response := readWithDeadline(t, session)
	if len(response) != len(request) || response[40] != 129 || !bytes.Equal(response[48:], request[48:]) {
		t.Fatalf("unexpected ICMPv6 response: %x", response)
	}
	if !bytes.Equal(response[8:24], destination) || !bytes.Equal(response[24:40], source) {
		t.Fatal("ICMPv6 addresses were not reversed")
	}
}

func TestSessionCloseUnblocksReaderAndCanRestart(t *testing.T) {
	for range 3 {
		session, err := NewSession(1500)
		if err != nil {
			t.Fatal(err)
		}
		result := make(chan error, 1)
		go func() {
			_, err := session.ReadPacket()
			result <- err
		}()
		if err = session.Close(); err != nil {
			t.Fatal(err)
		}
		if err = session.Close(); err != nil {
			t.Fatal(err)
		}
		select {
		case err = <-result:
			if !errors.Is(err, io.EOF) {
				t.Fatalf("read after close = %v", err)
			}
		case <-time.After(time.Second):
			t.Fatal("close did not unblock reader")
		}
		if err = session.WritePacket(echoPacket()); err == nil {
			t.Fatal("write after close succeeded")
		}
	}
}

func TestSessionRejectsMalformedPackets(t *testing.T) {
	session, err := NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	for _, packet := range [][]byte{nil, {0x45}, make([]byte, 1501), {0x70, 0, 0, 0}} {
		if err = session.WritePacket(packet); err == nil {
			t.Fatalf("accepted malformed packet: %x", packet)
		}
	}
	packet := echoPacket()
	packet[3]++
	if err = session.WritePacket(packet); err == nil {
		t.Fatal("accepted inconsistent IPv4 length")
	}
	for _, mtu := range []int32{0, 1279, 65536} {
		if _, err = NewSession(mtu); err == nil {
			t.Fatalf("accepted MTU %d", mtu)
		}
	}
}

func TestDeviceBoundedQueueAndBufferOwnership(t *testing.T) {
	device := newPacketDevice(1500)
	defer device.Close()
	packet := echoPacket()
	for range packetQueueSize {
		if err := device.inject(packet); err != nil {
			t.Fatal(err)
		}
	}
	if err := device.inject(packet); err == nil {
		t.Fatal("full queue accepted another packet")
	}
	packet[0] = 0
	buffer := make([]byte, 1500)
	n, err := device.Read(buffer)
	if err != nil || n == 0 || buffer[0] != 0x45 {
		t.Fatalf("input packet retained caller storage: n=%d err=%v", n, err)
	}
	if _, err = device.Write(buffer[:n]); err != nil {
		t.Fatal(err)
	}
	buffer[0] = 0
	reply, err := device.receive()
	if err != nil || reply[0] != 0x45 {
		t.Fatal("output packet retained stack storage")
	}
}

func TestSessionUDPThroughMihomoDirect(t *testing.T) {
	address := localIPv4(t)
	listener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: address.AsSlice()})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	_ = listener.SetReadDeadline(time.Now().Add(3 * time.Second))
	serverResult := make(chan error, 1)
	go func() {
		buffer := make([]byte, 128)
		n, source, err := listener.ReadFromUDP(buffer)
		if err == nil {
			_, err = listener.WriteToUDP(append([]byte("echo:"), buffer[:n]...), source)
		}
		serverResult <- err
	}()
	session, err := NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	payload := []byte("packetFlow-to-mihomo")
	packet := udpPacket(address, uint16(listener.LocalAddr().(*net.UDPAddr).Port), payload)
	if err = session.WritePacket(packet); err != nil {
		t.Fatal(err)
	}
	response := readWithDeadline(t, session)
	if response[9] != 17 || !bytes.Equal(response[28:], append([]byte("echo:"), payload...)) {
		t.Fatalf("unexpected DIRECT UDP response: %x", response)
	}
	if err = <-serverResult; err != nil {
		t.Fatal(err)
	}
}

func TestSessionTCPThroughMihomoDirect(t *testing.T) {
	address := localIPv4(t)
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: address.AsSlice()})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	_ = listener.SetDeadline(time.Now().Add(3 * time.Second))
	serverResult := make(chan error, 1)
	payload := []byte("tcp-packetFlow-to-mihomo")
	go func() {
		conn, err := listener.AcceptTCP()
		if err != nil {
			serverResult <- err
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
		buffer := make([]byte, len(payload))
		_, err = io.ReadFull(conn, buffer)
		if err == nil {
			_, err = conn.Write(append([]byte("echo:"), buffer...))
		}
		serverResult <- err
	}()
	session, err := NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	port := uint16(listener.Addr().(*net.TCPAddr).Port)
	if err = session.WritePacket(tcpPacket(address, port, 1000, 0, 2, nil)); err != nil {
		t.Fatal(err)
	}
	synack := readWithDeadline(t, session)
	if synack[9] != 6 || synack[33]&0x12 != 0x12 {
		t.Fatalf("expected SYN-ACK, got %x", synack)
	}
	ack := binary.BigEndian.Uint32(synack[24:28]) + 1
	if err = session.WritePacket(tcpPacket(address, port, 1001, ack, 0x10, nil)); err != nil {
		t.Fatal(err)
	}
	if err = session.WritePacket(tcpPacket(address, port, 1001, ack, 0x18, payload)); err != nil {
		t.Fatal(err)
	}
	for range 8 {
		response := readWithDeadline(t, session)
		headerLength := int(response[0]&0xf)*4 + int(response[32]>>4)*4
		if len(response) == headerLength {
			continue
		}
		if !bytes.Equal(response[headerLength:], append([]byte("echo:"), payload...)) {
			t.Fatalf("unexpected TCP response: %x", response)
		}
		if err = <-serverResult; err != nil {
			t.Fatal(err)
		}
		return
	}
	t.Fatal("no TCP payload received")
}

func readWithDeadline(t *testing.T, session *Session) []byte {
	t.Helper()
	type result struct {
		packet []byte
		err    error
	}
	results := make(chan result, 1)
	go func() {
		packet, err := session.ReadPacket()
		results <- result{packet, err}
	}()
	select {
	case result := <-results:
		if result.err != nil {
			t.Fatal(result.err)
		}
		return result.packet
	case <-time.After(3 * time.Second):
		_ = session.Close()
		t.Fatal("packet response timed out")
		return nil
	}
}

func localIPv4(t *testing.T) netip.Addr {
	t.Helper()
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, _ := iface.Addrs()
		for _, address := range addresses {
			prefix, err := netip.ParsePrefix(address.String())
			if err == nil && prefix.Addr().Is4() && prefix.Addr().IsGlobalUnicast() {
				return prefix.Addr()
			}
		}
	}
	t.Skip("DIRECT loopback echo needs a local non-loopback IPv4 address")
	return netip.Addr{}
}

func echoPacket() []byte {
	payload := append([]byte{8, 0, 0, 0, 0, 1, 0, 1}, []byte("phase0")...)
	binary.BigEndian.PutUint16(payload[2:], checksum(payload))
	return ipv4Packet(netip.MustParseAddr("1.1.1.1"), 1, payload)
}

func udpPacket(destination netip.Addr, port uint16, payload []byte) []byte {
	udp := make([]byte, 8+len(payload))
	binary.BigEndian.PutUint16(udp, 41000)
	binary.BigEndian.PutUint16(udp[2:], port)
	binary.BigEndian.PutUint16(udp[4:], uint16(len(udp)))
	copy(udp[8:], payload)
	return ipv4Packet(destination, 17, udp)
}

func tcpPacket(destination netip.Addr, port uint16, sequence, ack uint32, flags byte, payload []byte) []byte {
	tcp := make([]byte, 20+len(payload))
	binary.BigEndian.PutUint16(tcp, 41001)
	binary.BigEndian.PutUint16(tcp[2:], port)
	binary.BigEndian.PutUint32(tcp[4:], sequence)
	binary.BigEndian.PutUint32(tcp[8:], ack)
	tcp[12], tcp[13] = 0x50, flags
	binary.BigEndian.PutUint16(tcp[14:], 65535)
	copy(tcp[20:], payload)
	pseudo := append(netip.MustParseAddr("198.18.0.2").AsSlice(), destination.AsSlice()...)
	pseudo = append(pseudo, 0, 6, byte(len(tcp)>>8), byte(len(tcp)))
	binary.BigEndian.PutUint16(tcp[16:], checksum(append(pseudo, tcp...)))
	return ipv4Packet(destination, 6, tcp)
}

func ipv4Packet(destination netip.Addr, protocol byte, payload []byte) []byte {
	packet := make([]byte, 20+len(payload))
	packet[0], packet[8], packet[9] = 0x45, 64, protocol
	binary.BigEndian.PutUint16(packet[2:], uint16(len(packet)))
	copy(packet[12:16], netip.MustParseAddr("198.18.0.2").AsSlice())
	copy(packet[16:20], destination.AsSlice())
	binary.BigEndian.PutUint16(packet[10:], checksum(packet[:20]))
	copy(packet[20:], payload)
	return packet
}

func checksum(data []byte) uint16 {
	var sum uint32
	for len(data) >= 2 {
		sum += uint32(binary.BigEndian.Uint16(data))
		data = data[2:]
	}
	if len(data) != 0 {
		sum += uint32(data[0]) << 8
	}
	for sum > 0xffff {
		sum = sum>>16 + sum&0xffff
	}
	return ^uint16(sum)
}
