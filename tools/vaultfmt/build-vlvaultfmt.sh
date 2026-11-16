#!/usr/bin/env bash
# Builds VLVaultfmt.xcframework (vl-vaultfmt's C API, vl_vaultfmt.h and vl_vaultfmt_engine.h, as the Swift module
# VLVaultfmt) from the source pinned in tools/vaultfmt/vlvaultfmt.pin, into build/vlvaultfmt/ (git-ignored), where
# Package.swift's binary target finds it. The binary is never committed: like VLKeykit, it is built from pinned source on
# every machine.
#
#   tools/vaultfmt/build-vlvaultfmt.sh           build unless build/vlvaultfmt already holds this pin's framework
#   tools/vaultfmt/build-vlvaultfmt.sh --force   build again
#
# Environment:
#   VLVAULTFMT_REPO   a local clone to take a git pin's commit from instead of the pinned URL (the commit must be in it)
#
# One copy of each library in the app: vl-vaultfmt is compiled against the vl-keykit source of tools/keykit/vlkeykit.pin
# (put in place of the 0.2.0 its own wrap names) and the archive holds vl-vaultfmt alone. vl-keykit and libcrypto come
# from VLKeykit.xcframework (tools/keykit/build-vlkeykit.sh), which every target linking VLVaultfmt also links. The
# library's own scripts/build-xcframework.sh bundles its vl-keykit 0.2.0 and libcrypto instead, which would put two
# versions of vl-keykit's C++ symbols into one binary.
#
# Needs Xcode, meson, ninja, pkg-config and Homebrew's openssl@3 and nlohmann-json (brew install meson ninja pkg-config
# openssl@3 nlohmann-json), the same as VLKeykit. A static arm64 library; nothing here is signed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=vlvaultfmt.pin
source "$root/tools/vaultfmt/vlvaultfmt.pin"
# shellcheck source=../keykit/vlkeykit.pin
source "$root/tools/keykit/vlkeykit.pin"
out="$root/build/vlvaultfmt"
force=0
for arg in "$@"; do
    case "$arg" in
        --force) force=1 ;;
        *) echo "usage: $0 [--force]" >&2; exit 2 ;;
    esac
done

stamp="source=$VLVAULTFMT_SOURCE version=$VLVAULTFMT_VERSION keykit=$VLKEYKIT_SOURCE archs=arm64"
if [[ $force == 0 && -f "$out/STAMP" && "$(cat "$out/STAMP")" == "$stamp" && -d "$out/VLVaultfmt.xcframework" ]]; then
    echo "VLVaultfmt.xcframework is current ($VLVAULTFMT_VERSION, $VLVAULTFMT_SOURCE)"
    exit 0
fi

# A file pin's tarball, checked before it is unpacked into $2.
unpack() {
    local spec="${1#file:}" path want have
    path="$root/${spec%%#*}"
    want="${spec##*#sha256=}"
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "a file pin ends in #sha256=<64 hex digits>: $1" >&2; exit 1; }
    [[ -f "$path" ]] || { echo "$path is missing" >&2; exit 1; }
    have="$(shasum -a 256 "$path" | cut -d' ' -f1)"
    [[ "$have" == "$want" ]] || { echo "$path: SHA-256 is $have, the pin says $want" >&2; exit 1; }
    mkdir -p "$2"
    tar -xf "$path" -C "$2" --strip-components 1
}

src="$out/src"
rm -rf "$src" "$out/work" "$out/VLVaultfmt.xcframework" "$out/STAMP"
mkdir -p "$out"

case "$VLVAULTFMT_SOURCE" in
    file:*) unpack "$VLVAULTFMT_SOURCE" "$src" ;;
    git+*)
        spec="${VLVAULTFMT_SOURCE#git+}"
        rev="${spec##*#}"
        [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || { echo "vlvaultfmt.pin: a git pin names a full commit" >&2; exit 1; }
        git clone --quiet --no-checkout "${VLVAULTFMT_REPO:-${spec%%#*}}" "$src"
        git -C "$src" -c advice.detachedHead=false checkout --quiet "$rev"
        [[ "$(git -C "$src" rev-parse HEAD)" == "$rev" ]] || { echo "checked out the wrong commit" >&2; exit 1; }
        ;;
    *) echo "vlvaultfmt.pin: VLVAULTFMT_SOURCE is file:<path>#sha256=<hex> or git+<url>#<commit>" >&2; exit 1 ;;
esac
grep -q "version: '$VLVAULTFMT_VERSION'" "$src/meson.build" || {
    echo "the pinned source isn't vl-vaultfmt $VLVAULTFMT_VERSION (meson.build)" >&2
    exit 1
}

