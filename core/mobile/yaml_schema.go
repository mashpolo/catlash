package mobile

import (
	"errors"
	"fmt"
	"io"
	"reflect"
	"strings"

	"github.com/metacubex/mihomo/adapter/outbound"
	MConfig "github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

type yamlConfiguration struct {
	DNSHijack      dnsHijackRules            `yaml:"-"`
	SubRules       map[string][]string       `yaml:"sub-rules"`
	ProxyProviders map[string]map[string]any `yaml:"proxy-providers"`
	RuleProviders  map[string]map[string]any `yaml:"rule-providers"`
	Warnings       []string                  `yaml:"-"`
	Raw            *MConfig.RawConfig        `yaml:"-"`
	GlobalUA       string                    `yaml:"global-ua"`
	Mode           string                    `yaml:"mode"`
	Proxies        []map[string]any          `yaml:"proxies"`
	Groups         []groupConfiguration      `yaml:"proxy-groups"`
	Rules          []string                  `yaml:"rules"`
}

type groupConfiguration struct {
	Interval            int    `yaml:"interval"`
	Timeout             int    `yaml:"timeout"`
	Lazy                *bool  `yaml:"lazy"`
	ExpectedStatus      string `yaml:"expected-status"`
	IncludeAll          bool   `yaml:"include-all"`
	IncludeAllProxies   bool   `yaml:"include-all-proxies"`
	IncludeAllProviders bool   `yaml:"include-all-providers"`

	Use             []string `yaml:"use"`
	Filter          string   `yaml:"filter"`
	ExcludeFilter   string   `yaml:"exclude-filter"`
	ExcludeType     string   `yaml:"exclude-type"`
	Name            string   `yaml:"name"`
	Type            string   `yaml:"type"`
	Proxies         []string `yaml:"proxies"`
	URL             string   `yaml:"url"`
	Tolerance       uint16   `yaml:"tolerance"`
	Strategy        string   `yaml:"strategy"`
	DefaultSelected string   `yaml:"default-selected"`
	DisableUDP      bool     `yaml:"disable-udp"`
}

func parseYAML(value string) (*yamlConfiguration, error) {
	if len(value) > 16*1024*1024 {
		return nil, errors.New("YAML exceeds 16 MiB")
	}
	decoder := yaml.NewDecoder(strings.NewReader(value))
	var root yaml.Node
	if err := decoder.Decode(&root); err != nil {
		return nil, errors.New("invalid YAML syntax")
	}
	if len(root.Content) != 1 || root.Content[0].Kind != yaml.MappingNode {
		return nil, errors.New("YAML root must be a mapping")
	}
	node, err := normalizeYAMLNode(root.Content[0], "")
	if err != nil {
		return nil, err
	}
	var extra yaml.Node
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, errors.New("YAML must contain one document")
	}
	warnings := filterIOSYAML(node)
	if err := rejectNullListItems(node, ""); err != nil {
		return nil, err
	}
	var config yamlConfiguration
	if err := node.Decode(&config); err != nil {
		return nil, errors.New("YAML configuration has invalid field types")
	}
	if err := validateExcludedRoutes(node); err != nil {
		return nil, err
	}
	raw := MConfig.DefaultRawConfig()
	raw.GeodataMode = false
	if err := node.Decode(raw); err != nil {
		return nil, errors.New("YAML configuration has invalid field types")
	}
	config.Raw = raw
	config.DNSHijack, err = parseDNSHijack(raw.Tun.DNSHijack)
	if err != nil {
		return nil, err
	}
	if err := validateProviderConfiguration(&config); err != nil {
		return nil, err
	}
	config.Warnings = warnings
	if raw.GeodataLoader != "" && raw.GeodataLoader != "standard" && raw.GeodataLoader != "memconservative" && raw.GeodataLoader != "memc" {
		return nil, errors.New("unsupported geodata-loader")
	}
	for i := 0; i < len(node.Content); i += 2 {
		key := node.Content[i].Value
		switch key {
		case "profile":
			if err := validateYAMLFields(node.Content[i+1], reflect.TypeFor[MConfig.RawProfile](), key); err != nil {
				return nil, err
			}
		case "geox-url":
			if err := validateYAMLFields(node.Content[i+1], reflect.TypeFor[MConfig.RawGeoXUrl](), key); err != nil {
				return nil, err
			}
			config.Warnings = append(config.Warnings, "geox-url resources are prepared by the app")
		case "geo-auto-update", "geo-update-interval":
			config.Warnings = append(config.Warnings, key+" is managed through app resource snapshots")
		case "geodata-loader":
			config.Warnings = append(config.Warnings, "geodata-loader uses bounded in-memory loading on iOS")
		}
	}

	if err := validateDNSConfiguration(node, raw); err != nil {
		return nil, err
	}
	if err := validateSnifferConfiguration(node, raw.Sniffer); err != nil {
		return nil, err
	}
	if raw.DNS.Listen != "" {
		config.Warnings = append(config.Warnings, "dns.listen is replaced by DNS on packetFlow port 53; no DNS listener is opened")
	}
	if config.Mode == "" {
		config.Mode = "rule"
	}
	switch config.Mode {
	case "rule", "global", "direct":
	default:
		return nil, errors.New("mode must be rule, global or direct")
	}
	for index, mapping := range config.Proxies {
		path := fmt.Sprintf("proxies[%d]", index)
		kind, ok := mapping["type"].(string)
		if !ok {
			return nil, fmt.Errorf("%s.type must be a string", path)
		}
		typ := proxyOptionType(kind)
		if typ == nil {
			return nil, fmt.Errorf("%s.type is unsupported", path)
		}
		if err := validateInlineResources(mapping, kind, path, true); err != nil {
			return nil, err
		}
		if err := validateProxyFields(mapping, typ, path, true); err != nil {
			return nil, err
		}
	}
	for index, group := range config.Groups {
		if group.Tolerance != 0 && group.Type != "url-test" {
			return nil, fmt.Errorf("unsupported field proxy-groups[%d].tolerance", index)
		}
		if group.Strategy != "" && group.Type != "load-balance" {
			return nil, fmt.Errorf("unsupported field proxy-groups[%d].strategy", index)
		}
		if group.DefaultSelected != "" && group.Type != "select" {
			return nil, fmt.Errorf("unsupported field proxy-groups[%d].default-selected", index)
		}
	}
	return &config, nil
}

