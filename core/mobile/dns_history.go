package mobile

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strings"
	"time"

	M "github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"
)

const runtimeDNSLimit = 200

type runtimeDNSQuery struct {
	ID             string   `json:"id"`
	Domain         string   `json:"domain"`
	Type           string   `json:"type"`
	Initiator      string   `json:"initiator"`
	Upstream       string   `json:"upstream"`
	Mode           string   `json:"mode"`
	Cached         bool     `json:"cached"`
	StartedAt      int64    `json:"startedAt"`
	DurationMS     int64    `json:"durationMS"`
	Status         string   `json:"status"`
	ResponseCode   string   `json:"responseCode"`
	Answers        []string `json:"answers"`
	OmittedAnswers int      `json:"omittedAnswers"`
}

func (t *runtimeTelemetry) addDNS(record M.QueryRecord) {
	value := runtimeDNSQuery{Domain: boundedRuntimeText(strings.TrimSuffix(record.Question.Name, "."), 256), Type: D.Type(record.Question.Qtype).String(),
		Initiator: boundedRuntimeText(record.Initiator, 64), Upstream: dnsUpstreamLabel(record.Upstream), Mode: record.Mode,
		Cached: record.Cached, StartedAt: record.Start.UnixMilli(), DurationMS: max(0, time.Since(record.Start).Milliseconds()), Status: "success", Answers: []string{}}
	if value.Mode == "" {
		value.Mode = "resolver"
	}
	var timeout net.Error
	switch {
	case errors.Is(record.Err, context.Canceled):
		value.Status = "cancelled"
	case errors.Is(record.Err, context.DeadlineExceeded), errors.As(record.Err, &timeout) && timeout.Timeout():
		value.Status = "timeout"
	case record.Err != nil:
		value.Status = "failed"
	}
	if record.Msg != nil && record.Err == nil {
		value.ResponseCode = D.RcodeToString[record.Msg.Rcode]
		if record.Msg.Rcode != D.RcodeSuccess {
			value.Status = "failed"
		}
		for _, answer := range record.Msg.Answer {
			if len(value.Answers) == 8 {
				value.OmittedAnswers++
				continue
			}
			value.Answers = append(value.Answers, boundedRuntimeText(answer.String(), 256))
		}
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.nextDNSID++
	value.ID = fmt.Sprintf("%s:dns:%d", t.sessionID, t.nextDNSID)
	if len(t.dnsQueries) == runtimeDNSLimit {
		copy(t.dnsQueries, t.dnsQueries[1:])
		t.dnsQueries = t.dnsQueries[:len(t.dnsQueries)-1]
		t.droppedDNSQueries++
	}
	t.dnsQueries = append(t.dnsQueries, value)
}

func dnsUpstreamLabel(value string) string {
	if parsed, err := url.Parse(value); err == nil && parsed.Host != "" {
		value = parsed.Scheme + "://" + parsed.Host
	}
	return boundedRuntimeText(value, 256)
}

func (s *Session) ClearDNSCache(expectedSessionID string) error {
	s.mu.Lock()
	if s.closed || s.telemetry.sessionID != expectedSessionID {
		s.mu.Unlock()
		return errors.New("the packet session is no longer current")
	}
	s.tasks.Add(1)
	s.mu.Unlock()
	defer s.tasks.Done()
	s.dnsOwner.runtime.Load().resolvers.ClearSessionCache()
	s.telemetry.addLog("info", "DNS resolver caches cleared by user; fake-IP mappings preserved")
	return nil
}
