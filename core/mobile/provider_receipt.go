package mobile

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Receipts associate an actual download with its content and configured source.
// Old local bundles without a matching receipt simply have no timestamp or usage.
type providerReceipt struct {
	UpdatedAt    *int64           `json:"updatedAt,omitempty"`
	Subscription map[string]int64 `json:"subscription,omitempty"`
}
type providerReceiptFile struct {
	Digest string `json:"digest"`
	providerReceipt
}

func providerReceiptPath(root string, key resourceKey, mapping map[string]any) string {
	source, _ := mapping["url"].(string)
	return filepath.Join(root, "provider-info", digest([]byte(key.kind+"\x00"+key.name+"\x00"+source))+".json")
}
func readProviderReceipt(root string, key resourceKey, mapping map[string]any, data []byte) providerReceipt {
	if root == "" {
		return providerReceipt{}
	}
	body, err := os.ReadFile(providerReceiptPath(root, key, mapping))
	var record providerReceiptFile
	if err != nil || len(body) > 2048 || json.Unmarshal(body, &record) != nil || record.Digest != digest(data) {
		return providerReceipt{}
	}
	return record.providerReceipt
}
func saveProviderReceipt(root string, key resourceKey, mapping map[string]any, data []byte, header string) providerReceipt {
	now := time.Now().Unix()
	receipt := providerReceipt{UpdatedAt: &now}
	for _, entry := range strings.Split(header, ";") {
		k, v, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		k = strings.ToLower(strings.TrimSpace(k))
		switch k {
		case "expire":
			k = "expiresAt"
		case "upload", "download", "total":
		default:
			continue
		}
		n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
		if err != nil || n < 0 || (k == "expiresAt" && n == 0) {
			continue
		}
		if receipt.Subscription == nil {
			receipt.Subscription = make(map[string]int64)
		}
		receipt.Subscription[k] = n
	}
	if root == "" {
		return receipt
	}
	record := providerReceiptFile{Digest: digest(data), providerReceipt: receipt}
	path := providerReceiptPath(root, key, mapping)
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return receipt
	}
	tmp, err := os.CreateTemp(dir, ".receipt-")
	if err != nil {
		return receipt
	}
	defer os.Remove(tmp.Name())
	err = json.NewEncoder(tmp).Encode(record)
	closed := tmp.Close()
	if err == nil && closed == nil {
		_ = os.Rename(tmp.Name(), path)
	}
	return receipt
}
