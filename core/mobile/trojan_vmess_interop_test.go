package mobile

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/listener/sing"
	"github.com/metacubex/mihomo/transport/socks5"
	"github.com/metacubex/mihomo/transport/trojan"
	vmess "github.com/metacubex/sing-vmess"
	"github.com/metacubex/sing/common/buf"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
	"github.com/metacubex/tls"
)

func interopTrojanTLS(t *testing.T) (*tls.Config, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{"localhost"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	privateKey, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	pair, err := tls.X509KeyPair(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateKey}))
	if err != nil {
		t.Fatal(err)
	}
	return &tls.Config{Certificates: []tls.Certificate{pair}, NextProtos: []string{"http/1.1"}, MinVersion: tls.VersionTLS13}, fmt.Sprintf("%x", sha256.Sum256(der))
}

// This transport fixture checks Trojan framing; it is not a third-party server implementation.
func interopTrojanTransport(conn net.Conn, mode string) error {
	var key [trojan.KeyLength]byte
	if _, err := io.ReadFull(conn, key[:]); err != nil {
		return err
	}
	if key != trojan.Key("secret") {
		return errors.New("Trojan fixture authentication rejected")
	}
	separator := make([]byte, 2)
	if _, err := io.ReadFull(conn, separator); err != nil {
		return err
	}
	if string(separator) != "\r\n" {
		return errors.New("invalid Trojan authentication separator")
	}
	command, err := socks5.ReadByte(conn)
	if err != nil {
		return err
	}
	address, err := socks5.ReadAddr0(conn)
	if err != nil {
		return err
	}
	if _, err = io.ReadFull(conn, separator); err != nil {
		return err
	}
	if string(separator) != "\r\n" || address.String() != interopTarget {
		return errors.New("invalid Trojan request target or separator")
	}
	if mode == "tcp" {
		if command != trojan.CommandTCP {
			return errors.New("expected Trojan TCP command")
		}
		return interopEcho(conn, address.String())
	}
	if command != trojan.CommandUDP {
		return errors.New("expected Trojan UDP command")
	}
	packet := trojan.NewPacketConn(conn)
	payload := make([]byte, 1280)
	n, target, err := packet.ReadFrom(payload)
	if err != nil {
		return err
	}
	if target.String() != interopTarget || string(payload[:n]) != "hello" {
		return errors.New("unexpected Trojan UDP target or payload")
	}
	_, err = packet.WriteTo([]byte("proxy:hello"), target)
	return err
}

func TestProtocolInteropTrojanTLSTransport(t *testing.T) {
	for _, mode := range []string{"tcp", "udp", "bad-password", "bad-pin"} {
		t.Run(mode, func(t *testing.T) {
			tlsConfig, pin := interopTrojanTLS(t)
			port, done := interopTCPServer(t, func(raw net.Conn) error {
				conn := tls.Server(raw, tlsConfig)
				defer conn.Close()
				if err := conn.Handshake(); err != nil {
					return err
				}
				if conn.ConnectionState().Version != tls.VersionTLS13 || conn.ConnectionState().NegotiatedProtocol != "http/1.1" {
					return errors.New("unexpected Trojan TLS negotiation")
				}
				return interopTrojanTransport(conn, mode)
			})
			password := "secret"
			if mode == "bad-password" {
				password = "wrong"
			}
			if mode == "bad-pin" {
				pin = strings.Repeat("0", 64)
			}
			session := interopSession(t, fmt.Sprintf("type: trojan, password: %s, udp: true, sni: localhost, alpn: [http/1.1], fingerprint: '%s'", password, pin), port)
			if strings.HasPrefix(mode, "bad-") {
				err := interopRejected(t, session)
				serverErr := <-done
				if mode == "bad-pin" {
					if !strings.Contains(err.Error(), "fingerprints do not match") || serverErr == nil {
						t.Fatalf("expected TLS pin rejection: client=%v server=%v", err, serverErr)
					}
				} else if serverErr == nil || !strings.Contains(serverErr.Error(), "authentication rejected") {
					t.Fatalf("expected Trojan authentication rejection, got %v", serverErr)
				}
			} else {
				interopPackets(t, session, mode == "udp")
				if err := <-done; err != nil {
					t.Fatal(err)
				}
			}
			if err := session.Close(); err != nil {
				t.Fatal(err)
			}
			t.Log("Session.Close completed; TLS transport handler exited")
		})
	}
}

func interopVMessPacket(conn N.PacketConn, metadata M.Metadata) error {
	input := buf.NewPacket()
	defer input.Release()
	target, err := conn.ReadPacket(input)
	if err != nil {
		return err
	}
	if target.String() != interopTarget || metadata.Destination.String() != interopTarget || string(input.Bytes()) != "hello" {
		return errors.New("unexpected VMess UDP target or payload")
	}
	output := buf.NewPacket()
	output.Resize(N.CalculateFrontHeadroom(conn), 0)
	output.Write([]byte("proxy:hello"))
	return conn.WritePacket(output, target)
}

func TestProtocolInteropVMessAEAD(t *testing.T) {
	for _, mode := range []string{"tcp", "udp", "bad-uuid"} {
		t.Run(mode, func(t *testing.T) {
			service := vmess.NewService[string](sing.FnHandler{
				NewConnectionFn: func(_ context.Context, conn net.Conn, metadata M.Metadata) error {
					return interopEcho(conn, metadata.Destination.String())
				},
				NewPacketConnectionFn: func(_ context.Context, conn N.PacketConn, metadata M.Metadata) error {
					return interopVMessPacket(conn, metadata)
				},
			}, vmess.ServiceWithDisableHeaderProtection())
			if err := service.UpdateUsers([]string{"fixture"}, []string{interopUUID}, []int{0}); err != nil {
				t.Fatal(err)
			}
			if err := service.Start(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { service.Close() })
			port, done := interopTCPServer(t, func(conn net.Conn) error { return service.NewConnection(context.Background(), conn, M.Metadata{}) })
			uuid := interopUUID
			if mode == "bad-uuid" {
				uuid = "d7a8ff97-3d03-4a53-a48a-9138a5e4b884"
			}
			session := interopSession(t, "type: vmess, uuid: "+uuid+", alterId: 0, cipher: aes-128-gcm, udp: true", port)
			if mode == "bad-uuid" {
				interopRejected(t, session)
				if err := <-done; !errors.Is(err, vmess.ErrBadRequest) {
					t.Fatalf("expected native VMess UUID rejection, got %v", err)
				}
			} else {
				interopPackets(t, session, mode == "udp")
				if err := <-done; err != nil {
					t.Fatal(err)
				}
			}
			if err := session.Close(); err != nil {
				t.Fatal(err)
			}
			t.Log("Session.Close completed; native VMess service handler exited")
		})
	}
}
