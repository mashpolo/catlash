package mobile

import (
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
)

var bundledGeoIPPath atomic.Pointer[string]

func SetBundledGeoIPPath(path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("bundled GeoIP path must be absolute")
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return errors.New("bundled GeoIP file is unavailable")
	}
	if previous := bundledGeoIPPath.Load(); previous != nil {
		if *previous == path {
			return nil
		}
		return errors.New("bundled GeoIP path is already configured")
	}
	if !bundledGeoIPPath.CompareAndSwap(nil, &path) {
		return SetBundledGeoIPPath(path)
	}
	return nil
}
