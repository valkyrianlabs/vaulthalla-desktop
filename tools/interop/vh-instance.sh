#!/usr/bin/env bash
# A private Vaulthalla daemon for Desktop's live interop tests (docs/interop-testing.md).
#
# Runs on the Linux test box as root (sudo), from a build of the server checkout. Everything it creates is private and
# removed by `down`: the run directory /tmp/vhi_interop/ (backing, FUSE mount, logs, config, CLI socket), a database
# vh_harness_interop_<time> owned by the harness role (tools/harness/bootstrap.sh in the server repo), and the daemon
# process itself (VH_TEST_MODE=1, so it refuses anything that isn't private; core/include/runtime/TestInstance.hpp).
# It never touches an installed service, kills only the pid it started, and never prints the harness DB settings.
#
#   sudo vh-instance.sh up <build-dir> [device-port] [actor-account]   start, seed, enable remote device connections
#   sudo vh-instance.sh status                                           what is running (JSON; also in status.json)
#   sudo vh-instance.sh restart [--kill]                                 stop the daemon (SIGTERM, or SIGKILL as a crash)
#                                                                        and start it again on the same DB and run dir
#   /tmp/vhi_interop/vh <args>                                           vh as the seeded user (non-interactive)
#   /tmp/vhi_interop/vh-admin <args>                                     vh as the super admin
#   sudo vh-instance.sh down                                             stop the daemon, drop the DB, remove the run dir
#
# `sudo VHI_RUN=/tmp/<name> vh-instance.sh ...` runs another instance beside the default one (its own run dir, DB and
# port); the run dir must be directly under /tmp/ (the daemon's test mode refuses anything else).
set -euo pipefail

RUN=${VHI_RUN:-/tmp/vhi_interop}
[[ $RUN =~ ^/tmp/[A-Za-z0-9._-]+$ ]] || { echo "vh-instance: VHI_RUN must be /tmp/<name>" >&2; exit 64; }
STATE=$RUN/state.env
DB_ENV=/var/lib/vaulthalla-harness/db.env
SEED_USER=interop

die() { echo "vh-instance: $*" >&2; exit 1; }

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

listening() { ss -Hltn "sport = :$1" | grep -q .; }

# The daemon we started, and only it: same executable, test mode, our database.
ours() {
    local pid=$1 server=$2 db=$3
    [[ -r /proc/$pid/environ ]] || return 1
    [[ "$(readlink -f "/proc/$pid/exe")" == "$(readlink -f "$server")" ]] || return 1
    tr '\0' '\n' < "/proc/$pid/environ" | grep -qx 'VH_TEST_MODE=1' || return 1
    tr '\0' '\n' < "/proc/$pid/environ" | grep -qx "VH_TEST_DB_NAME=$db"
}

# The harness role's settings, into the caller's VH_TEST_DB_* (declare them local first): for the daemon's
# environment only, never printed, never in argv.
load_db_env() {
    local key value
    while IFS='=' read -r key value; do
        case $key in
            VH_TEST_DB_USER) VH_TEST_DB_USER=$value ;;
            VH_TEST_DB_PASS) VH_TEST_DB_PASS=$value ;;
            VH_TEST_DB_HOST) VH_TEST_DB_HOST=$value ;;
            VH_TEST_DB_PORT) VH_TEST_DB_PORT=$value ;;
        esac
    done < "$DB_ENV"
    [[ -n $VH_TEST_DB_USER && -n $VH_TEST_DB_PASS && -n $VH_TEST_DB_HOST && -n $VH_TEST_DB_PORT ]] \
        || die "$DB_ENV lacks a VH_TEST_DB_* setting"
}

# Starts the daemon on our run dir and database and waits until it serves; its pid replaces PID= in state.env.
launch() {
    local server=$1 db=$2 port=$3
    local VH_TEST_DB_USER="" VH_TEST_DB_PASS="" VH_TEST_DB_HOST="" VH_TEST_DB_PORT=""
    load_db_env
    # Not a group leader (no job control), so setsid doesn't fork and $! is the daemon's pid.
    setsid env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME="$RUN" TMPDIR="$RUN" VH_TEST_MODE=1 \
        VH_TEST_DB_NAME="$db" VH_TEST_DB_USER="$VH_TEST_DB_USER" VH_TEST_DB_PASS="$VH_TEST_DB_PASS" \
        VH_TEST_DB_HOST="$VH_TEST_DB_HOST" VH_TEST_DB_PORT="$VH_TEST_DB_PORT" \
        VH_TEST_BACKING_PATH="$RUN/backing" VH_TEST_MOUNT_PATH="$RUN/mnt" VH_TEST_LOG_PATH="$RUN/log" \
        VH_PATH_TO_SUPERADMIN_UID="$RUN/run" VH_PATH_TO_CONFIG="$RUN/config.yaml" VH_TEST_CLI_SOCKET="$RUN/cli.sock" \
        "$server" < /dev/null >> "$RUN/log/daemon.log" 2>&1 &
    local pid=$!
    sed -i '/^PID=/d' "$STATE"
    echo "PID=$pid" >> "$STATE"

    local deadline=$((SECONDS + 90))
    until [[ -S $RUN/cli.sock ]] && listening "$port"; do
        kill -0 "$pid" 2>/dev/null || { tail -30 "$RUN/log/daemon.log" >&2; die "the daemon exited during startup"; }
        (( SECONDS < deadline )) || { tail -30 "$RUN/log/daemon.log" >&2; die "the daemon is not ready after 90 s"; }
        sleep 0.3
    done
    ours "$pid" "$server" "$db" || die "pid $pid is not the instance we started"
    # Like the packaged daemon's socket: the vaulthalla group may connect, the peer uid decides who the caller is.
    chgrp vaulthalla "$RUN/cli.sock"
}

