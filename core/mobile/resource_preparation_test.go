package mobile

import (
	"context"
	"errors"
	"fmt"
	D "github.com/miekg/dns"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestResourcePreparationRestoresSelectionAndNeverFallsBackToDirect(t *testing.T) {
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if !strings.Contains(r.UserAgent(), "Clash") {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		fmt.Fprint(w, "payload:\n - example.invalid\n")
	}))
	defer server.Close()
	config := fmt.Sprintf(`proxy-groups: [{name: download, type: select, proxies: [REJECT, DIRECT]}]
rule-providers: {domains: {type: http, behavior: domain, proxy: download, url: '%s'}}
rules: ['MATCH,DIRECT']
`, server.URL)
	rejected, err := NewYAMLResourcePreparation(config, `{}`, "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err := rejected.Prepare(); err == nil {
		t.Fatal("REJECT selection downloaded via DIRECT")
	}
	if calls != 0 {
		t.Fatal("unexpected direct request")
	}
	allowed, err := NewYAMLResourcePreparation(config, `{"download":"DIRECT"}`, "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err := allowed.Prepare(); err != nil {
		t.Fatal(err)
	}
	if allowed.ResourceCount() != 1 || calls != 1 {
		t.Fatalf("resources=%d requests=%d", allowed.ResourceCount(), calls)
	}
	item, err := allowed.ResourceAt(0)
	if err != nil || item.Kind != "rule-provider" || item.Name != "domains" || !strings.Contains(string(item.Data), "example.invalid") {
		t.Fatalf("%v %v", item, err)
	}
	disabled, err := NewYAMLResourcePreparation("profile: {store-selected: false}\n"+config, `{"download":"DIRECT"}`, "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err := disabled.Prepare(); err != nil {
		t.Fatalf("store-selected=false rejected an explicit download selection: %v", err)
	}
	if calls != 2 {
		t.Fatal("explicit selection did not download through the requested route")
	}
	session, err := NewSession(1280)
	if err != nil {
		t.Fatalf("bootstrap owner was not closed: %v", err)
	}
	session.Close()
}

func TestResourcePreparationCancellationClosesBootstrapBeforeReturning(t *testing.T) {
	entered := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(entered); <-r.Context().Done() }))
	defer server.Close()
	config := fmt.Sprintf("rule-providers: {domains: {type: http, behavior: domain, proxy: DIRECT, url: '%s'}}\nrules: ['MATCH,DIRECT']\n", server.URL)
	preparation, err := NewYAMLResourcePreparation(config, `{}`, "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- preparation.Prepare() }()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("download did not start")
	}
	preparation.Cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("cancel: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancel did not finish")
	}
	session, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	session.Close()
}

func TestResourcePreparationDownloadsGeodataDiscoveredInClassicalProvider(t *testing.T) {
	geo := geoIPFixture(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/geo" {
			w.Write(geo)
			return
		}
		fmt.Fprint(w, "payload:\n - GEOIP,TEST,no-resolve\n")
	}))
	defer server.Close()
	config := fmt.Sprintf("geodata-mode: true\ngeox-url: {geoip: '%s/geo'}\nrule-providers: {rules: {type: http, behavior: classical, proxy: DIRECT, url: '%s/rules'}}\nrules: ['RULE-SET,rules,REJECT','MATCH,DIRECT']\n", server.URL, server.URL)
	preparation, err := NewYAMLResourcePreparation(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err := preparation.Prepare(); err != nil {
		t.Fatal(err)
	}
	if preparation.ResourceCount() != 2 {
		t.Fatalf("resources=%d", preparation.ResourceCount())
	}
	first, err := preparation.ResourceAt(0)
	if err != nil || first.Kind != "geoip-dat" || string(first.Data) != string(geo) {
		t.Fatal("discovered geodata missing")
	}
}

