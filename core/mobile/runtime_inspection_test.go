package mobile

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

func TestEffectiveViewUsesLiveRulesModeAndRedactsSecrets(t *testing.T) {
	config := "secret: dropped\nmixed-port: 7890\nproxies: [{name: X, type: socks5, server: private.invalid, port: 1080, password: do-not-show}]\nproxy-groups: [{name: Final, type: select, proxies: [DIRECT,X]}]\nrule-providers: {later: {type: http, behavior: domain, url: 'https://private.invalid/token'}}\nrules: ['RULE-SET,later,REJECT','PROCESS-NAME,app,REJECT','MATCH,Final']"
	s, err := NewYAMLSessionWithDeferredResources(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err = s.SetMode("global"); err != nil {
		t.Fatal(err)
	}
	if err = s.SelectProxy("Final", "X"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "view")
	if err = s.WriteEffectiveConfiguration(config, path); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, leak := range []string{"do-not-show", "private.invalid", "mixed-port", "PROCESS-NAME", "RULE-SET,later", "secret:"} {
		if strings.Contains(string(data), leak) {
			t.Fatalf("unexpected %s", leak)
		}
	}
	for _, want := range []string{"MATCH,Final", "global", "default-selected: X"} {
		if !strings.Contains(string(data), want) {
			t.Fatalf("missing %s: %s", want, data)
		}
	}
}
func TestTargetProviderRefreshUsesOneURLAndKeepsLiveSet(t *testing.T) {
	var calls []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls = append(calls, r.URL.Path)
		fmt.Fprint(w, "payload: ['example.org']\n")
	}))
	defer server.Close()
	config := fmt.Sprintf("rule-providers: {a: {type: http, behavior: domain, url: '%s/a'}, b: {type: http, behavior: domain,url: '%s/b'}}\nrules: ['MATCH,DIRECT']", server.URL, server.URL)
	s, err := NewYAMLSessionWithDeferredResources(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	prep, err := s.NewResourcePreparation(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err = prep.RefreshProvider("rule-provider", "a"); err != nil {
		t.Fatal(err)
	}
	if err = prep.Prepare(); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 1 || calls[0] != "/a" || prep.ResourceCount() != 1 || len(s.routing.ruleProviders) != 0 {
		t.Fatalf("requests %v", calls)
	}
	catalog, err := s.ProvidersJSON()
	if err != nil {
		t.Fatal(err)
	}
	var result []map[string]any
	if err = json.Unmarshal([]byte(catalog), &result); err != nil || len(result) != 2 || result[0]["status"] != "deferred" {
		t.Fatal(catalog, err)
	}
}

func TestEffectiveViewRetainsRulePunctuationAndFiltersDeferredDNS(t *testing.T) {
	config := dnsYAML(dnsFixture(t), "fake-ip") + ` nameserver-policy: {'rule-set:later': [1.1.1.1], 'live.invalid': [8.8.8.8]}
 fake-ip-filter: ['rule-set:later','*.lan']
rule-providers: {later: {type: http, behavior: domain, url: 'https://hidden.invalid/s?key=secret-provider', header: {Authorization: [secret-header]}}}
rules: ['DOMAIN-REGEX,a.?b#c,REJECT','MATCH,DIRECT']
`
	s, err := NewYAMLSessionWithDeferredResources(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	path := filepath.Join(t.TempDir(), "view")
	if err = s.WriteEffectiveConfiguration(config, path); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"rule-set:later", "secret-provider", "secret-header"} {
		if strings.Contains(string(b), forbidden) {
			t.Fatalf("found %s in effective view", forbidden)
		}
	}
	for _, wanted := range []string{"DOMAIN-REGEX,a.?b#c,REJECT", "*.lan", "live.invalid"} {
		if !strings.Contains(string(b), wanted) {
			t.Fatalf("missing %s in effective view: %s", wanted, b)
		}
	}
}
func TestInspectionMasksCredentialedDNSAndKeepsStandardDoHHost(t *testing.T) {
	var value yaml.Node
	if err := yaml.Unmarshal([]byte("servers: ['https://user:hidden@example.org/dns-query?token=embedded#proxy', 'https://other.invalid/private-token/path']"), &value); err != nil {
		t.Fatal(err)
	}
	redactAddresses(viewField(value.Content[0], "servers"))
	b, err := yaml.Marshal(&value)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"hidden", "user:", "embedded", "private-token", "#proxy"} {
		if strings.Contains(string(b), forbidden) {
			t.Fatal(string(b))
		}
	}
	if !strings.Contains(string(b), "https://example.org/dns-query") {
		t.Fatal(string(b))
	}
}
func TestProviderReceiptUsesOnlyVerifiedContentAndActualUsage(t *testing.T) {
	var calls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("Subscription-Userinfo", "upload=12; download=34; total=560; expire=1893456000; token=secret-ignored")
		fmt.Fprint(w, "proxies: [{name: P, type: socks5, server: 127.0.0.1, port: 1080}]")
	}))
	defer server.Close()
	config := fmt.Sprintf("proxy-providers: {remote: {type: http, url: '%s'}}\nproxy-groups: [{name: Final, type: select, use: [remote]}]\nrules: ['MATCH,Final']", server.URL)
	state := t.TempDir()
	s, err := NewYAMLSessionWithDeferredResources(config, "{}", "", state, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	catalog, err := s.ProvidersJSON()
	if err != nil {
		t.Fatal(err)
	}
	var rows []runtimeProvider
	if err = json.Unmarshal([]byte(catalog), &rows); err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Count == nil || *rows[0].Count != 1 || rows[0].UpdatedAt == nil || rows[0].Subscription["download"] != 34 || strings.Contains(catalog, "secret-ignored") {
		t.Fatal(catalog)
	}
	p, err := s.NewResourcePreparation(config, "{}", "", state, 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err = p.RefreshProvider("proxy-provider", "remote"); err != nil {
		t.Fatal(err)
	}
	if err = p.Prepare(); err != nil {
		t.Fatal(err)
	}
	if calls != 2 || p.ResourceCount() != 1 {
		t.Fatalf("update requests %d entries %d", calls, p.ResourceCount())
	}
	if receipt := readProviderReceipt(state, resourceKey{"proxy-provider", "remote"}, map[string]any{"url": server.URL}, []byte("old content")); receipt.UpdatedAt != nil {
		t.Fatal("old content gained new timing")
	}
}
