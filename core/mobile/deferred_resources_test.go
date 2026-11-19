package mobile

import (
	"encoding/json"
	"fmt"
	"testing"
)

func TestDeferredResourcesKeepSelectedProxyAndWholeRuleFallback(t *testing.T) {
	port := exitIPProxy(t, "selected")
	config := fmt.Sprintf(`profile: {store-selected: false}
sniffer: {enable: true}
proxies: [{name: chosen, type: socks5, server: 127.0.0.1, port: %d}]
proxy-groups: [{name: Final, type: select, proxies: [REJECT, chosen]}]
rule-providers: {remote: {type: http, behavior: domain, url: 'https://never.invalid/rules'}}
rules:
 - NOT,((RULE-SET,remote)),REJECT
 - NOT,((GEOIP,CN)),REJECT
 - GEOIP,CN,REJECT
 - MATCH,Final
`, port)
	if s, err := NewYAMLSessionWithStorage(config, `{"Final":"chosen"}`, "", "", 1280); err == nil {
		s.Close()
		t.Fatal("strict session accepted missing resources")
	}
	session, err := NewYAMLSessionWithDeferredResources(config, `{"Final":"chosen"}`, "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if !session.ResourcesPending() {
		t.Fatal("missing resources were not reported")
	}
	if len(session.routing.rules) != 1 {
		t.Fatalf("partial dependency left %d active rules", len(session.routing.rules))
	}
	result, err := session.exitIPJSON("http://198.51.100.9/", "http://198.51.100.9/v6", "http://198.51.100.9/")
	if err != nil {
		t.Fatal(err)
	}
	var response struct{ Route string }
	if json.Unmarshal([]byte(result), &response) != nil || response.Route != "selected" {
		t.Fatalf("fallback bypassed selected proxy: %s", result)
	}
}

func TestDeferredResourcesStillRejectInvalidResourcesAndUnknownDependencies(t *testing.T) {
	root := bundleFixture(t, "geoip-mmdb", "default", []byte("invalid database"))
	for _, tc := range []struct{ config, root string }{
		{"rules: ['GEOIP,CN,REJECT','MATCH,DIRECT']", root},
		{"rules: ['RULE-SET,unknown,REJECT','MATCH,DIRECT']", ""},
		{"proxy-providers: {remote: {type: http, url: 'https://never.invalid/nodes'}}\nproxy-groups: [{name: Final, type: select, use: [remote]}]\nrules: ['MATCH,Final']", ""},
	} {
		session, err := NewYAMLSessionWithDeferredResources(tc.config, "{}", tc.root, "", 1280)
		if err == nil {
			session.Close()
			t.Fatal("deferred mode accepted invalid or critical missing dependency")
		}
	}
}
