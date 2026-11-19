package mobile

import (
	"context"
	"errors"
	"net/url"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/common/structure"
	"github.com/metacubex/mihomo/common/utils"
	P "github.com/metacubex/mihomo/constant/provider"
)

type healthConfiguration struct {
	Enable         bool   `provider:"enable"`
	URL            string `provider:"url,omitempty"`
	Interval       int    `provider:"interval,omitempty"`
	Timeout        int    `provider:"timeout,omitempty"`
	Lazy           bool   `provider:"lazy,omitempty"`
	ExpectedStatus string `provider:"expected-status,omitempty"`
}
type sessionProvider struct {
	P.ProxyProvider
	touched   atomic.Int64
	healthURL string
}

func (p *sessionProvider) Touch()                 { p.touched.Store(time.Now().UnixNano()); p.ProxyProvider.Touch() }
func (p *sessionProvider) HealthCheckURL() string { return p.healthURL }

type healthJob struct {
	provider            *sessionProvider
	url                 string
	interval, timeLimit time.Duration
	lazy                bool
	expectedStatus      utils.IntRanges[uint16]
}

func (r *routingConfiguration) configureHealth(provider P.ProxyProvider, value any) (P.ProxyProvider, error) {
	config := healthConfiguration{Interval: 300, Timeout: 5000, Lazy: true}
	if value != nil {
		decoder := structure.NewDecoder(structure.Option{TagName: "provider", WeaklyTypedInput: true})
		mapping, ok := value.(map[string]any)
		if !ok {
			return nil, errors.New("health-check must be a mapping")
		}
		if err := decoder.Decode(mapping, &config); err != nil {
			return nil, errors.New("invalid provider health-check options")
		}
	}
	wrapped := &sessionProvider{ProxyProvider: provider, healthURL: config.URL}
	if !config.Enable {
		return wrapped, nil
	}
	parsed, err := url.Parse(config.URL)
	if err != nil || parsed.User != nil || parsed.Hostname() == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return nil, errors.New("health-check URL must be HTTP or HTTPS without credentials")
	}
	if config.Interval == 0 {
		config.Interval = 300
	}
	if config.Timeout == 0 {
		config.Timeout = 5000
	}
	if config.Interval < 1 || config.Interval > 86400 || config.Timeout < 1 || config.Timeout > 60000 {
		return nil, errors.New("health-check interval or timeout is outside supported bounds")
	}
	statuses, err := utils.NewUnsignedRanges[uint16](config.ExpectedStatus)
	if err != nil {
		return nil, errors.New("invalid health-check expected-status")
	}
	core := provider
	for {
		wrapped, ok := core.(*sessionProvider)
		if !ok {
			break
		}
		core = wrapped.ProxyProvider
	}
	for _, job := range r.healthJobs {
		previous := job.provider.ProxyProvider
		for {
			wrapped, ok := previous.(*sessionProvider)
			if !ok {
				break
			}
			previous = wrapped.ProxyProvider
		}
		if previous == core && job.url == config.URL {
			return job.provider, nil
		}
	}
	r.healthJobs = append(r.healthJobs, healthJob{provider: wrapped, url: config.URL, interval: time.Duration(config.Interval) * time.Second, timeLimit: time.Duration(config.Timeout) * time.Millisecond, lazy: config.Lazy, expectedStatus: statuses})
	return wrapped, nil
}
func (s *Session) startHealthChecks() {
	if s.routing == nil {
		return
	}
	previous := s.routing.healthCancels
	current := make(map[*sessionProvider]context.CancelFunc, len(s.routing.healthJobs))
	for _, job := range s.routing.healthJobs {
		if cancel := previous[job.provider]; cancel != nil {
			current[job.provider] = cancel
			delete(previous, job.provider)
			continue
		}
		ctx, cancel := context.WithCancel(s.ctx)
		current[job.provider] = cancel
		s.tasks.Add(1)
		go func() { defer s.tasks.Done(); s.runHealthJob(ctx, job) }()
	}
	for _, cancel := range previous {
		cancel()
	}
	s.routing.healthCancels = current
}
func (s *Session) runHealthJob(owner context.Context, job healthJob) {
	check := func() {
		for _, proxy := range job.provider.Proxies() {
			ctx, cancel := context.WithTimeout(owner, job.timeLimit)
			select {
			case s.testSlots <- struct{}{}:
				_, _ = proxy.URLTest(ctx, job.url, job.expectedStatus)
				<-s.testSlots
			case <-ctx.Done():
			}
			cancel()
			if owner.Err() != nil {
				return
			}
		}
	}
	check()
	ticker := time.NewTicker(job.interval)
	defer ticker.Stop()
	for {
		select {
		case <-owner.Done():
			return
		case <-ticker.C:
			if !job.lazy || time.Since(time.Unix(0, job.provider.touched.Load())) < job.interval {
				check()
			}
		}
	}
}
