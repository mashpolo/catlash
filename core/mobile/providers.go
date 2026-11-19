package mobile

import (
	"errors"
	"fmt"
	"io"
	"strings"

	AP "github.com/metacubex/mihomo/adapter/provider"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	RC "github.com/metacubex/mihomo/rules/common"
	RP "github.com/metacubex/mihomo/rules/provider"
	"go.yaml.in/yaml/v3"
)

func validateProxyMapping(mapping map[string]any, path string) error {
	kind, ok := mapping["type"].(string)
	if !ok || proxyOptionType(kind) == nil {
		return fmt.Errorf("%s.type is unsupported", path)
	}
	if err := validateProxyFields(mapping, proxyOptionType(kind), path, true); err != nil {
		return err
	}
	if err := validateInlineResources(mapping, kind, path, false); err != nil {
		return err
	}
	name, ok := mapping["name"].(string)
	if !ok || name == "" {
		return fmt.Errorf("%s.name must be nonempty", path)
	}
	return nil
}
func providerSource(data []byte) error {
	var document yaml.Node
	decoder := yaml.NewDecoder(strings.NewReader(string(data)))
	if err := decoder.Decode(&document); err != nil {
		return errors.New("invalid provider YAML")
	}
	if len(document.Content) != 1 || document.Content[0].Kind != yaml.MappingNode {
		return nil
	}
	root, err := normalizeYAMLNode(document.Content[0], "provider")
	if err != nil {
		return err
	}
	for i := 0; i < len(root.Content); i += 2 {
		if root.Content[i].Value == "proxies" {
			warnings := []string{}
			filterYAMLProxies(root.Content[i+1], "provider.proxies", &warnings)
			if err := rejectNullListItems(root.Content[i+1], "provider.proxies"); err != nil {
				return err
			}
		}
	}
	if decoder.Decode(new(yaml.Node)) != io.EOF {
		return errors.New("provider must contain one document")
	}
	return nil
}
func checkKeys(mapping map[string]any, path string, keys string) error {
	allowed := map[string]bool{}
	for _, key := range strings.Fields(keys) {
		allowed[key] = true
	}
	for key := range mapping {
		if !allowed[key] {
			delete(mapping, key)
		}
	}
	return nil
}
func validateProviderConfiguration(config *yamlConfiguration) error {
	for name, mapping := range config.ProxyProviders {
		path := "proxy-providers." + name
		if err := checkKeys(mapping, path, "type path url proxy interval filter exclude-filter exclude-type dialer-proxy size-limit payload age-secret-key health-check override header"); err != nil {
			return err
		}
		if hc, ok := mapping["health-check"].(map[string]any); ok {
			if err := checkKeys(hc, path+".health-check", "enable url interval timeout lazy expected-status"); err != nil {
				return err
			}
		}
		if override, ok := mapping["override"].(map[string]any); ok {
			if err := checkKeys(override, path+".override", "tfo mptcp udp udp-over-tcp up down dialer-proxy skip-cert-verify name-cert-verify ip-version additional-prefix additional-suffix proxy-name override-expr"); err != nil {
				return err
			}
		}
		if err := validateProviderSource(mapping, path); err != nil {
			return err
		}
	}
	for name, mapping := range config.RuleProviders {
		path := "rule-providers." + name
		if err := checkKeys(mapping, path, "type behavior format path url proxy interval size-limit payload header"); err != nil {
			return err
		}
		if err := validateProviderSource(mapping, path); err != nil {
			return err
		}
	}
	return nil
}
func validateProviderSource(mapping map[string]any, path string) error {
	switch mapping["type"] {
	case "inline", "http", "file":
	default:
		return fmt.Errorf("%s.type must be inline, http or file", path)
	}
	if proxy, exists := mapping["proxy"]; exists {
		if _, ok := proxy.(string); !ok {
			return fmt.Errorf("%s.proxy must be a string", path)
		}
	}
	return nil
}
func (r *routingConfiguration) providerBytes(kind, name string, mapping map[string]any) ([]byte, error) {
	if mapping["type"] == "inline" {
		key := "payload"
		if kind == "proxy-provider" {
			key = "proxies"
		}
		if _, ok := mapping["payload"]; !ok {
			return nil, fmt.Errorf("%s %s requires payload", kind, name)
		}
		return yaml.Marshal(map[string]any{key: mapping["payload"]})
	}
	data, ok := r.resources[resourceKey{kind, name}]
	if !ok {
		return nil, &missingProviderResource{kind: kind, name: name}
	}
	if limit, ok := mapping["size-limit"]; ok {
		value, ok := limit.(int)
		if !ok || value < 0 {
			return nil, fmt.Errorf("%s %s has invalid size-limit", kind, name)
		}
		if value > 0 && len(data) > value {
			return nil, fmt.Errorf("%s %s exceeds its size-limit", kind, name)
		}
	}
	return data, nil
}
func (r *routingConfiguration) loadProxyProviders(config *yamlConfiguration) error {
	r.proxyProviders = map[string]P.ProxyProvider{}
	r.ruleProviders = map[string]P.RuleProvider{}
	for name, mapping := range config.ProxyProviders {
		data, err := r.providerBytes("proxy-provider", name, mapping)
		if err != nil {
			return err
		}
		definitions, err := r.parseProxyProvider(name, mapping, data, r)
		if err != nil {
			return err
		}
		config.Proxies = append(config.Proxies, definitions...)
	}
	return nil
}
func (r *routingConfiguration) parseProxyProvider(name string, mapping map[string]any, data []byte, live *routingConfiguration) ([]map[string]any, error) {
	if r.providerOwned == nil {
		r.providerOwned = make(map[string][]io.Closer)
	}
	definitions := []map[string]any{}
	hooks := AP.MobileProxyHooks{Context: r.session.ctx, StateDirectory: func(mapping map[string]any) (string, error) { return r.identityDirectory(mapping, name) }, ValidateSource: providerSource, ValidateProxy: func(proxy map[string]any) error {
		kind, _ := proxy["type"].(string)
		typ := proxyOptionType(kind)
		if typ == nil {
			return errors.New("proxy-provider node type is unsupported")
		}
		if err := validateProxyFields(proxy, typ, "proxy-providers."+name+".proxies", true); err != nil {
			return err
		}
		if err := r.hydrateProxyFiles(proxy, "proxy-providers."+name+".proxies"); err != nil {
			return err
		}
		if err := validateProxyMapping(proxy, "proxy-providers."+name+".proxies"); err != nil {
			return err
		}
		definitions = append(definitions, proxy)
		return nil
	}}
	provider, err := AP.NewMobileProxyProvider(name, mapping, data, &sessionTunnel{routing: live}, hooks)
	if err != nil {
		return nil, fmt.Errorf("proxy-provider %s has invalid content or options", name)
	}
	rawProvider := provider
	provider, err = r.configureHealth(provider, mapping["health-check"])
	if err != nil {
		if closer, ok := rawProvider.(io.Closer); ok {
			_ = closer.Close()
		}
		for _, proxy := range rawProvider.Proxies() {
			_ = proxy.Close()
		}
		return nil, fmt.Errorf("proxy-provider %s: %w", name, err)
	}
	r.proxyProviders[name] = provider
	if closer, ok := rawProvider.(io.Closer); ok {
		r.providerOwned[name] = append(r.providerOwned[name], closer)
	}
	for _, proxy := range provider.Proxies() {
		r.providerOwned[name] = append(r.providerOwned[name], proxy)
		r.proxies[proxy.Name()] = proxy
	}
	return definitions, nil
}
func (r *routingConfiguration) loadRuleProviders(config *yamlConfiguration) error {
	r.ruleProviders = map[string]P.RuleProvider{}
	r.deferredProviders = map[string]bool{}
	if err := r.loadMissingRuleProviders(config); err != nil {
		return err
	}
	for name, rule := range r.ruleProviders {
		if config.RuleProviders[name]["type"] == "http" {
			live := &liveRuleProvider{}
			live.current.Store(&rule)
			r.ruleProviders[name] = live
		}
	}
	return nil
}

