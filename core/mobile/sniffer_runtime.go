package mobile

import (
	"errors"
	"fmt"
	"net"
	"reflect"
	"strings"

	N "github.com/metacubex/mihomo/common/net"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/sniffer"
	MConfig "github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"go.yaml.in/yaml/v3"
)

func validateSnifferConfiguration(root *yaml.Node, raw MConfig.RawSniffer) error {
	for i := 0; i < len(root.Content); i += 2 {
		if root.Content[i].Value != "sniffer" {
			continue
		}
		node := root.Content[i+1]
		if err := validateYAMLFields(node, reflect.TypeFor[MConfig.RawSniffer](), "sniffer"); err != nil {
			return err
		}
		for j := 0; j < len(node.Content); j += 2 {
			if node.Content[j].Value != "sniff" {
				continue
			}
			protocols := node.Content[j+1]
			if protocols.Tag == "!!null" {
				continue
			}
			if protocols.Kind != yaml.MappingNode {
				return errors.New("sniffer.sniff must be a mapping")
			}
			for k := 0; k < len(protocols.Content); k += 2 {
				if err := validateYAMLFields(protocols.Content[k+1], reflect.TypeFor[MConfig.RawSniffingConfig](), "sniffer.sniff."+protocols.Content[k].Value); err != nil {
					return err
				}
			}
		}
	}
	portLists := [][]string{raw.Ports}
	for _, config := range raw.Sniff {
		portLists = append(portLists, config.Ports)
	}
	for _, ports := range portLists {
		ranges, err := utils.NewUnsignedRangesFromList[uint64](ports)
		if err != nil {
			return errors.New("sniffer ports must be integers or ranges from 1 to 65535")
		}
		for _, port := range ranges {
			if port.Start() < 1 || port.End() > 65535 {
				return errors.New("sniffer ports must be integers or ranges from 1 to 65535")
			}
		}
	}
	if !raw.Enable {
		return nil
	}
	protocols := raw.Sniffing
	if len(raw.Sniff) > 0 {
		protocols = nil
		for name := range raw.Sniff {
			protocols = append(protocols, name)
		}
	}
	for _, protocol := range protocols {
		if !strings.EqualFold(protocol, "HTTP") && !strings.EqualFold(protocol, "TLS") {
			return fmt.Errorf("sniffer %s is unsupported on iOS; packetFlow TCP supports HTTP and TLS", protocol)
		}
	}
	return nil
}

func (r *routingConfiguration) buildSniffer(config *yamlConfiguration) error {
	if !config.Raw.Sniffer.Enable {
		return nil
	}
	parsed, err := MConfig.ParseMobileSniffer(config.Raw.Sniffer, r.ruleProviders, r)
	if err != nil {
		return fmt.Errorf("sniffer: %w", err)
	}
	r.sniffer, err = sniffer.NewDispatcher(parsed)
	r.warnings = append(r.warnings, "sniffer handles packetFlow TCP HTTP/TLS; explicit proxy sharing keeps the client-supplied target")
	return err
}

func (s *Session) sniffTCP(inbound net.Conn, target *C.Metadata) (net.Conn, error) {
	if s.routing == nil || !s.routing.sniffer.Enable() || target.Type != C.TUN {
		return inbound, nil
	}
	var restoreErr error
	if s.routing.dns != nil {
		restoreErr = s.routing.dns.restore(target)
	}
	stream := N.NewBufferedConn(inbound)
	if s.routing.sniffer.TCPSniff(stream, target) {
		return stream, nil
	}
	return stream, restoreErr
}
