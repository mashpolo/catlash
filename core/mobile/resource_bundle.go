package mobile

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

type resourceKey struct{ kind, name string }
type resourceManifest struct {
	Version int `json:"version"`
	Entries []struct {
		Kind   string `json:"kind"`
		Name   string `json:"name"`
		SHA256 string `json:"sha256"`
		Size   *int64 `json:"size"`
	} `json:"entries"`
}

const maximumResourceBundleBytes = 64 * 1024 * 1024
const maximumResourceBytes = 16 * 1024 * 1024

func digest(bytes []byte) string { value := sha256.Sum256(bytes); return hex.EncodeToString(value[:]) }
func validDigest(value string) bool {
	bytes, err := hex.DecodeString(value)
	return err == nil && len(bytes) == 32 && hex.EncodeToString(bytes) == value
}
func loadResourceBundle(directory string) (map[resourceKey][]byte, error) {
	resources := map[resourceKey][]byte{}
	if directory == "" {
		return resources, nil
	}
	invalid := errors.New("resource bundle is missing, damaged or unsafe")
	if !filepath.IsAbs(directory) || !validDigest(filepath.Base(directory)) {
		return nil, invalid
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() {
		return nil, invalid
	}
	root, err := os.OpenRoot(directory)
	if err != nil {
		return nil, invalid
	}
	defer root.Close()
	read := func(name string, limit int64) ([]byte, error) {
		file, err := root.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
		if err != nil {
			return nil, invalid
		}
		defer file.Close()
		info, err := file.Stat()
		if err != nil || !info.Mode().IsRegular() || info.Size() > limit {
			return nil, invalid
		}
		data := make([]byte, info.Size())
		if _, err := io.ReadFull(file, data); err != nil {
			return nil, invalid
		}
		var end [1]byte
		if n, err := file.Read(end[:]); n != 0 || err != io.EOF {
			return nil, invalid
		}
		return data, nil
	}
	data, err := read("manifest.json", maximumResourceBytes)
	if err != nil || digest(data) != filepath.Base(directory) {
		return nil, invalid
	}
	if err := providerSource(data); err != nil {
		return nil, invalid
	}
	var manifest resourceManifest
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&manifest) != nil || manifest.Version != 1 || manifest.Entries == nil {
		return nil, invalid
	}
	if decoder.Decode(new(any)) != io.EOF {
		return nil, invalid
	}
	var total int64
	previous := resourceKey{}
	for i, entry := range manifest.Entries {
		key := resourceKey{entry.Kind, entry.Name}
		if isGeoResource(key.kind) && key.name != "default" {
			return nil, invalid
		}
		if (key.kind != "proxy-provider" && key.kind != "rule-provider" && key.kind != "proxy-file" && !isGeoResource(key.kind)) || key.name == "" || entry.Size == nil || *entry.Size < 0 || *entry.Size > maximumResourceBytes || !validDigest(entry.SHA256) {
			return nil, invalid
		}
		if i > 0 && (key.kind < previous.kind || (key.kind == previous.kind && key.name <= previous.name)) {
			return nil, invalid
		}
		previous = key
		total += *entry.Size
		if total > maximumResourceBundleBytes {
			return nil, errors.New("resource bundle exceeds 64 MiB")
		}
		blob, err := read(entry.SHA256, *entry.Size)
		if err != nil || int64(len(blob)) != *entry.Size || digest(blob) != entry.SHA256 {
			return nil, invalid
		}
		resources[key] = blob
	}
	return resources, nil
}
