#!/bin/sh
# Builds the vaulthalla-1password helper for Apple Silicon into Helpers/vaulthalla-1password/bin/ (gitignored).
#
#   ./build.sh                  release build: bin/vaulthalla-1password
#   ./build.sh --fake           test build with the in-memory 1Password (VH_OP_FAKE=1): bin/vaulthalla-1password-fake
#   ./build.sh --output PATH    release build to PATH (the app build: Xcode's vaulthalla-1password target)
#
# CGO is required: 1Password's desktop-app integration dlopen()s libop_sdk_ipc_client.dylib from the 1Password
# app through cgo; without it the SDK refuses WithDesktopAppIntegration. Signing and bundling into the app happen
# in the app build (README.md, "Signing and entitlements"); this script only compiles.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

name=vaulthalla-1password
tags=""
output=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fake) name=vaulthalla-1password-fake; tags="-tags=fake" ;;
        --output) [ $# -ge 2 ] || { echo "usage: $0 [--fake] [--output PATH]" >&2; exit 2; }; output=$2; shift ;;
        *) echo "usage: $0 [--fake] [--output PATH]" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$output" ] || output="$here/bin/$name"

# Xcode runs scripts with a minimal PATH: look where Go installs itself too.
go=${GO:-}
if [ -z "$go" ]; then
    go=$(PATH="$PATH:/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin" command -v go || true)
fi
if [ -z "$go" ] || [ ! -x "$go" ]; then
    echo "error: Go is required to build the vaulthalla-1password helper (Helpers/vaulthalla-1password). Install it (brew install go, or https://go.dev/dl) and build again." >&2
    exit 1
fi

# The default build cache may not be writable (sandboxed builds, CI): fall back to a private one.
if [ -z "${GOCACHE:-}" ]; then
    cache=$("$go" env GOCACHE 2>/dev/null || true)
    if [ -z "$cache" ] || ! { mkdir -p "$cache" 2>/dev/null && [ -w "$cache" ]; }; then
        GOCACHE="${TMPDIR:-/tmp}/vh-op-gocache"
        export GOCACHE
    fi
fi

version=$(cat "$repo/VERSION" 2>/dev/null || echo 0.0.0)
if commit=$(git -C "$repo" rev-parse --short=12 HEAD 2>/dev/null); then
    version="$version+$commit"
    if ! git -C "$repo" diff --quiet HEAD -- "$here" 2>/dev/null; then
        version="$version.dirty"
    fi
fi

mkdir -p "$(dirname "$output")"
cd "$here"
# shellcheck disable=SC2086 # $tags is empty or one word
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 MACOSX_DEPLOYMENT_TARGET=27.0 \
    "$go" build $tags -trimpath -buildvcs=false \
    -ldflags "-s -w -X main.version=$version" \
    -o "$output" .

echo "built $output ($version)"
