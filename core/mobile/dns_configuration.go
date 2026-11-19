package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"reflect"
	"strings"

	MConfig "github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"go.yaml.in/yaml/v3"
)

func validateDNSConfiguration(root *yaml.Node, raw *MConfig.RawConfig) error {
	for i := 0; i < len(root.Content); i += 2 {
		if root.Content[i].Value != "dns" {
			continue
		}
		if err := validateYAMLFields(root.Content[i+1], reflect.TypeFor[MConfig.RawDNS](), "dns"); err != nil {
			return err
		}
	}
	if raw.DNS.ListenRoutingMark != 0 {
		return errors.New("unsupported field dns.listen-routing-mark")
	}
	for _, entry := range raw.DNS.FakeIPFilter {
		if raw.DNS.FakeIPFilterMode == C.FilterRule {
			kind := strings.TrimSpace(strings.Split(entry, ",")[0])
			switch kind {
			case "AND", "OR", "NOT", "GEOSITE", "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "DOMAIN-WILDCARD", "RULE-SET", "MATCH":
			default:
				return errors.New("dns.fake-ip-filter contains unsupported rule type")
			}
		}
	}
	return nil
}

func validateYAMLFields(node *yaml.Node, typ reflect.Type, path string) error {
	if node.Tag == "!!null" {
		return nil
	}
	if node.Kind != yaml.MappingNode {
		return fmt.Errorf("%s must be a mapping", path)
	}
	fields := map[string]reflect.Type{}
	for i := 0; i < typ.NumField(); i++ {
		field := typ.Field(i)
		key := strings.Split(field.Tag.Get("yaml"), ",")[0]
		if key != "" && key != "-" {
			fields[key] = field.Type
		}
	}
	for i := 0; i < len(node.Content); i += 2 {
		key := node.Content[i].Value
		field, ok := fields[key]
		if !ok {
			return fmt.Errorf("unsupported field %s.%s", path, key)
		}
		if field.Kind() == reflect.Struct && node.Content[i+1].Kind == yaml.MappingNode {
			if err := validateYAMLFields(node.Content[i+1], field, path+"."+key); err != nil {
				return err
			}
		}
	}
	return nil
}

func YAMLNetworkSettings(value string) (string, error) {
	config, err := parseYAML(value)
	if err != nil {
		return "", err
	}
	prefix4, prefix6 := netip.MustParsePrefix(packetIPv4CIDR), netip.MustParsePrefix(packetIPv6CIDR)
	servers := []string{}
	if config.Raw.DNS.Enable {
		servers = append(servers, prefix4.Addr().String())
	}
	excluded4, excluded6 := excludedNetworkRoutes(config.Raw.Tun.RouteExcludeAddress)
	result, err := json.Marshal(struct {
		IPv6               bool           `json:"ipv6"`
		DNSServers         []string       `json:"dnsServers"`
		IPv4Address        string         `json:"ipv4Address"`
		IPv4PrefixLength   int            `json:"ipv4PrefixLength"`
		IPv6Address        string         `json:"ipv6Address"`
		IPv6PrefixLength   int            `json:"ipv6PrefixLength"`
		IPv4ExcludedRoutes []networkRoute `json:"ipv4ExcludedRoutes,omitempty"`
		IPv6ExcludedRoutes []networkRoute `json:"ipv6ExcludedRoutes,omitempty"`
	}{config.Raw.IPv6, servers, prefix4.Addr().String(), prefix4.Bits(), prefix6.Addr().String(), prefix6.Bits(), excluded4, excluded6})
	return string(result), err
}
