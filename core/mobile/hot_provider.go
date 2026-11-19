package mobile

import (
	"context"
	"crypto/sha256"
	"errors"
	"sync/atomic"

	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

// Rules, DNS policies and the sniffer keep this handle for the entire session.
// Every lookup sees one complete immutable generation.
type liveRuleProvider struct {
	current atomic.Pointer[P.RuleProvider]
}

func (p *liveRuleProvider) rule() P.RuleProvider       { return *p.current.Load() }
func (p *liveRuleProvider) Name() string               { return p.rule().Name() }
func (p *liveRuleProvider) VehicleType() P.VehicleType { return p.rule().VehicleType() }
func (p *liveRuleProvider) Type() P.ProviderType       { return p.rule().Type() }
func (p *liveRuleProvider) Initial() error             { return p.rule().Initial() }
func (p *liveRuleProvider) Update() error              { return p.rule().Update() }
func (p *liveRuleProvider) Behavior() P.RuleBehavior   { return p.rule().Behavior() }
func (p *liveRuleProvider) Count() int                 { return p.rule().Count() }
func (p *liveRuleProvider) Strategy() any              { return p.rule().Strategy() }
func (p *liveRuleProvider) Match(metadata *C.Metadata, helper C.RuleMatchHelper) bool {
	return p.rule().Match(metadata, helper)
}

func (s *Session) NewProviderUpdate(value, resourceRoot, stateRoot, kind, name string) (*ResourcePreparation, error) {
	hash := sha256.Sum256([]byte(value))
	s.mu.Lock()
	if s.closed || s.routing == nil || s.routing.inspection.sourceHash != hash || s.routing.stateRoot != stateRoot || s.routing.inspection.resourceRoot != resourceRoot {
		s.mu.Unlock()
		return nil, errors.New("active configuration changed")
	}
	ctx, cancel := context.WithCancel(s.ctx)
	s.mu.Unlock()
	config, err := parseYAML(value)
	if err != nil {
		cancel()
		return nil, err
	}
	p := &ResourcePreparation{hotUpdate: true, sourceHash: hash, resourceRoot: resourceRoot, stateRoot: stateRoot, session: s, config: config, ctx: ctx, cancel: cancel}
	if err = p.RefreshProvider(kind, name); err != nil {
		cancel()
		return nil, err
	}
	return p, nil
}

func (p *ResourcePreparation) UpdateProvider() error {
	p.mu.Lock()
	if !p.hotUpdate || p.started {
		p.mu.Unlock()
		return errors.New("invalid or already started provider update")
	}
	p.started = true
	p.mu.Unlock()
	defer func() {
		p.cancel()
		p.session = nil
		p.config = nil
		p.subscriptionHeader = ""
	}()
	s := p.session
	if !s.providerUpdateMu.TryLock() {
		return errors.New("another provider update is in progress")
	}
	defer s.providerUpdateMu.Unlock()
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return context.Canceled
	}
	key := *p.target
	var row *runtimeProvider
	for i := range s.routing.inspection.providers {
		item := &s.routing.inspection.providers[i]
		if item.Kind == key.kind && item.Name == key.name {
			row = item
			break
		}
	}
	if row == nil || row.Status != "ready" {
		s.mu.Unlock()
		return errors.New("provider is still being prepared")
	}
	currentHash := row.contentHash
	otherBytes := s.routing.inspection.resourceBytes - row.contentSize
	s.tasks.Add(1)
	s.mu.Unlock()
	defer s.tasks.Done()
	if err := p.ctx.Err(); err != nil {
		return err
	}
	mapping := p.config.RuleProviders[key.name]
	if key.kind == "proxy-provider" {
		mapping = p.config.ProxyProviders[key.name]
	}
	data, err := p.downloadProvider(s, key, mapping)
	if err != nil {
		return err
	}
	if err = p.ctx.Err(); err != nil {
		return err
	}
	if len(data) > maximumResourceBundleBytes-otherBytes {
		return errors.New("resource bundle exceeds 64 MiB")
	}
	nextHash := sha256.Sum256(data)
	var commit, discard func()
	if nextHash != currentHash {
		if key.kind == "proxy-provider" {
			commit, discard, err = s.prepareHotProxy(p, key, data)
		} else {
			commit, err = s.prepareHotRule(key, mapping, data)
		}
		if err != nil {
			return err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || p.ctx.Err() != nil {
		if discard != nil {
			discard()
		}
		return context.Canceled
	}
	// Closing the session and starting a replacement serialize with this commit.
	// Once the cache is visible, publish the same generation to all live readers.
	if err = p.persistHotProvider(key, data); err != nil {
		if discard != nil {
			discard()
		}
		return err
	}
	if commit != nil {
		commit()
		if key.kind == "proxy-provider" {
			*row.Count = s.routing.proxyProviders[key.name].Count()
		} else {
			*row.Count = s.routing.ruleProviders[key.name].Count()
		}
		row.contentHash = nextHash
		row.contentSize = len(data)
		s.routing.inspection.resourceBytes = otherBytes + len(data)
	}
	row.providerReceipt = saveProviderReceipt(p.stateRoot, key, mapping, data, p.subscriptionHeader)
	return nil
}

func (s *Session) prepareHotRule(key resourceKey, mapping map[string]any, data []byte) (func(), error) {
	live, ok := s.routing.ruleProviders[key.name].(*liveRuleProvider)
	if !ok {
		return nil, errors.New("rule provider is still being prepared")
	}
	r := &routingConfiguration{resources: map[resourceKey][]byte{key: data}, ruleProviders: map[string]P.RuleProvider{}, domainRulesEnabled: s.routing.domainRulesEnabled, geo: s.routing.geo}
	config := &yamlConfiguration{RuleProviders: map[string]map[string]any{key.name: mapping}}
	if err := r.loadMissingRuleProviders(config); err != nil {
		return nil, err
	}
	next := r.ruleProviders[key.name]
	// Mihomo classical strategies retain their parser after construction.
	r.resources = nil
	r.ruleProviders = nil
	return func() { live.current.Store(&next) }, nil
}
