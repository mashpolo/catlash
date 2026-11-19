package mobile

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	D "github.com/miekg/dns"
)

func TestYAMLProfileStoreSelected(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		yaml := fmt.Sprintf("profile: {store-selected: %t}\nproxy-groups:\n - name: Proxy\n   type: select\n   proxies: [DIRECT, REJECT]\nrules: ['MATCH,Proxy']\n", enabled)
		session, err := NewYAMLSession(yaml, `{"Proxy":"REJECT"}`, 1280)
		if err != nil {
			t.Fatal(err)
		}
		catalog, err := session.ProxiesJSON()
		if err != nil {
			t.Fatal(err)
		}
		var decoded struct {
			Proxies []struct {
				Name string `json:"name"`
				Now  string `json:"now"`
			} `json:"proxies"`
		}
		if err := json.Unmarshal([]byte(catalog), &decoded); err != nil {
			t.Fatal(err)
		}
		wanted := "REJECT"
		found := false
		for _, group := range decoded.Proxies {
			if group.Name == "Proxy" {
				found = true
			}
			if group.Name == "Proxy" && group.Now != wanted {
				t.Fatalf("restored selection %q, want %q", group.Now, wanted)
			}
		}
		if !found {
			t.Fatal("catalog omitted the selector")
		}
		if err := session.SelectProxy("Proxy", "REJECT"); err != nil {
			t.Fatal(err)
		}
		if err := session.Close(); err != nil {
			t.Fatal(err)
		}
	}
	for _, value := range []string{"profile: {store-selected: wrong}", "profile: []"} {
		if _, err := parseYAML(value); err == nil {
			t.Fatalf("accepted invalid profile: %s", value)
		}
	}
}

