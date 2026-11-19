#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
GO_BIN="${GO_BIN:-go}"
OVERLAY="$(python3 "$ROOT/prepare-core-overlay.py")"
export GOTOOLCHAIN=local
export GOFLAGS="-mod=readonly -overlay=$OVERLAY"
cd "$ROOT/core"
"$GO_BIN" test -race -tags=with_gvisor -count=1 ./mobile
NATIVE_PACKAGES=(
    github.com/metacubex/mihomo/component/pool
    github.com/metacubex/mihomo/component/sniffer
    github.com/metacubex/mihomo/transport/snell
    github.com/metacubex/mihomo/transport/tuic/...
    github.com/metacubex/mihomo/config
    github.com/metacubex/mihomo/dns
    github.com/metacubex/mihomo/adapter/provider
    github.com/metacubex/mihomo/rules/provider
    github.com/metacubex/mihomo/rules/logic
)
"$GO_BIN" test -race -tags=with_gvisor -count=1 "${NATIVE_PACKAGES[@]}"
"$GO_BIN" test -race -tags=with_gvisor -count=1 -run '^TestMobile' github.com/metacubex/mihomo/adapter/outbound
"$GO_BIN" vet -tags=with_gvisor ./... "${NATIVE_PACKAGES[@]}" github.com/metacubex/mihomo/adapter/outbound
