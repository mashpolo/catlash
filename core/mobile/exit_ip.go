package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

const exitIPv4URL = "https://api.ipify.org?format=json"
const exitIPv6URL = "https://api6.ipify.org?format=json"
const exitIPIPURL = "https://myip.ipip.net/json"
const exitIPQualityURL = "https://api.ipquery.io/"
const maximumExitIPResponse = 64 * 1024

func (s *Session) ExitIPJSON() (string, error) {
	return s.exitIPJSON(exitIPv4URL, exitIPv6URL, exitIPQualityURL, exitIPIPURL)
}

func (s *Session) ExitIPJSONForRequest(requestID int64) (string, error) {
	if requestID <= 0 {
		return "", errors.New("exit IP request ID must be positive")
	}
	return s.exitIPJSONForRequest(requestID, exitIPv4URL, exitIPv6URL, exitIPQualityURL, exitIPIPURL)
}

func (s *Session) CancelExitIP() {
	s.exitIPMu.Lock()
	defer s.exitIPMu.Unlock()
	s.exitIPGeneration++
	if s.exitIPCancel != nil {
		s.exitIPCancel()
		s.exitIPCancel = nil
	}
}

func (s *Session) CancelExitIPForRequest(requestID int64) {
	s.exitIPMu.Lock()
	defer s.exitIPMu.Unlock()
	if requestID <= 0 || requestID < s.exitIPRequestID {
		return
	}
	s.exitIPRequestID = requestID
	s.exitIPGeneration++
	if s.exitIPCancel != nil {
		s.exitIPCancel()
		s.exitIPCancel = nil
	}
}

func (s *Session) beginExitIP(requestID int64) (context.Context, uint64, func(), error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, 0, nil, errors.New("session is closed")
	}
	s.exitIPMu.Lock()
	if requestID == 0 {
		requestID = s.exitIPRequestID + 1
	}
	if requestID <= s.exitIPRequestID {
		s.exitIPMu.Unlock()
		return nil, 0, nil, errors.New("exit IP request was superseded")
	}
	s.exitIPRequestID = requestID
	s.tasks.Add(1)
	ctx, cancel := context.WithTimeout(s.ctx, 21*time.Second)
	if s.exitIPCancel != nil {
		s.exitIPCancel()
	}
	s.exitIPGeneration++
	generation := s.exitIPGeneration
	s.exitIPCancel = cancel
	s.exitIPMu.Unlock()
	return ctx, generation, func() {
		cancel()
		s.exitIPMu.Lock()
		if s.exitIPGeneration == generation {
			s.exitIPCancel = nil
		}
		s.exitIPMu.Unlock()
		s.tasks.Done()
	}, nil
}

func (s *Session) exitIPJSON(addressEndpoint, fallbackEndpoint, qualityEndpoint string, ipipEndpoint ...string) (string, error) {
	return s.exitIPJSONForRequest(0, addressEndpoint, fallbackEndpoint, qualityEndpoint, ipipEndpoint...)
}

func (s *Session) exitIPJSONForRequest(requestID int64, addressEndpoint, fallbackEndpoint, qualityEndpoint string, ipipEndpoint ...string) (string, error) {
	ctx, generation, done, err := s.beginExitIP(requestID)
	if err != nil {
		return "", err
	}
	defer done()
	client, closeClient := s.exitIPClient(ctx)
	defer closeClient()
	address, err := detectPreferredExitIP(ctx, client, addressEndpoint, fallbackEndpoint, ipipEndpoint...)
	if !s.exitIPCurrent(generation) || ctx.Err() != nil {
		return "", context.Canceled
	}
	if err != nil {
		return "", err
	}
	qualityCtx, cancelQuality := exitIPQualityContext(ctx)
	defer cancelQuality()
	data, qualityAddress, qualityError := lookupExitIP(qualityCtx, client, qualityEndpoint+address+"?format=json")
	if !s.exitIPCurrent(generation) || errors.Is(ctx.Err(), context.Canceled) {
		return "", context.Canceled
	}
	if qualityError != nil || qualityAddress != address {
		fallback, _ := json.Marshal(struct {
			IP string `json:"ip"`
		}{address})
		return string(fallback), nil
	}
	return string(data), nil
}

