package mobile

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/transport/socks5"
	M "github.com/metacubex/sing/common/metadata"
	"github.com/metacubex/tls"
	D "github.com/miekg/dns"
)

func TestSnifferRoutesRealFragmentedHTTPAndTLSWithoutLosingBytes(t *testing.T) {
	for _, test := range []struct {
		name, protocol string
		override       bool
	}{{"http-domain", "HTTP", true}, {"http-preserve-ip", "HTTP", false}, {"tls-sni", "TLS", true}} {
		t.Run(test.name, func(t *testing.T) {
			port := uint16(80)
			if test.protocol == "TLS" {
				port = 443
			}
			config := fmt.Sprintf("sniffer: {enable: true, sniff: {%s: {ports: ['%d'], override-destination: %t}}}\n", test.protocol, port, test.override)
			want := fmt.Sprintf("203.0.113.77:%d", port)
			if test.override {
				want = fmt.Sprintf("sniff.invalid:%d", port)
			}
			state := runSnifferEcho(t, config, port, test.protocol == "TLS", want, "DOMAIN,sniff.invalid,node", "MATCH,REJECT")
			if len(state.Connections) == 0 || state.Connections[0].Host != "sniff.invalid" || !strings.HasPrefix(strings.ToUpper(state.Connections[0].Rule), "DOMAIN,") {
				t.Fatalf("sniffed route not recorded: %+v", state.Connections)
			}
		})
	}
}

func TestSnifferSkipPoliciesPreserveOriginalDestination(t *testing.T) {
	for _, option := range []string{
		"parse-pure-ip: false", "skip-domain: [sniff.invalid]", "skip-src-address: [198.18.0.0/16]", "skip-dst-address: [203.0.113.0/24]", "skip-domain: ['rule-set:sniff-skip']",
	} {
		t.Run(strings.Split(option, ":")[0], func(t *testing.T) {
			config := "sniffer: {enable: true, sniff: {HTTP: {ports: ['80']}}, " + option + "}\n"
			if strings.Contains(option, "rule-set:") {
				config += "rule-providers: {sniff-skip: {type: inline, behavior: domain, payload: [sniff.invalid]}}\n"
			}
			state := runSnifferEcho(t, config, 80, false, "203.0.113.77:80", "DOMAIN,sniff.invalid,REJECT", "MATCH,node")
			if state.Connections[0].Host != "" {
				t.Fatal("skip policy still replaced host")
			}
		})
	}
}

func TestSnifferDNSMappingAndForceDomainPolicies(t *testing.T) {
	for _, test := range []struct {
		name, options, mode string
		wantHost, wantProxy string
	}{
		{"mapping-forced", "force-dns-mapping: true", "redir-host", "sniff.invalid", "DIRECT"},
		{"mapping-preserved", "force-dns-mapping: false", "redir-host", "original.invalid", "REJECT"},
		{"fake-ip-forced-domain", "force-domain: [original.invalid]", "fake-ip", "sniff.invalid", "DIRECT"},
	} {
		t.Run(test.name, func(t *testing.T) {
			configuration := fmt.Sprintf("dns: {enable: true, enhanced-mode: %s, nameserver: [127.0.0.1:9]}\n", test.mode)
			if test.mode == "redir-host" {
				configuration += "hosts: {original.invalid: 203.0.113.77}\n"
			}
			configuration += "sniffer: {enable: true, sniff: {HTTP: {ports: ['80']}}, " + test.options + "}\nrules: ['DOMAIN,sniff.invalid,DIRECT', 'MATCH,REJECT']"
			s, err := NewYAMLSession(configuration, "{}", 1280)
			if err != nil {
				t.Fatal(err)
			}
			defer s.Close()
			answer, err := s.routing.dns.answer(dnsQuery(t, "original.invalid.", D.TypeA))
			if err != nil {
				t.Fatal(err)
			}
			ip, _ := netip.AddrFromSlice(dnsAnswer(t, answer).Answer[0].(*D.A).A)
			target := &C.Metadata{Type: C.TUN, NetWork: C.TCP, DstIP: ip.Unmap(), DstPort: 80}
			client, inbound := net.Pipe()
			defer client.Close()
			defer inbound.Close()
			payload := []byte("GET / HTTP/1.1\r\nHost: sniff.invalid\r\n\r\n")
			go func() { _, _ = client.Write(payload) }()
			stream, err := s.sniffTCP(inbound, target)
			if err != nil {
				t.Fatal(err)
			}
			_ = stream.SetReadDeadline(time.Now().Add(time.Second))
			actual := make([]byte, len(payload))
			if _, err := io.ReadFull(stream, actual); err != nil {
				t.Fatal(err)
			}
			if string(actual) != string(payload) || target.Host != test.wantHost {
				t.Fatalf("sniffed metadata/bytes: %+v", target)
			}
			proxy, err := s.route(target)
			if err != nil {
				t.Fatal(err)
			}
			if proxy.Name() != test.wantProxy {
				t.Fatalf("wrong domain route after restore: %s", proxy.Name())
			}
		})
	}
}

