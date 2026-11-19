package mobile

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestIdentityStateIsScopedPersistentAndLazy(t *testing.T) {
	root := t.TempDir()
	config := "proxies: [{name: tail, type: tailscale}, {name: zero, type: zerotier, network: '8056c2e21c000001'}, {name: easy, type: easytier, network-name: test, no-listener: true, peers: ['tcp://127.0.0.1:9']}]\nmode: direct"
	s, err := NewYAMLSessionWithStorage(config, "{}", "", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 3 {
		t.Fatalf("expected three node directories: %v %v", entries, err)
	}
	for _, entry := range entries {
		if !entry.IsDir() || len(entry.Name()) != 64 {
			t.Fatalf("unscoped state %s", entry.Name())
		}
		contents, err := os.ReadDir(filepath.Join(root, entry.Name()))
		if err != nil || len(contents) != 0 {
			t.Fatalf("constructor started identity protocol: %v %v", contents, err)
		}
		if err := os.WriteFile(filepath.Join(root, entry.Name(), "marker"), []byte("keep"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	s, err = NewYAMLSessionWithStorage(config, "{}", "", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	for _, entry := range entries {
		got, err := os.ReadFile(filepath.Join(root, entry.Name(), "marker"))
		if err != nil || string(got) != "keep" {
			t.Fatal("restart lost state")
		}
	}
}

func TestIdentityRejectsMissingUntrustedAndLinkedState(t *testing.T) {
	config := "proxies: [{name: node, type: tailscale}]\nmode: direct"
	for _, root := range []string{"", "relative/path"} {
		s, err := NewYAMLSessionWithStorage(config, "{}", "", root, 1280)
		if err == nil {
			s.Close()
			t.Fatalf("accepted root %q", root)
		}
	}
	root := t.TempDir()
	link := filepath.Join(t.TempDir(), "linked")
	if err := os.Symlink(root, link); err != nil {
		t.Fatal(err)
	}
	if s, err := NewYAMLSessionWithStorage(config, "{}", "", link, 1280); err == nil {
		s.Close()
		t.Fatal("accepted symbolic root")
	}
	s, err := NewYAMLSessionWithStorage(config, "{}", "", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	entries, _ := os.ReadDir(root)
	if err := os.Symlink(t.TempDir(), filepath.Join(root, entries[0].Name(), "escape")); err != nil {
		t.Fatal(err)
	}
	if s, err := NewYAMLSessionWithStorage(config, "{}", "", root, 1280); err == nil {
		s.Close()
		t.Fatal("accepted state symlink")
	}
	if s, err := NewYAMLSessionWithStorage(strings.Replace(config, "type: tailscale", "type: tailscale, state-dir: /tmp/arbitrary", 1), "{}", "", t.TempDir(), 1280); err == nil {
		s.Close()
		t.Fatal("accepted YAML state path")
	}
}

func TestIdentityProviderAndConstructorFailureReleaseSession(t *testing.T) {
	config := "proxy-providers: {nodes: {type: inline, payload: [{name: tail, type: tailscale}]}}\nproxy-groups: [{name: pick, type: select, use: [nodes]}]\nrules: ['MATCH,pick']"
	root := t.TempDir()
	for i := 0; i < 20; i++ {
		s, err := NewYAMLSessionWithStorage(config, "{}", "", root, 1280)
		if err != nil {
			t.Fatal(err)
		}
		s.Close()
	}
	bad := "proxies: [{name: good, type: tailscale}, {name: bad, type: zerotier, network: invalid}]\nmode: direct"
	if s, err := NewYAMLSessionWithStorage(bad, "{}", "", root, 1280); err == nil {
		s.Close()
		t.Fatal("accepted invalid identity protocol")
	}
	s, err := NewYAMLSessionWithStorage(config, "{}", "", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
}