# Stops our daemon, and only it: SIGTERM with a 20 s grace (then SIGKILL), or SIGKILL at once with `kill` (a crash).
stop_daemon() {
    local how=${1:-term}
    [[ -n ${PID:-} ]] && ours "$PID" "$SERVER" "$DB" || return 0
    if [[ $how == kill ]]; then kill -KILL "$PID"; else kill -TERM "$PID"; fi
    local deadline=$((SECONDS + 20))
    while kill -0 "$PID" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.3; done
    if kill -0 "$PID" 2>/dev/null; then
        echo "vh-instance: daemon $PID ignored SIGTERM for 20 s; sending SIGKILL" >&2
        kill -KILL "$PID"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.1; done
    fi
    # The daemon unmounts on a clean stop; after a kill the mount may remain (lazy unmount of our own path only).
    if grep -q " $RUN/mnt " /proc/self/mountinfo; then umount -l "$RUN/mnt" || true; fi
}

# Stops the daemon and starts it again on the same database, run dir and port (the seeded state and every open
# upload session survive; the device listener's key too).
cmd_restart() {
    [[ $EUID -eq 0 ]] || die "run as root (sudo)"
    [[ -r $STATE ]] || die "no instance ($RUN/state.env missing)"
    local how=term
    [[ ${1:-} == --kill ]] && how=kill
    # shellcheck disable=SC1090
    . "$STATE"
    ours "$PID" "$SERVER" "$DB" || die "pid $PID is not our running instance"
    stop_daemon "$how"
    rm -f "$RUN/cli.sock"
    local deadline=$((SECONDS + 30))
    while listening "$PORT"; do
        (( SECONDS < deadline )) || die "port $PORT is still in use after the stop"
        sleep 0.2
    done
    launch "$SERVER" "$DB" "$PORT"
    cmd_status > "$RUN/status.json"
    chmod 644 "$RUN/status.json"
    cat "$RUN/status.json"
}

as_admin() { "$RUN/vh-admin" "$@"; }
as_user() { "$RUN/vh" "$@"; }

cmd_up() {
    [[ $EUID -eq 0 ]] || die "run as root (sudo): FUSE allow_other and the TPM need it"
    local build=${1:?usage: up <build-dir> [device-port] [actor-account]} port=${2:-36982} actor=${3:-vhh-actor-01}
    build=$(readlink -f "$build")
    local server=$build/core/vaulthalla-server cli=$build/core/vaulthalla-cli usage=$build/core/vh_usage
    [[ -x $server && -x $cli ]] || die "$server or $cli missing (build first)"
    [[ -e $RUN ]] && die "$RUN exists: run \`down\` first"
    [[ -r $DB_ENV ]] || die "$DB_ENV missing: run the server repo's tools/harness/bootstrap.sh once"
    listening "$port" && die "port $port is in use"
    local actor_uid
    actor_uid=$(id -u "$actor") || die "no account $actor (tools/harness/bootstrap.sh creates vhh-actor-NN)"
    local admin_uid=${SUDO_UID:-}
    [[ -n $admin_uid && $admin_uid != 0 ]] || die "run through sudo from the account that should be the super admin"

    mkdir -p "$RUN"/{run,log,bin,seed}
    chmod 755 "$RUN" "$RUN/bin" "$RUN/seed"
    echo "$admin_uid" > "$RUN/run/superadmin_uid"
    install -m 755 "$cli" "$RUN/bin/vaulthalla-cli"

    local ws http s3
    ws=$(free_port); http=$(free_port); s3=$(free_port)
    cat > "$RUN/config.yaml" <<EOF
websocket_server: {enabled: true, host: 127.0.0.1, port: $ws, max_connections: 256}
http_preview_server: {enabled: true, host: 127.0.0.1, port: $http, max_connections: 256}
s3_gateway: {enabled: false, host: 127.0.0.1, port: $s3}
device_server: {enabled: true, port: $port, remote: false, max_connections: 64}
email: {enabled: false}
operator_emails: {enabled: false}
dev: {enabled: false, init_r2_test_vault: false}
EOF

    local db
    db=vh_harness_interop_$(date +%s)
    local VH_TEST_DB_USER="" VH_TEST_DB_PASS="" VH_TEST_DB_HOST="" VH_TEST_DB_PORT=""
    load_db_env
    runuser -u postgres -- createdb -O "$VH_TEST_DB_USER" "$db"

    cat > "$STATE" <<EOF
SERVER=$server
CLI=$cli
DB=$db
PORT=$port
ACTOR=$actor
ACTOR_UID=$actor_uid
ADMIN_UID=$admin_uid
EOF

    launch "$server" "$db" "$port"
    write_wrappers
    seed
    as_admin device remote enable > /dev/null
    # What the live tests compare against (readable without root): the pin, the contract hash, the vault.
    cmd_status > "$RUN/status.json"
    chmod 644 "$RUN/status.json"
    cat "$RUN/status.json"
}

