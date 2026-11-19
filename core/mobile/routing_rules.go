package mobile

import (
	"errors"
	"fmt"
	"strings"

	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/rules"
	RC "github.com/metacubex/mihomo/rules/common"
	"github.com/metacubex/mihomo/rules/logic"
	RP "github.com/metacubex/mihomo/rules/provider"
)

type rulePurpose uint8

var errUnsupportedOSRule = errors.New("rule requires unavailable OS process information")

const (
	routingRule rulePurpose = iota
	classicalRule
	dnsRule
)

func (r *routingConfiguration) buildRules(config *yamlConfiguration) error {
	r.subRules = make(map[string][]C.Rule, len(config.SubRules))
	for name := range config.SubRules {
		if name == "" {
			return errors.New("sub-rules name must not be empty")
		}
		r.subRules[name] = nil
	}
	for name, values := range config.SubRules {
		for index, value := range values {
			rule, err := r.parseRule(value)
			if errors.Is(err, errUnsupportedOSRule) || r.deferMissingResource(err) {
				r.skipDisplayRule(name, index)
				continue
			}
			if err != nil {
				return fmt.Errorf("sub-rules.%s[%d]: %w", name, index, err)
			}
			r.subRules[name] = append(r.subRules[name], rule)
		}
	}
	visited := map[string]uint8{}
	heights := map[string]int{}
	var visit func(string, int) error
	visit = func(name string, depth int) error {
		if visited[name] == 1 {
			return errors.New("sub-rules reference cycle")
		}
		if visited[name] == 2 {
			return nil
		}
		if depth > 64 {
			return errors.New("sub-rules nesting exceeds 64")
		}
		visited[name] = 1
		for _, rule := range r.subRules[name] {
			if rule.RuleType() == C.SubRules {
				if err := visit(rule.Adapter(), depth+1); err != nil {
					return err
				}
				heights[name] = max(heights[name], heights[rule.Adapter()]+1)
				if heights[name] > 64 {
					return errors.New("sub-rules nesting exceeds 64")
				}
			}
		}
		visited[name] = 2
		return nil
	}
	for name := range r.subRules {
		if err := visit(name, 0); err != nil {
			return err
		}
	}
	for index, value := range config.Rules {
		rule, err := r.parseRule(value)
		if errors.Is(err, errUnsupportedOSRule) || r.deferMissingResource(err) {
			r.skipDisplayRule("", index)
			continue
		}
		if err != nil {
			return fmt.Errorf("rules[%d]: %w", index, err)
		}
		r.rules = append(r.rules, rule)
	}
	return nil
}

func (r *routingConfiguration) parseRule(value string) (C.Rule, error) {
	kind, payload, target, params := RC.ParseRulePayload(value, true)
	if kind == "MATCH" && strings.Count(value, ",") != 1 {
		return nil, errors.New("MATCH requires one target")
	}
	if kind == "SUB-RULE" {
		if _, ok := r.subRules[target]; !ok {
			return nil, errors.New("unknown sub-rule target")
		}
		if err := validateLogicalPayload(payload); err != nil {
			return nil, err
		}
		return logic.NewSubRule(payload, target, r.subRules, r.conditionParser(routingRule, 0))
	}
	rule, err := r.parseCondition(kind, payload, target, params, routingRule, 0)
	if err != nil {
		return nil, err
	}
	if _, ok := r.proxies[target]; !ok {
		return nil, errors.New("unknown rule target")
	}
	r.requireNode(target)
	return rule, nil
}

func (r *routingConfiguration) conditionParser(purpose rulePurpose, depth int) RC.ParseRuleFunc {
	return func(kind, payload, target string, params []string, _ map[string][]C.Rule) (C.Rule, error) {
		return r.parseCondition(kind, payload, target, params, purpose, depth+1)
	}
}

