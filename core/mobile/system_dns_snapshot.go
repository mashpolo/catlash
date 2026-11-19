package mobile

import (
	"encoding/json"
	"errors"
	M "github.com/metacubex/mihomo/dns"
	"net/netip"
	"sync/atomic"
)

var systemDNSSnapshot atomic.Pointer[[]string]

// SetSystemDNSServersJSON captures the underlying network before tunnel DNS is
// installed. The host calls it at start, not during a revision switch.
func SetSystemDNSServersJSON(value string) error {
	var addresses []string
	if len(value) > 4096 || json.Unmarshal([]byte(value), &addresses) != nil || addresses == nil {
		return errors.New("system DNS servers must be an array of IP addresses")
	}
	servers := make([]string, 0, len(addresses))
	for _, value := range addresses {
		address, err := netip.ParseAddr(value)
		server := netip.AddrPort{}
		if err == nil {
			server = netip.AddrPortFrom(address, 53)
		} else {
			server, err = netip.ParseAddrPort(value)
		}
		if err != nil || server.Port() == 0 || server.Addr().IsUnspecified() || server.Addr().IsMulticast() {
			return errors.New("system DNS server is not a usable IP address")
		}
		duplicate := false
		for _, existing := range servers {
			if existing == server.String() {
				duplicate = true
				break
			}
		}
		if !duplicate {
			servers = append(servers, server.String())
		}
	}
	systemDNSSnapshot.Store(&servers)
	return nil
}

func init() {
	M.MobileSystemNameServers = func() ([]string, bool) {
		snapshot := systemDNSSnapshot.Load()
		if snapshot == nil {
			return nil, false
		}
		return *snapshot, true
	}
}
