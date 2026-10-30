#!/bin/bash
# Builds the Developer ID release: a signed app, notarized and stapled, in a signed, notarized and stapled DMG.
#
#   tools/release/build.sh [--out DIR]     DIR defaults to build/release
#
# Needs, in the keychain search list: the "Developer ID Application: Valkyrian Labs LLC (ZG2G6V7GLC)" identity, and
# the Developer ID profiles "Vaulthalla Desktop" (sh.vaulthalla.app), "Vaulthalla Desktop Finder"
# (sh.vaulthalla.app.fileprovider) and "Vaulthalla Desktop MCP" (sh.vaulthalla.app.mcp) installed for Xcode. Signing
# settings: DeveloperID.xcconfig.
#
#   VH_NOTARY_PROFILE   a `xcrun notarytool store-credentials` profile: notarize and staple (unset: signed only)
#   VH_BUILD_NUMBER     CFBundleVersion (default: the commit count, which only grows on main)
#
# The marketing version is VERSION. Writes Vaulthalla-<version>.dmg and its .sha256 to DIR.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

out="$repo/build/release"
while [ $# -gt 0 ]; do
    case "$1" in
        --out) [ $# -ge 2 ] || { echo "usage: $0 [--out DIR]" >&2; exit 2; }; out=$2; shift ;;
        *) echo "usage: $0 [--out DIR]" >&2; exit 2 ;;
    esac
    shift
done

log() { printf '==> %s\n' "$*"; }

version=$(tr -d '[:space:]' < "$repo/VERSION")
build=${VH_BUILD_NUMBER:-$(git -C "$repo" rev-list --count HEAD)}
identity="Developer ID Application: Valkyrian Labs LLC (ZG2G6V7GLC)"
work="$out/work"
rm -rf "$work"
mkdir -p "$work"

log "Archive $version ($build)"
xcodebuild -project "$repo/App/Vaulthalla.xcodeproj" -scheme Vaulthalla -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$work/DerivedData" \
    -archivePath "$work/Vaulthalla.xcarchive" -xcconfig "$here/DeveloperID.xcconfig" \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" -quiet archive
app="$work/Vaulthalla.xcarchive/Products/Applications/Vaulthalla.app"

log "Verify signatures"
codesign --verify --deep --strict --verbose=2 "$app"
# A Release build must never ship the debugger entitlement (notarization rejects it anyway).
# (Captured first: `grep -q` closing the pipe early would fail codesign under pipefail.)
for code in "$app" "$app"/Contents/PlugIns/*.appex "$app"/Contents/Helpers/*; do
    [ -L "$code" ] && continue  # Contents/Helpers/vaulthalla-mcp points into vaulthalla-mcp.app
    entitlements=$(codesign -d --entitlements - --xml "$code" 2>/dev/null)
    if [[ $entitlements == *get-task-allow* ]]; then
        echo "error: $code carries get-task-allow" >&2
        exit 1
    fi
    details=$(codesign -dvv "$code" 2>&1)
    [[ $details == *"Authority=$identity"* ]] || { echo "error: $code is not signed by $identity" >&2; exit 1; }
done

notarize() {
    local file=$1 result id status
    result=$(xcrun notarytool submit "$file" --keychain-profile "$VH_NOTARY_PROFILE" --wait --output-format json)
    id=$(plutil -extract id raw -o - - <<<"$result")
    status=$(plutil -extract status raw -o - - <<<"$result")
    if [ "$status" != "Accepted" ]; then
        echo "error: notarization of $(basename "$file") ended $status" >&2
        xcrun notarytool log "$id" --keychain-profile "$VH_NOTARY_PROFILE" >&2 || true
        exit 1
    fi
    log "Notarized $(basename "$file") ($id)"
}

# The app is notarized and stapled on its own first, so a copy dragged out of the DMG opens offline too.
if [ -n "${VH_NOTARY_PROFILE:-}" ]; then
    log "Notarize the app"
    ditto -c -k --keepParent "$app" "$work/Vaulthalla.zip"
    notarize "$work/Vaulthalla.zip"
    xcrun stapler staple "$app"
else
    log "VH_NOTARY_PROFILE unset: signed, not notarized"
fi

name="Vaulthalla-$version.dmg"
dmg="$out/$name"
log "Build $name"
mkdir -p "$work/dmg"
ditto "$app" "$work/dmg/Vaulthalla.app"
ln -s /Applications "$work/dmg/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "Vaulthalla" -srcfolder "$work/dmg" -fs APFS -format ULFO "$dmg"
codesign --force --sign "$identity" --timestamp "$dmg"

if [ -n "${VH_NOTARY_PROFILE:-}" ]; then
    log "Notarize the DMG"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
fi

(cd "$out" && shasum -a 256 "$name" > "$name.sha256")
log "$dmg"
