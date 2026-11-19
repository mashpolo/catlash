package mobile

import (
	"bytes"
	"encoding/binary"
	"math"
	"net/netip"
	"testing"

	"github.com/klauspost/compress/zstd"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	RP "github.com/metacubex/mihomo/rules/provider"
)

func mobileMRSFixture(t *testing.T, behavior P.RuleBehavior, yaml string) []byte {
	t.Helper()
	var output bytes.Buffer
	if err := RP.ConvertToMrs([]byte(yaml), behavior, P.YamlRule, &output); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}

func TestMobileMRSProvidersMatchDomainAndIPv4IPv6(t *testing.T) {
	for _, test := range []struct {
		name            string
		behavior        P.RuleBehavior
		yaml            string
		matches, misses []*C.Metadata
	}{
		{"domain", P.Domain, "payload:\n - '+.example.com'\n - 'exact.invalid'\n", []*C.Metadata{{Host: "www.example.com"}, {Host: "example.com"}, {Host: "exact.invalid"}}, []*C.Metadata{{Host: "other.invalid"}, {Host: "child.exact.invalid"}}},
		{"ipcidr", P.IPCIDR, "payload:\n - '192.0.2.0/24'\n - '2001:db8::/32'\n", []*C.Metadata{{DstIP: netip.MustParseAddr("192.0.2.7")}, {DstIP: netip.MustParseAddr("2001:db8::7")}}, []*C.Metadata{{DstIP: netip.MustParseAddr("198.51.100.1")}, {DstIP: netip.MustParseAddr("2001:db9::7")}}},
	} {
		t.Run(test.name, func(t *testing.T) {
			provider, err := RP.NewMobileMRSProvider(test.name, test.behavior, mobileMRSFixture(t, test.behavior, test.yaml))
			if err != nil {
				t.Fatal(err)
			}
			if provider.Count() != 2 || provider.Name() != test.name || provider.Behavior() != test.behavior || provider.VehicleType() != P.Inline {
				t.Fatal("unexpected provider metadata")
			}
			if err := provider.Initial(); err != nil {
				t.Fatal(err)
			}
			if err := provider.Update(); err != nil {
				t.Fatal(err)
			}
			for _, metadata := range test.matches {
				if !provider.Match(metadata, C.RuleMatchHelper{}) {
					t.Fatalf("did not match %v", metadata)
				}
			}
			for _, metadata := range test.misses {
				if provider.Match(metadata, C.RuleMatchHelper{}) {
					t.Fatalf("unexpected match %v", metadata)
				}
			}
		})
	}
}

func TestMobileMRSRejectsWrongBehaviorAndTruncation(t *testing.T) {
	valid := mobileMRSFixture(t, P.Domain, "payload:\n - 'example.com'\n")
	for _, behavior := range []P.RuleBehavior{P.IPCIDR, P.Classical, P.RuleBehavior(100)} {
		if _, err := RP.NewMobileMRSProvider("bad", behavior, valid); err == nil {
			t.Fatalf("accepted behavior %v", behavior)
		}
	}
	for size := 0; size < len(valid); size++ {
		if _, err := RP.NewMobileMRSProvider("truncated", P.Domain, valid[:size]); err == nil {
			t.Fatalf("accepted prefix %d", size)
		}
	}
}

func encodeMobileMRS(t *testing.T, decoded []byte) []byte {
	t.Helper()
	encoder, err := zstd.NewWriter(nil, zstd.WithEncoderConcurrency(1))
	if err != nil {
		t.Fatal(err)
	}
	defer encoder.Close()
	return encoder.EncodeAll(decoded, nil)
}

func decodeMobileMRS(t *testing.T, data []byte) []byte {
	t.Helper()
	decoder, err := zstd.NewReader(nil, zstd.WithDecoderConcurrency(1))
	if err != nil {
		t.Fatal(err)
	}
	defer decoder.Close()
	result, err := decoder.DecodeAll(data, nil)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestMobileMRSRejectsUntrustedAllocationLengths(t *testing.T) {
	domain := decodeMobileMRS(t, mobileMRSFixture(t, P.Domain, "payload:\n - 'example.com'\n"))
	ipcidr := decodeMobileMRS(t, mobileMRSFixture(t, P.IPCIDR, "payload:\n - '192.0.2.0/24'\n"))
	bitmapLength := 30 + int(binary.BigEndian.Uint64(domain[22:]))*8
	labelLength := bitmapLength + 8 + int(binary.BigEndian.Uint64(domain[bitmapLength:]))*8
	for _, test := range []struct {
		name     string
		behavior P.RuleBehavior
		original []byte
		offset   int
		value    uint64
	}{
		{"negative-count", P.Domain, domain, 5, math.MaxUint64},
		{"huge-count", P.Domain, domain, 5, math.MaxInt64},
		{"extra", P.Domain, domain, 13, math.MaxInt64},
		{"domain-leaves", P.Domain, domain, 22, math.MaxInt64},
		{"domain-bitmap", P.Domain, domain, bitmapLength, math.MaxInt64},
		{"domain-labels", P.Domain, domain, labelLength, math.MaxInt64},
		{"cidr-ranges", P.IPCIDR, ipcidr, 22, math.MaxInt64},
	} {
		t.Run(test.name, func(t *testing.T) {
			data := bytes.Clone(test.original)
			binary.BigEndian.PutUint64(data[test.offset:], test.value)
			if _, err := RP.NewMobileMRSProvider("invalid", test.behavior, encodeMobileMRS(t, data)); err == nil {
				t.Fatal("accepted unbounded length")
			}
		})
	}
}

func TestMobileMRSRejectsCorruptTrieAndIPRanges(t *testing.T) {
	domain := decodeMobileMRS(t, mobileMRSFixture(t, P.Domain, "payload:\n - 'example.com'\n"))
	leaves := int(binary.BigEndian.Uint64(domain[22:]))
	bitmapStart := 30 + leaves*8 + 8
	for i := bitmapStart; i < bitmapStart+8; i++ {
		domain[i] = 0
	}
	if _, err := RP.NewMobileMRSProvider("bad-tree", P.Domain, encodeMobileMRS(t, domain)); err == nil {
		t.Fatal("accepted corrupt tree")
	}
	ipcidr := decodeMobileMRS(t, mobileMRSFixture(t, P.IPCIDR, "payload:\n - '192.0.2.0/24'\n"))
	copy(ipcidr[30:46], bytes.Repeat([]byte{255}, 16))
	if _, err := RP.NewMobileMRSProvider("bad-range", P.IPCIDR, encodeMobileMRS(t, ipcidr)); err == nil {
		t.Fatal("accepted inverted range")
	}
}

func TestMobileMRSRejectsOversizedCompressedAndExpandedData(t *testing.T) {
	if _, err := RP.NewMobileMRSProvider("large", P.Domain, make([]byte, 16*1024*1024+1)); err == nil {
		t.Fatal("accepted oversized compressed input")
	}
	expanded := bytes.Repeat([]byte{0}, 16*1024*1024+1)
	if _, err := RP.NewMobileMRSProvider("bomb", P.Domain, encodeMobileMRS(t, expanded)); err == nil {
		t.Fatal("accepted oversized expanded input")
	}
}
