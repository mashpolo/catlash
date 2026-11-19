package mobile

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"regexp"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	N "github.com/metacubex/sing/common/network"
)

const runtimeConnectionLimit = 128
const runtimeLogLimit = 200

type runtimeConnection struct {
	ID          string `json:"id"`
	Network     string `json:"network"`
	Source      string `json:"source"`
	Destination string `json:"destination"`
	Host        string `json:"host"`
	Rule        string `json:"rule"`
	Proxy       string `json:"proxy"`
	StartedAt   int64  `json:"startedAt"`
	EndedAt     int64  `json:"endedAt"`
	Upload      int64  `json:"upload"`
	Download    int64  `json:"download"`
	Error       string `json:"error"`
}

type runtimeLog struct {
	ID      int64  `json:"id"`
	Time    int64  `json:"time"`
	Level   string `json:"level"`
	Message string `json:"message"`
}

type runtimeSnapshotData struct {
	InputQueueDrops    int64               `json:"inputQueueDrops"`
	OutputQueueDrops   int64               `json:"outputQueueDrops"`
	InvalidInputDrops  int64               `json:"invalidInputDrops"`
	SessionID          string              `json:"sessionID"`
	SampledAt          int64               `json:"sampledAt"`
	UploadTotal        int64               `json:"uploadTotal"`
	DownloadTotal      int64               `json:"downloadTotal"`
	ActiveCount        int                 `json:"activeCount"`
	Connections        []runtimeConnection `json:"connections"`
	Logs               []runtimeLog        `json:"logs"`
	DroppedConnections int64               `json:"droppedConnections"`
	DroppedLogs        int64               `json:"droppedLogs"`
	DNSQueries         []runtimeDNSQuery   `json:"dnsQueries"`
	DroppedDNSQueries  int64               `json:"droppedDNSQueries"`
}

type trackedConnection struct {
	owner  *runtimeTelemetry
	value  runtimeConnection
	cancel context.CancelFunc
}

type runtimeTelemetry struct {
	mu                              sync.Mutex
	sessionID                       string
	nextID                          int64
	nextLogID                       int64
	upload, download                int64
	activeCount                     int
	active                          map[string]*trackedConnection
	cancellations                   map[string]context.CancelFunc
	history                         []runtimeConnection
	logs                            []runtimeLog
	dnsQueries                      []runtimeDNSQuery
	nextDNSID, droppedDNSQueries    int64
	droppedConnections, droppedLogs int64
	stopLogs                        func()
}

func newRuntimeTelemetry() *runtimeTelemetry {
	t := &runtimeTelemetry{sessionID: rand.Text(), active: make(map[string]*trackedConnection), cancellations: make(map[string]context.CancelFunc)}
	subscription := log.Subscribe()
	done := make(chan struct{})
	go func() {
		defer close(done)
		for event := range subscription {
			t.addLog(event.Type(), event.Payload)
		}
	}()
	t.stopLogs = func() { log.UnSubscribe(subscription); <-done }
	t.addLog("info", "Packet session starting")
	return t
}

func (t *runtimeTelemetry) begin(metadata *C.Metadata, cancel context.CancelFunc) *trackedConnection {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.nextID++
	c := &trackedConnection{owner: t, cancel: cancel, value: runtimeConnection{
		ID: fmt.Sprintf("%s:%d", t.sessionID, t.nextID), Network: strings.ToLower(metadata.NetWork.String()),
		Source: boundedRuntimeText(metadata.SourceAddress(), 256), Destination: boundedRuntimeText(metadata.RemoteAddress(), 256),
		Host: boundedRuntimeText(metadata.Host, 256), StartedAt: time.Now().UnixMilli(),
	}}
	t.activeCount++
	t.cancellations[c.value.ID] = cancel
	if len(t.active) < runtimeConnectionLimit {
		t.active[c.value.ID] = c
	} else {
		t.droppedConnections++
	}
	return c
}

