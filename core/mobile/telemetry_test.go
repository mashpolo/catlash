package mobile

import (
	"context"
	"encoding/json"
	C "github.com/metacubex/mihomo/constant"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mihomo/log"
	M "github.com/metacubex/sing/common/metadata"
)

func runtimeSnapshot(t *testing.T, s *Session) runtimeSnapshotData {
	t.Helper()
	text, err := s.RuntimeSnapshotJSON()
	if err != nil {
		t.Fatal(err)
	}
	var value runtimeSnapshotData
	if err = json.Unmarshal([]byte(text), &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func TestRuntimeTCPCountsAndClose(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		conn, e := listener.Accept()
		if e != nil {
			return
		}
		defer conn.Close()
		_, _ = io.Copy(conn, conn)
	}()
	s, err := NewYAMLSession("mode: rule\nrules: ['MATCH,DIRECT']", "{}", 1500)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	client, inbound := net.Pipe()
	defer client.Close()
	handled := make(chan error, 1)
	go func() {
		handled <- (&sessionHandler{session: s}).NewConnection(context.Background(), inbound, M.Metadata{Source: M.ParseSocksaddr("198.18.0.2:41234"), Destination: M.ParseSocksaddr(listener.Addr().String())})
	}()
	_ = client.SetDeadline(time.Now().Add(3 * time.Second))
	payload := []byte("real runtime accounting")
	if _, err = client.Write(payload); err != nil {
		t.Fatal(err)
	}
	data := make([]byte, len(payload))
	if _, err = io.ReadFull(client, data); err != nil {
		t.Fatal(err)
	}
	snapshot := runtimeSnapshot(t, s)
	deadline := time.Now().Add(time.Second)
	for snapshot.DownloadTotal != int64(len(payload)) && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
		snapshot = runtimeSnapshot(t, s)
	}
	if snapshot.UploadTotal != int64(len(payload)) || snapshot.DownloadTotal != int64(len(payload)) || snapshot.ActiveCount != 1 {
		t.Fatalf("bad totals: %+v", snapshot)
	}
	connection := snapshot.Connections[0]
	if connection.Proxy != "DIRECT" || !strings.Contains(strings.ToUpper(connection.Rule), "MATCH") || connection.Network != "tcp" {
		t.Fatalf("missing route: %+v", connection)
	}
	if err = s.CloseConnection(connection.ID); err != nil {
		t.Fatal(err)
	}
	select {
	case <-handled:
	case <-time.After(time.Second):
		t.Fatal("connection did not close")
	}
	select {
	case <-serverDone:
	case <-time.After(time.Second):
		t.Fatal("upstream did not close")
	}
	snapshot = runtimeSnapshot(t, s)
	if snapshot.ActiveCount != 0 || snapshot.Connections[0].EndedAt == 0 {
		t.Fatal("connection remained active")
	}
	if err = s.CloseConnection(connection.ID); err != nil {
		t.Fatal("closing ended connection should be idempotent")
	}
}

