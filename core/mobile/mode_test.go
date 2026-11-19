package mobile

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"sync"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

func TestSetModeChangesRoutesAndCatalog(t *testing.T) {
	s, err := NewYAMLSession("mode: rule\nproxies: [{name: rules, type: direct}]\nrules: ['MATCH,rules']", `{"GLOBAL":"REJECT"}`, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, step := range []struct{ mode, proxy string }{{"rule", "rules"}, {"global", "REJECT"}, {"direct", "DIRECT"}, {"rule", "rules"}} {
		if err := s.SetMode(step.mode); err != nil {
			t.Fatal(err)
		}
		proxy, err := s.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("203.0.113.1"), DstPort: 443})
		if err != nil || proxy.Name() != step.proxy {
			t.Fatalf("mode %s: got %v, %v", step.mode, proxy, err)
		}
		assertCatalogMode(t, s, step.mode)
	}
	for _, invalid := range []string{"", "GLOBAL", "invalid"} {
		if err := s.SetMode(invalid); err == nil {
			t.Fatalf("accepted mode %q", invalid)
		}
		assertCatalogMode(t, s, "rule")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if err := s.SetMode("direct"); err == nil {
		t.Fatal("changed closed session")
	}
	basic, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer basic.Close()
	if err := basic.SetMode("global"); err == nil {
		t.Fatal("changed basic session to global")
	}
}

func assertCatalogMode(t *testing.T, s *Session, want string) {
	t.Helper()
	value, err := s.ProxiesJSON()
	if err != nil {
		t.Fatal(err)
	}
	var catalog struct {
		Mode string `json:"mode"`
	}
	if err := json.Unmarshal([]byte(value), &catalog); err != nil {
		t.Fatal(err)
	}
	if catalog.Mode != want {
		t.Fatalf("catalog mode = %s, want %s", catalog.Mode, want)
	}
}

func TestSetModeForNewUDPFlowsPreservesExistingFlow(t *testing.T) {
	portA, portB := udpSOCKSFixture(t, "rule"), udpSOCKSFixture(t, "global")
	address := localIPv4(t)
	listener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: address.AsSlice()})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		buffer := make([]byte, 1500)
		for {
			n, source, err := listener.ReadFromUDP(buffer)
			if err != nil {
				return
			}
			_, _ = listener.WriteToUDP(append([]byte("direct:"), buffer[:n]...), source)
		}
	}()
	defer func() { listener.Close(); <-done }()
	yaml := fmt.Sprintf("proxies: [{name: a, type: socks5, server: 127.0.0.1, port: %d, udp: true}, {name: b, type: socks5, server: 127.0.0.1, port: %d, udp: true}]\nrules: ['MATCH,a']", portA, portB)
	s, err := NewYAMLSession(yaml, `{"GLOBAL":"b"}`, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	send := func(source uint16, want string) {
		t.Helper()
		packet := udpPacket(address, uint16(listener.LocalAddr().(*net.UDPAddr).Port), []byte("hello"))
		binary.BigEndian.PutUint16(packet[20:], source)
		if err := s.WritePacket(packet); err != nil {
			t.Fatal(err)
		}
		reply := readWithDeadline(t, s)
		if len(reply) < 28 || reply[9] != 17 || string(reply[28:]) != want {
			t.Fatalf("reply %x, want %q", reply, want)
		}
	}
	send(41000, "rule:hello")
	for i, mode := range []string{"global", "direct", "rule"} {
		if err := s.SetMode(mode); err != nil {
			t.Fatal(err)
		}
		send(uint16(41001+i), mode+":hello")
		send(41000, "rule:hello")
	}
}

func TestSetModeConcurrentRoutesAndCatalog(t *testing.T) {
	s, err := NewYAMLSession("mode: rule\nrules: ['MATCH,DIRECT']", `{"GLOBAL":"REJECT"}`, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var workers sync.WaitGroup
	for worker := range 3 {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for i := range 100 {
				switch worker {
				case 0:
					if err := s.SetMode([]string{"rule", "global", "direct"}[i%3]); err != nil {
						t.Error(err)
					}
				case 1:
					if _, err := s.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("203.0.113.1"), DstPort: 443}); err != nil {
						t.Error(err)
					}
				case 2:
					if _, err := s.ProxiesJSON(); err != nil {
						t.Error(err)
					}
				}
			}
		}()
	}
	workers.Wait()
}
