package mobile

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	C "github.com/metacubex/mihomo/constant"
	D "github.com/miekg/dns"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func bundleFixture(t *testing.T, kind, name string, data []byte) string {
	t.Helper()
	hash := sha256.Sum256(data)
	digest := hex.EncodeToString(hash[:])
	manifest, _ := json.Marshal(map[string]any{"version": 1, "entries": []map[string]any{{"kind": kind, "name": name, "sha256": digest, "size": len(data)}}})
	id := sha256.Sum256(manifest)
	path := filepath.Join(t.TempDir(), hex.EncodeToString(id[:]))
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "manifest.json"), manifest, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, digest), data, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}
func TestResourceBundleIntegrityAndSymlinkRejection(t *testing.T) {
	data := []byte("proxies: [{name: node, type: direct}]\n")
	root := bundleFixture(t, "proxy-provider", "nodes", data)
	resources, err := loadResourceBundle(root)
	if err != nil || string(resources[resourceKey{"proxy-provider", "nodes"}]) != string(data) {
		t.Fatalf("resource %v %v", resources, err)
	}
	hash := sha256.Sum256(data)
	name := filepath.Join(root, hex.EncodeToString(hash[:]))
	if err := os.WriteFile(name, []byte("tampered"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadResourceBundle(root); err == nil {
		t.Fatal("accepted changed blob")
	}
	target := filepath.Join(t.TempDir(), "external")
	os.WriteFile(target, data, 0600)
	os.Remove(name)
	os.Symlink(target, name)
	if _, err := loadResourceBundle(root); err == nil {
		t.Fatal("accepted symlink blob")
	}
}
func TestInlineProxyProviderNativeFilterOverrideAndUse(t *testing.T) {
	config := `proxy-providers:
 nodes:
  type: inline
  filter: '^keep'
  override: {additional-prefix: 'prefix-'}
  payload: [{name: keep, type: direct}, {name: discard, type: reject}]
proxy-groups: [{name: pick, type: select, use: [nodes]}]
rules: ['MATCH,pick']
`
	session, err := NewYAMLSessionWithResources(config, "{}", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	catalog, err := session.ProxiesJSON()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(catalog, `"now":"prefix-keep"`) || strings.Contains(catalog, `"name":"discard"`) {
		t.Fatal(catalog)
	}
}

func TestCachedProviderRulesAndDNSPolicy(t *testing.T) {
	address := dnsFixture(t)
	data := []byte("payload:\n - '+.example.invalid'\n")
	root := bundleFixture(t, "rule-provider", "domains", data)
	config := dnsYAML(address, "fake-ip") + "rule-providers: {domains: {type: http, behavior: domain, url: 'https://unused.invalid/rules'}}\nrules: ['RULE-SET,domains,REJECT', 'MATCH,DIRECT']\n"
	config = strings.Replace(config, " enhanced-mode: fake-ip", " nameserver-policy: {'rule-set:domains': ['"+address+"']}\n fake-ip-filter: ['rule-set:domains']\n enhanced-mode: fake-ip", 1)
	session, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	session.WritePacket(udpPacket(netip.MustParseAddr("198.18.0.1"), 53, dnsQuery(t, "example.invalid.", D.TypeA)))
	answer := dnsAnswer(t, readWithDeadline(t, session)[28:])
	ip, _ := netip.AddrFromSlice(answer.Answer[0].(*D.A).A)
	ip = ip.Unmap()
	if ip.String() != "203.0.113.9" {
		t.Fatalf("fake-IP rule provider not applied: %s", ip)
	}
	selected, err := session.route(&C.Metadata{NetWork: C.TCP, DstIP: ip, DstPort: 443})
	if err != nil || selected.Name() != "REJECT" {
		t.Fatalf("RULE-SET route %v %v", selected, err)
	}
}

func TestProviderInvalidRuleAndReferenceCycleReject(t *testing.T) {
	for _, config := range []string{
		"rule-providers: {bad: {type: inline, behavior: ipcidr, payload: [invalid]}}",
		"rule-providers: {bad: {type: inline, behavior: classical, payload: ['GEOIP,CN']}}",
		"proxy-providers: {nodes: {type: inline, payload: [{name: node, type: socks5, server: localhost, port: 1, dialer-proxy: pick}]}}\nproxy-groups: [{name: pick, type: select, use: [nodes]}]",
	} {
		session, err := NewYAMLSessionWithResources(config, "{}", "", 1280)
		if err == nil {
			session.Close()
			t.Fatal("accepted invalid provider")
		}
		next, err := NewYAMLSession("mode: direct", "{}", 1280)
		if err != nil {
			t.Fatal(err)
		}
		next.Close()
	}
}

func TestCachedProxyProviderUsesSOCKSUDP(t *testing.T) {
	port := udpSOCKSFixture(t, "cached")
	data := []byte(fmt.Sprintf("proxies: [{name: remote, type: socks5, server: 127.0.0.1, port: %d, udp: true}]\n", port))
	root := bundleFixture(t, "proxy-provider", "nodes", data)
	config := "proxy-providers: {nodes: {type: file, path: /must-not-read-original}}\nproxy-groups: [{name: pick, type: select, use: [nodes]}]\nrules: ['MATCH,pick']"
	session, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	session.WritePacket(udpPacket(netip.MustParseAddr("203.0.113.8"), 443, []byte("hello")))
	reply := readWithDeadline(t, session)
	if string(reply[28:]) != "cached:hello" {
		t.Fatalf("provider bypassed SOCKS: %x", reply)
	}
}
func TestProviderNumericExpectedStatusAcrossPreparationAndSession(t *testing.T) {
	for _, status := range []int{http.StatusNoContent, http.StatusOK} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			var downloaded atomic.Bool
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/rules" {
					downloaded.Store(true)
					fmt.Fprint(w, "payload: ['example.invalid']\n")
					return
				}
				w.WriteHeader(status)
			}))
			defer server.Close()
			root := bundleFixture(t, "proxy-provider", "nodes", []byte("proxies: [{name: node, type: direct}]\n"))
			config := fmt.Sprintf("proxy-providers: {nodes: {type: http, url: 'https://unused.invalid/nodes', health-check: {enable: true, url: '%s/check', interval: 300, timeout: 5000, lazy: false, expected-status: 204}}}\nproxy-groups: [{name: pick, type: select, use: [nodes]}]\nrules: ['MATCH,pick']\n", server.URL)
			preparation, err := NewYAMLResourcePreparation(config+fmt.Sprintf("rule-providers: {domains: {type: http, behavior: domain, proxy: pick, url: '%s/rules'}}\n", server.URL), "{}", root, "", 1280)
			if err != nil {
				t.Fatal(err)
			}
			if err := preparation.Prepare(); err != nil {
				t.Fatal(err)
			}
			if !downloaded.Load() {
				t.Fatal("provider health options blocked the resource download")
			}
			session, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
			if err != nil {
				t.Fatal(err)
			}
			defer session.Close()
			proxy := session.routing.proxyProviders["nodes"].Proxies()[0]
			url := server.URL + "/check"
			deadline := time.Now().Add(time.Second)
			for len(proxy.ExtraDelayHistories()[url].History) == 0 && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond)
			}
			state := proxy.ExtraDelayHistories()[url]
			if len(state.History) == 0 || state.Alive != (status == http.StatusNoContent) {
				t.Fatalf("numeric expected-status did not classify HTTP %d: %+v", status, state)
			}
		})
	}
}

