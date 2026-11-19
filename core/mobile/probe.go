package mobile

import (
	"context"
	"encoding/json"
	"errors"
	C "github.com/metacubex/mihomo/constant"
	"net"
	neturl "net/url"
	"time"
)

func (s *Session) TestProxyResultJSON(name, url string, timeoutMS int32) (string, error) {
	delay, err := s.TestProxy(name, url, timeoutMS)
	status := "success"
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		status = "timeout"
	case errors.Is(err, context.Canceled):
		status = "cancelled"
	case err != nil:
		status = "failed"
	}
	data, marshalErr := json.Marshal(struct {
		Status string `json:"status"`
		Delay  int64  `json:"delayMilliseconds"`
	}{status, delay})
	return string(data), marshalErr
}

func (s *Session) TestProxy(name, url string, timeoutMS int32) (int64, error) {
	if timeoutMS < 1 || timeoutMS > 60000 {
		return 0, errors.New("test timeout must be between 1 and 60000 milliseconds")
	}
	parsed, err := neturl.Parse(url)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Hostname() == "" || parsed.User != nil {
		return 0, errors.New("test URL must be HTTP or HTTPS without credentials")
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return 0, errors.New("session is closed")
	}
	var proxy C.Proxy
	if s.routing == nil {
		if s.proxy.Name() == name {
			proxy = s.proxy
		}
	} else {
		proxy = s.routing.proxies[name]
	}
	if proxy == nil {
		s.mu.Unlock()
		return 0, errors.New("unknown proxy")
	}
	testContext := s.testContext
	s.tasks.Add(1)
	s.mu.Unlock()
	defer s.tasks.Done()
	ctx, cancel := context.WithTimeout(testContext, time.Duration(timeoutMS)*time.Millisecond)
	defer cancel()
	select {
	case s.testSlots <- struct{}{}:
		defer func() { <-s.testSlots }()
	case <-ctx.Done():
		return 0, ctx.Err()
	}
	delay, err := proxy.URLTest(ctx, url, nil)
	if err != nil {
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		var timeout net.Error
		if errors.As(err, &timeout) && timeout.Timeout() {
			return 0, context.DeadlineExceeded
		}
		return 0, errors.New("proxy URL test failed")
	}
	return int64(delay), nil
}

func (s *Session) CancelTests() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cancelTests()
	if !s.closed {
		s.testContext, s.cancelTests = context.WithCancel(s.ctx)
	}
}
