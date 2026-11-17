#!/usr/bin/env bash
# The opt-in live tests of VHVault (Tests/VHVaultTests/LiveS3Tests.swift) and of leaving managed storage
# (Tests/VHCloudTests/LiveS3EjectionTests.swift), a multipart upload among them (LiveS3Tests: the threshold lowered, moto
# enforcing S3's 5 MiB minimum part), against a real S3-compatible endpoint that checks every credential: moto
# server in a throwaway container on the Linux box `dev`, started by vaulthalla-cloud's own tests/live/s3dev-moto.sh
# (moto pinned by digest, an administrator key that exists only in that container).
#
#   tools/vaultfmt/live-s3.sh /path/to/vaulthalla-cloud [swift test arguments]
#
# On dev, inside s3dev-moto.sh's environment, a bootstrap creates three versioned buckets: two (a vault each:
# LiveS3Tests' lifecycle and its multipart upload) with an IAM user whose policy allows S3 on them only, and one for the
# ejection with two such users (one stands in for the cloud's
# key, the other for the key a customer makes in their own account after an ejection; the first bucket's key is the
# key for the wrong bucket). It hands this script those users' keys (never the administrator's). The Mac reaches moto through
# an SSH tunnel to dev's loopback for the test's duration only (nothing listens on the LAN); closing the session ends
# the bootstrap, and s3dev-moto.sh removes the container and its credentials. Needs `ssh dev` with podman, curl and
# python3-boto3 there.
set -euo pipefail
cloud="${1:?usage: $0 /path/to/vaulthalla-cloud [swift test arguments]}"
shift
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for f in tests/live/s3dev-moto.sh tests/live/moto-patches.py; do
    [[ -f "$cloud/$f" ]] || { echo "$cloud/$f is missing" >&2; exit 1; }
done

remote="$(ssh -o ClearAllForwardings=yes dev 'mktemp -d /tmp/vh-live-s3.XXXXXX')"
work="$(mktemp -d)"
cleanup() {
    [[ -n "${tunnel:-}" ]] && kill "$tunnel" 2> /dev/null || true
    [[ -n "${session:-}" ]] && kill "$session" 2> /dev/null || true
    wait 2> /dev/null || true
    ssh -o ClearAllForwardings=yes dev "rm -rf '$remote'" || true
    rm -rf "$work"
}
trap cleanup EXIT
chmod 700 "$work"
scp -q -o ClearAllForwardings=yes "$cloud/tests/live/s3dev-moto.sh" "$cloud/tests/live/moto-patches.py" "dev:$remote/"
cat > "$work/bootstrap.py" << 'PY'
# Runs inside s3dev-moto.sh: three versioned buckets and keys scoped to them, printed once as JSON; then waits for stdin
# to close (the test is over). The administrator key stays in this process's environment.
import json, os, sys, uuid
import boto3
ep = os.environ["VHC_S3DEV_ENDPOINT"]
admin = dict(endpoint_url=ep, aws_access_key_id=os.environ["VHC_S3DEV_ACCESS_KEY"],
             aws_secret_access_key=os.environ["VHC_S3DEV_SECRET_KEY"], region_name="us-east-1")
bucket = "vh-live-" + uuid.uuid4().hex[:12]
s3 = boto3.client("s3", **admin)
s3.create_bucket(Bucket=bucket)
s3.put_bucket_versioning(Bucket=bucket, VersioningConfiguration={"Status": "Enabled"})
eject = bucket + "-eject"
s3.create_bucket(Bucket=eject)
s3.put_bucket_versioning(Bucket=eject, VersioningConfiguration={"Status": "Enabled"})
multipart = bucket + "-mp"
s3.create_bucket(Bucket=multipart)
s3.put_bucket_versioning(Bucket=multipart, VersioningConfiguration={"Status": "Enabled"})
iam = boto3.client("iam", **admin)
def scoped(user, *names):
    iam.create_user(UserName=user)
    iam.put_user_policy(UserName=user, PolicyName="bucket", PolicyDocument=json.dumps({
        "Version": "2012-10-17",
        "Statement": [{"Effect": "Allow", "Action": "s3:*",
                       "Resource": [r for n in names for r in (f"arn:aws:s3:::{n}", f"arn:aws:s3:::{n}/*")]}]}))
    return iam.create_access_key(UserName=user)["AccessKey"]
key = scoped("vh-live-mac", bucket, multipart)
cloud = scoped("vh-live-cloud", eject)
own = scoped("vh-live-own", eject)
print(json.dumps({"port": int(ep.rsplit(":", 1)[1]), "bucket": bucket, "multipart_bucket": multipart,
                  "access": key["AccessKeyId"],
                  "secret": key["SecretAccessKey"], "eject_bucket": eject, "cloud_access": cloud["AccessKeyId"],
                  "cloud_secret": cloud["SecretAccessKey"], "own_access": own["AccessKeyId"],
                  "own_secret": own["SecretAccessKey"]}), flush=True)
sys.stdin.read()
PY
scp -q -o ClearAllForwardings=yes "$work/bootstrap.py" "dev:$remote/"

mkfifo "$work/in" "$work/out"
ssh -o ClearAllForwardings=yes dev "bash '$remote/s3dev-moto.sh' python3 -I '$remote/bootstrap.py'" < "$work/in" > "$work/out" &
session=$!
exec 3> "$work/in"
exec 4< "$work/out"
line=""
while IFS= read -r -u 4 next; do
    case "$next" in
        "{"*) line="$next"; break ;;
        *) echo "$next" >&2 ;;
    esac
done
[[ -n "$line" ]] || { echo "the bootstrap on dev gave no key" >&2; exit 1; }
field() { python3 -I -c 'import json, sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$1" <<< "$line"; }
port="$(field port)"
local_port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
# Not ExitOnForwardFailure: dev's ssh config adds forwards of its own, which may already be bound on this Mac.
ssh -N -L "127.0.0.1:$local_port:127.0.0.1:$port" dev 2> /dev/null &
tunnel=$!
for _ in $(seq 30); do
    curl -fsS -o /dev/null "http://127.0.0.1:$local_port/moto-api/" 2> /dev/null && break
    sleep 1
done
curl -fsS -o /dev/null "http://127.0.0.1:$local_port/moto-api/" || { echo "the tunnel to moto on dev isn't up" >&2; exit 1; }

cd "$root"
status=0
VH_LIVE_S3=1 VH_LIVE_S3_ENDPOINT="http://127.0.0.1:$local_port" VH_LIVE_S3_BUCKET="$(field bucket)" \
    VH_LIVE_S3_MULTIPART_BUCKET="$(field multipart_bucket)" \
    VH_LIVE_S3_REGION=us-east-1 VH_LIVE_S3_ACCESS_KEY="$(field access)" VH_LIVE_S3_SECRET_KEY="$(field secret)" \
    VH_LIVE_S3_EJECT_BUCKET="$(field eject_bucket)" VH_LIVE_S3_CLOUD_ACCESS_KEY="$(field cloud_access)" \
    VH_LIVE_S3_CLOUD_SECRET_KEY="$(field cloud_secret)" VH_LIVE_S3_OWN_ACCESS_KEY="$(field own_access)" \
    VH_LIVE_S3_OWN_SECRET_KEY="$(field own_secret)" \
    swift test --filter 'LiveS3Tests|LiveS3EjectionTests' "$@" || status=$?
exec 3>&-
exit $status
