package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"time"
)

func (s *Session) ExitIPQualityJSONForRequest(requestID int64, forceRefresh bool, cacheDirectory string) (string, error) {
	if requestID <= 0 {
		return "", errors.New("exit IP request ID must be positive")
	}
	return s.exitIPQualityJSONForRequest(requestID, forceRefresh, cacheDirectory, exitIPv4URL, exitIPv6URL, defaultQualityLookupOptions(), exitIPIPURL)
}

func (s *Session) exitIPQualityJSONForRequest(requestID int64, forceRefresh bool, cacheDirectory, addressEndpoint, fallbackEndpoint string, options qualityLookupOptions, ipipEndpoint ...string) (string, error) {
	ctx, generation, done, err := s.beginExitIP(requestID)
	if err != nil {
		return "", err
	}
	defer done()
	client, closeClient := s.exitIPClient(ctx)
	defer closeClient()
	address, err := detectPreferredExitIP(ctx, client, addressEndpoint, fallbackEndpoint, ipipEndpoint...)
	if err != nil {
		return "", err
	}
	if !s.exitIPCurrent(generation) || ctx.Err() != nil {
		return "", context.Canceled
	}
	var result exitIPQualityResult
	cached := false
	if !forceRefresh {
		result, cached = s.ipQualityCache.get(address, cacheDirectory, time.Now())
	}
	if !cached {
		result, err = lookupExitIPQualityWithinBudget(ctx, client, address, options)
		if err != nil {
			return "", err
		}
		result.CheckedAt = time.Now().Unix()
	}
	s.exitIPMu.Lock()
	defer s.exitIPMu.Unlock()
	if s.exitIPGeneration != generation || ctx.Err() != nil {
		return "", context.Canceled
	}
	if !cached {
		s.ipQualityCache.put(result, cacheDirectory, time.Now())
	}
	encoded, err := json.Marshal(result)
	return string(encoded), err
}

func (s *Session) exitIPClient(ctx context.Context) (*http.Client, func()) {
	transport := &http.Transport{
		DisableKeepAlives: true,
		DialContext: func(dialContext context.Context, _, address string) (net.Conn, error) {
			dialContext, cancel := context.WithCancel(dialContext)
			stop := context.AfterFunc(ctx, cancel)
			defer stop()
			defer cancel()
			return s.dialExitIP(dialContext, address)
		},
	}
	return &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}, transport.CloseIdleConnections
}

func detectPreferredExitIP(ctx context.Context, client *http.Client, addressEndpoint, fallbackEndpoint string, ipipEndpoint ...string) (string, error) {
	address, err := detectExitIP(ctx, client, addressEndpoint, false)
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	if err == nil {
		return address, nil
	}
	ipv4Error := err
	address, err = detectExitIP(ctx, client, fallbackEndpoint, true)
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	if err == nil {
		return address, nil
	}
	ipv6Error := err
	if len(ipipEndpoint) == 0 || ipipEndpoint[0] == "" {
		return "", fmt.Errorf("IPv4: %v; IPv6: %w", ipv4Error, ipv6Error)
	}
	address, err = detectIPIPExitIP(ctx, client, ipipEndpoint[0])
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	if err != nil {
		return "", fmt.Errorf("IPv4: %v; IPv6: %v; IPIP: %w", ipv4Error, ipv6Error, err)
	}
	return address, nil
}

// Leave time to encode and deliver an address even when every quality service stalls.
func exitIPQualityContext(parent context.Context) (context.Context, context.CancelFunc) {
	deadline := time.Now().Add(11 * time.Second)
	if limit, ok := parent.Deadline(); ok && limit.Add(-500*time.Millisecond).Before(deadline) {
		deadline = limit.Add(-500 * time.Millisecond)
	}
	return context.WithDeadline(parent, deadline)
}

func lookupExitIPQualityWithinBudget(parent context.Context, client *http.Client, address string, options qualityLookupOptions) (exitIPQualityResult, error) {
	ctx, cancel := exitIPQualityContext(parent)
	defer cancel()
	result, err := lookupIPQuality(ctx, client, address, options)
	if parent.Err() != nil {
		return result, parent.Err()
	}
	if errors.Is(err, context.DeadlineExceeded) {
		seen := map[string]bool{}
		for _, failure := range result.Failures {
			seen[failure.Source] = true
		}
		for _, wave := range qualityWaves {
			for _, source := range wave {
				if !seen[source] {
					result.Failures = append(result.Failures, ipQualityFailure{Source: source, Status: "timeout"})
				}
			}
		}
		return result, nil
	}
	return result, err
}
