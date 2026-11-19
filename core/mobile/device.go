package mobile

import (
	"encoding/binary"
	"errors"
	"io"
	"os"
	"sync"
	"sync/atomic"
)

const packetQueueSize = 64

var errQueueFull = errors.New("packet queue is full")

type invalidPacketError string

func (e invalidPacketError) Error() string { return string(e) }

type packetDevice struct {
	inputQueueDrops   atomic.Int64
	outputQueueDrops  atomic.Int64
	invalidInputDrops atomic.Int64
	mtu               int
	input             chan []byte
	output            chan []byte
	done              chan struct{}
	mu                sync.Mutex
	closed            bool
}

func newPacketDevice(mtu int) *packetDevice {
	return &packetDevice{
		mtu:    mtu,
		input:  make(chan []byte, packetQueueSize),
		output: make(chan []byte, packetQueueSize),
		done:   make(chan struct{}),
	}
}

func (d *packetDevice) inject(packet []byte) error {
	return d.enqueue(d.input, packet)
}

func (d *packetDevice) enqueue(queue chan []byte, packet []byte) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return os.ErrClosed
	}
	if queue == d.input {
		if err := validatePacket(packet, d.mtu); err != nil {
			d.invalidInputDrops.Add(1)
			return err
		}
	}
	// Producers hold the same lock. Consumers can only make more room.
	if len(queue) == cap(queue) {
		if queue == d.input {
			d.inputQueueDrops.Add(1)
		} else {
			d.outputQueueDrops.Add(1)
		}
		return errQueueFull
	}
	queue <- append([]byte(nil), packet...)
	return nil
}

func (d *packetDevice) dequeue(queue chan []byte) ([]byte, error) {
	select {
	case <-d.done:
		return nil, io.EOF
	case packet := <-queue:
		select {
		case <-d.done:
			return nil, io.EOF
		default:
			return packet, nil
		}
	}
}

func (d *packetDevice) Read(buffer []byte) (int, error) {
	packet, err := d.dequeue(d.input)
	if err != nil {
		return 0, err
	}
	if len(buffer) < len(packet) {
		return 0, io.ErrShortBuffer
	}
	return copy(buffer, packet), nil
}

func (d *packetDevice) Write(packet []byte) (int, error) {
	// A full link queue consumes and drops this datagram. The stack can keep
	// serving existing and subsequent flows after congestion clears.
	if err := d.enqueue(d.output, packet); err != nil && err != errQueueFull {
		return 0, err
	}
	return len(packet), nil
}

func (d *packetDevice) receive() ([]byte, error) {
	return d.dequeue(d.output)
}

func (d *packetDevice) Close() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return nil
	}
	d.closed = true
	close(d.done)
	drainPackets(d.input)
	drainPackets(d.output)
	return nil
}

func drainPackets(queue chan []byte) {
	for {
		select {
		case <-queue:
		default:
			return
		}
	}
}

func validatePacket(packet []byte, mtu int) error {
	if len(packet) == 0 || len(packet) > mtu {
		return invalidPacketError("packet length is outside the MTU")
	}
	switch packet[0] >> 4 {
	case 4:
		if len(packet) < 20 || int(packet[0]&0xf)*4 < 20 || int(packet[0]&0xf)*4 > len(packet) || int(binary.BigEndian.Uint16(packet[2:4])) != len(packet) {
			return invalidPacketError("invalid IPv4 packet length")
		}
	case 6:
		if len(packet) < 40 || int(binary.BigEndian.Uint16(packet[4:6]))+40 != len(packet) {
			return invalidPacketError("invalid IPv6 packet length")
		}
	default:
		return invalidPacketError("packet is not IPv4 or IPv6")
	}
	return nil
}
