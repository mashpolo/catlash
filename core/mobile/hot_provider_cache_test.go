package mobile

import (
	"os"
	"strings"
	"testing"
)

func TestHotProviderCacheSurvivesReconnectAndRespectsConfiguration(t *testing.T) {
	old := []byte("+.old.example\n")
	updated := []byte("+.one.example\n+.two.example\n")
	key := resourceKey{"rule-provider", "rules"}
	bundle := bundleFixture(t, key.kind, key.name, old)
	config := "rule-providers: {rules: {type: http, behavior: domain, format: text, url: 'https://rules.invalid/source'}}\nrules: ['MATCH,DIRECT']"
	profileRoot := t.TempDir()
	prep, err := NewYAMLResourcePreparation(config, "{}", bundle, profileRoot, 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer prep.Cancel()
	if err := prep.persistHotProvider(key, updated); err != nil {
		t.Fatal(err)
	}

	check := func(source, baseline string, want int) {
		t.Helper()
		s, err := NewYAMLSessionWithStorage(source, "{}", baseline, profileRoot, 1280)
		if err != nil {
			t.Fatal(err)
		}
		defer s.Close()
		if count := s.routing.ruleProviders["rules"].Count(); count != want {
			t.Fatalf("rule count = %d, want %d", count, want)
		}
	}
	check(config, bundle, 2)
	check(strings.Replace(config, "rules.invalid", "different.invalid", 1), bundle, 1)
	explicit := bundleFixture(t, key.kind, key.name, []byte("+.new-source.example"))
	check(config, explicit, 1)
	cache := hotProviderFile(profileRoot, key)
	if err := os.WriteFile(cache, []byte("truncated"), 0600); err != nil {
		t.Fatal(err)
	}
	check(config, bundle, 1)
}
