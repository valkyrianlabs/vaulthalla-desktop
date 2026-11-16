#!/usr/bin/env bash
# The Desktop-only vault drill (docs/desktop-vaults.md, "The drill"): Desktop's real client code
# (Tests/VHCloudTests/LiveDesktopDrillTests.swift) against the real Vaulthalla Cloud daemon, moto, the portal and a
# Vaulthalla server on the Linux box `dev`, which vaulthalla-cloud's `ci/milestone --only desktop` brings up there
# (tests/milestone/desktop.py) and keeps up while this runs.
#
#   tools/vaultfmt/desktop-drill.sh [swift test arguments]
#
# Environment (paths on dev; each a checkout of that repository, synced from this Mac before the run):
#   VH_DRILL_DEV_CLOUD   vaulthalla-cloud         (default /srv/wave4-cloud)
#   VH_DRILL_DEV_SERVER  vaulthalla-server        (default /srv/wave4-server; built with -Dintegration_tests=true)
#   VH_DRILL_DEV_PORTAL  vaulthalla-cloud-portal  (default /srv/wave4-portal)
#
# The Mac reaches dev's loopback only, through one SSH session's tunnels on the same port numbers (the endpoints the
# cloud names for the bucket work here unchanged); nothing listens on the LAN. Closing the session ends the drill on
# dev, which removes its daemon, database, containers, instances and run directories. The control endpoint's token is
# read from the session, passed to the test in its environment and never printed. Nothing here touches the keychain or
# the app's data: the test keeps everything in memory and a temporary container. Unsigned `swift test` only.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cloud="${VH_DRILL_DEV_CLOUD:-/srv/wave4-cloud}"
server="${VH_DRILL_DEV_SERVER:-/srv/wave4-server}"
portal="${VH_DRILL_DEV_PORTAL:-/srv/wave4-portal}"
work="$(mktemp -d)"
chmod 700 "$work"
cleanup() {
    [[ -n "${tunnel:-}" ]] && kill "$tunnel" 2> /dev/null || true
    exec 3>&- 2> /dev/null || true
    [[ -n "${session:-}" ]] && { wait "$session" 2> /dev/null || true; }
    rm -rf "$work"
}
trap cleanup EXIT

mkfifo "$work/in" "$work/out"
ssh -o ClearAllForwardings=yes dev "cd '$cloud' && VH_BUILD_JOBS=6 ci/milestone --only desktop --server-dir '$server' --portal-dir '$portal'" \
    < "$work/in" > "$work/out" &
session=$!
exec 3> "$work/in"
exec 4< "$work/out"
line=""
while IFS= read -r -u 4 next; do
    case "$next" in
        '{"desktop_drill"'*) line="$next"; break ;;
        *) echo "$next" >&2 ;;
    esac
done
[[ -n "$line" ]] || { echo "the drill on dev didn't come up" >&2; exit 1; }
# Keep relaying what dev says (one line per control operation) while the test runs.
cat <&4 >&2 3>&- &
field() { python3 -I -c 'import json, sys; print(json.loads(sys.stdin.read())["desktop_drill"][sys.argv[1]])' "$1" <<< "$line"; }
cloud_port="$(field cloud_port)"
s3_port="$(field s3_port)"
control_port="$(field control_port)"
for p in "$cloud_port" "$s3_port" "$control_port"; do
    if nc -z 127.0.0.1 "$p" 2> /dev/null; then echo "port $p is taken on this Mac; run the drill again" >&2; exit 1; fi
done
# Not ExitOnForwardFailure (nor ClearAllForwardings, which drops these -L too): dev's ssh config adds forwards of its
# own, which may already be bound on this Mac. No child keeps the session's stdin open (3>&-): closing it ends the drill.
ssh -N -L "127.0.0.1:$cloud_port:127.0.0.1:$cloud_port" \
    -L "127.0.0.1:$s3_port:127.0.0.1:$s3_port" -L "127.0.0.1:$control_port:127.0.0.1:$control_port" dev 2> /dev/null 3>&- 4<&- &
tunnel=$!
for _ in $(seq 30); do
    curl -fsS -o /dev/null "http://127.0.0.1:$cloud_port/readyz" 2> /dev/null && break
    sleep 1
done
curl -fsS -o /dev/null "http://127.0.0.1:$cloud_port/readyz" || { echo "the tunnel to the cloud on dev isn't up" >&2; exit 1; }

cd "$root"
status=0
VH_LIVE_DRILL=1 VH_DRILL_CLOUD="http://127.0.0.1:$cloud_port" VH_DRILL_CONTROL="http://127.0.0.1:$control_port" \
    VH_DRILL_TOKEN="$(field token)" swift test --filter LiveDesktopDrillTests "$@" || status=$?
curl -fsS -o /dev/null -X POST -H "Authorization: Bearer $(field token)" "http://127.0.0.1:$control_port/shutdown" || true
exit $status
