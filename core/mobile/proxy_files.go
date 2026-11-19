package mobile

import (
	"crypto/x509"
	"fmt"
	"strings"
)

func (r *routingConfiguration) hydrateProxyFiles(mapping map[string]any, path string) error {
	if err := r.hydrateProxyFileValues(mapping, path); err != nil {
		return err
	}
	kind, _ := mapping["type"].(string)
	return validateInlineResources(mapping, kind, path, false)
}

func (r *routingConfiguration) hydrateProxyFileValues(mapping map[string]any, path string) error {
	kind, _ := mapping["type"].(string)
	for _, field := range []string{"certificate", "private-key"} {
		value, _ := mapping[field].(string)
		if value == "" || field == "private-key" && (kind == "wireguard" || kind == "masque") {
			continue
		}
		inline := strings.Contains(value, "PRIVATE KEY")
		if field == "certificate" {
			inline = x509.NewCertPool().AppendCertsFromPEM([]byte(value))
		}
		if inline {
			continue
		}
		data, ok := r.resources[resourceKey{"proxy-file", value}]
		if !ok {
			return fmt.Errorf("%s.%s requires an associated proxy-file resource", path, field)
		}
		mapping[field] = string(data)
	}
	for key, value := range mapping {
		switch child := value.(type) {
		case map[string]any:
			if err := r.hydrateProxyFileValues(child, path+"."+key); err != nil {
				return err
			}
		case []any:
			for index, item := range child {
				if nested, ok := item.(map[string]any); ok {
					if err := r.hydrateProxyFileValues(nested, fmt.Sprintf("%s.%s[%d]", path, key, index)); err != nil {
						return err
					}
				}
			}
		}
	}
	return nil
}
