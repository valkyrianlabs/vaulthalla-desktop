#!/bin/sh
# Builds the vaulthalla-1password helper for Apple Silicon into Helpers/vaulthalla-1password/bin/ (gitignored).
#
#   ./build.sh          release build: bin/vaulthalla-1password
#   ./build.sh --fake   test build with the in-memory 1Password (VH_OP_FAKE=1): bin/vaulthalla-1password-fake
#
# CGO is required: 1Password's desktop-app integration dlopen()s libop_sdk_ipc_client.dylib from the 1Password
# app through cgo; without it the SDK refuses WithDesktopAppIntegration. Signing and bundling into the app happen
# in the app build (see README.md); this script only compiles.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

name=vaulthalla-1password
tags=""
if [ "${1:-}" = "--fake" ]; then
    name=vaulthalla-1password-fake
    tags="-tags=fake"
elif [ $# -gt 0 ]; then
    echo "usage: $0 [--fake]" >&2
    exit 2
fi

version=$(cat "$repo/VERSION" 2>/dev/null || echo 0.0.0)
if commit=$(git -C "$repo" rev-parse --short=12 HEAD 2>/dev/null); then
    version="$version+$commit"
    if ! git -C "$repo" diff --quiet HEAD -- "$here" 2>/dev/null; then
        version="$version.dirty"
    fi
fi

mkdir -p "$here/bin"
cd "$here"
# shellcheck disable=SC2086 # $tags is empty or one word
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 MACOSX_DEPLOYMENT_TARGET=27.0 \
    go build $tags -trimpath -buildvcs=false \
    -ldflags "-s -w -X main.version=$version" \
    -o "bin/$name" .

echo "built $here/bin/$name ($version)"
