#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
GO_BIN="${GO_BIN:-go}"
EXPECTED_GO="go1.27.1"
EXPECTED_CORE="024245dc72bc92f48237f865119afe0cd53ac9e6"

if [ "$("$GO_BIN" env GOVERSION)" != "$EXPECTED_GO" ]; then
    echo "This prototype requires $EXPECTED_GO; set GO_BIN to that Go executable." >&2
    exit 1
fi
if [ "$(git -C "$ROOT/vendor/mihomo" rev-parse HEAD)" != "$EXPECTED_CORE" ]; then
    echo "Mihomo checkout differs from the phase 0 baseline." >&2
    exit 1
fi
if [ -n "$(git -C "$ROOT/vendor/mihomo" status --porcelain)" ]; then
    echo "Mihomo checkout has local changes; the prototype needs the recorded baseline." >&2
    exit 1
fi

mkdir -p "$ROOT/build/tools"
export FLCLASH_GO_BINARY="$(command -v "$GO_BIN")"
GO_BIN="$FLCLASH_GO_BINARY"
export PATH="$ROOT/build/tools:$(dirname "$GO_BIN"):$PATH"
export GOTOOLCHAIN=local
OVERLAY="$(python3 "$ROOT/prepare-core-overlay.py")"
export FLCLASH_GO_OVERLAY="$OVERLAY"
cp "$ROOT/go-overlay-wrapper.sh" "$ROOT/build/tools/go"
chmod +x "$ROOT/build/tools/go"
export GOFLAGS="-mod=readonly -overlay=$OVERLAY"
cd "$ROOT/core"
"$GO_BIN" build -o "$ROOT/build/tools/gomobile" golang.org/x/mobile/cmd/gomobile
"$GO_BIN" build -o "$ROOT/build/tools/gobind" golang.org/x/mobile/cmd/gobind
FRAMEWORK_BUILD="$(mktemp -d "$ROOT/build/framework.XXXXXX")"
trap 'rm -rf "$FRAMEWORK_BUILD"' EXIT
"$ROOT/build/tools/gomobile" bind \
    -target=ios/arm64,iossimulator/arm64,macos/arm64 \
    -iosversion=18.0 -macosversion=13.0 \
    -tags=with_gvisor -trimpath \
    -o "$FRAMEWORK_BUILD/MihomoBridge.xcframework" ./mobile
if [ -d "$ROOT/build/MihomoBridge.xcframework" ]; then
    mv "$ROOT/build/MihomoBridge.xcframework" "$FRAMEWORK_BUILD/previous.xcframework"
fi
if ! mv "$FRAMEWORK_BUILD/MihomoBridge.xcframework" "$ROOT/build/MihomoBridge.xcframework"; then
    if [ -d "$FRAMEWORK_BUILD/previous.xcframework" ]; then
        mv "$FRAMEWORK_BUILD/previous.xcframework" "$ROOT/build/MihomoBridge.xcframework"
    fi
    exit 1
fi
"$GO_BIN" version > "$ROOT/build/core-build.txt"
printf 'Mihomo=%s\nTags=with_gvisor\nTargets=ios-arm64,ios-simulator-arm64,macos-arm64\n' \
    "$EXPECTED_CORE" >> "$ROOT/build/core-build.txt"
shasum -a 256 go.mod go.sum >> "$ROOT/build/core-build.txt"
shasum -a 256 mobile/*.go >> "$ROOT/build/core-build.txt"
shasum -a 256 "$ROOT/build-core.sh" "$ROOT/prepare-core-overlay.py" "$ROOT/go-overlay-wrapper.sh" >> "$ROOT/build/core-build.txt"

cat "$ROOT/build/mihomo-overlay-prepared/patches.sha256" >> "$ROOT/build/core-build.txt"
