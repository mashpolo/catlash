package mobile

import (
	"bytes"
	"encoding/binary"
	"net"
	"testing"

	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/oschwald/maxminddb-golang"
)

func mobileMMDBString(value string) []byte {
	if len(value) < 29 {
		return append([]byte{0x40 | byte(len(value))}, value...)
	}
	return append([]byte{0x40 | 29, byte(len(value) - 29)}, value...)
}

func mobileMMDBMap(entries ...[]byte) []byte {
	result := []byte{0xe0 | byte(len(entries)/2)}
	for _, entry := range entries {
		result = append(result, entry...)
	}
	return result
}

func mobileMMDBUint(value uint32) []byte {
	result := []byte{0xc4, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(result[1:], value)
	return result
}

func mobileMMDBFixture(databaseType string, record []byte) []byte {
	data := []byte{0, 0, 17, 0, 0, 1}
	data = append(data, make([]byte, 16)...)
	data = append(data, record...)
	data = append(data, []byte("\xab\xcd\xefMaxMind.com")...)
	return append(data, mobileMMDBMap(
		mobileMMDBString("node_count"), mobileMMDBUint(1),
		mobileMMDBString("record_size"), mobileMMDBUint(24),
		mobileMMDBString("ip_version"), mobileMMDBUint(4),
		mobileMMDBString("database_type"), mobileMMDBString(databaseType),
		mobileMMDBString("binary_format_major_version"), mobileMMDBUint(2),
		mobileMMDBString("binary_format_minor_version"), mobileMMDBUint(0),
		mobileMMDBString("description"), mobileMMDBMap(mobileMMDBString("en"), mobileMMDBString("local test fixture")),
	)...)
}

func TestMobileMMDBCountryFormatsAndIndependentReaders(t *testing.T) {
	maxmind := mobileMMDBMap(mobileMMDBString("country"), mobileMMDBMap(mobileMMDBString("iso_code"), mobileMMDBString("US")))
	meta := append([]byte{2, 4}, mobileMMDBString("us")...)
	meta = append(meta, mobileMMDBString("test")...)
	for _, test := range []struct {
		kind   string
		record []byte
		count  int
	}{
		{"GeoLite2-Country", maxmind, 1}, {"GeoIP2-City", maxmind, 1}, {"sing-geoip", mobileMMDBString("us"), 1}, {"Meta-geoip0", meta, 2},
	} {
		t.Run(test.kind, func(t *testing.T) {
			input := mobileMMDBFixture(test.kind, test.record)
			reader, err := mmdb.NewMobileIPReader(input)
			if err != nil {
				t.Fatal(err)
			}
			defer reader.Close()
			clear(input)
			codes := reader.LookupCode(net.ParseIP("1.2.3.4"))
			if len(codes) != test.count || codes[0] != "us" {
				t.Fatalf("unexpected result %v", codes)
			}
			if codes := reader.LookupCode(net.ParseIP("192.0.2.1")); len(codes) != 0 {
				t.Fatalf("unexpected missing result %v", codes)
			}
			second, err := mmdb.NewMobileIPReader(mobileMMDBFixture("sing-geoip", mobileMMDBString("de")))
			if err != nil {
				t.Fatal(err)
			}
			defer second.Close()
			if second.LookupCode(net.ParseIP("1.2.3.4"))[0] != "de" || reader.LookupCode(net.ParseIP("1.2.3.4"))[0] != "us" {
				t.Fatal("readers shared global state")
			}
		})
	}
}

func TestMobileMMDBASNFormatsAndMissingAddresses(t *testing.T) {
	for _, kind := range []string{"GeoLite2-ASN", "DBIP-ASN-Lite (compat=GeoLite2-ASN)", "ipinfo generic_asn_free.mmdb"} {
		t.Run(kind, func(t *testing.T) {
			record := mobileMMDBMap(mobileMMDBString("autonomous_system_number"), mobileMMDBUint(64512), mobileMMDBString("autonomous_system_organization"), mobileMMDBString("test operator"))
			if kind == "ipinfo generic_asn_free.mmdb" {
				record = mobileMMDBMap(mobileMMDBString("asn"), mobileMMDBString("AS64512"), mobileMMDBString("name"), mobileMMDBString("test operator"))
			}
			reader, err := mmdb.NewMobileASNReader(mobileMMDBFixture(kind, record))
			if err != nil {
				t.Fatal(err)
			}
			defer reader.Close()
			asn, name := reader.LookupASN(net.ParseIP("1.2.3.4"))
			if asn != "64512" || name != "test operator" {
				t.Fatalf("unexpected %q %q", asn, name)
			}
			asn, _ = reader.LookupASN(net.ParseIP("192.0.2.1"))
			if asn != "0" && asn != "" {
				t.Fatalf("unexpected missing ASN %q", asn)
			}
			if err := reader.Close(); err != nil {
				t.Fatal(err)
			}
			asn, _ = reader.LookupASN(net.ParseIP("1.2.3.4"))
			if asn != "0" && asn != "" {
				t.Fatalf("closed reader returned ASN %q", asn)
			}
			var result any
			if err := reader.Lookup(net.ParseIP("1.2.3.4"), &result); err == nil {
				t.Fatal("closed raw reader accepted lookup")
			}
		})
	}
}

func TestMobileMMDBRejectsUnknownTypeTruncationAndBadSchema(t *testing.T) {
	valid := mobileMMDBFixture("sing-geoip", mobileMMDBString("us"))
	for length := 0; length < len(valid); length++ {
		if reader, err := mmdb.NewMobileIPReader(valid[:length]); err == nil {
			reader.Close()
			t.Fatalf("accepted truncation %d", length)
		}
	}
	for _, data := range [][]byte{
		mobileMMDBFixture("unknown", mobileMMDBString("us")),
		mobileMMDBFixture("GeoLite2-ASN", mobileMMDBString("us")),
		mobileMMDBFixture("sing-geoip", mobileMMDBUint(123)),
		mobileMMDBFixture("Meta-geoip0", append([]byte{1, 4}, mobileMMDBUint(123)...)),
	} {
		if reader, err := mmdb.NewMobileIPReader(data); err == nil {
			reader.Close()
			t.Fatal("accepted invalid IP database")
		}
	}
	for _, data := range [][]byte{
		mobileMMDBFixture("unknown", mobileMMDBUint(123)),
		mobileMMDBFixture("sing-geoip", mobileMMDBString("us")),
		mobileMMDBFixture("ipinfo generic_asn_free.mmdb", mobileMMDBMap(mobileMMDBString("asn"), mobileMMDBString("A"))),
	} {
		if reader, err := mmdb.NewMobileASNReader(data); err == nil {
			reader.Close()
			t.Fatal("accepted invalid ASN database")
		}
	}
	broken := bytes.Clone(valid)
	broken[0], broken[1], broken[2] = 255, 255, 255
	if reader, err := mmdb.NewMobileIPReader(broken); err == nil {
		reader.Close()
		t.Fatal("accepted corrupt tree")
	}
}

func TestMobileMMDBClosedCountryReaderAndReopen(t *testing.T) {
	data := mobileMMDBFixture("Meta-geoip0", mobileMMDBString("us"))
	reader, err := mmdb.NewMobileIPReader(data)
	if err != nil {
		t.Fatal(err)
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	if codes := reader.LookupCode(net.ParseIP("1.2.3.4")); len(codes) != 0 {
		t.Fatalf("closed reader returned %v", codes)
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := mmdb.NewMobileIPReader(data)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if codes := reopened.LookupCode(net.ParseIP("1.2.3.4")); len(codes) != 1 || codes[0] != "us" {
		t.Fatalf("reopen failed: %v", codes)
	}
}

func TestMobileMMDBMalformedMetaRecordDoesNotPanic(t *testing.T) {
	reader, err := mmdb.NewMobileIPReader(mobileMMDBFixture("Meta-geoip0", mobileMMDBString("us")))
	if err != nil {
		t.Fatal(err)
	}
	reader.Close()
	bad := mobileMMDBFixture("Meta-geoip0", append([]byte{1, 4}, mobileMMDBUint(123)...))
	reader.Reader, err = maxminddb.FromBytes(bad)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	if codes := reader.LookupCode(net.ParseIP("1.2.3.4")); len(codes) != 0 {
		t.Fatalf("invalid record returned %v", codes)
	}
}

func TestMobileMMDBRejectsExcessiveEncodedCollections(t *testing.T) {
	oversizedMap := []byte{0xff, 0xff, 0xff, 0xff}
	for _, kind := range []string{"GeoLite2-Country", "Meta-geoip0"} {
		if reader, err := mmdb.NewMobileIPReader(mobileMMDBFixture(kind, oversizedMap)); err == nil {
			reader.Close()
			t.Fatal("accepted unbounded collection")
		}
	}
	if reader, err := mmdb.NewMobileIPReader(make([]byte, 16*1024*1024+1)); err == nil {
		reader.Close()
		t.Fatal("accepted oversized database")
	}
}
