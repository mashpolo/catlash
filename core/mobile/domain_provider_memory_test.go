package mobile

import (
	"fmt"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	RP "github.com/metacubex/mihomo/rules/provider"
	"runtime"
	"strings"
	"testing"
)

func TestDomainTextProviderBuildUsesBoundedAdditionalMemory(t *testing.T) {
	var text strings.Builder
	for i := 0; i < 100000; i++ {
		fmt.Fprintf(&text, "+.host%06d.example.invalid\n", i)
	}
	data := []byte(text.String())
	config, err := parseYAML("rule-providers: {domains: {type: http, behavior: domain, format: text, url: 'https://example.invalid/list'}}\nrules: ['MATCH,DIRECT']")
	if err != nil {
		t.Fatal(err)
	}
	r := &routingConfiguration{resources: map[resourceKey][]byte{{"rule-provider", "domains"}: data}}
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	if err = r.loadRuleProviders(config); err != nil {
		t.Fatal(err)
	}
	runtime.ReadMemStats(&after)
	t.Logf("domain index allocated %d bytes for %d bytes of input", after.TotalAlloc-before.TotalAlloc, len(data))
	if allocated := after.TotalAlloc - before.TotalAlloc; allocated > uint64(len(data))*3 {
		t.Fatalf("domain index allocated %d bytes for %d bytes of input", allocated, len(data))
	}
	if !r.ruleProviders["domains"].Match(&C.Metadata{Host: "sub.host099999.example.invalid"}, C.RuleMatchHelper{}) {
		t.Fatal("large provider lost suffix rule")
	}
}

func TestDomainTextProviderPreservesMihomoMatching(t *testing.T) {
	data := []byte("#comment\n//comment\nEXACT.example\n.suffix.example\n+.both.example\n*.one.example\ninside.*.example\n+.many.*.example\n例子.example\n+.重复.example\nEXACT.example\n")
	native, err := RP.NewMobileRuleProvider("native", P.Domain, P.TextRule, data, nil)
	if err != nil {
		t.Fatal(err)
	}
	config, _ := parseYAML("rule-providers: {domains: {type: http, behavior: domain, format: text, url: 'https://example.invalid/list'}}")
	r := &routingConfiguration{resources: map[resourceKey][]byte{{"rule-provider", "domains"}: data}}
	if err = r.loadRuleProviders(config); err != nil {
		t.Fatal(err)
	}
	compact := r.ruleProviders["domains"]
	for _, host := range []string{"exact.example", "EXACT.EXAMPLE", "sub.exact.example", "suffix.example", "x.suffix.example", "a.b.suffix.example", "both.example", "a.b.both.example", "one.example", "x.one.example", "x.y.one.example", "inside.x.example", "inside.x.y.example", "many.x.example", "a.many.x.example", "例子.example", "x.重复.example", "重复.example", "nomatch.invalid", ""} {
		m := &C.Metadata{Host: host}
		if got, want := compact.Match(m, C.RuleMatchHelper{}), native.Match(m, C.RuleMatchHelper{}); got != want {
			t.Fatalf("host %q: got %t want %t", host, got, want)
		}
	}
	if compact.Count() != native.Count() {
		t.Fatal("provider count changed")
	}
}
