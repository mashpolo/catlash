package mobile

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/auth"
	C "github.com/metacubex/mihomo/constant"
	authstore "github.com/metacubex/mihomo/listener/auth"
	httpproxy "github.com/metacubex/mihomo/listener/http"
	"github.com/metacubex/mihomo/transport/socks5"
)

type sharingConfiguration struct {
	Enabled       bool   `json:"enabled"`
	ListenAddress string `json:"listenAddress"`
	HTTPPort      int    `json:"httpPort"`
	SOCKSPort     int    `json:"socksPort"`
	Username      string `json:"username"`
	Password      string `json:"password"`
}

type sharingStatus struct {
	Enabled       bool   `json:"enabled"`
	ListenAddress string `json:"listenAddress"`
	HTTPPort      int    `json:"httpPort"`
	SOCKSPort     int    `json:"socksPort"`
}

type sharingServer struct {
	session     *Session
	config      sharingConfiguration
	ctx         context.Context
	cancel      context.CancelFunc
	listeners   []net.Listener
	mu          sync.Mutex
	closed      bool
	connections map[net.Conn]struct{}
	tasks       sync.WaitGroup
}

func (s *Session) ConfigureSharing(configJSON string) (string, error) {
	if len(configJSON) > 4096 {
		return "", errors.New("sharing configuration is too large")
	}
	var config sharingConfiguration
	decoder := json.NewDecoder(strings.NewReader(configJSON))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return "", errors.New("invalid sharing configuration")
	}
	if decoder.Decode(new(any)) != io.EOF {
		return "", errors.New("invalid sharing configuration")
	}
	if config.Enabled {
		address, err := netip.ParseAddr(config.ListenAddress)
		if err != nil || address.IsMulticast() || address.Zone() != "" {
			return "", errors.New("listenAddress must be a unicast or unspecified IP address")
		}
		if config.HTTPPort < 1 || config.HTTPPort > 65535 || config.SOCKSPort < 1 || config.SOCKSPort > 65535 || config.HTTPPort == config.SOCKSPort {
			return "", errors.New("HTTP and SOCKS ports must be different values from 1 to 65535")
		}
		if strings.TrimSpace(config.Username) == "" || config.Password == "" || len(config.Username) > 255 || len(config.Password) > 255 || strings.Contains(config.Username, ":") {
			return "", errors.New("sharing requires a username and password of at most 255 bytes")
		}
	}
	s.sharingMu.Lock()
	defer s.sharingMu.Unlock()
	s.mu.Lock()
	closed := s.closed
	s.mu.Unlock()
	if closed {
		return "", errors.New("session is closed")
	}
	s.stopSharingLocked()
	if !config.Enabled {
		return s.sharingStatusLocked()
	}
	server := &sharingServer{session: s, config: config, connections: make(map[net.Conn]struct{})}
	server.ctx, server.cancel = context.WithCancel(s.ctx)
	for _, port := range []int{config.HTTPPort, config.SOCKSPort} {
		listener, err := net.Listen("tcp", net.JoinHostPort(config.ListenAddress, strconv.Itoa(port)))
		if err != nil {
			server.close()
			return "", errors.New("could not bind sharing listener; verify address and port availability")
		}
		server.listeners = append(server.listeners, listener)
	}
	s.sharing = server
	for index, listener := range server.listeners {
		server.tasks.Add(1)
		go server.accept(listener, index == 0)
	}
	s.telemetry.addLog("info", "Authenticated HTTP and SOCKS5 TCP sharing enabled")
	return s.sharingStatusLocked()
}

func (s *Session) SharingStatusJSON() (string, error) {
	s.sharingMu.Lock()
	defer s.sharingMu.Unlock()
	return s.sharingStatusLocked()
}
func (s *Session) sharingStatusLocked() (string, error) {
	status := sharingStatus{}
	if s.sharing != nil {
		c := s.sharing.config
		status = sharingStatus{true, c.ListenAddress, c.HTTPPort, c.SOCKSPort}
	}
	data, err := json.Marshal(status)
	return string(data), err
}
func (s *Session) stopSharingLocked() {
	if s.sharing != nil {
		s.sharing.close()
		s.sharing = nil
		s.telemetry.addLog("info", "Proxy sharing stopped")
	}
}

