package mobile

import (
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/geodata"
)

func TestYAMLAnchorsMergePreservesNativePriority(t *testing.T) {
	value := `proxies:
 - &first {name: first, type: socks5, server: 127.0.0.1, port: 1080, udp: true}
 - &second {name: second, type: socks5, server: 127.0.0.2, port: 1081, udp: false}
 - {<<: [*first, *second], name: combined, port: 1082}
proxy-groups:
 - {name: pick, type: select, proxies: &members [first, combined]}
 - {name: other, type: select, proxies: *members}
rules: ["MATCH,pick"]
`
	config, err := parseYAML(value)
	if err != nil {
		t.Fatal(err)
	}
	got := config.Proxies[2]
	if got["server"] != "127.0.0.1" || got["port"] != 1082 || got["udp"] != true {
		t.Fatalf("merge priority changed: %#v", got)
	}
	s, err := NewYAMLSession(value, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.SelectProxy("other", "combined"); err != nil {
		t.Fatal(err)
	}
}

func TestYAMLAnchorsRejectInvalidDocuments(t *testing.T) {
	for _, value := range []string{
		"proxies: [ &p {name: p, type: direct, name: duplicate}, {<<: *p, name: q}]",
		"proxies: &p [*p]",
		"proxies: [{<<: 42, name: p, type: direct}]",
	} {
		if _, err := parseYAML(value); err == nil {
			t.Fatalf("accepted invalid alias document %s", value)
		}
	}
	var value strings.Builder
	value.WriteString("proxies: &a [one, one, one, one, one, one, one, one, one, one]\n")
	for i := byte('b'); i < 'h'; i++ {
		value.WriteString(string(i) + ": &" + string(i) + " [" + strings.TrimSuffix(strings.Repeat("*"+string(i-1)+",", 10), ",") + "]\n")
	}
	if _, err := parseYAML(value.String()); err == nil || !strings.Contains(err.Error(), "expanded YAML") {
		t.Fatalf("expected expansion limit, got %v", err)
	}
}

func TestYAMLProviderAcceptsAnchorsAndRejectsCycles(t *testing.T) {
	if err := providerSource([]byte("proxies: [ &p {name: one, type: direct}, {<<: *p, name: two}]")); err != nil {
		t.Fatal(err)
	}
	root := bundleFixture(t, "proxy-provider", "nodes", []byte("proxies: [ &p {name: one, type: direct}, {<<: *p, name: two}]"))
	session, err := NewYAMLSessionWithResources("proxy-providers: {nodes: {type: file, path: /must-not-read}}\nproxy-groups: [{name: pick, type: select, use: [nodes]}]\nrules: ['MATCH,pick']", "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if err := session.SelectProxy("pick", "two"); err != nil {
		t.Fatal(err)
	}
	if err := providerSource([]byte("proxies: &p [*p]")); err == nil {
		t.Fatal("accepted provider alias cycle")
	}
}

func TestYAMLGeodataDefaultDoesNotInheritGlobal(t *testing.T) {
	previous := geodata.GeodataMode()
	geodata.SetGeodataMode(true)
	defer geodata.SetGeodataMode(previous)
	config, err := parseYAML("mode: direct")
	if err != nil {
		t.Fatal(err)
	}
	if config.Raw.GeodataMode {
		t.Fatal("default inherited global geodata mode")
	}
	config, err = parseYAML("mode: direct\ngeodata-mode: true")
	if err != nil || !config.Raw.GeodataMode {
		t.Fatalf("explicit mode lost: %v", err)
	}
}
