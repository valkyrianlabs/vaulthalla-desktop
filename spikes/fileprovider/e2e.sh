#!/bin/bash
# THROWAWAY SPIKE (vaulthalla/desktop#2): the File Provider runtime half of the spike (Q1 launch, Q3-Q6).
# Prerequisites: build (README.md), interop instance up on dev, `VaulthallaSpike create-key` + `pair <host:port>` done,
# and the domain enabled once in System Settings > General > Login Items & Extensions > File Providers.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
APPB=$HERE/build/DD/Build/Products/Debug/VaulthallaSpike.app
APP=$APPB/Contents/MacOS/VaulthallaSpike
TOOL=$APPB/Contents/MacOS/vh-agent
G="$HOME/Library/Group Containers/QG2U5HNCG4.sh.vaulthalla.desktop.spike"
t() { perl -e 'alarm shift; exec @ARGV' "$@"; }   # timeout: anything under CloudStorage can block
say() { echo; echo "=== $*"; }

$APP list-domains | grep -q "vault-3 " || $APP add-domain vault-3 "interop-vault · dev"
if $APP list-domains | grep "vault-3 " | grep -q "userEnabled=false"; then
    echo "domain vault-3 is not enabled: System Settings > General > Login Items & Extensions > File Providers > VaulthallaSpike"
    open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension" 2>/dev/null
    exit 2
fi
ROOT=$($APP root-url vault-3 | sed -n 's/.*root of vault-3: //p')
pgrep -x VaulthallaSpike && { echo "the app is running; quit it"; exit 1; }

say "Q1/Q3: enumerate the vault root from the extension (app not running)"
t 60 ls -la "$ROOT" "$ROOT/docs"
pgrep -lf SpikeFileProvider.appex
say "Q3: fetch /docs/blob.bin"
python3 - "$ROOT/docs/blob.bin" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
print(len(data), "bytes; equals seeded pattern:", data == bytes((i * 7 + 3) % 256 for i in range(65536)))
PY

say "Q4: server-side add, then signal from a separate process"
NAME=fresh-$(date +%s).txt
ssh dev "echo spike > /tmp/$NAME && /tmp/vhi_interop/vh fs put 3 - /$NAME < /tmp/$NAME && rm /tmp/$NAME"
sleep 5; echo "before signal:"; t 30 ls "$ROOT" | grep -c "$NAME"
[ -x "$TOOL" ] || bash "$HERE/embed-agent-tool.sh"
$TOOL signal vault-3
for i in 1 2 3 4 5 6 7 8 9 10; do sleep 2; t 30 ls "$ROOT" | grep -q "$NAME" && break; done
echo "after signal:"; t 30 ls "$ROOT" | grep "$NAME"

say "Q6: ranged read of big.bin (48 MiB): 1 MiB at 20 MiB"
t 120 dd if="$ROOT/big.bin" bs=1m skip=20 count=1 2>/dev/null | python3 -c '
import sys
d = sys.stdin.buffer.read()
print(len(d), "bytes; equals pattern:", d == bytes(((i*7+3)+20*31)%256 for i in range(1<<20)))'
ls -ls "$ROOT/big.bin"; du -k "$ROOT/big.bin"
grep -E "fetchPartialContents|fetchContents|GET /download" "$G/spike.log" | tail -8

say "Q5: 12 more domains"
$APP add-domains many 12
for i in $(seq 1 12); do r=$($APP root-url many-$i | sed -n 's/.*root of many-[0-9]*: //p'); t 30 ls "$r" > /dev/null; done
sleep 5
ps -axo pid,rss,etime,command | grep -c "[S]pikeFileProvider.appex"
ps -axo pid,rss,etime,command | grep "[S]pikeFileProvider.appex" | cut -c1-120
for i in $(seq 1 12); do $APP remove-domain many-$i > /dev/null; done
grep "ext init" "$G/spike.log" | tail -14
