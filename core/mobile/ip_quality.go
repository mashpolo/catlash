package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/netip"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type ipQuality struct {
	Source       string `json:"source"`
	Type         string `json:"type"`
	Organization string `json:"organization,omitempty"`
	ASN          int    `json:"asn,omitempty"`
	IsProxy      bool   `json:"isProxy"`
	IsVPN        bool   `json:"isVpn"`
	IsTor        bool   `json:"isTor"`
	IsAbuser     bool   `json:"isAbuser"`
	Inferred     bool   `json:"inferred"`
}

type ipQualityFailure struct {
	Source string `json:"source"`
	Status string `json:"status"`
}

type exitIPQualityResult struct {
	IP           string             `json:"ip"`
	CountryCode  string             `json:"countryCode,omitempty"`
	Organization string             `json:"organization,omitempty"`
	Quality      *ipQuality         `json:"quality,omitempty"`
	Failures     []ipQualityFailure `json:"failures"`
	CheckedAt    int64              `json:"checkedAt,omitempty"`
	Cached       bool               `json:"cached"`
}

var qualityWaves = [][]string{{"identMe", "ipApiCom", "ipQuery"}, {"ipLocate"}, {"ipApiIs"}, {"proxyCheck"}}

type qualityLookupOptions struct {
	endpoint func(source, ip string) string
	timeout  time.Duration
	hedge    time.Duration
}

func defaultQualityLookupOptions() qualityLookupOptions {
	return qualityLookupOptions{endpoint: qualityEndpoint, timeout: 8 * time.Second, hedge: time.Second}
}

func qualityEndpoint(source, ip string) string {
	switch source {
	case "identMe":
		return "https://ident.me/json"
	case "ipApiCom":
		return "http://ip-api.com/json/" + ip + "?fields=status,isp,org,as,mobile,proxy,hosting,countryCode,query"
	case "ipQuery":
		return "https://api.ipquery.io/" + ip + "?format=json"
	case "ipLocate":
		return "https://iplocate.io/api/lookup/" + ip
	case "ipApiIs":
		return "https://api.ipapi.is/?q=" + ip
	case "proxyCheck":
		return "https://proxycheck.io/v3/" + ip
	default:
		panic("unknown IP quality source")
	}
}

func lookupIPQuality(parent context.Context, client *http.Client, ip string, options qualityLookupOptions) (exitIPQualityResult, error) {
	ctx, cancel := context.WithCancel(parent)
	var tasks sync.WaitGroup
	defer func() { cancel(); tasks.Wait() }()
	type answer struct {
		result  exitIPQualityResult
		failure ipQualityFailure
	}
	answers := make(chan answer, 6)
	wave, inFlight := 0, 0
	timer := time.NewTimer(options.hedge)
	defer timer.Stop()
	launch := func() {
		for _, source := range qualityWaves[wave] {
			inFlight++
			tasks.Go(func() {
				value, status := queryIPQuality(ctx, client, source, ip, options)
				answers <- answer{value, ipQualityFailure{source, status}}
			})
		}
		wave++
		timer.Reset(options.hedge)
	}
	launch()
	result := exitIPQualityResult{IP: ip, Failures: []ipQualityFailure{}}
	var fallback *exitIPQualityResult
	for {
		select {
		case <-ctx.Done():
			return result, ctx.Err()
		case <-timer.C:
			if wave < len(qualityWaves) {
				launch()
			}
		case value := <-answers:
			inFlight--
			if value.failure.Status != "" {
				result.Failures = append(result.Failures, value.failure)
			} else if !value.result.Quality.Inferred {
				return value.result, nil
			} else if fallback == nil {
				fallback = &value.result
			}
			if inFlight == 0 {
				if wave < len(qualityWaves) {
					launch()
					continue
				}
				if fallback != nil {
					return *fallback, nil
				}
				sort.Slice(result.Failures, func(i, j int) bool {
					return qualitySourceIndex(result.Failures[i].Source) < qualitySourceIndex(result.Failures[j].Source)
				})
				return result, nil
			}
		}
	}
}

func qualitySourceIndex(source string) int {
	for i, candidate := range []string{"identMe", "ipApiCom", "ipQuery", "ipLocate", "proxyCheck", "ipApiIs"} {
		if source == candidate {
			return i
		}
	}
	return 6
}

func queryIPQuality(parent context.Context, client *http.Client, source, ip string, options qualityLookupOptions) (exitIPQualityResult, string) {
	ctx, cancel := context.WithTimeout(parent, options.timeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, options.endpoint(source, ip), nil)
	if err != nil {
		return exitIPQualityResult{}, "failed"
	}
	request.Header.Set("Accept", "application/json")
	response, err := client.Do(request)
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return exitIPQualityResult{}, "timeout"
		}
		return exitIPQualityResult{}, "failed"
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusTooManyRequests {
		return exitIPQualityResult{}, "rateLimited"
	}
	if response.StatusCode != http.StatusOK {
		return exitIPQualityResult{}, "failed"
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, maximumExitIPResponse+1))
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return exitIPQualityResult{}, "timeout"
	}
	if err != nil || len(data) > maximumExitIPResponse {
		return exitIPQualityResult{}, "failed"
	}
	var value map[string]any
	if json.Unmarshal(data, &value) != nil || value == nil {
		return exitIPQualityResult{}, "failed"
	}
	return parseIPQuality(source, ip, value)
}

