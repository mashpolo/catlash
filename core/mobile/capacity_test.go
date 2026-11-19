package mobile

import (
	"encoding/binary"
	"fmt"
	"net/netip"
	"strings"
	"testing"
)

func TestFiftyUDPFlowsRemainPinnedAcrossOneHundredSelections(t *testing.T) {
	portA, portB := udpSOCKSFixture(t, "a"), udpSOCKSFixture(t, "b")
	yaml := fmt.Sprintf("proxies:\n - {name: a, type: socks5, server: 127.0.0.1, port: %d, udp: true}\n - {name: b, type: socks5, server: 127.0.0.1, port: %d, udp: true}\nproxy-groups:\n - {name: selection, type: select, proxies: [a,b]}\nrules: [\"MATCH,selection\"]\n", portA, portB)
	session, err := NewYAMLSession(yaml, `{}`, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	round := func() {
		t.Helper()
		for index := range 50 {
			packet := udpPacket(netip.MustParseAddr("203.0.113.1"), 53, []byte("bulk"))
			binary.BigEndian.PutUint16(packet[20:], uint16(41000+index))
			if err := session.WritePacket(packet); err != nil {
				t.Fatal(err)
			}
		}
		seen := make(map[uint16]bool)
		for range 50 {
			response := readWithDeadline(t, session)
			if len(response) < 28 || string(response[28:]) != "a:bulk" {
				t.Fatalf("existing flow changed outbound: %x", response)
			}
			port := binary.BigEndian.Uint16(response[22:24])
			if port < 41000 || port >= 41050 || seen[port] {
				t.Fatalf("unexpected or duplicate flow reply: %d", port)
			}
			seen[port] = true
		}
	}
	round()
	for index := range 100 {
		choice := "a"
		if index%2 == 1 {
			choice = "b"
		}
		if err := session.SelectProxy("selection", choice); err != nil {
			t.Fatal(err)
		}
	}
	round()
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	restarted, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	if err := restarted.Close(); err != nil {
		t.Fatal(err)
	}
}

func BenchmarkLargeYAMLSession(b *testing.B) {
	var configuration strings.Builder
	configuration.WriteString("proxies:\n")
	for index := range 1000 {
		fmt.Fprintf(&configuration, " - {name: node%d, type: socks5, server: 127.0.0.1, port: 9, udp: true}\n", index)
	}
	configuration.WriteString("proxy-groups:\n - name: selection\n   type: select\n   proxies: [")
	for index := range 1000 {
		if index > 0 {
			configuration.WriteByte(',')
		}
		fmt.Fprintf(&configuration, "node%d", index)
	}
	configuration.WriteString("]\nrules:\n")
	for index := range 50000 {
		fmt.Fprintf(&configuration, " - IP-CIDR,10.%d.%d.0/24,selection,no-resolve\n", index/256, index%256)
	}
	configuration.WriteString(" - MATCH,REJECT\n")
	yaml := configuration.String()
	b.ReportAllocs()
	b.SetBytes(int64(len(yaml)))
	b.ResetTimer()
	for range b.N {
		session, err := NewYAMLSession(yaml, `{}`, 1280)
		if err != nil {
			b.Fatal(err)
		}
		if err := session.Close(); err != nil {
			b.Fatal(err)
		}
	}
}
