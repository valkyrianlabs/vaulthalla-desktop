#!/usr/bin/env bash
# Builds VLKeykit.xcframework (vl-keykit's C API as the Swift module VLKeykit) from the source pinned in
# tools/keykit/vlkeykit.pin, into build/vlkeykit/ (git-ignored), where Package.swift's binary target finds it. The
# binary is never committed: like the 1Password helper, it is built from pinned source on every machine.
#
#   tools/keykit/build-vlkeykit.sh             build unless build/vlkeykit already holds this pin's framework
#   tools/keykit/build-vlkeykit.sh --force     build again
#   tools/keykit/build-vlkeykit.sh --vendor-vectors
#                                              also copy the pin's golden vectors into Tests/VHKeykitTests/Resources
#
# Environment:
#   VLKEYKIT_REPO   a local clone to take a git pin's commit from instead of the pinned URL (the commit must be in it)
#   GH_TOKEN        only for a git or https pin of the private repository; the committed tarball needs none
#
# Needs Xcode, meson, ninja, pkg-config and Homebrew's openssl@3 and nlohmann-json (brew install meson ninja
# pkg-config openssl@3 nlohmann-json). The framework is a static arm64 library with libcrypto linked in; nothing here
# is signed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=vlkeykit.pin
source "$root/tools/keykit/vlkeykit.pin"
out="$root/build/vlkeykit"
vectors_dir="$root/Tests/VHKeykitTests/Resources"
force=0
vendor=0
for arg in "$@"; do
    case "$arg" in
        --force) force=1 ;;
        --vendor-vectors) vendor=1 ;;
        *) echo "usage: $0 [--force] [--vendor-vectors]" >&2; exit 2 ;;
    esac
done

stamp="source=$VLKEYKIT_SOURCE version=$VLKEYKIT_VERSION archs=arm64"
if [[ $force == 0 && $vendor == 0 && -f "$out/STAMP" && "$(cat "$out/STAMP")" == "$stamp" && -d "$out/VLKeykit.xcframework" ]]; then
    echo "VLKeykit.xcframework is current ($VLKEYKIT_VERSION, $VLKEYKIT_SOURCE)"
    exit 0
fi

src="$out/src"
rm -rf "$src" "$out/work" "$out/VLKeykit.xcframework" "$out/STAMP"
mkdir -p "$out"

authed() {  # a github.com URL with the token, when there is one
    if [[ -n "${GH_TOKEN:-}" && "$1" == https://github.com/* ]]; then
        echo "https://x-access-token:${GH_TOKEN}@github.com/${1#https://github.com/}"
    else
        echo "$1"
    fi
}

case "$VLKEYKIT_SOURCE" in
    file:*)
        spec="${VLKEYKIT_SOURCE#file:}"
        path="$root/${spec%%#*}"
        want="${spec##*#sha256=}"
        [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "vlkeykit.pin: a file pin ends in #sha256=<64 hex digits>" >&2; exit 1; }
        [[ -f "$path" ]] || { echo "vlkeykit.pin: $path is missing" >&2; exit 1; }
        have="$(shasum -a 256 "$path" | cut -d' ' -f1)"
        [[ "$have" == "$want" ]] || { echo "the tarball's SHA-256 is $have, the pin says $want" >&2; exit 1; }
        mkdir -p "$src"
        tar -xf "$path" -C "$src" --strip-components 1
        ;;
    git+*)
        spec="${VLKEYKIT_SOURCE#git+}"
        url="${spec%%#*}"
        rev="${spec##*#}"
        [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || { echo "vlkeykit.pin: a git pin names a full commit" >&2; exit 1; }
        from="${VLKEYKIT_REPO:-$(authed "$url")}"
        git clone --quiet --no-checkout "$from" "$src"
        git -C "$src" -c advice.detachedHead=false checkout --quiet "$rev"
        [[ "$(git -C "$src" rev-parse HEAD)" == "$rev" ]] || { echo "checked out the wrong commit" >&2; exit 1; }
        ;;
    https://*)
        url="${VLKEYKIT_SOURCE%%#*}"
        want="${VLKEYKIT_SOURCE##*#sha256=}"
        [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "vlkeykit.pin: a tarball pin ends in #sha256=<64 hex digits>" >&2; exit 1; }
        headers=()
        [[ -n "${GH_TOKEN:-}" ]] && headers=(-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/octet-stream")
        curl -fsSL "${headers[@]}" -o "$out/source.tar.gz" "$url"
        have="$(shasum -a 256 "$out/source.tar.gz" | cut -d' ' -f1)"
        [[ "$have" == "$want" ]] || { echo "the tarball's SHA-256 is $have, the pin says $want" >&2; exit 1; }
        mkdir -p "$src"
        tar -xzf "$out/source.tar.gz" -C "$src" --strip-components 1
        rm "$out/source.tar.gz"
        ;;
    *) echo "vlkeykit.pin: VLKEYKIT_SOURCE is file:<path>#sha256=<hex>, git+<url>#<commit> or <https url>#sha256=<hex>" >&2; exit 1 ;;
esac

grep -q "version: '$VLKEYKIT_VERSION'" "$src/meson.build" || {
    echo "the pinned source isn't vl-keykit $VLKEYKIT_VERSION (meson.build)" >&2
    exit 1
}

# The library's own script, arm64 only (Vaulthalla Desktop is Apple silicon only), for macOS 27.
ARCHS=arm64 MACOSX_DEPLOYMENT_TARGET=27.0 "$src/scripts/build-xcframework.sh" "$out/work"
mv "$out/work/VLKeykit.xcframework" "$out/VLKeykit.xcframework"

# The golden vectors the Swift wrapper's tests read must be this source's.
for f in vhc.json vectors.json; do
    if [[ $vendor == 1 ]]; then
        mkdir -p "$vectors_dir"
        cp "$src/vectors/$f" "$vectors_dir/$f"
    elif ! cmp -s "$src/vectors/$f" "$vectors_dir/$f"; then
        echo "Tests/VHKeykitTests/Resources/$f differs from the pinned source's: run with --vendor-vectors" >&2
        exit 1
    fi
done
rm -rf "$src" "$out/work"
echo "$stamp" > "$out/STAMP"
echo "built $out/VLKeykit.xcframework ($VLKEYKIT_VERSION)"
