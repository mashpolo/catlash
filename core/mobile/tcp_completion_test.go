package mobile

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/sing/common/bufio"
)

type h2CompletionConn struct {
	writer        *io.PipeWriter
	body          io.ReadCloser
	responseError error
	ready         chan struct{}
	secondRead    chan struct{}
	readCount     atomic.Int32
	readError     chan error
}

type uploadTimeoutConn struct{ net.Conn }

func (c uploadTimeoutConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if err == io.EOF {
		return n, os.ErrDeadlineExceeded
	}
	return n, err
}

func (c *h2CompletionConn) Read(p []byte) (int, error) {
	if c.readCount.Add(1) == 2 {
		close(c.secondRead)
	}
	<-c.ready
	if c.responseError != nil {
		return 0, c.responseError
	}
	n, err := c.body.Read(p)
	if err != nil {
		select {
		case c.readError <- err:
		default:
		}
	}
	return n, err
}
func (c *h2CompletionConn) Write(p []byte) (int, error) { return c.writer.Write(p) }
func (c *h2CompletionConn) Close() error {
	c.writer.Close()
	<-c.ready
	if c.body != nil {
		return c.body.Close()
	}
	return nil
}
func (c *h2CompletionConn) LocalAddr() net.Addr              { return &net.TCPAddr{} }
func (c *h2CompletionConn) RemoteAddr() net.Addr             { return &net.TCPAddr{} }
func (c *h2CompletionConn) SetDeadline(time.Time) error      { return nil }
func (c *h2CompletionConn) SetReadDeadline(time.Time) error  { return nil }
func (c *h2CompletionConn) SetWriteDeadline(time.Time) error { return nil }

func newH2CompletionConn(t *testing.T, ctx context.Context, payload []byte, truncated bool) *h2CompletionConn {
	t.Helper()
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		request := make([]byte, len(payload))
		if _, err := io.ReadFull(r.Body, request); err != nil {
			return
		}
		if string(request) != string(payload) {
			t.Error("HTTP/2 server received incorrect upload")
			return
		}
		if r.ProtoMajor != 2 {
			t.Error("fixture did not negotiate HTTP/2")
			return
		}
		if truncated {
			w.Header().Set("Content-Length", fmt.Sprint(len(payload)+10))
		}
		w.Write(request)
		w.(http.Flusher).Flush()
		if !truncated {
			<-r.Context().Done()
		}
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	t.Cleanup(server.Close)
	body, writer := io.Pipe()
	conn := &h2CompletionConn{writer: writer, ready: make(chan struct{}), secondRead: make(chan struct{}), readError: make(chan error, 2)}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, server.URL, body)
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		response, err := server.Client().Do(request)
		conn.responseError = err
		if response != nil {
			conn.body = response.Body
		}
		close(conn.ready)
	}()
	return conn
}

func runH2Completion(t *testing.T, ending string) (runtimeConnection, error, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	payload := []byte("completed HTTP/2 payload")
	outbound := newH2CompletionConn(t, ctx, payload, ending == "truncated")
	defer outbound.Close()
	client, inbound := net.Pipe()
	defer client.Close()
	tracked := newRuntimeTelemetry()
	defer tracked.stopLogs()
	connection := tracked.begin(&C.Metadata{NetWork: C.TCP}, cancel)
	if ending == "upload-timeout" {
		inbound = uploadTimeoutConn{inbound}
	}
	result := make(chan error, 1)
	go func() {
		err := bufio.CopyConn(ctx, &runtimeCountedConn{Conn: inbound, count: connection.countDownload}, &runtimeCountedConn{Conn: outbound, count: connection.countUpload})
		connection.finish(err)
		result <- err
	}()
	client.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := client.Write(payload); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, len(payload))
	if _, err := io.ReadFull(client, response); err != nil || string(response) != string(payload) {
		t.Fatalf("response %q: %v", response, err)
	}
	select {
	case <-outbound.secondRead:
	case <-time.After(time.Second):
		t.Fatal("download did not wait for further data")
	}
	switch ending {
	case "normal", "upload-timeout":
		client.Close()
	case "external":
		outbound.body.Close()
	}
	var copyError error
	select {
	case copyError = <-result:
	case <-time.After(time.Second):
		t.Fatal("relay did not finish")
	}
	var readError error
	select {
	case readError = <-outbound.readError:
	case <-time.After(time.Second):
		t.Fatal("no terminal HTTP/2 read")
	}
	tracked.mu.Lock()
	defer tracked.mu.Unlock()
	if tracked.activeCount != 0 || len(tracked.history) != 1 {
		t.Fatal("missing completed connection")
	}
	value := tracked.history[0]
	if value.Upload != int64(len(payload)) || value.Download != int64(len(payload)) {
		t.Fatalf("lost counts: %+v", value)
	}
	return value, copyError, readError
}

func TestRuntimeLocalHTTP2BodyCloseIsNormalCompletion(t *testing.T) {
	value, copyError, readError := runH2Completion(t, "normal")
	if readError == nil || readError.Error() != "http2: response body closed" {
		t.Fatalf("did not reproduce actual HTTP/2 close: %v", readError)
	}
	if copyError != nil || value.Error != "" {
		t.Fatalf("successful relay marked failed: %v / %s", copyError, value.Error)
	}
}

func TestRuntimeUnownedHTTP2BodyCloseRemainsFailure(t *testing.T) {
	value, copyError, _ := runH2Completion(t, "external")
	if copyError == nil || !strings.Contains(value.Error, "response body closed") {
		t.Fatalf("unowned close hidden: %v / %s", copyError, value.Error)
	}
}

func TestRuntimeTruncatedHTTP2ResponseRemainsFailure(t *testing.T) {
	value, copyError, _ := runH2Completion(t, "truncated")
	if copyError == nil || !strings.Contains(value.Error, "unexpected EOF") {
		t.Fatalf("truncated response hidden: %v / %s", copyError, value.Error)
	}
}

func TestRuntimeUploadTimeoutWithHTTP2CleanupRemainsFailure(t *testing.T) {
	value, copyError, readError := runH2Completion(t, "upload-timeout")
	if readError == nil || readError.Error() != "http2: response body closed" {
		t.Fatalf("did not reproduce HTTP/2 cleanup: %v", readError)
	}
	if !errors.Is(copyError, os.ErrDeadlineExceeded) || !strings.Contains(value.Error, os.ErrDeadlineExceeded.Error()) {
		t.Fatalf("upload timeout hidden by download cleanup: %v / %s", copyError, value.Error)
	}
}
