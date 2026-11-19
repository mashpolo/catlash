package mobile

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/geodata/router"
	"github.com/metacubex/mihomo/component/mmdb"
	C "github.com/metacubex/mihomo/constant"
	RC "github.com/metacubex/mihomo/rules/common"
)

type missingGeoResource struct{ kind string }

func (e *missingGeoResource) Error() string {
	return "required resource " + e.kind + "/default is unavailable"
}

type geoRuntime struct {
	resources    map[resourceKey][]byte
	mode         bool
	algorithm    string
	ipMatchers   map[string]router.IPMatcher
	siteMatchers map[string]router.DomainMatcher
	ipReader     *mmdb.IPReader
	asnReader    *mmdb.ASNReader
}

func isGeoResource(kind string) bool {
	switch kind {
	case "geoip-dat", "geosite-dat", "geoip-mmdb", "asn-mmdb":
		return true
	}
	return false
}
func (g *geoRuntime) data(kind string) ([]byte, error) {
	data, ok := g.resources[resourceKey{kind, "default"}]
	if !ok {
		return nil, &missingGeoResource{kind: kind}
	}
	return data, nil
}
func (g *geoRuntime) NewGeoIP(country, target string, source, noResolve bool) (*RC.GEOIP, error) {
	if strings.EqualFold(country, "lan") {
		return RC.NewMobileGEOIP(country, target, source, noResolve, nil, nil), nil
	}
	if g.mode {
		key := strings.TrimPrefix(strings.ToLower(country), "!")
		matcher := g.ipMatchers[key]
		if matcher == nil {
			var err error
			_, explicit := g.resources[resourceKey{"geoip-dat", "default"}]
			if path := bundledGeoIPPath.Load(); path != nil && !explicit {
				matcher, err = geodata.NewMobileGeoIPMatcherFromFile(filepath.Join(filepath.Dir(*path), "GeoIP.dat"), key)
				if errors.Is(err, os.ErrNotExist) {
					return nil, &missingGeoResource{kind: "geoip-dat"}
				}
			} else {
				var data []byte
				data, err = g.data("geoip-dat")
				if err != nil {
					return nil, err
				}
				matcher, err = geodata.NewMobileGeoIPMatcher(data, key)
			}
			if err != nil {
				return nil, errors.New("geoip-dat contains an invalid or missing requested entry")
			}
			g.ipMatchers[key] = matcher
		}
		if strings.HasPrefix(country, "!") {
			matcher = router.NewNotIpMatcherGroup(matcher)
		}
		return RC.NewMobileGEOIP(country, target, source, noResolve, matcher, nil), nil
	}
	if g.ipReader == nil {
		var err error
		_, explicit := g.resources[resourceKey{"geoip-mmdb", "default"}]
		if path := bundledGeoIPPath.Load(); path != nil && !explicit {
			g.ipReader, err = mmdb.NewMobileIPReaderFromFile(*path)
		} else {
			var data []byte
			data, err = g.data("geoip-mmdb")
			if err != nil {
				return nil, err
			}
			g.ipReader, err = mmdb.NewMobileIPReader(data)
		}
		if err != nil {
			return nil, errors.New("geoip-mmdb is invalid or unsupported")
		}
	}
	return RC.NewMobileGEOIP(country, target, source, noResolve, nil, g.ipReader), nil
}
func (g *geoRuntime) NewGeoSite(country, target string) (*RC.GEOSITE, error) {
	key := strings.TrimPrefix(strings.ToLower(country), "!")
	matcher := g.siteMatchers[key]
	if matcher == nil {
		data, err := g.data("geosite-dat")
		if err != nil {
			return nil, err
		}
		matcher, err = geodata.NewMobileGeoSiteMatcher(data, key, g.algorithm)
		if err != nil {
			return nil, errors.New("geosite-dat contains an invalid or missing requested entry")
		}
		g.siteMatchers[key] = matcher
	}
	if strings.HasPrefix(country, "!") {
		matcher = router.NewNotDomainMatcherGroup(matcher)
	}
	return RC.NewMobileGEOSITE(country, target, matcher), nil
}
func (g *geoRuntime) newASN(asn, target string, source, noResolve bool) (*RC.ASN, error) {
	if g.asnReader == nil {
		var err error
		_, explicit := g.resources[resourceKey{"asn-mmdb", "default"}]
		if path := bundledGeoIPPath.Load(); path != nil && !explicit {
			g.asnReader, err = mmdb.NewMobileASNReaderFromFile(filepath.Join(filepath.Dir(*path), "ASN.mmdb"))
			if errors.Is(err, os.ErrNotExist) {
				return nil, &missingGeoResource{kind: "asn-mmdb"}
			}
		} else {
			var data []byte
			data, err = g.data("asn-mmdb")
			if err != nil {
				return nil, err
			}
			g.asnReader, err = mmdb.NewMobileASNReader(data)
		}
		if err != nil {
			return nil, errors.New("asn-mmdb is invalid or unsupported")
		}
	}
	return RC.NewMobileIPASN(asn, target, source, noResolve, g.asnReader), nil
}
func (g *geoRuntime) parseRule(kind, payload, target string, params []string) (C.Rule, error) {
	source, noResolve := false, false
	for _, parameter := range params {
		switch parameter {
		case "src":
			source = true
		case "no-resolve":
			noResolve = true
		default:
			return nil, errors.New("unsupported geodata rule parameter")
		}
	}
	switch kind {
	case "GEOSITE":
		if len(params) != 0 {
			return nil, errors.New("GEOSITE does not accept rule parameters")
		}
		return g.NewGeoSite(payload, target)
	case "GEOIP":
		return g.NewGeoIP(payload, target, source, noResolve)
	case "SRC-GEOIP":
		return g.NewGeoIP(payload, target, true, true)
	case "IP-ASN":
		return g.newASN(payload, target, source, noResolve)
	case "SRC-IP-ASN":
		return g.newASN(payload, target, true, true)
	default:
		return nil, fmt.Errorf("unsupported geodata rule %s", kind)
	}
}
func (g *geoRuntime) Close() error {
	var err error
	if g.ipReader != nil {
		err = g.ipReader.Close()
	}
	if g.asnReader != nil {
		err = errors.Join(err, g.asnReader.Close())
	}
	return err
}
