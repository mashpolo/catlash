package mobile

import (
	"strings"
	"testing"
)

func TestYAMLSessionRejectsUnsupportedPathsAndReferences(t *testing.T) {
	for _, test := range []struct{ yaml, path string }{
		{"mode: rule\nmode: direct\n", "mode"},
		{"proxy-groups: [{name: loop, type: select, proxies: [loop]}]\nrules: [\"MATCH,loop\"]\n", "cycle"},
		{"proxy-groups: [{name: pick, type: select, proxies: [missing]}]\n", "missing"},
		{"rules: [\"GEOIP,CN,DIRECT\"]\n", "rules[0]"},
		{"rules: [\"DOMAIN,example.com,DIRECT\"]\n", "rules[0]"},
	} {
		session, err := NewYAMLSession(test.yaml, "{}", 1280)
		if err == nil {
			session.Close()
			t.Errorf("accepted unsupported YAML %s", test.yaml)
			continue
		}
		if !strings.Contains(err.Error(), test.path) {
			t.Errorf("error %q omitted %q", err, test.path)
		}
	}
}

func TestYAMLSessionGroupsAndPrivateStatus(t *testing.T) {
	session, err := NewYAMLSession("proxies: [{name: node, type: socks5, server: localhost, port: 1234, password: private-value}]\nproxy-groups: [{name: pick, type: select, proxies: [node, DIRECT]}]\nrules: [\"MATCH,pick\"]\n", `{"pick":"DIRECT"}`, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	status, err := session.ProxiesJSON()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(status, "private-value") || strings.Contains(status, "localhost") {
		t.Fatalf("status leaked options: %s", status)
	}
	if err = session.SelectProxy("pick", "node"); err != nil {
		t.Fatal(err)
	}
	if err = session.SelectProxy("pick", "missing"); err == nil {
		t.Fatal("accepted invalid member")
	}
}

func TestYAMLRejectsFileResourcesBeforeConstruction(t *testing.T) {
	for _, test := range []struct{ node, path string }{
		{"{name: node, type: socks5, server: localhost, port: 1234, certificate: /tmp/external.pem}", "proxies[0].certificate"},
		{"{name: node, type: ssh, server: localhost, port: 22, private-key: /tmp/id_rsa}", "proxies[0].private-key"},
		{"{name: node, type: tailscale, state-dir: /tmp/state}", "proxies[0].state-dir"},
		{"{name: node, type: zerotier, planet: /tmp/planet}", "proxies[0].planet"},

		{"{name: node, type: tailscale}", "resource root"},
		{"{name: node, type: zerotier}", "resource root"},
		{"{name: node, type: easytier}", "resource root"},
	} {
		s, err := NewYAMLSession("proxies: ["+test.node+"]", "{}", 1280)
		if err == nil {
			s.Close()
			t.Fatalf("accepted file-dependent node %s", test.node)
		}
		if !strings.Contains(err.Error(), test.path) {
			t.Fatalf("got %q, expected path %s", err, test.path)
		}
	}
}