func validateYAMLNode(node *yaml.Node, path string) error {
	if node.Kind == yaml.AliasNode {
		return nil
	}
	if node.Kind == yaml.MappingNode {
		seen := map[string]bool{}
		for i := 0; i < len(node.Content); i += 2 {
			key := node.Content[i]
			if key.Kind != yaml.ScalarNode || (key.Tag != "!!str" && key.Tag != "!!merge") {
				return fmt.Errorf("mapping key must be a string at %s", path)
			}
			child := key.Value
			if path != "" {
				child = path + "." + child
			}
			if seen[key.Value] {
				return fmt.Errorf("duplicate YAML key %s", child)
			}
			seen[key.Value] = true
			if err := validateYAMLNode(node.Content[i+1], child); err != nil {
				return err
			}
		}
	} else if node.Kind == yaml.SequenceNode {
		for i, child := range node.Content {
			if err := validateYAMLNode(child, fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
	}
	return nil
}

var proxyOptionTypes = map[string]reflect.Type{
	"ss": reflect.TypeFor[outbound.ShadowSocksOption](), "ssr": reflect.TypeFor[outbound.ShadowSocksROption](), "socks5": reflect.TypeFor[outbound.Socks5Option](), "http": reflect.TypeFor[outbound.HttpOption](),
	"vmess": reflect.TypeFor[outbound.VmessOption](), "vless": reflect.TypeFor[outbound.VlessOption](), "snell": reflect.TypeFor[outbound.SnellOption](), "trojan": reflect.TypeFor[outbound.TrojanOption](),
	"hysteria": reflect.TypeFor[outbound.HysteriaOption](), "hysteria2": reflect.TypeFor[outbound.Hysteria2Option](), "wireguard": reflect.TypeFor[outbound.WireGuardOption](), "tuic": reflect.TypeFor[outbound.TuicOption](),
	"shadowquic": reflect.TypeFor[outbound.ShadowQuicOption](), "gost-relay": reflect.TypeFor[outbound.GostRelayOption](), "ssh": reflect.TypeFor[outbound.SshOption](), "mieru": reflect.TypeFor[outbound.MieruOption](),
	"anytls": reflect.TypeFor[outbound.AnyTLSOption](), "sudoku": reflect.TypeFor[outbound.SudokuOption](), "masque": reflect.TypeFor[outbound.MasqueOption](), "trusttunnel": reflect.TypeFor[outbound.TrustTunnelOption](),
	"openvpn": reflect.TypeFor[outbound.OpenVPNOption](), "tailscale": reflect.TypeFor[outbound.TailscaleOption](), "zerotier": reflect.TypeFor[outbound.ZeroTierOption](), "easytier": reflect.TypeFor[outbound.EasyTierOption](),
	"direct": reflect.TypeFor[outbound.DirectOption](), "reject": reflect.TypeFor[outbound.RejectOption](),
}

func proxyOptionType(kind string) reflect.Type { return proxyOptionTypes[kind] }

func proxyFields(typ reflect.Type) map[string]reflect.Type {
	fields := map[string]reflect.Type{}
	for i := 0; i < typ.NumField(); i++ {
		field := typ.Field(i)
		key := strings.Split(field.Tag.Get("proxy"), ",")[0]
		if field.Anonymous && key == "" {
			for name, value := range proxyFields(field.Type) {
				fields[name] = value
			}
			continue
		}
		if key != "" && key != "-" {
			fields[key] = field.Type
		}
	}
	return fields
}

func validateProxyFields(mapping map[string]any, typ reflect.Type, path string, root bool) error {
	fields := proxyFields(typ)
	if root {
		fields["type"] = reflect.TypeFor[string]()
		fields["smux"] = reflect.TypeFor[outbound.SingMuxOption]()
	}
	for key, value := range mapping {
		field, ok := fields[key]
		if !ok || (root && (key == "interface-name" || key == "routing-mark")) {
			delete(mapping, key)
			continue
		}
		for field.Kind() == reflect.Pointer {
			field = field.Elem()
		}
		if child, ok := value.(map[string]any); ok && field.Kind() == reflect.Struct {
			if err := validateProxyFields(child, field, path+"."+key, false); err != nil {
				return err
			}
		}
	}
	return nil
}
