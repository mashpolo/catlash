package mobile

import (
	"fmt"
	C "github.com/metacubex/mihomo/constant"
	"testing"
)

func TestUnsupportedOSRulesSkipEntireLogicalExpression(t *testing.T) {
	config := "sniffer: {enable: true}\nrules:\n - PROCESS-NAME,desktop-app,REJECT\n - PROCESS-PATH,/usr/bin/app,REJECT\n - UID,1000,REJECT\n - NOT,((PROCESS-NAME,desktop-app)),REJECT\n - OR,((DOMAIN,ordinary.invalid),(PROCESS-NAME,desktop-app)),REJECT\n - DOMAIN,blocked.invalid,REJECT\n - MATCH,DIRECT\n"
	session, err := NewYAMLSession(config, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if len(session.routing.rules) != 2 {
		t.Fatalf("kept %d rules, want only supported rules", len(session.routing.rules))
	}
	for _, host := range []string{"ordinary.invalid", "blocked.invalid"} {
		proxy, err := session.route(&C.Metadata{NetWork: C.TCP, Host: host, DstPort: 443})
		if err != nil {
			t.Fatal(err)
		}
		want := "DIRECT"
		if host == "blocked.invalid" {
			want = "REJECT"
		}
		if proxy.Name() != want {
			t.Fatalf("route %s = %s, want %s", host, proxy.Name(), want)
		}
	}
}

func TestClassicalProviderSkipsUnsupportedOSRules(t *testing.T) {
	for _, format := range []string{"yaml", "yaml-rules", "text"} {
		t.Run(format, func(t *testing.T) {
			data := "PROCESS-NAME,desktop-app\nNOT,((PROCESS-NAME,desktop-app))\nDOMAIN,blocked.invalid\n"
			if format == "yaml" {
				data = "payload:\n - PROCESS-NAME,desktop-app\n - NOT,((PROCESS-NAME,desktop-app))\n - DOMAIN,blocked.invalid\n"
			}
			if format == "yaml-rules" {
				data = "rules:\n - PROCESS-NAME,desktop-app\n - NOT,((PROCESS-NAME,desktop-app))\n - DOMAIN,blocked.invalid\n"
				format = "yaml"
			}
			root := bundleFixture(t, "rule-provider", "desktop", []byte(data))
			config := fmt.Sprintf("sniffer: {enable: true}\nrule-providers: {desktop: {type: file, behavior: classical, format: %s, path: unused}}\nrules: ['RULE-SET,desktop,REJECT','MATCH,DIRECT']\n", format)
			session, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
			if err != nil {
				t.Fatal(err)
			}
			defer session.Close()
			if got := session.routing.ruleProviders["desktop"].Count(); got != 1 {
				t.Fatalf("provider kept %d rules, want 1", got)
			}
			for _, host := range []string{"ordinary.invalid", "blocked.invalid"} {
				proxy, err := session.route(&C.Metadata{NetWork: C.TCP, Host: host, DstPort: 443})
				if err != nil {
					t.Fatal(err)
				}
				want := "DIRECT"
				if host == "blocked.invalid" {
					want = "REJECT"
				}
				if proxy.Name() != want {
					t.Fatalf("provider route %s = %s, want %s", host, proxy.Name(), want)
				}
			}
		})
	}
}

func TestUnsupportedOSRuleFilteringStillRejectsInvalidRules(t *testing.T) {
	for _, rule := range []string{"PROCESS-NAEM,app,REJECT", "NOT,((PROCESS-NAME,app),(DOMAIN,example.invalid)),REJECT", "AND,((PROCESS-NAME,app),(DOMAIN-REGEX,[)),REJECT"} {
		session, err := NewYAMLSession("sniffer: {enable: true}\nrules:\n - "+rule+"\n - MATCH,DIRECT\n", "{}", 1280)
		if err == nil {
			session.Close()
			t.Fatalf("accepted malformed rule %q", rule)
		}
	}
}

func TestBuiltinRejectDropKeepsConfiguredRoute(t *testing.T) {
	session, err := NewYAMLSession("rules: ['MATCH,REJECT-DROP']\n", "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	proxy, err := session.route(&C.Metadata{NetWork: C.TCP, DstPort: 443})
	if err != nil {
		t.Fatal(err)
	}
	if proxy.Name() != "REJECT-DROP" || proxy.Type() != C.RejectDrop {
		t.Fatalf("drop route changed to %s (%s)", proxy.Name(), proxy.Type())
	}
}

func TestUnsupportedOSRulesIgnoreUnusedValuesAndTargets(t *testing.T) {
	config := "rules:\n - PROCESS-NAME-REGEX,[,unused-target\n - UID,invalid,unused-target\n - PROCESS-NAME,,unused-target\n - NOT,((PROCESS-NAME-REGEX,[)),unused-target\n - MATCH,DIRECT\n"
	session, err := NewYAMLSession(config, "{}", 1280)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if len(session.routing.rules) != 1 {
		t.Fatal("unused OS rule remained active")
	}
}