func (s *sharingServer) accept(listener net.Listener, isHTTP bool) {
	defer s.tasks.Done()
	for {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		s.mu.Lock()
		if s.closed || len(s.connections) >= 128 {
			s.mu.Unlock()
			conn.Close()
			continue
		}
		s.connections[conn] = struct{}{}
		s.tasks.Add(1)
		s.mu.Unlock()
		go func() {
			defer s.tasks.Done()
			defer conn.Close()
			defer func() { s.mu.Lock(); delete(s.connections, conn); s.mu.Unlock() }()
			_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
			if isHTTP {
				store := authstore.NewAuthStore(auth.NewAuthenticator([]auth.AuthUser{{User: s.config.Username, Pass: s.config.Password}}))
				httpproxy.HandleConn(conn, &sharingTunnel{server: s, client: conn}, store, inbound.WithInName("IOS-SHARING"))
			} else {
				s.serveSOCKS(conn)
			}
		}()
	}
}

func (s *sharingServer) close() {
	s.mu.Lock()
	s.closed = true
	connections := make([]net.Conn, 0, len(s.connections))
	for conn := range s.connections {
		connections = append(connections, conn)
	}
	s.mu.Unlock()
	s.cancel()
	for _, l := range s.listeners {
		_ = l.Close()
	}
	for _, c := range connections {
		_ = c.Close()
	}
	s.tasks.Wait()
}

type sharingTunnel struct {
	server *sharingServer
	client net.Conn
}

func (t *sharingTunnel) HandleTCPConn(conn net.Conn, metadata *C.Metadata) {
	s := t.server
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		conn.Close()
		return
	}
	s.tasks.Add(1)
	s.mu.Unlock()
	defer s.tasks.Done()
	_ = t.client.SetDeadline(time.Time{})
	_ = s.session.forwardTCP(s.ctx, conn, metadata, nil)
}
func (t *sharingTunnel) HandleUDPPacket(packet C.UDPPacket, _ *C.Metadata) { packet.Drop() }
func (t *sharingTunnel) NatTable() C.NatTable                              { return nil }

func (s *sharingServer) serveSOCKS(conn net.Conn) {
	if err := s.authenticateSOCKS(conn); err != nil {
		return
	}
	var header [3]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		return
	}
	if header[0] != 5 || header[2] != 0 {
		return
	}
	if header[1] != socks5.CmdConnect {
		_, _ = conn.Write([]byte{5, 7, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	address, err := socks5.ReadAddr(conn, make([]byte, socks5.MaxAddrLen))
	if err != nil {
		_, _ = conn.Write([]byte{5, 8, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	inboundConn, metadata := inbound.NewSocket(address, conn, C.SOCKS5, inbound.WithInName("IOS-SHARING"))
	_ = s.session.forwardTCP(s.ctx, inboundConn, metadata, func(dialError error) error {
		if dialError != nil {
			_, _ = conn.Write([]byte{5, 1, 0, 1, 0, 0, 0, 0, 0, 0})
			return dialError
		}
		_, err := conn.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0})
		if err != nil {
			return err
		}
		return conn.SetDeadline(time.Time{})
	})
}

func (s *sharingServer) authenticateSOCKS(conn net.Conn) error {
	var header [2]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		return err
	}
	if header[0] != 5 || header[1] == 0 {
		return errors.New("invalid SOCKS greeting")
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(conn, methods); err != nil {
		return err
	}
	if !bytes.Contains(methods, []byte{2}) {
		_, _ = conn.Write([]byte{5, 255})
		return errors.New("SOCKS authentication required")
	}
	if _, err := conn.Write([]byte{5, 2}); err != nil {
		return err
	}
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		return err
	}
	if header[0] != 1 || header[1] == 0 {
		return errors.New("invalid SOCKS authentication")
	}
	username := make([]byte, int(header[1]))
	if _, err := io.ReadFull(conn, username); err != nil {
		return err
	}
	var size [1]byte
	if _, err := io.ReadFull(conn, size[:]); err != nil {
		return err
	}
	password := make([]byte, int(size[0]))
	if _, err := io.ReadFull(conn, password); err != nil {
		return err
	}
	if subtle.ConstantTimeCompare(username, []byte(s.config.Username)) != 1 || subtle.ConstantTimeCompare(password, []byte(s.config.Password)) != 1 {
		_, _ = conn.Write([]byte{1, 1})
		s.session.telemetry.addLog("warning", "SOCKS sharing authentication failed")
		return errors.New("authentication failed")
	}
	_, err := conn.Write([]byte{1, 0})
	return err
}