func TestRuntimeUDPCountsAndClose(t *testing.T) {
	address := localIPv4(t)
	server, err := net.ListenUDP("udp4", &net.UDPAddr{IP: address.AsSlice()})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	go func() {
		buffer := make([]byte, 128)
		n, source, e := server.ReadFromUDP(buffer)
		if e == nil {
			_, _ = server.WriteToUDP(buffer[:n], source)
		}
	}()
	s, err := NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	data := []byte("udp-count")
	if err = s.WritePacket(udpPacket(address, uint16(server.LocalAddr().(*net.UDPAddr).Port), data)); err != nil {
		t.Fatal(err)
	}
	_ = readWithDeadline(t, s)
	value := runtimeSnapshot(t, s)
	if value.UploadTotal != int64(len(data)) || value.DownloadTotal != int64(len(data)) || value.ActiveCount != 1 {
		t.Fatalf("bad UDP totals: %+v", value)
	}
	if err = s.CloseConnection(value.Connections[0].ID); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for runtimeSnapshot(t, s).ActiveCount != 0 {
		if time.Now().After(deadline) {
			t.Fatal("UDP close timed out")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestRuntimeLogsBoundedAndSessionIsolation(t *testing.T) {
	s, err := NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	first := runtimeSnapshot(t, s).SessionID
	for i := 0; i < 400; i++ {
		s.telemetry.addLog("info", "bounded")
	}
	log.Warnln("runtime-log-test https://user:secret@localhost/?token=hidden")
	deadline := time.Now().Add(time.Second)
	for {
		snapshot := runtimeSnapshot(t, s)
		found := false
		for _, entry := range snapshot.Logs {
			if strings.Contains(entry.Message, "runtime-log-test") {
				found = true
				if strings.Contains(entry.Message, "secret") || strings.Contains(entry.Message, "hidden") {
					t.Fatal("secret in log")
				}
			}
		}
		if found {
			if len(snapshot.Logs) != 200 || snapshot.DroppedLogs == 0 {
				t.Fatal("unbounded logs")
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("Mihomo log not captured")
		}
		time.Sleep(time.Millisecond)
	}
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	s, err = NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	next := runtimeSnapshot(t, s)
	if next.SessionID == first || next.UploadTotal != 0 || next.ActiveCount != 0 || len(next.Connections) != 0 {
		t.Fatal("previous session data leaked")
	}
	if err = s.CloseConnection(first + ":1"); err == nil {
		t.Fatal("accepted foreign ID")
	}
}

func TestRuntimeBoundsAndConcurrentSnapshots(t *testing.T) {
	s, err := NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var group sync.WaitGroup
	group.Go(func() {
		for range 100 {
			runtimeSnapshot(t, s)
		}
	})
	records := make([]*trackedConnection, 300)
	for i := range records {
		records[i] = s.telemetry.begin(&C.Metadata{NetWork: C.TCP}, func() {})
		records[i].countUpload(7)
	}
	snapshot := runtimeSnapshot(t, s)
	if snapshot.ActiveCount != 300 || len(snapshot.Connections) != 128 || snapshot.UploadTotal != 2100 || snapshot.DroppedConnections != 172 {
		t.Fatalf("wrong bounded active snapshot: %+v", snapshot)
	}
	for _, r := range records {
		r.finish(nil)
	}
	for range 300 {
		r := s.telemetry.begin(&C.Metadata{NetWork: C.UDP}, func() {})
		r.countDownload(5)
		r.finish(nil)
	}
	group.Wait()
	snapshot = runtimeSnapshot(t, s)
	if len(snapshot.Connections) != 128 || snapshot.ActiveCount != 0 || snapshot.DownloadTotal != 1500 || snapshot.DroppedConnections != 472 {
		t.Fatalf("wrong bounded history snapshot: %+v", snapshot)
	}
	for range 300 {
		s.telemetry.addLog("info", strings.Repeat("\x01", 4000))
	}
	encoded, err := s.RuntimeSnapshotJSON()
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) > 1_048_576 {
		t.Fatal("snapshot exceeds bridge response limit")
	}
}

func TestRuntimeLogRedaction(t *testing.T) {
	for _, input := range []string{"Authorization: Bearer sensitive-token", "private-key: sensitive-token", "-----BEGIN PRIVATE KEY-----\nsensitive-token\n-----END PRIVATE KEY-----", "https://user:sensitive-token@example.test/"} {
		if got := boundedRuntimeText(input, 1024); strings.Contains(got, "sensitive-token") {
			t.Fatalf("unredacted value: %s", got)
		}
	}
}

func TestRuntimeLogLevelsTimestampsAndClosedSubscription(t *testing.T) {
	session, err := NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	started := time.Now().UnixMilli()
	log.Debugln("level-check-debug")
	log.Infoln("level-check-info")
	log.Warnln("level-check-warning")
	log.Errorln("level-check-error")
	expected := map[string]string{
		"level-check-debug": "debug", "level-check-info": "info",
		"level-check-warning": "warning", "level-check-error": "error",
	}
	deadline := time.Now().Add(time.Second)
	for {
		snapshot := runtimeSnapshot(t, session)
		found := 0
		var previousID, previousTime int64
		for _, entry := range snapshot.Logs {
			if level, ok := expected[entry.Message]; ok {
				found++
				if entry.Level != level || entry.Time < started || entry.Time > snapshot.SampledAt || entry.ID <= previousID || entry.Time < previousTime {
					t.Fatalf("invalid captured log metadata: %+v", entry)
				}
				previousID, previousTime = entry.ID, entry.Time
			}
		}
		if found == len(expected) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("captured %d of %d levels", found, len(expected))
		}
		time.Sleep(time.Millisecond)
	}
	if err := session.Close(); err != nil {
		t.Fatal(err)
	}
	closed := runtimeSnapshot(t, session)
	next, err := NewSession(1500)
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	log.Infoln("after-closed-subscription")
	deadline = time.Now().Add(time.Second)
	for {
		snapshot := runtimeSnapshot(t, next)
		found := false
		for _, entry := range snapshot.Logs {
			if _, old := expected[entry.Message]; old {
				t.Fatal("previous logs entered new session")
			}
			if entry.Message == "after-closed-subscription" {
				found = true
			}
		}
		if found {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("new session did not receive logs")
		}
		time.Sleep(time.Millisecond)
	}
	if frozen := runtimeSnapshot(t, session); len(frozen.Logs) != len(closed.Logs) || frozen.DroppedLogs != closed.DroppedLogs {
		t.Fatal("closed session continued collecting logs")
	}
}
