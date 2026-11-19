package mobile

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/transport/socks5"
)

func udpSOCKSFixture(t *testing.T, label string) int {
	t.Helper()
	listener, _ := socksFixture(t)
	port := listener.Addr().(*net.TCPAddr).Port
	udp, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { udp.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				conn.SetDeadline(time.Now().Add(3 * time.Second))
				if _, _, _, err := socks5.ServerHandshake(conn, nil); err == nil {
					io.Copy(io.Discard, conn)
				}
			}()
		}
	}()
	go func() {
		buffer := make([]byte, 1500)
		for {
			n, source, err := udp.ReadFromUDP(buffer)
			if err != nil {
				return
			}
			address, payload, err := socks5.DecodeUDPPacket(buffer[:n])
			if err != nil {
				return
			}
			reply, _ := socks5.EncodeUDPPacket(address, append([]byte(label+":"), payload...))
			udp.WriteToUDP(reply, source)
		}
	}()
	return port
}

func TestYAMLRulesAndSelectionKeepExistingUDPFlow(t *testing.T) {
	portA, portB := udpSOCKSFixture(t, "a"), udpSOCKSFixture(t, "b")
	yaml := fmt.Sprintf("proxies:\n - {name: a, type: socks5, server: 127.0.0.1, port: %d, udp: true}\n - {name: b, type: socks5, server: 127.0.0.1, port: %d, udp: true}\nproxy-groups:\n - {name: pick, type: select, proxies: [a, b]}\nrules: [\"DST-PORT,53,pick\", \"MATCH,REJECT\"]\n", portA, portB)
	session, err := NewYAMLSession(yaml, `{}`, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	send := func(sourcePort uint16, want string) {
		t.Helper()
		packet := udpPacket(netip.MustParseAddr("203.0.113.1"), 53, []byte("hello"))
		binary.BigEndian.PutUint16(packet[20:], sourcePort)
		if err := session.WritePacket(packet); err != nil {
			t.Fatal(err)
		}
		response := readWithDeadline(t, session)
		if string(response[28:]) != want {
			t.Fatalf("reply %q, want %q", response[28:], want)
		}
	}
	send(41000, "a:hello")
	if err := session.SelectProxy("pick", "b"); err != nil {
		t.Fatal(err)
	}
	send(41000, "a:hello")
	send(41002, "b:hello")
	selected, err := session.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("203.0.113.1"), DstPort: 443})
	if err != nil || selected.Name() != "REJECT" {
		t.Fatalf("unmatched port used %v %v", selected, err)
	}
}

func TestYAMLRuleModesAndReferenceCycles(t *testing.T) {
	for _, config := range []string{
		"proxies: [{name: a, type: socks5, server: localhost, port: 1, dialer-proxy: b}, {name: b, type: socks5, server: localhost, port: 2, dialer-proxy: a}]",
		"proxies: [{name: a, type: socks5, server: localhost, port: 1, dialer-proxy: pick}]\nproxy-groups: [{name: pick, type: select, proxies: [a]}]",
	} {
		if s, err := NewYAMLSession(config, "{}", 1280); err == nil {
			s.Close()
			t.Fatal("accepted reference cycle")
		}
	}
	for _, mode := range []string{"rule", "global", "direct"} {
		t.Run(mode, func(t *testing.T) {
			s, err := NewYAMLSession("mode: "+mode, "{\"GLOBAL\":\"REJECT\"}", 1280)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			proxy, err := s.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("203.0.113.1"), DstPort: 443})
			if mode == "rule" {
				if err == nil {
					t.Fatal("unmatched rule silently routed")
				}
				return
			}
			expected := "DIRECT"
			if mode == "global" {
				expected = "REJECT"
			}
			if err != nil || proxy.Name() != expected {
				t.Fatalf("got %v %v", proxy, err)
			}
		})
	}
}

func TestYAMLRecognizesAllProtocolSchemas(t *testing.T) {
	protocols := strings.Fields("ss ssr socks5 http vmess vless snell trojan hysteria hysteria2 wireguard tuic shadowquic gost-relay ssh mieru anytls sudoku masque trusttunnel openvpn tailscale zerotier easytier")
	for _, protocol := range protocols {
		config, err := parseYAML(fmt.Sprintf("proxies: [{name: node, type: %s}]", protocol))
		if err != nil || len(config.Proxies) != 1 {
			t.Fatalf("protocol %s rejected before parser: %v", protocol, err)
		}
	}
}

