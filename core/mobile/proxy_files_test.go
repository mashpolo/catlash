package mobile

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"strings"
	"testing"
	"time"
)

func proxyPEMFixture(t *testing.T) []byte {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	key, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "fixture.invalid"}, NotBefore: time.Unix(0, 0), NotAfter: time.Unix(2000000000, 0), KeyUsage: x509.KeyUsageDigitalSignature}
	certificate, err := x509.CreateCertificate(rand.Reader, template, template, public, private)
	if err != nil {
		t.Fatal(err)
	}
	return append(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key}), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificate})...)
}

func TestProxyFileSnapshotResolvesTLSAndSSHWithoutOriginalPath(t *testing.T) {
	root := bundleFixture(t, "proxy-file", "/never/read/client.pem", proxyPEMFixture(t))
	config := "proxies: [{name: tls, type: socks5, server: 127.0.0.1, port: 1, tls: true, certificate: /never/read/client.pem, private-key: /never/read/client.pem}, {name: ssh, type: ssh, server: 127.0.0.1, port: 1, username: test, private-key: /never/read/client.pem}]\nmode: direct"
	if _, err := YAMLNetworkSettings(config); err != nil {
		t.Fatal(err)
	}
	session, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	session.Close()
}

func TestProxyFileProviderHydratesAfterNativeOverride(t *testing.T) {
	root := bundleFixture(t, "proxy-file", "identity.pem", proxyPEMFixture(t))
	config := "proxy-providers: {nodes: {type: inline, payload: [{name: ssh, type: ssh, server: 127.0.0.1, port: 1, username: test, private-key: identity.pem}]}}\nproxy-groups: [{name: pick, type: select, use: [nodes]}]\nrules: ['MATCH,pick']"
	session, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
	if err != nil {
		t.Fatal(err)
	}
	session.Close()
}

func TestProxyFileMissingAndInvalidContentAreRejected(t *testing.T) {
	config := "proxies: [{name: ssh, type: ssh, server: 127.0.0.1, port: 1, private-key: /never/read/private.pem}]\nmode: direct"
	for _, root := range []string{"", bundleFixture(t, "proxy-file", "/never/read/private.pem", []byte("invalid contents"))} {
		session, err := NewYAMLSessionWithResources(config, "{}", root, 1280)
		if err == nil {
			session.Close()
			t.Fatal("accepted missing or invalid key")
		}
		if strings.Contains(err.Error(), "/never/read") || strings.Contains(err.Error(), "invalid contents") {
			t.Fatalf("error exposed resource value: %v", err)
		}
	}
}
