package mobile

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/transport/socks5"
)

func unusedSharingPort(t *testing.T) int {
	t.Helper()
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	return port
}
func enableTestSharing(t *testing.T, s *Session) sharingStatus {
	t.Helper()
	config := sharingConfiguration{Enabled: true, ListenAddress: "127.0.0.1", HTTPPort: unusedSharingPort(t), SOCKSPort: unusedSharingPort(t), Username: "test-user", Password: "test-password"}
	data, _ := json.Marshal(config)
	out, err := s.ConfigureSharing(string(data))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "password") {
		t.Fatal("sharing status leaked password")
	}
	var status sharingStatus
	if err = json.Unmarshal([]byte(out), &status); err != nil {
		t.Fatal(err)
	}
	return status
}
func connectShared(t *testing.T, port int) net.Conn {
	t.Helper()
	c, e := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), time.Second)
	if e != nil {
		t.Fatal(e)
	}
	c.SetDeadline(time.Now().Add(3 * time.Second))
	t.Cleanup(func() { c.Close() })
	return c
}
func sharingEchoServer(t *testing.T) net.Listener {
	t.Helper()
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, e := l.Accept()
			if e != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	return l
}
func sharingSession(t *testing.T) *Session {
	t.Helper()
	s, e := NewYAMLSession("mode: rule\nrules: ['MATCH,DIRECT']", "{}", 1500)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestSharingHTTPAndSOCKSTraffic(t *testing.T) {
	s := sharingSession(t)
	status := enableTestSharing(t, s)
	server := sharingEchoServer(t)
	c := connectShared(t, status.HTTPPort)
	fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Authorization: Basic %s\r\n\r\n", server.Addr(), server.Addr(), base64.StdEncoding.EncodeToString([]byte("test-user:test-password")))
	response, e := http.ReadResponse(bufio.NewReader(c), &http.Request{Method: "CONNECT"})
	if e != nil || response.StatusCode != 200 {
		t.Fatalf("CONNECT: %v %v", response, e)
	}
	payload := []byte("shared-http-data")
	c.Write(payload)
	reply := make([]byte, len(payload))
	if _, e = io.ReadFull(c, reply); e != nil || string(reply) != string(payload) {
		t.Fatal("HTTP CONNECT forwarding failed", e)
	}
	socks := connectShared(t, status.SOCKSPort)
	if _, e = socks5.ClientHandshake(socks, socks5.ParseAddr(server.Addr().String()), socks5.CmdConnect, &socks5.User{Username: "test-user", Password: "test-password"}); e != nil {
		t.Fatal(e)
	}
	socks.Write(payload)
	if _, e = io.ReadFull(socks, reply); e != nil || string(reply) != string(payload) {
		t.Fatal("SOCKS forwarding failed", e)
	}
	value := runtimeSnapshot(t, s)
	if value.ActiveCount != 2 || value.UploadTotal < int64(2*len(payload)) {
		t.Fatalf("missing shared telemetry: %+v", value)
	}
	for _, connection := range value.Connections {
		if connection.Proxy != "DIRECT" || !strings.Contains(strings.ToLower(connection.Rule), "match") {
			t.Fatal("sharing bypassed route", connection)
		}
	}
}

func TestSharingRejectsAuthenticationAndUDP(t *testing.T) {
	s := sharingSession(t)
	status := enableTestSharing(t, s)
	server := sharingEchoServer(t)
	c := connectShared(t, status.HTTPPort)
	fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", server.Addr(), server.Addr())
	r, e := http.ReadResponse(bufio.NewReader(c), &http.Request{Method: "CONNECT"})
	if e != nil || r.StatusCode != 407 {
		t.Fatalf("missing HTTP auth rejection: %v %v", r, e)
	}
	c = connectShared(t, status.SOCKSPort)
	if _, e = socks5.ClientHandshake(c, socks5.ParseAddr(server.Addr().String()), socks5.CmdConnect, &socks5.User{Username: "test-user", Password: "wrong"}); e == nil {
		t.Fatal("accepted wrong SOCKS password")
	}
	c = connectShared(t, status.SOCKSPort)
	if code := sharingSOCKSReply(t, c, server.Addr().String(), socks5.CmdUDPAssociate); code != 7 {
		t.Fatalf("UDP not rejected explicitly: %d", code)
	}
	if runtimeSnapshot(t, s).ActiveCount != 0 {
		t.Fatal("unauthenticated forwarding")
	}
}

func TestSharingShutdownAndFailedReplacement(t *testing.T) {
	s := sharingSession(t)
	status := enableTestSharing(t, s)
	half := connectShared(t, status.SOCKSPort)
	half.Write([]byte{5})
	if _, e := s.ConfigureSharing(`{"enabled":false}`); e != nil {
		t.Fatal(e)
	}
	var b [1]byte
	if _, e := half.Read(b[:]); e == nil {
		t.Fatal("half-handshake not closed")
	}
	for _, port := range []int{status.HTTPPort, status.SOCKSPort} {
		l, e := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if e != nil {
			t.Fatal("port not released", e)
		}
		l.Close()
	}
	status = enableTestSharing(t, s)
	half = connectShared(t, status.HTTPPort)
	blocker, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer blocker.Close()
	config := sharingConfiguration{Enabled: true, ListenAddress: "127.0.0.1", HTTPPort: blocker.Addr().(*net.TCPAddr).Port, SOCKSPort: unusedSharingPort(t), Username: "u", Password: "p"}
	data, _ := json.Marshal(config)
	if _, e = s.ConfigureSharing(string(data)); e == nil {
		t.Fatal("accepted occupied port")
	}
	out, _ := s.SharingStatusJSON()
	if strings.Contains(out, `"enabled":true`) {
		t.Fatal("failed replacement remained enabled")
	}
	if _, e = half.Read(b[:]); e == nil {
		t.Fatal("old client survived replacement")
	}
	status = enableTestSharing(t, s)
	half = connectShared(t, status.SOCKSPort)
	s.Close()
	if _, e = half.Read(b[:]); e == nil {
		t.Fatal("session close retained client")
	}
}

func sharingSOCKSReply(t *testing.T, conn net.Conn, address string, command byte) byte {
	t.Helper()
	conn.Write([]byte{5, 1, 2})
	var reply [10]byte
	if _, e := io.ReadFull(conn, reply[:2]); e != nil || reply[1] != 2 {
		t.Fatal("SOCKS greeting", e)
	}
	credentials := append([]byte{1, 9}, []byte("test-user")...)
	credentials = append(credentials, 13)
	credentials = append(credentials, []byte("test-password")...)
	conn.Write(credentials)
	if _, e := io.ReadFull(conn, reply[:2]); e != nil || reply[1] != 0 {
		t.Fatal("SOCKS auth", e)
	}
	conn.Write(append([]byte{5, command, 0}, socks5.ParseAddr(address)...))
	if _, e := io.ReadFull(conn, reply[:]); e != nil {
		t.Fatal("SOCKS reply", e)
	}
	return reply[1]
}

func TestSharingHTTPGetAndInvalidConfiguration(t *testing.T) {
	s := sharingSession(t)
	status := enableTestSharing(t, s)
	server, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer server.Close()
	httpServer := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Proxy-Authorization") != "" {
			t.Error("proxy credential forwarded to target")
		}
		io.WriteString(w, "shared-get-ok")
	})}
	go httpServer.Serve(server)
	defer httpServer.Close()
	conn := connectShared(t, status.HTTPPort)
	fmt.Fprintf(conn, "GET http://%s/check HTTP/1.1\r\nHost: %s\r\nProxy-Authorization: Basic %s\r\nConnection: close\r\n\r\n", server.Addr(), server.Addr(), base64.StdEncoding.EncodeToString([]byte("test-user:test-password")))
	response, err := http.ReadResponse(bufio.NewReader(conn), &http.Request{Method: "GET"})
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || string(body) != "shared-get-ok" {
		t.Fatalf("GET failed: %q %v", body, err)
	}
	for _, config := range []string{`{"enabled":true,"listenAddress":"bad","httpPort":7890,"socksPort":7891,"username":"u","password":"p"}`, `{"enabled":true,"listenAddress":"127.0.0.1","httpPort":7890,"socksPort":7891,"username":"u","password":""}`} {
		if _, err = s.ConfigureSharing(config); err == nil {
			t.Fatal("accepted invalid configuration")
		}
	}
	current, _ := s.SharingStatusJSON()
	if !strings.Contains(current, `"enabled":true`) {
		t.Fatal("invalid config replaced active sharing")
	}
}