func TestYAMLFailedConstructionAllowsNextSession(t *testing.T) {
	for range 3 {
		s, err := NewYAMLSession("proxies: [{name: good, type: socks5, server: localhost, port: 1234}, {name: bad, type: ss, cipher: invalid}]", "{}", 1280)
		if err == nil {
			s.Close()
			t.Fatal("accepted invalid outbound")
		}
		s, err = NewYAMLSession("mode: direct", "{}", 1280)
		if err != nil {
			t.Fatal(err)
		}
		if err = s.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestProxyDelayAndCancelBoundedConcurrency(t *testing.T) {
	var active, maxActive atomic.Int32
	started := make(chan struct{}, 20)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		current := active.Add(1)
		defer active.Add(-1)
		for {
			old := maxActive.Load()
			if old >= current || maxActive.CompareAndSwap(old, current) {
				break
			}
		}
		started <- struct{}{}
		<-r.Context().Done()
	}))
	defer server.Close()
	session, err := NewYAMLSession("mode: direct", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	var tasks sync.WaitGroup
	results := make(chan error, 12)
	for range 12 {
		tasks.Add(1)
		go func() { defer tasks.Done(); _, err := session.TestProxy("DIRECT", server.URL, 5000); results <- err }()
	}
	for range 4 {
		select {
		case <-started:
		case <-time.After(3 * time.Second):
			t.Fatal("tests did not start")
		}
	}
	session.CancelTests()
	done := make(chan struct{})
	go func() { tasks.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cancel did not release all tests")
	}
	if maxActive.Load() > 4 {
		t.Fatalf("concurrency exceeded four: %d", maxActive.Load())
	}
	for range 12 {
		if err := <-results; err == nil {
			t.Fatal("cancelled test succeeded")
		}
	}
	fast := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	defer fast.Close()
	if _, err = session.TestProxy("DIRECT", fast.URL, 1000); err != nil {
		t.Fatal(err)
	}
	status, _ := session.ProxiesJSON()
	var decoded map[string]any
	if err := json.Unmarshal([]byte(status), &decoded); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(status, `"delay":`) {
		t.Fatal("delay missing")
	}
	if _, err = session.TestProxy("DIRECT", "https://user:secret@example.com", 1000); err == nil {
		t.Fatal("credential URL accepted")
	}
}

func TestYAMLStaticGroupsAndUDPPolicy(t *testing.T) {
	for _, kind := range []string{"select", "url-test", "fallback", "load-balance"} {
		t.Run(kind, func(t *testing.T) {
			extra := ""
			if kind == "load-balance" {
				extra = ", strategy: round-robin"
			}
			session, err := NewYAMLSession(fmt.Sprintf("proxy-groups: [{name: pick, type: %s, proxies: [DIRECT, REJECT]%s}]\nrules: [\"MATCH,pick\"]", kind, extra), "{}", 1280)
			if err != nil {
				t.Fatal(err)
			}
			defer session.Close()
			metadata := &C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("203.0.113.1"), DstPort: 443}
			first, err := session.route(metadata)
			if err != nil || first.Name() != "DIRECT" {
				t.Fatalf("first route %v %v", first, err)
			}
			if kind != "load-balance" {
				if err := session.SelectProxy("pick", "REJECT"); err != nil {
					t.Fatal(err)
				}
			}
			next, err := session.route(metadata)
			if err != nil || next.Name() != "REJECT" {
				t.Fatalf("next route %v %v", next, err)
			}
		})
	}
	session, err := NewYAMLSession("proxy-groups: [{name: blocked, type: select, proxies: [DIRECT], disable-udp: true}, {name: nested, type: select, proxies: [blocked]}]\nrules: [\"MATCH,nested\"]", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if proxy, err := session.route(&C.Metadata{NetWork: C.UDP}); err == nil {
		t.Fatalf("ignored disable-udp: %v", proxy)
	}
}

func TestYAMLPacketRuleMatching(t *testing.T) {
	for _, rule := range []string{"IP-CIDR,203.0.113.0/24,REJECT,no-resolve", "SRC-IP-CIDR,198.18.0.0/16,REJECT", "SRC-PORT,41000,REJECT", "DST-PORT,443,REJECT", "NETWORK,tcp,REJECT"} {
		t.Run(rule, func(t *testing.T) {
			session, err := NewYAMLSession("rules: [\""+rule+"\", \"MATCH,DIRECT\"]", "{}", 1280)
			if err != nil {
				t.Fatal(err)
			}
			defer session.Close()
			proxy, err := session.route(&C.Metadata{NetWork: C.TCP, SrcIP: netip.MustParseAddr("198.18.0.2"), SrcPort: 41000, DstIP: netip.MustParseAddr("203.0.113.1"), DstPort: 443})
			if err != nil || proxy.Name() != "REJECT" {
				t.Fatalf("rule did not match: %v %v", proxy, err)
			}
		})
	}
}

func TestCloseCancelsProxyTestsAndReleasesOwnership(t *testing.T) {
	started := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(started); <-r.Context().Done() }))
	defer server.Close()
	session, err := NewYAMLSession("mode: direct", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	result := make(chan error, 1)
	go func() { _, err := session.TestProxy("DIRECT", server.URL, 60000); result <- err }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("test did not start")
	}
	stopped := make(chan error, 1)
	go func() { stopped <- session.Close() }()
	select {
	case err := <-stopped:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Close did not finish")
	}
	select {
	case err := <-result:
		if err == nil {
			t.Fatal("test survived Close")
		}
	case <-time.After(time.Second):
		t.Fatal("owned test did not return after Close")
	}
	next, err := NewYAMLSession("mode: direct", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	next.Close()
}