func (s *Session) exitIPCurrent(generation uint64) bool {
	s.exitIPMu.Lock()
	defer s.exitIPMu.Unlock()
	return s.exitIPGeneration == generation && s.ctx.Err() == nil
}

func detectExitIP(parent context.Context, client *http.Client, endpoint string, ipv6 bool) (string, error) {
	ctx, cancel := context.WithTimeout(parent, 4*time.Second)
	defer cancel()
	_, address, err := lookupExitIP(ctx, client, endpoint)
	if err != nil {
		return "", err
	}
	ip, _ := netip.ParseAddr(address)
	if ip.Is6() != ipv6 {
		return "", errors.New("exit IP service returned the wrong address family")
	}
	return address, nil
}

func fetchExitIPResponse(ctx context.Context, client *http.Client, endpoint string) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/json")
	response, err := client.Do(request)
	if err != nil {
		var requestError *url.Error
		if errors.As(err, &requestError) {
			err = requestError.Err
		}
		return nil, fmt.Errorf("exit IP lookup failed: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("exit IP service returned HTTP %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, maximumExitIPResponse+1))
	if err != nil {
		return nil, errors.New("exit IP response could not be read")
	}
	if len(data) > maximumExitIPResponse {
		return nil, errors.New("exit IP response exceeds the size limit")
	}
	return data, nil
}

func lookupExitIP(ctx context.Context, client *http.Client, endpoint string) ([]byte, string, error) {
	data, err := fetchExitIPResponse(ctx, client, endpoint)
	if err != nil {
		return nil, "", err
	}
	var value struct {
		IP    string          `json:"ip"`
		Error json.RawMessage `json:"error"`
	}
	if err = json.Unmarshal(data, &value); err != nil {
		return nil, "", errors.New("exit IP service returned invalid JSON")
	}
	if len(value.Error) > 0 && string(value.Error) != "null" {
		return nil, "", errors.New("exit IP service reported an error")
	}
	ip, err := netip.ParseAddr(value.IP)
	if err != nil || ip.Is4In6() || ip.Zone() != "" {
		return nil, "", errors.New("exit IP service did not return a native IP address")
	}
	return data, ip.String(), nil
}

func (s *Session) dialExitIP(ctx context.Context, address string) (net.Conn, error) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil, errors.New("session is closed")
	}
	s.tasks.Add(1)
	s.mu.Unlock()
	defer s.tasks.Done()
	metadata := &C.Metadata{NetWork: C.TCP, Type: C.INNER}
	if err := metadata.SetRemoteAddress(address); err != nil {
		return nil, err
	}
	proxy, err := s.route(metadata)
	if err != nil {
		return nil, err
	}
	if s.routing != nil && s.routing.dns != nil && proxy.IsL3Protocol(metadata) {
		if err := s.routing.dns.resolve(metadata); err != nil {
			return nil, err
		}
	}
	return proxy.DialContext(ctx, metadata)
}

func detectIPIPExitIP(parent context.Context, client *http.Client, endpoint string) (string, error) {
	ctx, cancel := context.WithTimeout(parent, 4*time.Second)
	defer cancel()
	data, err := fetchExitIPResponse(ctx, client, endpoint)
	if err != nil {
		return "", err
	}
	var value struct {
		Ret  string `json:"ret"`
		Data struct {
			IP string `json:"ip"`
		} `json:"data"`
	}
	if json.Unmarshal(data, &value) != nil || value.Ret != "ok" {
		return "", errors.New("IPIP service returned an invalid result")
	}
	ip, err := netip.ParseAddr(value.Data.IP)
	if err != nil || ip.Is4In6() || ip.Zone() != "" || !ip.IsGlobalUnicast() || ip.IsPrivate() {
		return "", errors.New("IPIP service did not return a native public IP address")
	}
	for _, prefix := range nonPublicExitIPPrefixes {
		if prefix.Contains(ip) {
			return "", errors.New("IPIP service did not return a public IP address")
		}
	}
	return ip.String(), nil
}

var nonPublicExitIPPrefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"), netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"), netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"), netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"), netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("2001:db8::/32"),
}
