#!/bin/bash
# Signed-build proof that DeviceIdentityStore creates, finds, rotates and deletes Secure Enclave identities in the
# data protection keychain (valkyrianlabs/vaulthalla-desktop#11). CI can't run it: it needs a team-signed app, because
# keychain-access-groups is a restricted entitlement that only a provisioning profile grants.
#
#   tools/keychain-proof/run.sh <TEAM_ID> [bundle id]
#
# Builds tools/keychain-proof (an LSUIElement app that links VHIdentity, entitled for the keychain group
# <TEAM_ID>.<bundle id>) with automatic provisioning, runs it once with the default access group and once with the
# explicit group, and deletes the build. The bundle id defaults to sh.vaulthalla.desktop.keychain-proof; a free
# Personal Team registers it on first use (free teams may register 10 App IDs per 7 days, so reusing an existing one,
# such as a spike's, saves one). Every keychain item the proof writes is under a namespace unique to the run and is
# deleted before it exits; it exits non-zero if any check fails or anything is left behind.
set -euo pipefail

TEAM=${1:?usage: run.sh <TEAM_ID> [bundle id]}
BUNDLE_ID=${2:-sh.vaulthalla.desktop.keychain-proof}
HERE=$(cd "$(dirname "$0")" && pwd)
DERIVED=$(mktemp -d "${TMPDIR:-/tmp}/vh-keychain-proof.XXXXXX")
trap 'rm -rf "$DERIVED"' EXIT

xcodebuild -project "$HERE/KeychainProof.xcodeproj" -scheme KeychainProof -configuration Debug \
    -destination "platform=macOS" -derivedDataPath "$DERIVED" DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    -allowProvisioningUpdates -quiet build

APP="$DERIVED/Build/Products/Debug/KeychainProof.app"
codesign --verify --strict "$APP"
echo "signed: $(codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|TeamIdentifier)=' | tr '\n' ' ')"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -extract keychain-access-groups json -o - - || true
echo
"$APP/Contents/MacOS/KeychainProof" "$TEAM.$BUNDLE_ID"