func TestSnifferConfigurationRejectsInvalidSupportedValues(t *testing.T) {
	for _, value := range []string{
		"sniffer: {enable: true, sniff: {HTTP: {ports: ['70000']}}}",
	} {
		s, err := NewYAMLSession(value, "{}", 1280)
		if err == nil {
			_ = s.Close()
			t.Fatalf("accepted invalid sniffer options: %s", value)
		}
	}
}

func TestSnifferDisabledDoesNotLoadUnusedGeoResources(t *testing.T) {
	s, err := NewYAMLSession("sniffer: {enable: false, sniff: {QUIC: {ports: ['443']}}, force-domain: ['geosite:example'], skip-src-address: ['geoip:zz']}\nrules: ['MATCH,DIRECT']", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if s.routing.sniffer.Enable() {
		t.Fatal("disabled sniffer is enabled")
	}
}

func TestSnifferPendingReadCancelsWithSession(t *testing.T) {
	s, err := NewYAMLSession("sniffer: {enable: true, sniff: {HTTP: {ports: ['80']}}}\nrules: ['MATCH,REJECT']", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	client, inbound := net.Pipe()
	defer client.Close()
	done := make(chan error, 1)
	go func() {
		done <- (&sessionHandler{session: s}).NewConnection(context.Background(), inbound, M.Metadata{Destination: M.ParseSocksaddr("203.0.113.77:80")})
	}()
	deadline := time.Now().Add(time.Second)
	for runtimeSnapshot(t, s).ActiveCount != 1 {
		if time.Now().After(deadline) {
			t.Fatal("sniffer did not start")
		}
		time.Sleep(time.Millisecond)
	}
	started := time.Now()
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if time.Since(started) > 500*time.Millisecond {
		t.Fatal("close waited for sniffer deadline")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("sniffer handler survived session close")
	}
}

func runSnifferEcho(t *testing.T, snifferYAML string, port uint16, useTLS bool, wantedTarget string, rules ...string) runtimeSnapshotData {
	t.Helper()
	listener, _ := socksFixture(t)
	serverTLS, _ := interopTrojanTLS(t)
	observed := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			observed <- err
			return
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
		target, _, _, err := socks5.ServerHandshake(conn, nil)
		if err != nil {
			observed <- err
			return
		}
		if target.String() != wantedTarget {
			observed <- fmt.Errorf("target %s, want %s", target, wantedTarget)
			return
		}
		if useTLS {
			conn = tls.Server(conn, serverTLS)
		}
		observed <- nil
		_, _ = io.Copy(conn, conn)
	}()
	quoted := make([]string, len(rules))
	for i, rule := range rules {
		quoted[i] = "'" + rule + "'"
	}
	configuration := snifferYAML + fmt.Sprintf("proxies: [{name: node, type: socks5, server: 127.0.0.1, port: %d}]\nrules: [%s]\n", listener.Addr().(*net.TCPAddr).Port, strings.Join(quoted, ","))
	s, err := NewYAMLSession(configuration, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	client, inbound := net.Pipe()
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	handled := make(chan error, 1)
	go func() {
		handled <- (&sessionHandler{session: s}).NewConnection(context.Background(), inbound, M.Metadata{Source: M.ParseSocksaddr("198.18.0.2:1234"), Destination: M.ParseSocksaddr(fmt.Sprintf("203.0.113.77:%d", port))})
	}()
	var stream net.Conn = fragmentSnifferConn{client}
	payload := []byte("GET / HTTP/1.1\r\nHost: sniff.invalid\r\n\r\n")
	if useTLS {
		stream = tls.Client(stream, &tls.Config{ServerName: "sniff.invalid", InsecureSkipVerify: true, MinVersion: tls.VersionTLS13})
		payload = []byte("actual encrypted payload after sniffing")
	}
	if _, err := stream.Write(payload); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, len(payload))
	if _, err := io.ReadFull(stream, response); err != nil {
		t.Fatal(err)
	}
	if string(response) != string(payload) {
		t.Fatal("sniffer consumed or changed stream bytes")
	}
	if err := <-observed; err != nil {
		t.Fatal(err)
	}
	state := runtimeSnapshot(t, s)
	_ = client.Close()
	select {
	case <-handled:
	case <-time.After(time.Second):
		t.Fatal("sniffed flow survived close")
	}
	return state
}

type fragmentSnifferConn struct{ net.Conn }

func (c fragmentSnifferConn) Write(bytes []byte) (int, error) {
	count := 0
	for len(bytes) > 0 {
		size := min(13, len(bytes))
		n, err := c.Conn.Write(bytes[:size])
		count += n
		bytes = bytes[n:]
		if err != nil {
			return count, err
		}
	}
	return count, nil
}
