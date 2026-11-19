package mobile

import (
	"context"
	"errors"
	"runtime"
	"testing"
	"time"
)

func preparationOwnedBuffer(released chan struct{}) []byte {
	buffer := new([1 << 20]byte)
	runtime.SetFinalizer(buffer, func(*[1 << 20]byte) { close(released) })
	return buffer[:]
}

func TestCancelledPreparationReleasesDataWhileBridgeRetainsHandle(t *testing.T) {
	p, err := NewYAMLResourcePreparation("rules: ['MATCH,DIRECT']", "{}", "", "", 1280)
	if err != nil {
		t.Fatal(err)
	}
	released := make(chan struct{})
	p.resources[resourceKey{"proxy-file", "unused"}] = preparationOwnedBuffer(released)
	p.Cancel()
	if err = p.Prepare(); !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation was lost", err)
	}
	deadline := time.After(time.Second)
	for {
		runtime.GC()
		select {
		case <-released:
			runtime.KeepAlive(p)
			return
		case <-deadline:
			runtime.KeepAlive(p)
			t.Fatal("cancelled preparation retains large resource data")
		case <-time.After(10 * time.Millisecond):
		}
	}
}