func (c *trackedConnection) routed(metadata *C.Metadata, proxy, rule string) {
	t := c.owner
	t.mu.Lock()
	defer t.mu.Unlock()
	c.value.Host = boundedRuntimeText(metadata.RuleHost(), 256)
	c.value.Destination = boundedRuntimeText(metadata.RemoteAddress(), 256)
	c.value.Proxy = boundedRuntimeText(proxy, 256)
	c.value.Rule = boundedRuntimeText(rule, 256)
	t.appendLogLocked("info", fmt.Sprintf("%s %s → %s via %s [%s]", c.value.Network, c.value.Source, c.value.Destination, c.value.Proxy, c.value.Rule))
}

func (c *trackedConnection) countUpload(n int64) {
	t := c.owner
	t.mu.Lock()
	c.value.Upload += n
	t.upload += n
	t.mu.Unlock()
}
func (c *trackedConnection) countDownload(n int64) {
	t := c.owner
	t.mu.Lock()
	c.value.Download += n
	t.download += n
	t.mu.Unlock()
}

func (c *trackedConnection) finish(err error) {
	t := c.owner
	t.mu.Lock()
	defer t.mu.Unlock()
	c.value.EndedAt = time.Now().UnixMilli()
	if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, net.ErrClosed) && !errors.Is(err, io.EOF) {
		c.value.Error = boundedRuntimeText(err.Error(), 512)
		t.appendLogLocked("warning", fmt.Sprintf("%s %s: %s", c.value.Network, c.value.Destination, c.value.Error))
	}
	t.activeCount--
	delete(t.cancellations, c.value.ID)
	if _, ok := t.active[c.value.ID]; ok {
		delete(t.active, c.value.ID)
		if len(t.history) == runtimeConnectionLimit {
			copy(t.history, t.history[1:])
			t.history = t.history[:len(t.history)-1]
			t.droppedConnections++
		}
		t.history = append(t.history, c.value)
	}
}

func (t *runtimeTelemetry) addLog(level, message string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.appendLogLocked(level, message)
}
func (t *runtimeTelemetry) appendLogLocked(level, message string) {
	t.nextLogID++
	if len(t.logs) == runtimeLogLimit {
		copy(t.logs, t.logs[1:])
		t.logs = t.logs[:len(t.logs)-1]
		t.droppedLogs++
	}
	t.logs = append(t.logs, runtimeLog{ID: t.nextLogID, Time: time.Now().UnixMilli(), Level: strings.ToLower(level), Message: boundedRuntimeText(message, 1024)})
}

var runtimeURLCredentials = regexp.MustCompile(`(?i)([a-z][a-z0-9+.-]*://)[^\s/@]+@`)
var runtimeAuthorization = regexp.MustCompile(`(?i)(authorization["']?\s*[:=]\s*)[^\r\n]+`)
var runtimePrivateKey = regexp.MustCompile(`(?s)-----BEGIN[^-]*PRIVATE KEY-----.*?-----END[^-]*PRIVATE KEY-----`)
var runtimeSecrets = regexp.MustCompile(`(?i)((?:password|passwd|token|secret|authorization|private-key|uuid)["']?\s*[:=]\s*["']?)[^\s,;"'&]+`)

func boundedRuntimeText(value string, limit int) string {
	value = runtimePrivateKey.ReplaceAllString(value, "[redacted private key]")
	value = runtimeAuthorization.ReplaceAllString(value, "${1}[redacted]")
	value = runtimeURLCredentials.ReplaceAllString(value, "${1}[redacted]@")
	value = runtimeSecrets.ReplaceAllString(value, "${1}[redacted]")
	if len(value) > limit {
		value = string([]byte(value)[:limit]) + "…"
	}
	return strings.ToValidUTF8(value, "�")
}

