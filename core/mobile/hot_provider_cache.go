package mobile

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

func hotProviderFile(root string, key resourceKey) string {
	return filepath.Join(root, "hot-provider-"+digest([]byte(key.kind+"\x00"+key.name)))
}

// An explicit resource bundle or a changed YAML file supersedes overrides made
// against its predecessor. Keep at most one cached update per provider name.
func hotProviderBinding(sourceHash [32]byte, bundle string) [32]byte {
	return sha256.Sum256(append(sourceHash[:], filepath.Base(bundle)...))
}

func (p *ResourcePreparation) persistHotProvider(key resourceKey, data []byte) error {
	if p.stateRoot == "" {
		return nil
	}
	if len(data) > maximumResourceBytes {
		return errors.New("provider exceeds the cache size limit")
	}
	tmp, err := os.CreateTemp(p.stateRoot, ".hot-provider-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	binding := hotProviderBinding(p.sourceHash, p.resourceRoot)
	sum := sha256.Sum256(data)
	for _, part := range [][]byte{binding[:], sum[:], data} {
		if _, err = tmp.Write(part); err != nil {
			_ = tmp.Close()
			return err
		}
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), hotProviderFile(p.stateRoot, key))
}

func readHotProvider(path string, binding [32]byte, limit int) []byte {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil
	}
	defer f.Close()
	info, err := f.Stat()
	const headerSize = 2 * sha256.Size
	if err != nil || !info.Mode().IsRegular() || info.Size() < headerSize || info.Size() > int64(headerSize+limit) {
		return nil
	}
	var found, sum [sha256.Size]byte
	if _, err = io.ReadFull(f, found[:]); err != nil || binding != found {
		return nil
	}
	if _, err = io.ReadFull(f, sum[:]); err != nil {
		return nil
	}
	data := make([]byte, int(info.Size())-headerSize)
	if _, err = io.ReadFull(f, data); err != nil || sha256.Sum256(data) != sum {
		return nil
	}
	return data
}

func loadHotProviders(sourceHash [32]byte, config *yamlConfiguration, resources map[resourceKey][]byte, stateRoot, bundle string) map[string]bool {
	if stateRoot == "" {
		return nil
	}
	updatedProxySources := make(map[string]bool)
	binding := hotProviderBinding(sourceHash, bundle)
	var total int
	for _, data := range resources {
		total += len(data)
	}
	// Apply shrinking entries first so a growing entry can use the freed space
	// regardless of the order in which Go iterates the provider maps.
	loaded := make(map[resourceKey]bool)
	for _, allowGrowth := range []bool{false, true} {
		load := func(kind string, providers map[string]map[string]any) {
			for name, mapping := range providers {
				key := resourceKey{kind, name}
				if mapping["type"] != "http" || loaded[key] {
					continue
				}
				old := resources[key]
				remaining := 64*1024*1024 - (total - len(old))
				limit := min(maximumResourceBytes, remaining)
				if !allowGrowth {
					limit = min(limit, len(old))
				}
				data := readHotProvider(hotProviderFile(stateRoot, key), binding, limit)
				if data == nil {
					continue
				}
				if kind == "proxy-provider" && !bytes.Equal(old, data) {
					updatedProxySources[name] = true
				}
				resources[key] = data
				loaded[key] = true
				total += len(data) - len(old)
			}
		}
		load("proxy-provider", config.ProxyProviders)
		load("rule-provider", config.RuleProviders)
	}
	return updatedProxySources
}