func (r *routingConfiguration) parseCondition(kind, payload, target string, params []string, purpose rulePurpose, depth int) (C.Rule, error) {
	if depth > 64 {
		return nil, errors.New("logical rule nesting exceeds 64")
	}
	switch kind {
	case "PROCESS-NAME", "PROCESS-PATH", "PROCESS-NAME-REGEX", "PROCESS-PATH-REGEX", "PROCESS-NAME-WILDCARD", "PROCESS-PATH-WILDCARD", "UID":
		return nil, errUnsupportedOSRule
	}
	if kind != "MATCH" && payload == "" {
		return nil, errors.New("rule requires a payload")
	}
	if purpose == classicalRule && (kind == "MATCH" || kind == "RULE-SET" || kind == "SUB-RULE") {
		return nil, errors.New("unsupported classical provider rule type")
	}
	if purpose == dnsRule {
		switch kind {
		case "AND", "OR", "NOT", "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "DOMAIN-WILDCARD", "GEOSITE", "RULE-SET", "MATCH":
		default:
			return nil, errors.New("DNS fake-IP rules require domain predicates")
		}
	}
	switch kind {
	case "AND", "OR", "NOT":
		if len(params) != 0 {
			return nil, errors.New("logical rule does not accept parameters")
		}
		if err := validateLogicalPayload(payload); err != nil {
			return nil, err
		}
		ignored := false
		var pendingError error
		parse := func(kind, payload, target string, params []string, _ map[string][]C.Rule) (C.Rule, error) {
			rule, err := r.parseCondition(kind, payload, target, params, purpose, depth+1)
			if errors.Is(err, errUnsupportedOSRule) {
				ignored = true
				return RC.NewMatch(target), nil
			}
			if r.allowDeferredResources && isMissingResource(err) {
				pendingError = err
				return RC.NewMatch(target), nil
			}
			return rule, err
		}
		var rule C.Rule
		var err error
		switch kind {
		case "AND":
			rule, err = logic.NewAND(payload, target, parse)
		case "OR":
			rule, err = logic.NewOR(payload, target, parse)
		default:
			rule, err = logic.NewNOT(payload, target, parse)
		}
		if err == nil && ignored {
			return nil, errUnsupportedOSRule
		}
		if err == nil && pendingError != nil {
			return nil, pendingError
		}
		return rule, err
	case "GEOIP", "SRC-GEOIP", "IP-ASN", "SRC-IP-ASN", "GEOSITE":
		if kind == "GEOSITE" && !r.domainRulesEnabled {
			return nil, errors.New("GEOSITE rules require enabled DNS mapping, fake-IP or sniffer")
		}
		return r.geo.parseRule(kind, payload, target, params)
	case "RULE-SET":
		provider, ok := r.ruleProviders[payload]
		if !ok {
			if r.deferredProviders[payload] {
				return nil, &missingProviderResource{kind: "rule-provider", name: payload}
			}
			return nil, errors.New("unknown rule provider")
		}
		if purpose == dnsRule && provider.Behavior() == P.IPCIDR {
			return nil, errors.New("DNS fake-IP rule provider must contain domain rules")
		}
		if provider.Behavior() == P.Domain && !r.domainRulesEnabled {
			return nil, errors.New("domain rule providers require enabled DNS mapping, fake-IP or sniffer")
		}
		source, noResolve := false, false
		for _, parameter := range params {
			switch parameter {
			case "src":
				source = true
			case "no-resolve":
				noResolve = true
			default:
				return nil, errors.New("unsupported RULE-SET parameter")
			}
		}
		return RP.NewMobileRuleSet(payload, target, source, noResolve, provider)
	case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "DOMAIN-WILDCARD":
		if !r.domainRulesEnabled {
			return nil, errors.New("DOMAIN rules require enabled DNS mapping, fake-IP or sniffer")
		}
	case "MATCH", "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR", "IP-SUFFIX", "SRC-IP-SUFFIX", "SRC-PORT", "DST-PORT", "NETWORK":
	default:
		return nil, errors.New("unsupported rule type")
	}
	for _, parameter := range params {
		if (kind != "IP-CIDR" && kind != "IP-CIDR6" && kind != "IP-SUFFIX") || (parameter != "no-resolve" && parameter != "src") {
			return nil, errors.New("unsupported rule parameter")
		}
	}
	parsed, err := rules.ParseRule(kind, payload, target, params, nil)
	if err != nil {
		return nil, errors.New("invalid rule payload")
	}
	return parsed, nil
}

func validateLogicalPayload(payload string) error {
	depth, count := 0, 0
	for _, character := range payload {
		switch character {
		case '(':
			depth++
			count++
			if depth > 64 || count > 1024 {
				return errors.New("logical rule exceeds nesting or predicate limit")
			}
		case ')':
			depth--
			if depth < 0 {
				return errors.New("invalid logical rule parentheses")
			}
		}
	}
	if depth != 0 {
		return errors.New("invalid logical rule parentheses")
	}
	return nil
}

func (r *routingConfiguration) NewGeoIP(country, target string, source, noResolve bool) (*RC.GEOIP, error) {
	return r.geo.NewGeoIP(country, target, source, noResolve)
}
func (r *routingConfiguration) NewGeoSite(country, target string) (*RC.GEOSITE, error) {
	return r.geo.NewGeoSite(country, target)
}
func (r *routingConfiguration) ParseDNSRule(kind, payload, target string, params []string) (C.Rule, error) {
	return r.parseCondition(kind, payload, target, params, dnsRule, 0)
}
