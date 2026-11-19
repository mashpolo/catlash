package mobile

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	M "github.com/metacubex/sing/common/metadata"
)

// The old flow must continue to pass traffic even when the new rule would reject it.
func TestHotRuleUpdatePreservesEstablishedTCPDuringAndAfterDownload(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		select {
		case <-release:
			fmt.Fprintln(w, "127.0.0.1/32")
		case <-r.Context().Done():
		}
	}))
	defer source.Close()
	bundle := bundleFixture(t, "rule-provider", "ips", []byte("192.0.2.0/24\n"))
	config := fmt.Sprintf("rule-providers: {ips: {type: http, behavior: ipcidr, format: text, url: '%s'}}\nrules: ['RULE-SET,ips,REJECT','MATCH,DIRECT']", source.URL)
	s, err := NewYAMLSessionWithStorage(config, "{}", bundle, "", 1500)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		if conn, err := listener.Accept(); err == nil {
			defer conn.Close()
			_, _ = io.Copy(conn, conn)
		}
	}()
	client, inbound := net.Pipe()
	defer client.Close()
	go func() {
		_ = (&sessionHandler{session: s}).NewConnection(s.ctx, inbound, M.Metadata{Destination: M.ParseSocksaddr(listener.Addr().String())})
	}()
	echo := func(message string) {
		t.Helper()
		client.SetDeadline(time.Now().Add(3 * time.Second))
		if _, err := io.WriteString(client, message); err != nil {
			t.Fatal(err)
		}
		response := make([]byte, len(message))
		if _, err := io.ReadFull(client, response); err != nil || string(response) != message {
			t.Fatalf("TCP echo: %q, %v", response, err)
		}
	}
	echo("before")
	p, err := s.NewProviderUpdate(config, bundle, "", "rule-provider", "ips")
	if err != nil {
		t.Fatal(err)
	}
	defer p.Cancel()
	done := make(chan error, 1)
	go func() { done <- p.UpdateProvider() }()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("provider download did not start")
	}
	echo("during")
	close(release)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("update did not finish")
	}
	next, err := s.route(&C.Metadata{NetWork: C.TCP, DstIP: netip.MustParseAddr("127.0.0.1"), DstPort: 443})
	if err != nil || next.Name() != "REJECT" {
		t.Fatalf("new connections should be rejected: %v %v", next, err)
	}
	echo("after")
}
