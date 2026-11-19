#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
swiftc -O -target arm64-apple-macos13 \
    -F "$ROOT/build/MihomoBridge.xcframework/macos-arm64" -framework MihomoBridge -lresolv \
    "$ROOT/SnapshotStore/DiagnosticReport.swift" "$ROOT/PacketBridge/ProcessMetrics.swift" \
    "$ROOT/Tools/HostCapacity/main.swift" -o "$ROOT/build/host-capacity"
"$ROOT/build/host-capacity" "$@" > "$ROOT/build/host-capacity.json"
cat "$ROOT/build/host-capacity.json"