func (s *Session) RuntimeSnapshotJSON() (string, error) {
	t := s.telemetry
	t.mu.Lock()
	snapshot := runtimeSnapshotData{SessionID: t.sessionID, SampledAt: time.Now().UnixMilli(), UploadTotal: t.upload, DownloadTotal: t.download, ActiveCount: t.activeCount, Connections: make([]runtimeConnection, 0, len(t.active)+len(t.history)), Logs: append([]runtimeLog{}, t.logs...), DroppedConnections: t.droppedConnections, DroppedLogs: t.droppedLogs}
	if d := s.device; d != nil {
		snapshot.InputQueueDrops = d.inputQueueDrops.Load()
		snapshot.OutputQueueDrops = d.outputQueueDrops.Load()
		snapshot.InvalidInputDrops = d.invalidInputDrops.Load()
	}
	snapshot.DNSQueries = append([]runtimeDNSQuery{}, t.dnsQueries...)
	snapshot.DroppedDNSQueries = t.droppedDNSQueries
	for _, c := range t.active {
		snapshot.Connections = append(snapshot.Connections, c.value)
	}
	snapshot.Connections = append(snapshot.Connections, t.history...)
	t.mu.Unlock()
	sort.Slice(snapshot.Connections, func(i, j int) bool { return snapshot.Connections[i].StartedAt > snapshot.Connections[j].StartedAt })
	data, err := json.Marshal(snapshot)
	for err == nil && len(data) > 900_000 {
		if len(snapshot.Logs) > 0 {
			n := (len(snapshot.Logs) + 1) / 2
			snapshot.Logs = snapshot.Logs[n:]
			snapshot.DroppedLogs += int64(n)
		} else if len(snapshot.Connections) > 0 {
			n := (len(snapshot.Connections) + 1) / 2
			snapshot.Connections = snapshot.Connections[:len(snapshot.Connections)-n]
			snapshot.DroppedConnections += int64(n)
		} else {
			n := (len(snapshot.DNSQueries) + 1) / 2
			snapshot.DNSQueries = snapshot.DNSQueries[n:]
			snapshot.DroppedDNSQueries += int64(n)
		}
		data, err = json.Marshal(snapshot)
	}
	return string(data), err
}

func (s *Session) CloseConnection(id string) error {
	t := s.telemetry
	t.mu.Lock()
	c := t.active[id]
	if c == nil {
		for _, old := range t.history {
			if old.ID == id {
				t.mu.Unlock()
				return nil
			}
		}
		t.mu.Unlock()
		return errors.New("connection is no longer available")
	}
	cancel := c.cancel
	t.mu.Unlock()
	cancel()
	t.addLog("info", "Connection closed by user: "+id)
	return nil
}

func (s *Session) CloseAllConnections(expectedSessionID string) error {
	s.mu.Lock()
	if s.closed || s.telemetry.sessionID != expectedSessionID {
		s.mu.Unlock()
		return errors.New("the packet session is no longer current")
	}
	s.tasks.Add(1)
	s.mu.Unlock()
	defer s.tasks.Done()
	t := s.telemetry
	t.mu.Lock()
	cancels := make([]context.CancelFunc, 0, len(t.cancellations))
	for _, cancel := range t.cancellations {
		cancels = append(cancels, cancel)
	}
	t.mu.Unlock()
	for _, cancel := range cancels {
		cancel()
	}
	t.addLog("info", fmt.Sprintf("User requested closing %d active connections", len(cancels)))
	return nil
}

type runtimeCountedConn struct {
	net.Conn
	count  N.CountFunc
	closed atomic.Bool
}

func (c *runtimeCountedConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	// CopyConn closes transports without CloseWrite when upload ends normally.
	if err != nil && c.closed.Load() && err.Error() == "http2: response body closed" {
		return n, io.EOF
	}
	return n, err
}

func (c *runtimeCountedConn) Close() error {
	c.closed.Store(true)
	return c.Conn.Close()
}

func (c *runtimeCountedConn) UnwrapWriter() (io.Writer, []N.CountFunc) {
	return c.Conn, []N.CountFunc{c.count}
}
func (c *runtimeCountedConn) Upstream() any { return c.Conn }

func (s *Session) routeWithRule(metadata *C.Metadata) (C.Proxy, string, error) {
	if s.routing != nil {
		return s.routing.routeWithRule(metadata)
	}
	return s.proxy, "direct", nil
}
