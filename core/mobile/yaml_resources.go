package mobile

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"strings"
)

func validateInlineResources(mapping map[string]any, kind, path string, allowReferences bool) error {
	for _, key := range []string{"state-dir", "planet"} {
		if _, ok := mapping[key]; ok {
			return fmt.Errorf("unsupported file field %s.%s: resource root is required", path, key)
		}
	}
	if !allowReferences {
		certificate, _ := mapping["certificate"].(string)
		privateKey, _ := mapping["private-key"].(string)
		if certificate != "" && !x509.NewCertPool().AppendCertsFromPEM([]byte(certificate)) {
			return fmt.Errorf("%s.certificate must contain an inline PEM certificate", path)
		}
		switch kind {
		case "wireguard", "masque":
		case "ssh":
			if privateKey != "" && !strings.Contains(privateKey, "PRIVATE KEY") {
				return fmt.Errorf("%s.private-key must contain an inline SSH private key", path)
			}
		default:
			if privateKey != "" {
				if _, err := tls.X509KeyPair([]byte(certificate), []byte(privateKey)); err != nil {
					return fmt.Errorf("%s.private-key must form a valid inline PEM key pair", path)
				}
			}
		}
	}
	for key, value := range mapping {
		switch child := value.(type) {
		case map[string]any:
			if err := validateInlineResources(child, "", path+"."+key, allowReferences); err != nil {
				return err
			}
		case []any:
			for index, item := range child {
				if nested, ok := item.(map[string]any); ok {
					if err := validateInlineResources(nested, "", fmt.Sprintf("%s.%s[%d]", path, key, index), allowReferences); err != nil {
						return err
					}
				}
			}
		}
	}
	return nil
}
