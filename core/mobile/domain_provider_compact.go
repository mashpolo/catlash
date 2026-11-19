package mobile

import (
	"bytes"
	"errors"
	"sort"
	"strings"

	"github.com/metacubex/mihomo/component/trie"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

// Ordinary domain rules share the immutable download buffer. Only label
// wildcards and Unicode patterns need Mihomo's general matcher.
type compactDomainEntry struct{ start, sizeAndKind uint32 }
type compactDomainProvider struct {
	name    string
	data    []byte
	entries []compactDomainEntry
	complex *trie.DomainSet
	count   int
}

func newCompactDomainProvider(name string, data []byte) (P.RuleProvider, error) {
	count := 0
	for rest := data; len(rest) > 0; {
		line, next, found := bytes.Cut(rest, []byte{'\n'})
		line = bytes.TrimSpace(line)
		if len(line) != 0 && line[0] != '#' && !bytes.HasPrefix(line, []byte("//")) {
			count++
		}
		if !found {
			break
		}
		rest = next
	}
	p := &compactDomainProvider{name: name, data: data, entries: make([]compactDomainEntry, 0, count)}
	var complex trie.DomainSetBuilder
	for start := 0; start < len(data); {
		end := bytes.IndexByte(data[start:], '\n')
		if end < 0 {
			end = len(data)
		} else {
			end += start
		}
		raw := data[start:end]
		line := bytes.TrimSpace(raw)
		offset := start
		start = end + 1
		if len(line) == 0 || line[0] == '#' || bytes.HasPrefix(line, []byte("//")) {
			continue
		}
		offset += bytes.Index(raw, line)
		if bytes.IndexByte(line, '/') >= 0 {
			return nil, errors.New("invalid domain provider rule")
		}
		body := line
		kind := uint32(0)
		if bytes.HasPrefix(body, []byte("+.")) {
			body = body[2:]
			offset += 2
			kind = 2
		} else if body[0] == '.' {
			body = body[1:]
			offset++
			kind = 1
		}
		special := false
		for _, c := range body {
			if c >= 128 || c == '*' || c == '+' {
				special = true
				break
			}
		}
		if special {
			if err := complex.Insert(string(line)); err != nil {
				return nil, errors.New("invalid domain provider rule")
			}
		} else {
			if len(body) == 0 || body[0] == '.' || body[len(body)-1] == '.' || bytes.Contains(body, []byte("..")) {
				return nil, errors.New("invalid domain provider rule")
			}
			p.entries = append(p.entries, compactDomainEntry{uint32(offset), uint32(len(body)) | kind<<30})
		}
		p.count++
	}
	sort.Slice(p.entries, func(i, j int) bool { return compareDomainBytes(p.domain(p.entries[i]), p.domain(p.entries[j])) < 0 })
	p.complex = complex.Build()
	return p, nil
}
func (p *compactDomainProvider) domain(e compactDomainEntry) []byte {
	return p.data[e.start : e.start+(e.sizeAndKind&((1<<30)-1))]
}
func lowerDomainByte(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}
func compareDomainBytes(a, b []byte) int {
	for i := 0; i < len(a) && i < len(b); i++ {
		x, y := lowerDomainByte(a[i]), lowerDomainByte(b[i])
		if x < y {
			return -1
		}
		if x > y {
			return 1
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}
func compareDomainHost(a []byte, b string) int {
	for i := 0; i < len(a) && i < len(b); i++ {
		x, y := lowerDomainByte(a[i]), b[i]
		if x < y {
			return -1
		}
		if x > y {
			return 1
		}
	}
	if len(a) < len(b) {
		return -1
	}
	if len(a) > len(b) {
		return 1
	}
	return 0
}
func (p *compactDomainProvider) Match(metadata *C.Metadata, _ C.RuleMatchHelper) bool {
	host := metadata.RuleHost()
	if p.complex != nil && p.complex.Has(host) {
		return true
	}
	host = strings.ToLower(host)
	for offset := 0; offset < len(host); {
		suffix := host[offset:]
		index := sort.Search(len(p.entries), func(i int) bool { return compareDomainHost(p.domain(p.entries[i]), suffix) >= 0 })
		for index < len(p.entries) && compareDomainHost(p.domain(p.entries[index]), suffix) == 0 {
			kind := p.entries[index].sizeAndKind >> 30
			if kind == 2 && (offset == 0 || offset > 1) || kind == 0 && offset == 0 || kind == 1 && offset > 1 {
				return true
			}
			index++
		}
		dot := strings.IndexByte(suffix, '.')
		if dot < 0 {
			break
		}
		offset += dot + 1
	}
	return false
}
func (p *compactDomainProvider) Name() string               { return p.name }
func (p *compactDomainProvider) VehicleType() P.VehicleType { return P.Inline }
func (p *compactDomainProvider) Type() P.ProviderType       { return P.Rule }
func (p *compactDomainProvider) Initial() error             { return nil }
func (p *compactDomainProvider) Update() error              { return nil }
func (p *compactDomainProvider) Behavior() P.RuleBehavior   { return P.Domain }
func (p *compactDomainProvider) Count() int                 { return p.count }
func (p *compactDomainProvider) Strategy() any              { return p }
