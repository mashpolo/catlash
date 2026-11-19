package mobile

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

const maximumQualityCacheEntries = 128

type ipQualityCache struct {
	mu      sync.Mutex
	entries map[string]exitIPQualityResult
}

func (c *ipQualityCache) get(ip, directory string, now time.Time) (exitIPQualityResult, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = make(map[string]exitIPQualityResult)
	}
	if value, ok := c.entries[ip]; ok && qualityCacheFresh(value, now) {
		value.Cached = true
		return value, true
	}
	if directory != "" {
		for _, value := range readQualityCache(directory) {
			if value.IP == ip && value.Quality != nil && qualityCacheFresh(value, now) {
				c.entries[ip] = value
				c.trim(now)
				value.Cached = true
				return value, true
			}
		}
	}
	return exitIPQualityResult{}, false
}

func (c *ipQualityCache) put(value exitIPQualityResult, directory string, now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil {
		c.entries = make(map[string]exitIPQualityResult)
	}
	if directory != "" {
		for _, stored := range readQualityCache(directory) {
			if current, ok := c.entries[stored.IP]; !ok || stored.CheckedAt > current.CheckedAt {
				c.entries[stored.IP] = stored
			}
		}
	}
	c.entries[value.IP] = value
	c.trim(now)
	if directory == "" {
		return
	}
	var stored []exitIPQualityResult
	for _, entry := range c.entries {
		if entry.Quality != nil {
			stored = append(stored, entry)
		}
	}
	data, err := json.Marshal(stored)
	if err != nil || os.MkdirAll(directory, 0700) != nil {
		return
	}
	file, err := os.CreateTemp(directory, ".ip-quality-*")
	if err != nil {
		return
	}
	defer os.Remove(file.Name())
	_, err = file.Write(data)
	closeError := file.Close()
	if err == nil && closeError == nil {
		_ = os.Rename(file.Name(), filepath.Join(directory, "ip-quality.json"))
	}
}

func (c *ipQualityCache) trim(now time.Time) {
	var entries []exitIPQualityResult
	for ip, value := range c.entries {
		if !qualityCacheFresh(value, now) {
			delete(c.entries, ip)
		} else {
			entries = append(entries, value)
		}
	}
	if len(entries) <= maximumQualityCacheEntries {
		return
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].CheckedAt > entries[j].CheckedAt })
	for _, value := range entries[maximumQualityCacheEntries:] {
		delete(c.entries, value.IP)
	}
}

func readQualityCache(directory string) []exitIPQualityResult {
	file, err := os.Open(filepath.Join(directory, "ip-quality.json"))
	if err != nil {
		return nil
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, 512*1024+1))
	if err != nil || len(data) > 512*1024 {
		return nil
	}
	var entries []exitIPQualityResult
	if json.Unmarshal(data, &entries) != nil || len(entries) > maximumQualityCacheEntries {
		return nil
	}
	return entries
}

func qualityCacheFresh(value exitIPQualityResult, now time.Time) bool {
	if value.CheckedAt <= 0 {
		return false
	}
	age := now.Sub(time.Unix(value.CheckedAt, 0))
	if age < 0 {
		return false
	}
	if value.Quality == nil {
		return len(value.Failures) > 0 && age < 5*time.Minute
	}
	if qualitySourceIndex(value.Quality.Source) == 6 {
		return false
	}
	switch value.Quality.Type {
	case "residential", "mobile", "business", "hosting":
		return age < 72*time.Hour
	}
	return false
}