func TestFakeIPStateConcurrentAllocationsAndRangeChange(t *testing.T) {
	yaml := dnsYAML(dnsFixture(t), "fake-ip") + "profile: {store-fake-ip: true}\n"
	root := t.TempDir()
	session := newStateSession(t, yaml, root)
	var group sync.WaitGroup
	addresses := make([]netip.Addr, 20)
	for index := range addresses {
		group.Add(1)
		go func() {
			defer group.Done()
			addresses[index] = lookupStateIP(t, session, fmt.Sprintf("concurrent-%d.invalid.", index), D.TypeA)
		}()
	}
	group.Wait()
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	session = newStateSession(t, yaml, root)
	for index, address := range addresses {
		if host, ok := session.routing.dns.mapper.FindHostByIP(address); !ok || host != fmt.Sprintf("concurrent-%d.invalid", index) {
			t.Fatalf("lost mapping %d: %q", index, host)
		}
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	yaml = strings.Replace(yaml, "dns:\n", "dns:\n fake-ip-range: 198.19.0.1/16\n", 1)
	session = newStateSession(t, yaml, root)
	for _, address := range addresses {
		if _, ok := session.routing.dns.mapper.FindHostByIP(address); ok {
			t.Fatal("old range mapping restored")
		}
	}
	if !netip.MustParsePrefix("198.19.0.0/16").Contains(lookupStateIP(t, session, "new-range.invalid.", D.TypeA)) {
		t.Fatal("new range was not used")
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestFakeIPStatePersistsAndIsolatesProfiles(t *testing.T) {
	address := dnsFixture(t)
	yaml := dnsYAML(address, "fake-ip") + "profile: {store-fake-ip: true}\nrules: ['MATCH,DIRECT']\n"
	firstRoot, secondRoot := t.TempDir(), t.TempDir()
	first := newStateSession(t, yaml, firstRoot)
	ip4 := lookupStateIP(t, first, "kept.invalid.", D.TypeA)
	ip6 := lookupStateIP(t, first, "kept.invalid.", D.TypeAAAA)
	content, err := os.ReadFile(filepath.Join(firstRoot, "fake-ip.json"))
	if err != nil || !strings.Contains(string(content), "kept.invalid") {
		t.Fatalf("new mappings not saved before response: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	second := newStateSession(t, yaml, secondRoot)
	if _, ok := second.routing.dns.mapper.FindHostByIP(ip4); ok {
		t.Fatal("another profile restored first profile's mapping")
	}
	if err := second.Close(); err != nil {
		t.Fatal(err)
	}
	restored := newStateSession(t, yaml, firstRoot)
	for _, ip := range []netip.Addr{ip4, ip6} {
		if host, ok := restored.routing.dns.mapper.FindHostByIP(ip); !ok || host != "kept.invalid" {
			t.Fatalf("mapping not restored for %s: %q", ip, host)
		}
	}
	if got := lookupStateIP(t, restored, "kept.invalid.", D.TypeA); got != ip4 {
		t.Fatalf("address changed: %s != %s", got, ip4)
	}
	if got := lookupStateIP(t, restored, "next.invalid.", D.TypeA); got == ip4 {
		t.Fatal("allocator overwrote restored address")
	}
	if err := restored.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestFakeIPDisabledDoesNotRestoreOrKeepPreviousState(t *testing.T) {
	yaml := dnsYAML(dnsFixture(t), "fake-ip") + "profile: {store-fake-ip: true}\n"
	root := t.TempDir()
	session := newStateSession(t, yaml, root)
	oldIP := lookupStateIP(t, session, "previous.invalid.", D.TypeA)
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	session = newStateSession(t, strings.Replace(yaml, "store-fake-ip: true", "store-fake-ip: false", 1), root)
	if _, ok := session.routing.dns.mapper.FindHostByIP(oldIP); ok {
		t.Fatal("disabled persistence restored a mapping")
	}
	_ = lookupStateIP(t, session, "volatile.invalid.", D.TypeA)
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "fake-ip.json")); !os.IsNotExist(err) {
		t.Fatalf("disabled persistence retained state: %v", err)
	}
	session = newStateSession(t, yaml, root)
	if _, ok := session.routing.dns.mapper.FindHostByIP(oldIP); ok {
		t.Fatal("re-enabling restored stale disabled state")
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestFakeIPStateRejectsUnsafeAndDamagedStorage(t *testing.T) {
	yaml := dnsYAML(dnsFixture(t), "fake-ip") + "profile: {store-fake-ip: true}\n"
	if session, err := NewYAMLSession(yaml, "{}", 1280); err == nil {
		session.Close()
		t.Fatal("persistent Fake-IP accepted missing controlled directory")
	}
	root := t.TempDir()
	for _, content := range []string{"broken", `{"version":1,"pools":[{},null]}`, strings.Repeat(" ", 2*1024*1024+1)} {
		if err := os.WriteFile(filepath.Join(root, "fake-ip.json"), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
		if session, err := NewYAMLSessionWithStorage(yaml, "{}", "", root, 1280); err == nil {
			session.Close()
			t.Fatal("accepted damaged Fake-IP state")
		}
	}
	if err := os.Remove(filepath.Join(root, "fake-ip.json")); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(outside, []byte("unchanged"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "fake-ip.json")); err != nil {
		t.Fatal(err)
	}
	if session, err := NewYAMLSessionWithStorage(yaml, "{}", "", root, 1280); err == nil {
		session.Close()
		t.Fatal("accepted symlinked state")
	}
	content, _ := os.ReadFile(outside)
	if string(content) != "unchanged" {
		t.Fatal("outside state changed")
	}
}

func TestDisabledFakeIPClearsStoredStateWithDNSOff(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, fakeIPStateFile), []byte("previous cache"), 0600); err != nil {
		t.Fatal(err)
	}
	session := newStateSession(t, "profile: {store-fake-ip: false}\ndns: {enable: false}\n", root)
	if _, err := os.Stat(filepath.Join(root, fakeIPStateFile)); !os.IsNotExist(err) {
		t.Fatal("disabled profile retained previous Fake-IP state")
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
}

func newStateSession(t *testing.T, yaml, root string) *Session {
	t.Helper()
	session, err := NewYAMLSessionWithStorage(yaml, "{}", "", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { session.Close() })
	return session
}

func lookupStateIP(t *testing.T, session *Session, host string, kind uint16) netip.Addr {
	t.Helper()
	response, err := session.routing.dns.answer(dnsQuery(t, host, kind))
	if err != nil {
		t.Fatal(err)
	}
	answer := dnsAnswer(t, response)
	switch value := answer.Answer[0].(type) {
	case *D.A:
		ip, _ := netip.AddrFromSlice(value.A)
		return ip.Unmap()
	case *D.AAAA:
		ip, _ := netip.AddrFromSlice(value.AAAA)
		return ip
	default:
		t.Fatalf("unexpected answer %v", answer)
		return netip.Addr{}
	}
}
