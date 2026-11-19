package mobile

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

type runtimeInspection struct {
	resourceBytes int
	resourceRoot  string
	sourceHash    [32]byte
	skipped       map[string]map[int]bool
	deferredDNS   *yaml.Node
	providers     []runtimeProvider
}

func (r *routingConfiguration) skipDisplayRule(group string, index int) {
	if r.inspection.skipped == nil {
		r.inspection.skipped = make(map[string]map[int]bool)
	}
	if r.inspection.skipped[group] == nil {
		r.inspection.skipped[group] = make(map[int]bool)
	}
	r.inspection.skipped[group][index] = true
}

func (s *Session) ProvidersJSON() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.routing == nil {
		return "", errors.New("YAML session unavailable")
	}
	data, err := json.Marshal(s.routing.inspection.providers)
	return string(data), err
}

// WriteEffectiveConfiguration writes a redacted view of the same validated input used by this session.
// Rendering runs on demand, without holding packet processing locks or retaining a second YAML tree.
func (s *Session) WriteEffectiveConfiguration(value, path string) error {
	s.mu.Lock()
	if s.closed || s.routing == nil {
		s.mu.Unlock()
		return errors.New("YAML session unavailable")
	}
	r := s.routing
	if sha256.Sum256([]byte(value)) != r.inspection.sourceHash {
		s.mu.Unlock()
		return errors.New("configuration changed")
	}
	r.mu.Lock()
	mode := r.mode
	selected := map[string]string{}
	for name, group := range r.groups {
		if group.Type().String() == "Selector" {
			selected[name] = group.Now()
		}
	}
	r.mu.Unlock()
	view := r.inspection
	s.mu.Unlock()
	var doc yaml.Node
	if err := yaml.NewDecoder(strings.NewReader(value)).Decode(&doc); err != nil {
		return errors.New("invalid YAML")
	}
	node, err := normalizeYAMLNode(doc.Content[0], "")
	if err != nil {
		return err
	}
	filterIOSYAML(node)
	stripYAMLComments(node)
	putViewValue(node, "mode", mode)
	if rules := viewField(node, "rules"); rules != nil {
		omitRules(rules, view.skipped[""])
	}
	if subs := viewField(node, "sub-rules"); subs != nil {
		for i := 0; i < len(subs.Content); i += 2 {
			omitRules(subs.Content[i+1], view.skipped[subs.Content[i].Value])
		}
	}
	if dns := viewField(node, "dns"); dns != nil {
		for i := 0; i < len(dns.Content); i += 2 {
			key := dns.Content[i].Value
			switch key {
			case "nameserver-policy", "proxy-server-nameserver-policy", "fake-ip-filter", "fallback-filter":
				if effective := viewField(view.deferredDNS, key); effective != nil {
					dns.Content[i+1] = cloneViewNode(effective)
				}
			}
			switch key {
			case "nameserver", "default-nameserver", "direct-nameserver", "proxy-server-nameserver", "fallback", "nameserver-policy", "proxy-server-nameserver-policy":
				redactAddresses(dns.Content[i+1])
			}
		}
	}
	if groups := viewField(node, "proxy-groups"); groups != nil {
		for _, group := range groups.Content {
			name := viewField(group, "name")
			if name != nil {
				if current, ok := selected[name.Value]; ok {
					putViewValue(group, "default-selected", current)
				}
			}
			redactAddresses(viewField(group, "url"))
		}
	}
	if proxies := viewField(node, "proxies"); proxies != nil {
		for _, proxy := range proxies.Content {
			maskProxyFields(proxy)
		}
	}
	for _, section := range []string{"proxy-providers", "rule-providers"} {
		mappings := viewField(node, section)
		if mappings == nil {
			continue
		}
		for i := 1; i < len(mappings.Content); i += 2 {
			mapping := mappings.Content[i]
			for _, key := range []string{"path", "header", "payload", "override", "url", "age-secret-key"} {
				if val := viewField(mapping, key); val != nil {
					maskViewNode(val)
				}
			}
			if health := viewField(mapping, "health-check"); health != nil {
				redactAddresses(viewField(health, "url"))
			}
		}
	}
	redactAddresses(viewField(node, "geox-url"))
	if agent := viewField(node, "global-ua"); agent != nil {
		maskViewNode(agent)
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	enc := yaml.NewEncoder(f)
	enc.SetIndent(2)
	err = enc.Encode(node)
	err = errors.Join(err, enc.Close(), f.Close())
	if err != nil {
		_ = os.Remove(path)
	}
	return err
}
func viewField(mapping *yaml.Node, key string) *yaml.Node {
	if mapping != nil && mapping.Kind == yaml.MappingNode {
		for i := 0; i < len(mapping.Content); i += 2 {
			if mapping.Content[i].Value == key {
				return mapping.Content[i+1]
			}
		}
	}
	return nil
}
func putViewValue(mapping *yaml.Node, key, value string) {
	node := &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: value}
	if existing := viewField(mapping, key); existing != nil {
		*existing = *node
		return
	}
	mapping.Content = append(mapping.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, node)
}
func stripYAMLComments(node *yaml.Node) {
	node.HeadComment = ""
	node.LineComment = ""
	node.FootComment = ""
	node.Anchor = ""
	for _, child := range node.Content {
		stripYAMLComments(child)
	}
}
func cloneViewNode(node *yaml.Node) *yaml.Node {
	copy := *node
	copy.Content = make([]*yaml.Node, len(node.Content))
	for i, child := range node.Content {
		copy.Content[i] = cloneViewNode(child)
	}
	return &copy
}
func omitRules(node *yaml.Node, skipped map[int]bool) {
	if len(skipped) == 0 {
		return
	}
	list := node.Content[:0]
	for index, child := range node.Content {
		if !skipped[index] {
			list = append(list, child)
		}
	}
	node.Content = list
}
func maskViewNode(node *yaml.Node) {
	*node = yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: "***"}
}