func (r *routingConfiguration) loadMissingRuleProviders(config *yamlConfiguration) error {
	for name, mapping := range config.RuleProviders {
		if r.ruleProviders[name] != nil {
			continue
		}
		data, err := r.providerBytes("rule-provider", name, mapping)
		if err != nil {
			if r.deferProviderResource(name, err) {
				continue
			}
			return err
		}
		behavior, _ := mapping["behavior"].(string)
		b, err := P.ParseBehavior(behavior)
		if err != nil {
			return fmt.Errorf("rule-provider %s has invalid behavior", name)
		}
		format, _ := mapping["format"].(string)
		if mapping["type"] == "inline" {
			format = "yaml"
		}
		f, err := P.ParseRuleFormat(format)
		if err != nil {
			return fmt.Errorf("rule-provider %s has invalid format", name)
		}
		if f == P.YamlRule {
			if err := providerSource(data); err != nil {
				return fmt.Errorf("rule-provider %s has invalid YAML", name)
			}
		}
		if b == P.Classical && f != P.MrsRule {
			data, err = r.filterUnsupportedProviderRules(data, f)
			if err != nil {
				if r.deferProviderResource(name, err) {
					continue
				}
				return fmt.Errorf("rule-provider %s: %w", name, err)
			}
		}
		if b == P.Domain && f == P.TextRule {
			provider, err := newCompactDomainProvider(name, data)
			if err != nil {
				return fmt.Errorf("rule-provider %s has invalid content", name)
			}
			r.ruleProviders[name] = provider
			continue
		}
		var ruleError error
		parse := func(kind, payload, target string, params []string, sub map[string][]C.Rule) (C.Rule, error) {
			rule, err := r.parseProviderRule(kind, payload, target, params, sub)
			if err != nil {
				ruleError = err
			}
			return rule, err
		}
		provider, err := RP.NewMobileRuleProvider(name, b, f, data, parse)
		if err != nil {
			if ruleError != nil {
				if r.deferProviderResource(name, ruleError) {
					continue
				}
				return fmt.Errorf("rule-provider %s: %w", name, ruleError)
			}
			return fmt.Errorf("rule-provider %s has invalid content", name)
		}
		r.ruleProviders[name] = provider
	}
	return nil
}
func (r *routingConfiguration) parseProviderRule(kind, payload, target string, params []string, _ map[string][]C.Rule) (C.Rule, error) {
	return r.parseCondition(kind, payload, target, params, classicalRule, 0)
}

