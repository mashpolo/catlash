package mobile

import (
	"context"
	"io"
	"net"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	M "github.com/metacubex/sing/common/metadata"
)

func TestRuntimeCloseAllIncludesUndisplayedConnectionsAndRejectsStaleSession(t *testing.T) {
	s, err := NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	contexts := make([]context.Context, 300)
	records := make([]*trackedConnection, 300)
	for i := range contexts {
		var cancel context.CancelFunc
		contexts[i], cancel = context.WithCancel(context.Background())
		records[i] = s.telemetry.begin(&C.Metadata{NetWork: C.TCP}, cancel)
	}
	if err := s.CloseAllConnections("foreign"); err == nil {
		t.Fatal("foreign session accepted")
	}
	for _, ctx := range contexts {
		if ctx.Err() != nil {
			t.Fatal("foreign command closed a connection")
		}
	}
	if err := s.CloseAllConnections(s.telemetry.sessionID); err != nil {
		t.Fatal(err)
	}
	for i, ctx := range contexts {
		if ctx.Err() == nil {
			t.Fatalf("connection %d survived close all", i)
		}
		records[i].finish(nil)
	}
	next, cancel := context.WithCancel(context.Background())
	defer cancel()
	current := s.telemetry.begin(&C.Metadata{NetWork: C.UDP}, cancel)
	defer current.finish(nil)
	if next.Err() != nil {
		t.Fatal("new connection inherited previous close all")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if err := s.CloseAllConnections(s.telemetry.sessionID); err == nil {
		t.Fatal("closed session accepted close all")
	}
}

func TestRuntimeCloseAllClosesActualTCPTransports(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	serverDone := make(chan struct{}, 2)
	go func() {
		for range 2 {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() { defer func() { _ = conn.Close(); serverDone <- struct{}{} }(); _, _ = io.Copy(conn, conn) }()
		}
	}()
	s, err := NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	handled := make(chan error, 2)
	for range 2 {
		client, inbound := net.Pipe()
		defer client.Close()
		go func() {
			handled <- (&sessionHandler{session: s}).NewConnection(context.Background(), inbound, M.Metadata{Destination: M.ParseSocksaddr(listener.Addr().String())})
		}()
		_ = client.SetDeadline(time.Now().Add(time.Second))
		if _, err := client.Write([]byte("ok")); err != nil {
			t.Fatal(err)
		}
		if _, err := io.ReadFull(client, make([]byte, 2)); err != nil {
			t.Fatal(err)
		}
	}
	state := runtimeSnapshot(t, s)
	if state.ActiveCount != 2 {
		t.Fatal("fixture did not establish two connections")
	}
	if err := s.CloseAllConnections(state.SessionID); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		select {
		case <-handled:
		case <-time.After(time.Second):
			t.Fatal("TCP handler survived")
		}
		select {
		case <-serverDone:
		case <-time.After(time.Second):
			t.Fatal("upstream did not observe close")
		}
	}
	if runtimeSnapshot(t, s).ActiveCount != 0 {
		t.Fatal("runtime remained active")
	}
}
