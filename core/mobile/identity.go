package mobile

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
)

func (r *routingConfiguration) identityDirectory(mapping map[string]any, provider string) (string, error) {
	kind, _ := mapping["type"].(string)
	switch kind {
	case "tailscale", "zerotier", "easytier":
	default:
		return "", nil
	}
	if r.stateRoot == "" {
		return "", errors.New("this protocol requires a controlled resource root for identity storage")
	}
	if !filepath.IsAbs(r.stateRoot) {
		return "", errors.New("identity state root must be absolute")
	}
	info, err := os.Lstat(r.stateRoot)
	if err != nil || !info.IsDir() {
		return "", errors.New("identity state root must be a directory without symlinks")
	}
	root, err := os.OpenRoot(r.stateRoot)
	if err != nil {
		return "", errors.New("identity state root is unavailable")
	}
	defer root.Close()
	name, _ := mapping["name"].(string)
	hash := sha256.Sum256([]byte(kind + "\x00" + provider + "\x00" + name))
	directory := hex.EncodeToString(hash[:])
	if err := root.Mkdir(directory, 0700); err != nil && !errors.Is(err, fs.ErrExist) {
		return "", errors.New("cannot create identity state directory")
	}
	if err := fs.WalkDir(root.FS(), directory, func(_ string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Type()&fs.ModeSymlink != 0 || !entry.IsDir() && !entry.Type().IsRegular() {
			return errors.New("identity state contains a link or special file")
		}
		return nil
	}); err != nil {
		return "", errors.New("identity state directory contains unsupported entries")
	}
	return filepath.Join(r.stateRoot, directory), nil
}