write_wrappers() {
    # shellcheck disable=SC1090
    . "$STATE"
    cat > "$RUN/vh-admin" <<EOF
#!/bin/sh
exec sudo -u '#$ADMIN_UID' env VAULTHALLA_CLI_SOCKET=$RUN/cli.sock VAULTHALLA_NONINTERACTIVE=1 $RUN/bin/vaulthalla-cli "\$@"
EOF
    cat > "$RUN/vh" <<EOF
#!/bin/sh
exec sudo -u '#$ACTOR_UID' env VAULTHALLA_CLI_SOCKET=$RUN/cli.sock VAULTHALLA_NONINTERACTIVE=1 $RUN/bin/vaulthalla-cli "\$@"
EOF
    chmod 755 "$RUN/vh-admin" "$RUN/vh"
}

# One user (mapped to the actor account, so `vh` as that account acts as them) with one local vault holding a text
# file and a 64 KiB binary whose byte i is (i * 7 + 3) mod 256.
seed() {
    # shellcheck disable=SC1090
    . "$STATE"
    as_admin user create "$SEED_USER" --role unprivileged --linux-uid "$ACTOR_UID" > /dev/null
    as_admin vault create interop-vault --local --owner "$SEED_USER" --desc "Desktop interop" > /dev/null
    local vault
    vault=$(as_admin vault list --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
rows = data if isinstance(data, list) else data.get("vaults", data.get("data", []))
print(next(v["id"] for v in rows if v.get("name") == "interop-vault"))')
    echo "VAULT=$vault" >> "$STATE"
    # Owning a vault grants nothing by itself: the vault role is what lets the user (and its devices) use it.
    as_admin vault role assign "$vault" manager -u "$SEED_USER" > /dev/null
    printf 'Hello from the Vaulthalla interop instance.\n' > "$RUN/seed/hello.txt"
    python3 -c 'import sys; sys.stdout.buffer.write(bytes((i * 7 + 3) % 256 for i in range(65536)))' > "$RUN/seed/blob.bin"
    chmod 644 "$RUN/seed/"*
    as_user fs put "$vault" - /hello.txt < "$RUN/seed/hello.txt" > /dev/null
    as_user fs put "$vault" - /docs/blob.bin < "$RUN/seed/blob.bin" > /dev/null
}

cmd_status() {
    [[ -r $STATE ]] || die "no instance ($RUN/state.env missing)"
    # shellcheck disable=SC1090
    . "$STATE"
    local alive=false spki ws_hash=""
    ours "$PID" "$SERVER" "$DB" 2>/dev/null && alive=true
    spki=$(as_admin device remote status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["server_spki_sha256"])')
    if [[ -x ${SERVER%/*}/vh_usage ]]; then
        ws_hash=$("${SERVER%/*}/vh_usage" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["ws_hash"])')
    fi
    python3 - "$alive" "$PID" "$DB" "$PORT" "${VAULT:-0}" "$spki" "$ws_hash" <<'EOF'
import json, sys
alive, pid, db, port, vault, spki, ws_hash = sys.argv[1:]
print(json.dumps({"alive": alive == "true", "pid": int(pid), "db": db, "device_port": int(port),
                  "vault_id": int(vault), "user": "interop", "server_spki_sha256": spki, "ws_hash": ws_hash}))
EOF
}

cmd_down() {
    [[ $EUID -eq 0 ]] || die "run as root (sudo)"
    [[ -r $STATE ]] || { [[ -e $RUN ]] && die "$RUN exists without state.env: inspect it by hand"; echo "nothing to stop"; return; }
    # shellcheck disable=SC1090
    . "$STATE"
    stop_daemon term
    runuser -u postgres -- dropdb --if-exists "$DB"
    rm -rf "$RUN"
    echo "stopped; dropped $DB; removed $RUN"
}

case ${1:-} in
    up) shift; cmd_up "$@" ;;
    status) cmd_status ;;
    restart) shift; cmd_restart "$@" ;;
    down) cmd_down ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 64 ;;
esac
