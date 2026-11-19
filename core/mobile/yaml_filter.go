package mobile

import (
	"fmt"
	"reflect"
	"strings"

	"github.com/metacubex/mihomo/adapter/outbound"
	MConfig "github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

// Decode only runtime settings so ignored desktop options never activate host services.
func filterIOSYAML(root *yaml.Node) []string {
	warnings := []string{}
	filterYAMLKeys(root, "", "mode proxies proxy-groups rules sub-rules dns hosts ipv6 proxy-providers rule-providers tun sniffer profile geodata-mode geodata-loader geosite-matcher geox-url geo-auto-update geo-update-interval global-ua keep-alive-idle keep-alive-interval disable-keep-alive", &warnings)
	for i := 0; i < len(root.Content); i += 2 {
		key, value := root.Content[i].Value, root.Content[i+1]
		switch key {
		case "dns":
			filterYAMLStruct(value, reflect.TypeFor[MConfig.RawDNS](), "yaml", key, &warnings)
			removeYAMLKeys(value, key, "listen listen-routing-mark", &warnings)
		case "profile":
			filterYAMLStruct(value, reflect.TypeFor[MConfig.RawProfile](), "yaml", key, &warnings)
		case "geox-url":
			filterYAMLStruct(value, reflect.TypeFor[MConfig.RawGeoXUrl](), "yaml", key, &warnings)
		case "tun":
			filterYAMLKeys(value, key, "dns-hijack route-exclude-address", &warnings)
		case "sniffer":
			filterYAMLStruct(value, reflect.TypeFor[MConfig.RawSniffer](), "yaml", key, &warnings)
			if value.Kind != yaml.MappingNode {
				continue
			}
			for j := 0; j < len(value.Content); j += 2 {
				if value.Content[j].Value == "sniff" {
					filterYAMLMapping(value.Content[j+1], key+".sniff", func(name string, child *yaml.Node) bool {
						if !supportedSniffer(name) {
							return false
						}
						filterYAMLStruct(child, reflect.TypeFor[MConfig.RawSniffingConfig](), "yaml", key+".sniff."+name, &warnings)
						return true
					}, &warnings)
				} else if value.Content[j].Value == "sniffing" && value.Content[j+1].Kind == yaml.SequenceNode {
					list := value.Content[j+1]
					kept := list.Content[:0]
					for _, protocol := range list.Content {
						if protocol.Tag != "!!str" || supportedSniffer(protocol.Value) {
							kept = append(kept, protocol)
						}
					}
					list.Content = kept
				}
			}
		case "proxies":
			filterYAMLProxies(value, key, &warnings)
		case "proxy-groups":
			if value.Kind != yaml.SequenceNode {
				continue
			}
			for index, group := range value.Content {
				filterYAMLStruct(group, reflect.TypeFor[groupConfiguration](), "yaml", fmt.Sprintf("%s[%d]", key, index), &warnings)
			}
		case "proxy-providers", "rule-providers":
			if value.Kind != yaml.MappingNode {
				continue
			}
			for j := 0; j < len(value.Content); j += 2 {
				name, provider := value.Content[j].Value, value.Content[j+1]
				path := key + "." + name
				keys := "type behavior format path url proxy interval size-limit payload header"
				if key == "proxy-providers" {
					keys = "type path url proxy interval filter exclude-filter exclude-type dialer-proxy size-limit payload age-secret-key health-check override header"
				}
				filterYAMLKeys(provider, path, keys, &warnings)
				if key != "proxy-providers" || provider.Kind != yaml.MappingNode {
					continue
				}
				for k := 0; k < len(provider.Content); k += 2 {
					field, nested := provider.Content[k].Value, provider.Content[k+1]
					switch field {
					case "payload":
						filterYAMLProxies(nested, path+".payload", &warnings)
					case "health-check":
						filterYAMLKeys(nested, path+".health-check", "enable url interval timeout lazy expected-status", &warnings)
					case "override":
						filterYAMLKeys(nested, path+".override", "tfo mptcp udp udp-over-tcp up down dialer-proxy skip-cert-verify name-cert-verify ip-version additional-prefix additional-suffix proxy-name override-expr", &warnings)
					}
				}
			}
		}
	}
	return warnings
}

func supportedSniffer(name string) bool {
	return strings.EqualFold(name, "HTTP") || strings.EqualFold(name, "TLS")
}

func filterYAMLProxies(list *yaml.Node, path string, warnings *[]string) {
	if list.Kind != yaml.SequenceNode {
		return
	}
	for index, proxy := range list.Content {
		if proxy.Kind != yaml.MappingNode {
			continue
		}
		var typ reflect.Type
		for i := 0; i < len(proxy.Content); i += 2 {
			if proxy.Content[i].Value == "type" {
				typ = proxyOptionType(proxy.Content[i+1].Value)
			}
		}
		if typ == nil {
			continue
		}
		fields := proxyFields(typ)
		fields["type"] = reflect.TypeFor[string]()
		fields["smux"] = reflect.TypeFor[outbound.SingMuxOption]()
		delete(fields, "interface-name")
		delete(fields, "routing-mark")
		filterYAMLTypedMapping(proxy, fields, "proxy", fmt.Sprintf("%s[%d]", path, index), warnings)
	}
}

func filterYAMLStruct(node *yaml.Node, typ reflect.Type, tag, path string, warnings *[]string) {
	fields := map[string]reflect.Type{}
	if tag == "proxy" {
		fields = proxyFields(typ)
	} else {
		for i := 0; i < typ.NumField(); i++ {
			field := typ.Field(i)
			key := strings.Split(field.Tag.Get(tag), ",")[0]
			if key != "" && key != "-" {
				fields[key] = field.Type
			}
		}
	}
	filterYAMLTypedMapping(node, fields, tag, path, warnings)
}

func filterYAMLTypedMapping(node *yaml.Node, fields map[string]reflect.Type, tag, path string, warnings *[]string) {
	filterYAMLMapping(node, path, func(key string, value *yaml.Node) bool {
		typ, ok := fields[key]
		if !ok {
			return false
		}
		for typ.Kind() == reflect.Pointer {
			typ = typ.Elem()
		}
		if typ.Kind() == reflect.Struct && !typ.Implements(reflect.TypeFor[yaml.Unmarshaler]()) &&
			!reflect.PointerTo(typ).Implements(reflect.TypeFor[yaml.Unmarshaler]()) {
			filterYAMLStruct(value, typ, tag, path+"."+key, warnings)
		}
		return true
	}, warnings)
}

func filterYAMLKeys(node *yaml.Node, path, keys string, warnings *[]string) {
	allowed := map[string]bool{}
	for _, key := range strings.Fields(keys) {
		allowed[key] = true
	}
	filterYAMLMapping(node, path, func(key string, _ *yaml.Node) bool { return allowed[key] }, warnings)
}

func removeYAMLKeys(node *yaml.Node, path, keys string, warnings *[]string) {
	removed := map[string]bool{}
	for _, key := range strings.Fields(keys) {
		removed[key] = true
	}
	filterYAMLMapping(node, path, func(key string, _ *yaml.Node) bool { return !removed[key] }, warnings)
}

func filterYAMLMapping(node *yaml.Node, path string, keep func(string, *yaml.Node) bool, warnings *[]string) {
	if node.Kind != yaml.MappingNode {
		return
	}
	content := node.Content[:0]
	for i := 0; i < len(node.Content); i += 2 {
		key, value := node.Content[i], node.Content[i+1]
		if keep(key.Value, value) {
			content = append(content, key, value)
		} else {
			field := key.Value
			if path != "" {
				field = path + "." + field
			}
			*warnings = append(*warnings, field+" is not applied by the iOS packet tunnel")
		}
	}
	node.Content = content
}

func rejectNullListItems(node *yaml.Node, path string) error {
	if node.Kind == yaml.MappingNode {
		for i := 0; i < len(node.Content); i += 2 {
			child := node.Content[i].Value
			if path != "" {
				child = path + "." + child
			}
			if err := rejectNullListItems(node.Content[i+1], child); err != nil {
				return err
			}
		}
	} else if node.Kind == yaml.SequenceNode {
		for i, child := range node.Content {
			if child.Tag == "!!null" {
				return fmt.Errorf("null list item is unsupported at %s[%d]", path, i)
			}
			if err := rejectNullListItems(child, fmt.Sprintf("%s[%d]", path, i)); err != nil {
				return err
			}
		}
	}
	return nil
}