# vl-keykit: the source VLKeykit is built from, as a plain subproject directory (no wrap, no download, no patch).
[[ "$VLKEYKIT_SOURCE" == file:* ]] || { echo "build-vlvaultfmt.sh needs tools/keykit/vlkeykit.pin to be a file pin" >&2; exit 1; }
rm -rf "$src/subprojects/vl-keykit.wrap" "$src/subprojects/packagecache" "$src/subprojects/packagefiles" \
    "$src/subprojects/vl-keykit"*
unpack "$VLKEYKIT_SOURCE" "$src/subprojects/vl-keykit"
grep -q "version: '$VLKEYKIT_VERSION'" "$src/subprojects/vl-keykit/meson.build" || {
    echo "tools/keykit/vlkeykit.pin isn't vl-keykit $VLKEYKIT_VERSION" >&2
    exit 1
}

# A hermetic build: no stray include or library paths from the shell.
unset CPATH LIBRARY_PATH CPPFLAGS CFLAGS CXXFLAGS LDFLAGS PKG_CONFIG_PATH CC CXX
for tool in meson ninja xcodebuild libtool lipo pkg-config; do
    command -v "$tool" > /dev/null || { echo "build-vlvaultfmt.sh: $tool is missing" >&2; exit 1; }
done
prefix="$(brew --prefix openssl@3 2> /dev/null || true)"
[[ -n "$prefix" && -d "$prefix/lib/pkgconfig" ]] || { echo "build-vlvaultfmt.sh: Homebrew's openssl@3 is missing" >&2; exit 1; }
json_pc="$(brew --prefix nlohmann-json 2> /dev/null || true)/share/pkgconfig"
target=27.0
work="$out/work"
mkdir -p "$work"
cat > "$work/cross.ini" << EOF
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-arch', 'arm64', '-mmacosx-version-min=$target']
cpp_args = ['-arch', 'arm64', '-mmacosx-version-min=$target']
c_link_args = ['-arch', 'arm64', '-mmacosx-version-min=$target']
cpp_link_args = ['-arch', 'arm64', '-mmacosx-version-min=$target']

[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
# The library's own options (scripts/build-xcframework.sh): release, NDEBUG, one unity file, no tests.
meson setup "$work/build" "$src" --cross-file "$work/cross.ini" --buildtype=release -Db_ndebug=true --wrap-mode=nodownload \
    --unity=on -Dunity_size=1000 -Dtests=disabled -Dpkg_config_path="$prefix/lib/pkgconfig:$json_pc" > "$work/setup.log"
meson compile -C "$work/build" > "$work/compile.log"
if grep -nE "warning:|WARNING:" "$work/setup.log" "$work/compile.log"; then
    echo "build-vlvaultfmt.sh: the build must be silent" >&2
    exit 1
fi
# vl-vaultfmt alone: vl-keykit and libcrypto are VLKeykit's. Meson puts the subproject's vl-keykit objects into
# libvl-vaultfmt.a; they are taken out again.
cp "$work/build/libvl-vaultfmt.a" "$work/libVLVaultfmt.a"
keykit_members=()
while IFS= read -r member; do
    [[ "$member" == *vl-keykit* ]] && keykit_members+=("$member")
done < <(ar -t "$work/libVLVaultfmt.a")
if [[ ${#keykit_members[@]} -gt 0 ]]; then
    ar -d "$work/libVLVaultfmt.a" "${keykit_members[@]}"
    ranlib "$work/libVLVaultfmt.a"
fi
if ar -t "$work/libVLVaultfmt.a" | grep -q vl-keykit || ! ar -t "$work/libVLVaultfmt.a" | grep -q vl-vaultfmt; then
    echo "build-vlvaultfmt.sh: libVLVaultfmt.a must hold vl-vaultfmt's objects and no vl-keykit's" >&2
    exit 1
fi

headers="$work/headers"
mkdir -p "$headers/VLVaultfmt"
cp "$src/include/vl/vaultfmt/vl_vaultfmt.h" "$src/include/vl/vaultfmt/vl_vaultfmt_engine.h" "$headers/VLVaultfmt/"
cat > "$headers/VLVaultfmt/module.modulemap" << 'EOF'
module VLVaultfmt {
    header "vl_vaultfmt.h"
    header "vl_vaultfmt_engine.h"
    link "c++"
    export *
}
EOF
xcodebuild -create-xcframework -library "$work/libVLVaultfmt.a" -headers "$headers" \
    -output "$out/VLVaultfmt.xcframework" > /dev/null
rm -rf "$src" "$work"
echo "$stamp" > "$out/STAMP"
echo "built $out/VLVaultfmt.xcframework ($VLVAULTFMT_VERSION against vl-keykit $VLKEYKIT_VERSION)"
