package mobile

import (
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/keepalive"
	MConfig "github.com/metacubex/mihomo/config"
)

func TestYAMLFilterPreservesDynamicDNSPolicies(t *testing.T) {
	value := `dns:
  nameserver-policy:
    '+.example.invalid': ['1.1.1.1']
    'rule-set:private': ['9.9.9.9']
  proxy-server-nameserver-policy:
    '+.gateway.invalid': ['8.8.8.8']
`
	actual, err := parseYAML(value)
	if err != nil {
		t.Fatal(err)
	}
	expected, err := MConfig.UnmarshalRawConfig([]byte(value))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actual.Raw.DNS.NameServerPolicy, expected.DNS.NameServerPolicy) ||
		!reflect.DeepEqual(actual.Raw.DNS.ProxyServerNameserverPolicy, expected.DNS.ProxyServerNameserverPolicy) {
		t.Fatal("filter changed dynamic DNS policy keys or values")
	}
}

func TestYAMLNullOptionalFieldsFollowNativeDefaults(t *testing.T) {
	value := `mode: direct
ipv6: null
hosts: null
proxies: null
proxy-groups: null
proxy-providers: null
rule-providers: null
rules: null
sub-rules: null
profile: null
geox-url: null
dns:
  nameserver: null
  fallback: null
  nameserver-policy: null
  fallback-filter: null
sniffer:
  sniff: null
  force-domain: null
tun:
  route-exclude-address: null
  dns-hijack: null
`
	got, err := parseYAML(value)
	if err != nil {
		t.Fatal(err)
	}
	want, err := MConfig.UnmarshalRawConfig([]byte(value))
	if err != nil {
		t.Fatal(err)
	}
	if got.Raw.IPv6 != want.IPv6 || !reflect.DeepEqual(got.Raw.DNS, want.DNS) ||
		!reflect.DeepEqual(got.Raw.Profile, want.Profile) || !reflect.DeepEqual(got.Raw.GeoXUrl, want.GeoXUrl) ||
		!reflect.DeepEqual(got.Raw.Tun, want.Tun) || !reflect.DeepEqual(got.Raw.Sniffer, want.Sniffer) {
		t.Fatal("optional null fields changed native default decoding")
	}
}

func TestYAMLConfiguredKeepAliveReachesDialerAndRestoresAfterClose(t *testing.T) {
	previousIdle, previousInterval, previousDisabled := keepalive.KeepAliveIdle(), keepalive.KeepAliveInterval(), keepalive.DisableKeepAlive()
	session, err := NewYAMLSession("mode: direct\nkeep-alive-idle: 15\nkeep-alive-interval: 30\n", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	dialer := &net.Dialer{}
	keepalive.SetNetDialer(dialer)
	if !dialer.KeepAliveConfig.Enable || dialer.KeepAliveConfig.Idle != 15*time.Second || dialer.KeepAliveConfig.Interval != 30*time.Second {
		t.Fatalf("configured TCP keepalive did not reach the dialer: %+v", dialer.KeepAliveConfig)
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	if keepalive.KeepAliveIdle() != previousIdle || keepalive.KeepAliveInterval() != previousInterval || keepalive.DisableKeepAlive() != previousDisabled {
		t.Fatal("closed YAML session leaked TCP settings into subsequent sessions")
	}
	_, err = NewYAMLSession("keep-alive-idle: 22\nkeep-alive-interval: 33\nrules: ['UNSUPPORTED-RULE,DIRECT']", "{}", 1280)
	if err == nil {
		t.Fatal("expected invalid routing configuration to fail")
	}
	if keepalive.KeepAliveIdle() != previousIdle || keepalive.KeepAliveInterval() != previousInterval {
		t.Fatal("failed YAML session leaked TCP settings")
	}
}

func TestYAMLGlobalUserAgentIsUsedByResourceDownload(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		t.Run(fmt.Sprint(explicit), func(t *testing.T) {
			seen := make(chan string, 1)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				seen <- r.Header.Get("User-Agent")
				_, _ = w.Write([]byte("payload:\n - example.invalid\n"))
			}))
			defer server.Close()
			header, expected := "", "FixtureAgent/1"
			if explicit {
				header, expected = "\n    header: {User-Agent: ProviderAgent/2}", "ProviderAgent/2"
			}
			value := fmt.Sprintf("global-ua: FixtureAgent/1\nrule-providers:\n  remote:\n    type: http\n    behavior: domain\n    url: %s%s\nrules: ['MATCH,DIRECT']\n", server.URL, header)
			preparation, err := NewYAMLResourcePreparation(value, "{}", "", "", 1280)
			if err != nil {
				t.Fatal(err)
			}
			defer preparation.Cancel()
			if err := preparation.Prepare(); err != nil {
				t.Fatal(err)
			}
			if got := <-seen; got != expected {
				t.Fatalf("download User-Agent %q, expected %q", got, expected)
			}
		})
	}
}

