package mobile

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"testing"
	"time"
)

func TestPacketFlowFullQueuesRecover(t *testing.T) {
	// Pause the consumer at each boundary so both queues fill deterministically.
	d := newPacketDevice(1280)
	defer d.Close()
	s := &Session{device: d}
	packet := echoPacket()
	for range packetQueueSize + 1 {
		if err := s.SubmitPacket(packet); err != nil {
			t.Fatal("input pressure stopped the flow", err)
		}
		if n, err := d.Write(packet); n != len(packet) || err != nil {
			t.Fatal("output pressure stopped the stack", n, err)
		}
	}
	if d.inputQueueDrops.Load() != 1 || d.outputQueueDrops.Load() != 1 {
		t.Fatal("overflow missing from counters")
	}
	buffer := make([]byte, 1280)
	for range packetQueueSize {
		if _, err := d.Read(buffer); err != nil {
			t.Fatal(err)
		}
		if _, err := s.ReadPacket(); err != nil {
			t.Fatal(err)
		}
	}
	if len(d.input) != 0 || len(d.output) != 0 {
		t.Fatal("queue exceeded its bound")
	}
	packet[29]++
	if err := s.SubmitPacket(packet); err != nil {
		t.Fatal(err)
	}
	if n, err := d.Read(buffer); err != nil || !bytes.Equal(buffer[:n], packet) {
		t.Fatal("input did not recover", n, err)
	}
	if _, err := d.Write(packet); err != nil {
		t.Fatal(err)
	}
	if got, err := s.ReadPacket(); err != nil || !bytes.Equal(got, packet) {
		t.Fatal("output did not recover", err)
	}
}

func TestPacketFlowDropsInvalidPacketsAndHonorsClose(t *testing.T) {
	s, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, packet := range [][]byte{nil, {0x45, 0x00}, make([]byte, 1281)} {
		if err = s.SubmitPacket(packet); err != nil {
			t.Fatal("single invalid input stopped the flow", err)
		}
	}
	if stats := runtimeSnapshot(t, s); stats.InvalidInputDrops != 3 {
		t.Fatal("missing input drop count", stats.InvalidInputDrops)
	}
	if err = s.SubmitPacket(echoPacket()); err != nil {
		t.Fatal(err)
	}
	if got := readWithDeadline(t, s); got[20] != 0 {
		t.Fatal("valid echo did not reach stack")
	}
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	for _, packet := range [][]byte{nil, echoPacket()} {
		if err = s.SubmitPacket(packet); !errors.Is(err, os.ErrClosed) {
			t.Fatal("write after close", err)
		}
	}
	if _, err = s.ReadPacket(); !errors.Is(err, io.EOF) {
		t.Fatal("read after close", err)
	}
	if _, err = s.device.Write(echoPacket()); !errors.Is(err, os.ErrClosed) {
		t.Fatal("stack write after close", err)
	}
}

func TestPacketFlowBurstStillReturnsFreshStackReply(t *testing.T) {
	s, err := NewSession(1280)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	p := echoPacket()
	for range packetQueueSize * 16 {
		if err = s.SubmitPacket(p); err != nil {
			t.Fatal("burst interrupted session", err)
		}
	}
	fresh := echoPacket()
	copy(fresh[28:], "resume")
	fresh[22], fresh[23] = 0, 0
	binary.BigEndian.PutUint16(fresh[22:], checksum(fresh[20:]))
	recovered := make(chan bool, 1)
	go func() {
		for {
			got, err := s.ReadPacket()
			if err != nil {
				recovered <- false
				return
			}
			if len(got) == len(fresh) && got[20] == 0 && bytes.Equal(got[28:], fresh[28:]) {
				recovered <- true
				return
			}
		}
	}()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	deadline := time.After(3 * time.Second)
	for {
		if err = s.SubmitPacket(fresh); err != nil {
			t.Fatal(err)
		}
		select {
		case ok := <-recovered:
			if !ok {
				t.Fatal("reader ended before fresh reply")
			}
			return
		case <-tick.C:
		case <-deadline:
			t.Fatal("stack stopped responding after queue pressure")
		}
	}
}
