package mobile

import (
	"context"
	"net"
	"testing"
	"time"

	M "github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"
)

func TestDNSResolverCloseWaitsForPendingExchange(t *testing.T) {
	for _, callerTimeout := range []time.Duration{time.Minute, 20 * time.Millisecond} {
		t.Run(callerTimeout.String(), func(t *testing.T) {
			socket, err := net.ListenPacket("udp4", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer socket.Close()
			received := make(chan struct{}, 8)
			readerDone := make(chan struct{})
			go func() {
				defer close(readerDone)
				buffer := make([]byte, 4096)
				for {
					if _, _, err := socket.ReadFrom(buffer); err != nil {
						return
					}
					received <- struct{}{}
				}
			}()
			scope := M.NewSessionScope(context.Background())
			resolvers := M.NewResolver(M.Config{Context: scope.Context(), Main: []M.NameServer{{Addr: socket.LocalAddr().String()}}, Default: []M.NameServer{{Addr: socket.LocalAddr().String()}}})
			defer resolvers.Close()
			result := make(chan error, 1)
			ctx, cancel := context.WithTimeout(context.Background(), callerTimeout)
			defer cancel()
			go func() {
				request := new(D.Msg)
				request.SetQuestion("pending.invalid.", D.TypeA)
				_, err := resolvers.ExchangeContext(ctx, request)
				result <- err
			}()
			select {
			case <-received:
			case err := <-result:
				t.Fatalf("DNS query returned before reaching fixture: %v", err)
			case <-time.After(time.Second):
				t.Fatal("DNS request did not reach fixture")
			}
			if callerTimeout < time.Second {
				select {
				case <-result:
				case <-time.After(time.Second):
					t.Fatal("caller timeout did not return")
				}
			}
			closed := make(chan struct{})
			go func() { resolvers.Close(); close(closed) }()
			select {
			case <-closed:
			case <-time.After(time.Second):
				t.Fatal("DNS Close left pending work")
			}
			if callerTimeout > time.Second {
				select {
				case err := <-result:
					if err == nil {
						t.Fatal("cancelled DNS succeeded")
					}
				case <-time.After(time.Second):
					t.Fatal("DNS request remains blocked")
				}
			}
			request := new(D.Msg)
			request.SetQuestion("after-close.invalid.", D.TypeA)
			if _, err := resolvers.ExchangeContext(context.Background(), request); err == nil {
				t.Fatal("closed resolver accepted new query")
			}
			socket.Close()
			<-readerDone
		})
	}
}