func (r *routingConfiguration) filterUnsupportedProviderRules(data []byte, format P.RuleFormat) ([]byte, error) {
	var payload struct {
		Rules       []string `yaml:"payload"`
		Alternative []string `yaml:"rules,omitempty"`
	}
	if format == P.YamlRule {
		if err := yaml.Unmarshal(data, &payload); err != nil {
			return nil, errors.New("invalid classical provider YAML")
		}
		if len(payload.Rules) == 0 {
			payload.Rules = payload.Alternative
		}
		payload.Alternative = nil
	} else {
		payload.Rules = strings.Split(string(data), "\n")
	}
	kept := payload.Rules[:0]
	for _, value := range payload.Rules {
		value = strings.TrimSpace(value)
		if value == "" || strings.HasPrefix(value, "#") || strings.HasPrefix(value, "//") {
			continue
		}
		kind, condition, target, params := RC.ParseRulePayload(value, false)
		_, err := r.parseProviderRule(kind, condition, target, params, nil)
		if errors.Is(err, errUnsupportedOSRule) {
			continue
		}
		if err != nil {
			return nil, err
		}
		kept = append(kept, value)
	}
	payload.Rules = kept
	if format == P.YamlRule {
		return yaml.Marshal(payload)
	}
	return []byte(strings.Join(kept, "\n") + "\n"), nil
}
