package mobile

import (
	"runtime"
	"testing"
	"time"
)

func watchRuleProviderCollection(s *Session, released chan struct{}) {
	provider := (*s.routing.ruleProviders["domains"].(*liveRuleProvider).current.Load()).(*compactDomainProvider)
	runtime.SetFinalizer(provider, func(*compactDomainProvider) { close(released) })
}

func TestClosedSessionReleasesRulesWhileBridgeRetainsHandle(t *testing.T) {
	root := bundleFixture(t, "rule-provider", "domains", []byte("+.example.invalid\n"))
	config := `dns:
  enable: true
  enhanced-mode: redir-host
  nameserver: [1.1.1.1]
  nameserver-policy: {'rule-set:domains': 1.1.1.1}
rule-providers:
  domains: {type: http, behavior: domain, format: text, url: 'https://example.invalid/list'}
proxy-groups: [{name: Selected, type: select, proxies: [DIRECT]}]
rules: ['RULE-SET,domains,REJECT','MATCH,Selected']`
	s, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	released := make(chan struct{})
	watchRuleProviderCollection(s, released)
	retainedProxy := s.routing.proxies["Selected"]
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	if retainedProxy.Unwrap(nil, false) != nil {
		t.Fatal("closed group still resolves a proxy")
	}
	deadline := time.After(time.Second)
	for {
		runtime.GC()
		select {
		case <-released:
			if _, err = s.ProxiesJSON(); err == nil {
				t.Fatal("closed session still operates")
			}
			if err = s.Close(); err != nil {
				t.Fatal("repeat close changed result", err)
			}
			runtime.KeepAlive(retainedProxy)
			runtime.KeepAlive(s)
			return
		case <-deadline:
			runtime.KeepAlive(retainedProxy)
			runtime.KeepAlive(s)
			t.Fatal("closed session retains rule provider and DNS policy")
		case <-time.After(10 * time.Millisecond):
		}
	}
}

func completedPreparationHandle(t *testing.T, released chan struct{}) *ResourcePreparation {
	t.Helper()
	root := bundleFixture(t, "rule-provider", "domains", []byte("+.example.invalid\n"))
	config := `rule-providers: {domains: {type: http, behavior: domain, format: text, url: 'https://example.invalid/list'}}
rules: ['MATCH,DIRECT']`
	s, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	p, err := s.NewResourcePreparation(config, "{}", root, "", 1280)
	if err != nil {
		s.Close()
		t.Fatal(err)
	}
	if err = p.Prepare(); err != nil {
		s.Close()
		t.Fatal(err)
	}
	runtime.SetFinalizer(s, func(*Session) { close(released) })
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestCompletedPreparationReleasesSessionAndKeepsResults(t *testing.T) {
	released := make(chan struct{})
	p := completedPreparationHandle(t, released)
	deadline := time.After(time.Second)
	for {
		runtime.GC()
		select {
		case <-released:
			item, err := p.ResourceAt(0)
			if err != nil || p.ResourceCount() != 1 || string(item.Data) != "+.example.invalid\n" {
				t.Fatal("completed result was released with session", err)
			}
			runtime.KeepAlive(p)
			return
		case <-deadline:
			runtime.KeepAlive(p)
			t.Fatal("completed preparation retains closed session")
		case <-time.After(10 * time.Millisecond):
		}
	}
}