func TestProviderHealthChecksBoundedAndOwned(t *testing.T) {
	arrived := make(chan struct{}, 12)
	var active, max atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		current := active.Add(1)
		defer active.Add(-1)
		for {
			old := max.Load()
			if old >= current || max.CompareAndSwap(old, current) {
				break
			}
		}
		arrived <- struct{}{}
		<-r.Context().Done()
	}))
	defer server.Close()
	payload := []string{}
	providers := []string{}
	for i := range 8 {
		payload = append(payload, fmt.Sprintf("{name: direct%d, type: direct}", i))
		providers = append(providers, fmt.Sprintf("p%d: {type: inline, health-check: {enable: true, url: '%s', interval: 1, timeout: 60000, lazy: false}, payload: [%s]}", i, server.URL, payload[i]))
	}
	config := "proxy-providers: {" + strings.Join(providers, ",") + "}\nmode: direct"
	session, err := NewYAMLSessionWithResources(config, "{}", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	for range 4 {
		select {
		case <-arrived:
		case <-time.After(time.Second):
			t.Fatal("health checks did not start")
		}
	}
	done := make(chan error, 1)
	go func() { done <- session.Close() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("health checks survived close")
	}
	if max.Load() > 4 {
		t.Fatalf("health concurrency %d", max.Load())
	}
}

func TestGroupHealthCheckAndIncludeAllProviders(t *testing.T) {
	arrived := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { arrived <- struct{}{}; <-r.Context().Done() }))
	defer server.Close()
	config := fmt.Sprintf("proxy-providers: {nodes: {type: inline, payload: [{name: node, type: direct}]}}\nproxy-groups: [{name: auto, type: url-test, include-all-providers: true, url: '%s', interval: 10, timeout: 60000}]\nrules: ['MATCH,auto']", server.URL)
	session, err := NewYAMLSessionWithResources(config, "{}", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	select {
	case <-arrived:
	case <-time.After(time.Second):
		t.Fatal("group probe did not start")
	}
	done := make(chan error, 1)
	go func() { done <- session.Close() }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("group health check survived close")
	}
}

func TestProviderGroupEmptyFilterDoesNotBypassPolicy(t *testing.T) {
	config := "proxy-providers: {nodes: {type: inline, payload: [{name: only, type: direct}]}}\nproxy-groups: [{name: pick, type: select, use: [nodes], filter: '^missing$'}]\nrules: ['MATCH,pick']"
	session, err := NewYAMLSession(config, "{}", 1280)
	if err == nil {
		session.Close()
		t.Fatal("empty filter silently used the excluded direct node")
	}
}
