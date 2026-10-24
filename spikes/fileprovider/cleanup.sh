#!/bin/bash
# THROWAWAY SPIKE: remove everything the spike created on this Mac and stop the interop instance on dev.
HERE=$(cd "$(dirname "$0")" && pwd)
APP=$HERE/build/DD/Build/Products/Debug/VaulthallaSpike.app/Contents/MacOS/VaulthallaSpike
$APP remove-all
$APP delete-key
$APP delete-secret
pluginkit -e default -i sh.vaulthalla.desktop.spike.fileprovider
ls -la ~/Library/CloudStorage/
ssh dev 'sudo bash ~/vh-interop-src/vh-instance.sh down'
