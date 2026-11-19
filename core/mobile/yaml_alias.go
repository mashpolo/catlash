package mobile

import (
	"errors"

	"go.yaml.in/yaml/v3"
)

func normalizeYAMLNode(node *yaml.Node, path string) (*yaml.Node, error) {
	if err := validateYAMLNode(node, path); err != nil {
		return nil, err
	}
	if !hasYAMLAliases(node) {
		return node, nil
	}
	if _, err := expandedYAMLSize(node, make(map[*yaml.Node]int), make(map[*yaml.Node]bool)); err != nil {
		return nil, err
	}
	var value map[string]any
	if err := node.Decode(&value); err != nil {
		return nil, errors.New("invalid YAML aliases or merge")
	}
	var normalized yaml.Node
	if err := normalized.Encode(value); err != nil {
		return nil, errors.New("invalid expanded YAML")
	}
	if err := validateYAMLNode(&normalized, path); err != nil {
		return nil, err
	}
	return &normalized, nil
}

func hasYAMLAliases(node *yaml.Node) bool {
	if node.Kind == yaml.AliasNode || node.Tag == "!!merge" {
		return true
	}
	for _, child := range node.Content {
		if hasYAMLAliases(child) {
			return true
		}
	}
	return false
}

func expandedYAMLSize(node *yaml.Node, memo map[*yaml.Node]int, active map[*yaml.Node]bool) (int, error) {
	if size, ok := memo[node]; ok {
		return size, nil
	}
	if active[node] {
		return 0, errors.New("YAML alias contains a cycle")
	}
	active[node] = true
	defer delete(active, node)
	size := len(node.Value) + 16
	children := node.Content
	if node.Kind == yaml.AliasNode {
		children = []*yaml.Node{node.Alias}
	}
	for _, child := range children {
		childSize, err := expandedYAMLSize(child, memo, active)
		if err != nil {
			return 0, err
		}
		size += childSize
		if size > 16*1024*1024 {
			return 0, errors.New("expanded YAML exceeds 16 MiB")
		}
	}
	memo[node] = size
	return size, nil
}