// Outbound adapters have independent credential and transport schemas. Preserve common
// protocol and transport options while masking connection details of unrecognized fields.
func maskProxyFields(mapping *yaml.Node) {
	for i := 0; i < len(mapping.Content); i += 2 {
		key := mapping.Content[i].Value
		value := mapping.Content[i+1]
		switch key {
		case "name", "type", "port", "udp", "tls", "network", "cipher", "tfo", "mptcp", "skip-cert-verify", "alpn", "ip-version", "packet-encoding", "client-fingerprint", "flow", "udp-over-tcp", "udp-over-stream":
		default:
			maskViewNode(value)
		}
	}
}
func redactAddresses(node *yaml.Node) {
	if node == nil {
		return
	}
	switch node.Kind {
	case yaml.MappingNode:
		for i := 1; i < len(node.Content); i += 2 {
			redactAddresses(node.Content[i])
		}
	case yaml.SequenceNode:
		for _, child := range node.Content {
			redactAddresses(child)
		}
	case yaml.ScalarNode:
		v := node.Value
		if !strings.Contains(v, "://") {
			if strings.ContainsAny(v, "@?#") {
				maskViewNode(node)
			}
			return
		}
		u, err := url.Parse(v)
		if err != nil || u.Scheme == "" || (u.Host == "" && u.Scheme != "system") {
			maskViewNode(node)
			return
		}
		if u.Path != "" && u.Path != "/" && u.Path != "/dns-query" {
			u.Path = "/***"
		}
		u.User = nil
		u.RawQuery = ""
		u.ForceQuery = false
		u.Fragment = ""
		u.RawPath = ""
		node.Value = u.String()
	}
}

type runtimeProvider struct {
	contentSize int
	contentHash [32]byte
	Kind        string `json:"kind"`
	Name        string `json:"name"`
	Source      string `json:"source"`
	Status      string `json:"status"`
	Count       *int   `json:"count,omitempty"`
	providerReceipt
}

func (r *routingConfiguration) captureProviders(c *yamlConfiguration) {
	for _, data := range r.resources {
		r.inspection.resourceBytes += len(data)
	}
	rows := []runtimeProvider{}
	for _, kind := range []string{"proxy-provider", "rule-provider"} {
		mappings := c.ProxyProviders
		if kind == "rule-provider" {
			mappings = c.RuleProviders
		}
		for name, mapping := range mappings {
			source, _ := mapping["type"].(string)
			row := runtimeProvider{Kind: kind, Name: name, Source: source, Status: "deferred"}
			var count int
			if kind == "proxy-provider" && r.proxyProviders[name] != nil {
				count = r.proxyProviders[name].Count()
				row.Count = &count
			}
			if kind == "rule-provider" && r.ruleProviders[name] != nil {
				count = r.ruleProviders[name].Count()
				row.Count = &count
			}
			if row.Count != nil {
				row.Status = "ready"
			}
			if data := r.resources[resourceKey{kind, name}]; source == "http" && data != nil {
				row.contentSize = len(data)
				row.contentHash = sha256.Sum256(data)
				row.providerReceipt = readProviderReceipt(r.stateRoot, resourceKey{kind, name}, mapping, data)
			}
			rows = append(rows, row)
		}
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Kind == rows[j].Kind {
			return rows[i].Name < rows[j].Name
		}
		return rows[i].Kind < rows[j].Kind
	})
	r.inspection.providers = rows
}
