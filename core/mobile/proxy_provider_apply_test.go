package mobile

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestApplyDownloadsRemoteProxyProvidersAndReusesData(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if r.Header.Get("User-Agent") != "provider-test" {
			t.Error("provider header lost")
		}
		fmt.Fprint(w, "proxies: [{name: downloaded, type: direct}]")
	}))
	defer server.Close()
	value := fmt.Sprintf(`proxy-providers:
  remote: {type: http, url: %q, proxy: DIRECT, header: {User-Agent: [provider-test]}}
proxy-groups: [{name: Selected, type: select, use: [remote]}]
rules: ['MATCH,Selected']`, server.URL)
	s, err := NewYAMLSessionWithDeferredResources(value, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if requests.Load() != 1 {
		t.Fatal("provider was not loaded during apply")
	}
	statuses, err := s.ProxiesJSON()
	if err != nil || !strings.Contains(statuses, "downloaded") {
		t.Fatal("downloaded node unavailable", err)
	}
	p, err := s.NewResourcePreparation(value, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err = p.Prepare(); err != nil {
		t.Fatal(err)
	}
	if requests.Load() != 1 || p.ResourceCount() != 1 {
		t.Fatal("active provider was not reused")
	}
}

func TestApplyRemoteProxyProviderHonorsDependencyAndNoDirectFallback(t *testing.T) {
	for _, proxy := range []string{"Ready", "Blocked"} {
		t.Run(proxy, func(t *testing.T) {
			var requests atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests.Add(1)
				fmt.Fprint(w, "proxies: [{name: downloaded, type: direct}]")
			}))
			defer server.Close()
			value := fmt.Sprintf(`proxy-providers:
  remote: {type: http, url: %q, proxy: %s}
proxy-groups:
- {name: Ready, type: select, proxies: [DIRECT]}
- {name: Blocked, type: select, proxies: [REJECT]}
- {name: Selected, type: select, use: [remote]}
rules: ['MATCH,Selected']`, server.URL, proxy)
			s, err := NewYAMLSessionWithDeferredResources(value, "{}", "", "", 1280)
			if proxy == "Blocked" {
				if s != nil {
					s.Close()
				}
				if err == nil || requests.Load() != 0 {
					t.Fatal("failed download proxy fell back to DIRECT")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			s.Close()
			if requests.Load() != 1 {
				t.Fatal("ready group not used")
			}
		})
	}
}

func TestApplyRemoteProxyProviderDependencyOrderAndCycle(t *testing.T) {
	for _, cycle := range []bool{false, true} {
		t.Run(fmt.Sprint(cycle), func(t *testing.T) {
			var requests atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requests.Add(1)
				fmt.Fprintf(w, "proxies: [{name: node%s, type: direct}]", r.URL.Path[1:])
			}))
			defer server.Close()
			firstProxy := "DIRECT"
			if cycle {
				firstProxy = "Final"
			}
			value := fmt.Sprintf(`proxy-providers:
  a-dependent: {type: http, url: %q, proxy: Bootstrap}
  z-bootstrap: {type: http, url: %q, proxy: %s}
proxy-groups:
- {name: Bootstrap, type: select, use: [z-bootstrap]}
- {name: Final, type: select, use: [a-dependent]}
rules: ['MATCH,Final']`, server.URL+"/dependent", server.URL+"/bootstrap", firstProxy)
			s, err := NewYAMLSessionWithDeferredResources(value, "{}", "", "", 1280)
			if cycle {
				if s != nil {
					s.Close()
				}
				if err == nil || requests.Load() != 0 {
					t.Fatal("circular dependency fetched directly")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			s.Close()
			if requests.Load() != 2 {
				t.Fatal("dependency downloads missing")
			}
		})
	}
}