func TestSharingDisableClosesEstablishedAndPendingClients(t *testing.T) {
	s := sharingSession(t)
	status := enableTestSharing(t, s)
	server := sharingEchoServer(t)
	connected := connectShared(t, status.SOCKSPort)
	if code := sharingSOCKSReply(t, connected, server.Addr().String(), socks5.CmdConnect); code != 0 {
		t.Fatalf("connect reply %d", code)
	}
	half := connectShared(t, status.HTTPPort)
	half.Write([]byte("CON"))
	if _, err := s.ConfigureSharing(`{"enabled":false}`); err != nil {
		t.Fatal(err)
	}
	for _, conn := range []net.Conn{connected, half} {
		var value [1]byte
		_, err := conn.Read(value[:])
		if err == nil {
			t.Fatal("client survived disable")
		}
		if e, ok := err.(net.Error); ok && e.Timeout() {
			t.Fatal("client was not closed; read timed out")
		}
	}
	if runtimeSnapshot(t, s).ActiveCount != 0 {
		t.Fatal("shared forwarding survived disable")
	}
}

func TestSharingSOCKSReportsDialFailure(t *testing.T) {
	s := sharingSession(t)
	status := enableTestSharing(t, s)
	conn := connectShared(t, status.SOCKSPort)
	if code := sharingSOCKSReply(t, conn, fmt.Sprintf("127.0.0.1:%d", unusedSharingPort(t)), socks5.CmdConnect); code == 0 {
		t.Fatal("failed outbound reported success")
	}
}
