package mobile

import (
	"strings"
	"testing"
)

func TestConfiguredSessionRejectsInvalidConfiguration(t *testing.T) {
	for _, configuration := range []string{
		strings.Repeat(" ", 16*1024) + `{"version":1,"mtu":1280,"outbound":{"type":"direct"}}`,
		`{}`,
		`{"version":1,"mtu":1280,"outbound":{"type":"direct","server":""}}`,
		`{"version":1,"mtu":1280,"outbound":{"type":"direct","udp":null}}`,
		`{"version":1,"mtu":1280,"outbound":{"type":"socks5","server":"localhost","port":1234,"udp":null}}`,
		`{"version":1,"mtu":1280,"outbound":{"type":"socks5","server":"localhost","port":1234,"password":null}}`,
		`{"version":1,"mtu":1280,"outbound":{"type":"socks5","server":"localhost","port":1234,"username":"` + strings.Repeat("界", 86) + `"}}`, `{"version":2,"mtu":1280,"outbound":{"type":"direct"}}`,
		`{"version":1,"mtu":1279,"outbound":{"type":"direct"}}`,
		`{"version":1,"mtu":1280,"outbound":{"type":"unknown"}}`,
		`{"version":1,"mtu":1280,"outbound":{"type":"socks5","server":"localhost","port":0}}`,
		`{"version":1,"mtu":1280,"outbound":{"type":"direct","server":"ignored"}}`,
		`{"version":1,"mtu":1280,"outbound":{"type":"direct"},"rules":[]}`,
		`{"version":1,"mtu":1280,"outbound":{"type":"direct"}} {}`,
	} {
		session, err := NewConfiguredSession(configuration)
		if err == nil {
			session.Close()
			t.Errorf("accepted %s", configuration)
		}
	}
}

func TestConfiguredSessionFiftyRestarts(t *testing.T) {
	for range 50 {
		session, err := NewConfiguredSession(`{"version":1,"mtu":1280,"outbound":{"type":"direct"}}`)
		if err != nil {
			t.Fatal(err)
		}
		if err := session.WritePacket(echoPacket()); err != nil {
			t.Fatal(err)
		}
		readWithDeadline(t, session)
		if err := session.Close(); err != nil {
			t.Fatal(err)
		}
	}
}
