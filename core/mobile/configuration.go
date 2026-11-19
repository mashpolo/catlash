package mobile

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
)

type configuration struct {
	Version  int             `json:"version"`
	MTU      int32           `json:"mtu"`
	Outbound json.RawMessage `json:"outbound"`
}

type outboundConfiguration struct {
	Type     string `json:"type"`
	Server   string `json:"server,omitempty"`
	Port     int    `json:"port,omitempty"`
	Username string `json:"username,omitempty"`
	Password string `json:"password,omitempty"`
	UDP      *bool  `json:"udp,omitempty"`
}

func NewConfiguredSession(value string) (*Session, error) {
	if len(value) > 16*1024 {
		return nil, errors.New("configuration exceeds 16 KiB")
	}
	var config configuration
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return nil, err
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return nil, errors.New("configuration must contain one JSON object")
	}
	if config.Version != 1 {
		return nil, errors.New("unsupported configuration version")
	}
	proxy, err := parseOutbound(config.Outbound)
	if err != nil {
		return nil, err
	}
	return newSession(config.MTU, proxy, defaultUDPIdleTimeout)
}

func parseOutbound(raw json.RawMessage) (map[string]any, error) {
	var outbound outboundConfiguration
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&outbound); err != nil {
		return nil, err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return nil, err
	}
	for _, value := range fields {
		if bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return nil, errors.New("outbound fields cannot be null")
		}
	}
	proxy := map[string]any{"name": "OUTBOUND", "type": outbound.Type}
	switch outbound.Type {
	case "direct":
		if len(fields) != 1 {
			return nil, errors.New("DIRECT does not accept proxy options")
		}
	case "socks5":
		if strings.TrimSpace(outbound.Server) == "" || outbound.Port < 1 || outbound.Port > 65535 {
			return nil, errors.New("SOCKS5 requires a server and port between 1 and 65535")
		}
		if len(outbound.Username) > 255 || len(outbound.Password) > 255 {
			return nil, errors.New("SOCKS5 credentials must fit in 255 bytes")
		}
		proxy["server"], proxy["port"] = outbound.Server, outbound.Port
		udp := true
		if outbound.UDP != nil {
			udp = *outbound.UDP
		}
		proxy["username"], proxy["password"], proxy["udp"] = outbound.Username, outbound.Password, udp
	default:
		return nil, errors.New("phase 1 supports DIRECT and SOCKS5 outbound configurations")
	}
	return proxy, nil
}
