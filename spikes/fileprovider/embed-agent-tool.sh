#!/bin/bash
# THROWAWAY SPIKE: put the agent binary into the app's Contents/MacOS as a bare tool (Bundle.main = the app) with only
# the App Group entitlement (keychain-access-groups on a bare tool is killed by AMFI: "No matching profile found"),
# then reseal the app.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
A=$HERE/build/DD/Build/Products/Debug/VaulthallaSpike.app
ID=$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')
cp "$A/Contents/Library/LoginItems/SpikeAgent.app/Contents/MacOS/SpikeAgent" "$A/Contents/MacOS/vh-agent"
cp "$A/Contents/Library/LoginItems/SpikeAgent.app/Contents/MacOS/SpikeAgent.debug.dylib" "$A/Contents/MacOS/"
codesign --force --sign "$ID" --options runtime --identifier sh.vaulthalla.desktop.spike.agent-tool \
    --entitlements "$HERE/Config/AgentTool.entitlements" "$A/Contents/MacOS/vh-agent"
codesign --force --sign "$ID" --preserve-metadata=identifier,entitlements,requirements,flags,runtime "$A"
codesign --verify --deep --strict "$A"
