#!/bin/bash
set -euo pipefail
# gomobile replaces GOFLAGS for Apple targets; restore the same core overlay for every Go subprocess.
export GOFLAGS="${GOFLAGS:-} -overlay=$FLCLASH_GO_OVERLAY"
exec "$FLCLASH_GO_BINARY" "$@"