func TestResourcePreparationRejectsUnavailableProxyProviderDependency(t *testing.T) {
	config := `proxy-providers: {nodes: {type: http, proxy: MAIN, url: 'https://never.invalid/nodes'}}
proxy-groups: [{name: MAIN, type: select, use: [nodes]}]
rules: ['MATCH,DIRECT']`
	preparation, err := NewYAMLResourcePreparation(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	err = preparation.Prepare()
	if err == nil || !strings.Contains(err.Error(), "dependency") {
		t.Fatalf("missing dependency error: %v", err)
	}
	session, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	session.Close()
}

func TestResourcePreparationUsesCachedBundleWithoutStartingAnotherSession(t *testing.T) {
	root := bundleFixture(t, "rule-provider", "rules", []byte("payload: ['10.0.0.0/8']\n"))
	config := `rule-providers: {rules: {type: http, behavior: ipcidr, proxy: MAIN, url: 'https://never.invalid/rules'}}
rules: ['MATCH,DIRECT']`
	session, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	preparation, err := NewYAMLResourcePreparation(config, "{}", root, "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err := preparation.Prepare(); err != nil {
		t.Fatal(err)
	}
	if preparation.ResourceCount() != 1 {
		t.Fatal("cached resource lost")
	}
}

func TestResourcePreparationUsesConfiguredBootstrapDNS(t *testing.T) {
	socket, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var queries atomic.Int32
	resolver := &D.Server{PacketConn: socket, Handler: D.HandlerFunc(func(w D.ResponseWriter, request *D.Msg) {
		queries.Add(1)
		response := new(D.Msg)
		response.SetReply(request)
		if len(request.Question) > 0 && request.Question[0].Qtype == D.TypeA {
			response.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: request.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60}, A: net.ParseIP("127.0.0.1")}}
		}
		w.WriteMsg(response)
	})}
	go resolver.ActivateAndServe()
	defer resolver.Shutdown()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "payload:\n - 10.0.0.0/8\n") }))
	defer server.Close()
	address := strings.Replace(server.URL, "127.0.0.1", "download.invalid", 1)
	config := fmt.Sprintf("dns: {enable: true, nameserver: ['%s'], proxy-server-nameserver: ['%s']}\nrule-providers: {rules: {type: http, behavior: ipcidr, proxy: DIRECT, url: '%s'}}\nrules: ['MATCH,DIRECT']", socket.LocalAddr(), socket.LocalAddr(), address)
	preparation, err := NewYAMLResourcePreparation(config, "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	if err := preparation.Prepare(); err != nil {
		t.Fatal(err)
	}
	if queries.Load() == 0 {
		t.Fatal("configured bootstrap DNS was bypassed")
	}
}

func TestResourceDownloadReportsSafeTransportFailures(t *testing.T) {
	for _, scenario := range []string{"closed", "timeout", "cancelled"} {
		t.Run(scenario, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if scenario == "closed" {
					conn, _, err := w.(http.Hijacker).Hijack()
					if err == nil {
						conn.Close()
					}
					return
				}
				<-r.Context().Done()
			}))
			defer server.Close()
			session, err := NewYAMLSession("mode: direct", "{}", 1280)
			if err != nil {
				t.Fatal(err)
			}
			defer session.Close()
			preparation, err := NewYAMLResourcePreparation("mode: direct", "{}", "", "", 1280)
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(preparation.ctx, 50*time.Millisecond)
			defer cancel()
			preparation.ctx = ctx
			if scenario == "cancelled" {
				cancel()
			}
			_, err = preparation.downloadWithRoute(session, map[string]any{"url": server.URL + "/private?token=must-not-appear"}, false)
			wanted := map[string]string{"closed": "resource proxy connection closed", "timeout": "resource HTTP request timed out", "cancelled": "resource HTTP request cancelled"}[scenario]
			if err == nil || err.Error() != wanted {
				t.Fatalf("got %v, want %s", err, wanted)
			}
		})
	}
}