func TestYAMLExportedDesktopDefaultsAreAccepted(t *testing.T) {
	value := `mode: direct
ss-config: ""
vmess-config: ""
inbound-tfo: false
inbound-mptcp: false
authentication: []
skip-auth-prefixes: []
lan-allowed-ips: ['0.0.0.0/0', '::/0']
lan-disallowed-ips: null
external-controller-routing-mark: 0
external-doh-server: ""
interface-name: ""
routing-mark: 0
tunnels: null
listeners: null
unified-delay: false
tcp-concurrent: false
find-process-mode: strict
global-client-fingerprint: ""
etag-support: true
disable-keep-alive: false
ntp: {enable: false}
tuic-server: {enable: false}
iptables: {enable: false}
mitm: {enable: false}
tls: {certificate: "", private-key: "", custom-certifactes: null}
experimental: {fingerprints: null, quic-go-disable-gso: false, quic-go-disable-ecn: true, dialer-ip4p-convert: false}
clash-for-android: {append-system-dns: false, ui-subtitle-pattern: ""}
tun:
  enable: false
  dns-mode: ""
  file-descriptor: 0
  recvmsgx: true
  sendmsgx: false
  processors-per-channel: 1
  inet6-address: [fdfe:dcba:9876::1/126]
  auto-route: true
  auto-detect-interface: true
`
	config, err := parseYAML(value)
	if err != nil {
		t.Fatal(err)
	}
	if len(config.Warnings) == 0 {
		t.Fatal("desktop defaults were accepted without reporting iOS handling")
	}
}

func TestYAMLCompatibilityKeepsInvalidSupportedValuesRejected(t *testing.T) {
	for _, value := range []string{
		"dns: {enable: invalid}",
		"proxies: [null]",
		"rules: [null]",
		"profile: &empty null\nrules: [*empty]",
		"proxies: [{name: node, type: unsupported-protocol}]",
		"tun: {dns-hijack: ['https://any:53']}",
		"tun: {route-exclude-address: [not-a-cidr]}",
	} {
		if _, err := parseYAML(value); err == nil {
			t.Fatalf("accepted unsupported input %q", value)
		}
	}
}

func TestYAMLUnsupportedOptionsAreRemovedBeforeNativeDecode(t *testing.T) {
	value := `unknown-option: [null]
ntp: {enable: true}
mitm: {enable: true}
listeners: [{type: http, port: 9999}]
interface-name: en0
routing-mark: 23
dns: {enable: false, unsupported: null, listen: [invalid], listen-routing-mark: 99}
tun: {auto-route: false, file-descriptor: 9, device: custom, unexpected: [null]}
proxies: [{name: node, type: direct, interface-name: en0, routing-mark: 99, decoration: [null]}]
proxy-groups: [{name: pick, type: select, proxies: [node], icon: anything}]
sniffer: {enable: true, unknown: true, sniff: {HTTP: {ports: ['80'], decoration: true}, QUIC: {ports: [invalid]}}}
rules: ['MATCH,pick']
`
	config, err := parseYAML(value)
	if err != nil {
		t.Fatal(err)
	}
	if config.Raw.NTP.Enable || config.Raw.Interface != "" || config.Raw.RoutingMark != 0 || len(config.Raw.Listeners) != 0 || config.Raw.Tun.FileDescriptor != 0 || config.Raw.DNS.ListenRoutingMark != 0 {
		t.Fatal("ignored desktop fields reached native runtime")
	}
	if _, exists := config.Proxies[0]["interface-name"]; exists {
		t.Fatal("ignored proxy interface reached native runtime")
	}
	if _, exists := config.Raw.Sniffer.Sniff["QUIC"]; exists {
		t.Fatal("unsupported sniffer reached native runtime")
	}
	if len(config.Groups) != 1 || len(config.Proxies) != 1 || len(config.Rules) != 1 {
		t.Fatal("filter removed nodes, groups, or rules")
	}
}

func TestYAMLDownloadedProviderIgnoresDesktopNodeOptions(t *testing.T) {
	data := []byte("proxies: [{name: node, type: direct, interface-name: nonexistent, routing-mark: 999, extra: {certificate: /must-not-read, decoration: [null]}}]\n")
	root := bundleFixture(t, "proxy-provider", "remote", data)
	value := "proxy-providers: {remote: {type: http, url: 'https://never.invalid/nodes'}}\nproxy-groups: [{name: pick, type: select, use: [remote]}]\nrules: ['MATCH,pick']\n"
	session, err := NewYAMLSessionWithResources(value, "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if err := session.SelectProxy("pick", "node"); err != nil {
		t.Fatal(err)
	}
}