func parseIPQuality(source, ip string, value map[string]any) (exitIPQualityResult, string) {
	result := exitIPQualityResult{IP: ip, Failures: []ipQualityFailure{}}
	if value["error"] != nil {
		return result, "failed"
	}
	address, hasAddress := value["ip"]
	if source == "ipApiCom" {
		address, hasAddress = value["query"]
	}
	if hasAddress || source == "identMe" {
		parsed, err := netip.ParseAddr(qualityText(address))
		if err != nil || parsed.String() != ip {
			return result, "ipMismatch"
		}
	}
	q := &ipQuality{Source: source}
	switch source {
	case "identMe":
		q.Type = qualityDeclaredType(value["type"])
		q.Organization = qualityText(value["aso"])
		q.ASN = qualityASN(value["asn"])
		result.CountryCode = qualityCountry(value["cc"])
	case "ipApiCom":
		if value["status"] != "success" {
			return result, "failed"
		}
		q.Type = qualityPickType(qualityFlag(value["hosting"]), qualityFlag(value["mobile"]), "")
		q.Organization = qualityFirstText(value["org"], value["isp"])
		q.ASN = qualityASN(value["as"])
		q.IsProxy = qualityFlag(value["proxy"])
		result.CountryCode = qualityCountry(value["countryCode"])
	case "ipQuery":
		risk, isp := qualityObject(value["risk"]), qualityObject(value["isp"])
		q.Type = qualityPickType(qualityFlag(risk["is_datacenter"]), qualityFlag(risk["is_mobile"]), "")
		q.Organization = qualityFirstText(isp["org"], isp["isp"])
		q.ASN = qualityASN(isp["asn"])
		qualityFlags(q, risk, "is_")
		result.CountryCode = qualityCountry(qualityObject(value["location"])["country_code"])
	case "ipLocate", "ipApiIs":
		company, asn := qualityObject(value["company"]), qualityObject(value["asn"])
		declared := qualityDeclaredType(company["type"])
		if declared == "" {
			declared = qualityDeclaredType(asn["type"])
		}
		flags, hosting, organization := value, "is_datacenter", "org"
		if source == "ipLocate" {
			flags, hosting, organization = qualityObject(value["privacy"]), "is_hosting", "name"
		}
		q.Type = qualityPickType(qualityFlag(flags[hosting]), source == "ipApiIs" && qualityFlag(value["is_mobile"]), declared)
		q.Organization = qualityFirstText(company["name"], asn[organization])
		q.ASN = qualityASN(asn["asn"])
		qualityFlags(q, flags, "is_")
		result.CountryCode = qualityCountry(value["country_code"])
		if source == "ipApiIs" {
			result.CountryCode = qualityCountry(qualityObject(value["location"])["country_code"])
		}
	case "proxyCheck":
		if value["status"] == "denied" {
			return result, "rateLimited"
		}
		if value["status"] != "ok" && value["status"] != "warning" {
			return result, "failed"
		}
		entry := qualityObject(value[ip])
		network, detections := qualityObject(entry["network"]), qualityObject(entry["detections"])
		declared := ""
		switch network["type"] {
		case "Residential":
			declared = "residential"
		case "Business":
			declared = "business"
		}
		q.Type = qualityPickType(qualityFlag(detections["hosting"]) || network["type"] == "Hosting", network["type"] == "Wireless", declared)
		q.Organization = qualityText(network["organisation"])
		q.ASN = qualityASN(network["asn"])
		qualityFlags(q, detections, "")
		result.CountryCode = qualityCountry(qualityObject(entry["location"])["country_code"])
	}
	if q.Type == "" && (source == "ipQuery" || source == "ipApiCom") {
		q.Type, q.Inferred = "residential", true
	}
	if q.Type == "" {
		return result, "noType"
	}
	result.Quality, result.Organization = q, q.Organization
	return result, ""
}

func qualityFlags(q *ipQuality, flags map[string]any, prefix string) {
	q.IsProxy = qualityFlag(flags[prefix+"proxy"])
	q.IsVPN = qualityFlag(flags[prefix+"vpn"])
	q.IsTor = qualityFlag(flags[prefix+"tor"])
	q.IsAbuser = (q.Source == "ipLocate" || q.Source == "ipApiIs") && qualityFlag(flags[prefix+"abuser"])
}

func qualityPickType(hosting, mobile bool, declared string) string {
	if hosting || declared == "hosting" {
		return "hosting"
	}
	if mobile {
		return "mobile"
	}
	return declared
}

func qualityDeclaredType(value any) string {
	switch value {
	case "isp":
		return "residential"
	case "business", "education", "government", "banking":
		return "business"
	case "hosting":
		return "hosting"
	default:
		return ""
	}
}

func qualityFlag(value any) bool             { flag, _ := value.(bool); return flag }
func qualityObject(value any) map[string]any { object, _ := value.(map[string]any); return object }
func qualityText(value any) string {
	text, _ := value.(string)
	if len(text) > 512 {
		return ""
	}
	return strings.TrimSpace(text)
}
func qualityFirstText(first, second any) string {
	if text := qualityText(first); text != "" {
		return text
	}
	return qualityText(second)
}
func qualityCountry(value any) string {
	code := strings.ToUpper(qualityText(value))
	if len(code) != 2 || code[0] < 'A' || code[0] > 'Z' || code[1] < 'A' || code[1] > 'Z' {
		return ""
	}
	return code
}

var qualityASNDigits = regexp.MustCompile(`\d+`)

func qualityASN(value any) int {
	if number, ok := value.(float64); ok {
		if number > 0 && number <= 4294967295 && number == float64(int64(number)) {
			return int(number)
		}
		return 0
	}
	number, _ := strconv.ParseUint(qualityASNDigits.FindString(qualityText(value)), 10, 32)
	return int(number)
}
