# Interop testing against a live daemon

`Tests/VHNodesLiveTests` drives Desktop's real client code (`PairingClient`, `NodeSession`, `WsClient`,
`DeviceHTTPClient`) against a real `vaulthalla-server` built from the server repository, over the network. It is
opt-in: without `VH_LIVE_NODE` every test in it is skipped, so `swift test` and CI never need a daemon.

## What it covers

| Test | Steps |
|---|---|
| `aDecoyCodeDeniesThePairing` | open a window (`vh device pair`), pair, approve with one of the two decoys from `vh device pending`: the client ends `denied`, the key never becomes a device, and the HTTP lanes refuse it (`DeviceHTTPError.forbidden`) |
| `pairsTalksRotatesAndIsRevoked` | 1. pair and approve with the code the client computed (it must be one of the daemon's three); the pin is the daemon's listener key. 2. `NodeSession` online with that pin; `device.server.identity`; `meta.contract.get` (`ws_hash` equals the daemon build's); `storage.vault.list` equals `vh vault list` as the same user; `fs.list` of the seeded vault. 3. `DeviceHTTPClient`: whole file and a `Range` request (206, exact bytes). 4. `/mcp`: `initialize`, `notifications/initialized` (202), `tools/list` (no key export, pairing or remote tools), `vh_run` refuses `vault keys export`, `device approve`, `device remote enable`; `vh_read` lists the vault as the device's user; `vault delete` without `confirm` returns `needs_confirmation: destructive`. 5. `rotateDeviceKey()`: the session reconnects with the new key, `vh device list` shows the new device id with no previous key, and the lanes accept the new key; a credential consumer session on the same Keychain (no lease) comes online with the rotated key and can't rotate, and `CredentialReader.check` reports the key accepted. 6. `vh device revoke`: the session reports `revoked`, keeps no connection, the lanes refuse the key, and the listener has no open connections; the consumer reports `revoked` too (refused, reloaded, refused again) without writing anything, and `check` reports the key refused |

`LiveTransferTests` covers direct transport (the server's docs/reference/transfer-protocol.md); each test pairs its own
key and revokes it at the end:

| Test | Steps |
|---|---|
| `endpointsAreAdvertisedAndSelectionVerifiesThem` | 1. `device.endpoints` on a Device session: the box's address (kind `lan`, source `interface`, the instance's port), `127.0.0.1` and `::1` (`loopback`), no link-local address or scope id, `node_id` the server's; the owner session reports `endpointsChanged`; the route is the configured address, `lan`, verified with the current pin. 2. The configured endpoint is a throwaway `openssl s_server` with a fresh P-256 key on the box (`VH_LIVE_DECOY_PORT`), the candidates the node's advertised list plus an unresolvable name: the session comes online on the advertised LAN address, the decoy is `identityMismatch`, `configuredEndpointMismatched` is false, and nothing asks for pairing again or touches the record. 3. `testRoute()` keeps that route |
| `largeResumableUploadOverTheDeviceLane` | 300 MB (over Cloudflare's 100 MB) in fixed 64 MiB parts, two at a time; the session's status polled meanwhile (ranges sorted, disjoint, on part boundaries, summing to `received_bytes`, never shrinking), `complete`/`committed` afterwards, no persisted record left, and `vh fs get` reads the same SHA-256 |
| `aDroppedRouteResumesWithOnlyTheGaps` | 300 MB in 16 MiB parts through a counting TCP relay on the Mac (TLS end to end); at 40 % on the node every connection is cut and new ones refused for 3 s; the node's status says what it kept; what the relay carried after that is at most the gap plus the parts that were in flight (resent with their digest) plus framing; the file is exact |
| `aDaemonRestartResumesWithOnlyTheGaps`, `aDaemonCrashResumesWithOnlyTheGaps` | the same with `vh-instance.sh restart` (SIGTERM) and `restart --kill` (SIGKILL) mid-file: the listener key survives, the session resumes on the restarted node with the gaps only |
| `resubmittedPartsAreIdempotentAndConflictsAreRefused` | over the wire: a part sent twice is 200 both times with the same `sha256`; other bytes for the stored range are 409 `part_conflict` and change nothing; a partial overlap is 409 `part_overlap`; a short part that isn't the last is 400. Then `ResumableUploader` takes over a record that never saw the first answer and commits the exact file; a part after the commit is 409 `file_state` |
| `conditionalSingleFileSessions` | `putContent` over the resumable threshold (the File Provider's writes): create (`if_none_match`), create again → conflict with the current version, replace with that version (`if_match`) → a new version, replace with the stale one → conflict; the bytes and the download's validator are the replace's; the relay shows the file went once, in parts |
| `calibrationLanesAndTestConnection` | `/transfer/probe` (node id, capabilities, `no-store`), `/sink` (bytes, `Server-Timing`), `/source` (exact length; over 256 MiB is 400); `testConnection()` (RTT under 200 ms, both rates between 1 MB/s and 10 GbE, within the 16 MiB budget, a suggestion inside the limits, the monitor seeded as `calibrated`); `ConnectionTests.calibrating` on a live session (route `lan`, rates, the "Uploads would start with …" note) |

`LiveTransferBenchmarks` (also needs `VH_LIVE_BENCH=1`) times 1 GiB uploads (legacy whole-file `/upload/session`,
resumable with fixed 64 MiB × 2 parts, resumable with automatic tuning cold and warm) and a download, interleaved,
`VH_LIVE_BENCH_REPS` times, plus the calibration lanes with 256 MiB bodies; every upload is checked with `vh fs get`.
Each row has the throughput, the time from the last byte sent to the commit, this process's peak resident set and
footprint, the daemon's CPU and peak RSS (sampled on the box from `/proc`, its high-water mark reset through
`clear_refs`), and the requests the daemon logged. That count needs the instance's `http` logger and console at debug
(`logging.log_levels.console_log_level` and `subsystem_levels.http` in `$RUN/config.yaml`, then `restart`); it is
`-` otherwise. Benchmark an optimized server build (`-Doptimization=3`, as the packages are), not the default `-O0`.

`tools/interop/web-resumable.py` (run on the box) drives the browser's contract (the server's
`web/src/features/files/upload/engine.ts`) against the instance's web listener: a throwaway user logs in over `/ws` for
the `refresh` cookie, then a 150 MB file goes in parts of the web cap (64 MiB), three at a time with `Content-Digest`;
a part over the cap is 413 `part_too_large`; status, finish, and `vh fs get` close it.

Keys go into the file-based keychain under a namespace unique to the run (`sh.vaulthalla.app.test.<uuid>`), and
everything under it is deleted afterwards, also on failure (as in `Tests/VHIdentityTests/TestSupport.swift`).

## The daemon: a private test instance

`tools/interop/vh-instance.sh` runs a `VH_TEST_MODE=1` instance on a Linux box. Everything it owns is private:
`/tmp/vhi_interop/` (backing store, FUSE mount, logs, config, CLI socket) and a database `vh_harness_interop_<time>`
owned by the server harness's role. The daemon refuses to start unless all of that is private
(`core/include/runtime/TestInstance.hpp`). The script never touches an installed service and stops only the pid it
started.

Prerequisites on the box: a build of the server checkout (`meson setup <build> -Dmanpage=false && meson compile -C
<build> core/vaulthalla-server core/vaulthalla-cli core/vh_usage`), and the server harness bootstrapped once
(`sudo tools/harness/bootstrap.sh`: the `vh_harness` role and the `vhh-actor-NN` accounts).

```sh
# Mac: copy the server checkout and the script to the box (here the ssh host `dev`), build there
rsync -a --delete --exclude='build*/' --exclude='node_modules/' --exclude='.git' \
    <server-checkout>/ dev:work/vaulthalla-interop/
scp tools/interop/vh-instance.sh dev:work/vh-instance.sh
ssh dev 'cd ~/work/vaulthalla-interop && meson setup build-interop -Dmanpage=false &&
         meson compile -C build-interop core/vaulthalla-server core/vaulthalla-cli core/vh_usage'

# start: private DB + run dir, seed, enable remote device connections; prints status.json
ssh dev 'sudo bash ~/work/vh-instance.sh up ~/work/vaulthalla-interop/build-interop 36982'
```

`up` takes the device port (default 36982, clear of the installed default 36972) and the actor account (default
`vhh-actor-01`). It seeds:

- the super admin mapped to the account that ran `sudo` (`vh-admin` below);
- the user `interop` (role `unprivileged`, mapped to the actor account's uid), owner of the local vault
  `interop-vault` with the vault role `manager`;
- `/hello.txt` (44 bytes) and `/docs/blob.bin` (64 KiB, byte *i* = (7*i* + 3) mod 256) in that vault, uploaded with
  `vh fs put` as `interop`;
- `vh device remote enable`: the listener moves to every interface through the daemon's own path.

`/tmp/vhi_interop/vh` runs `vh` as `interop` (the account pairing happens under), `/tmp/vhi_interop/vh-admin` as the
super admin, both non-interactive. `/tmp/vhi_interop/status.json` holds what the tests compare against: the listener's
SPKI pin, the build's `ws_hash`, the vault id.

`restart [--kill]` stops the daemon (SIGTERM, or SIGKILL as a crash) and starts it again on the same database, run
directory and port; the seeded state, open upload sessions and the listener key survive. `sudo VHI_RUN=/tmp/<name> bash
vh-instance.sh …` runs a second instance beside the default one (its own run dir, database and port; point the tests
at it with `VH_LIVE_RUN`).

## Run

```sh
VH_LIVE_NODE=<box address>:36982 swift test --scratch-path .build-interop --filter Live
```

| Variable | Default | Meaning |
|---|---|---|
| `VH_LIVE_NODE` | (unset: skip) | the device listener as this Mac reaches it |
| `VH_LIVE_SSH` | `dev` | ssh destination of the box (the tests run `vh` there for the owner's side) |
| `VH_LIVE_RUN` | `/tmp/vhi_interop` | the instance's run directory |
| `VH_LIVE_SCRIPT` | `~/work/vh-instance.sh` | the instance script on the box (the restart tests run `restart` through sudo) |
| `VH_LIVE_DECOY_PORT` | `36990` | a free port on the box for the identity-mismatch decoy |
| `VH_LIVE_BENCH` | (unset: skip) | `1` runs `LiveTransferBenchmarks` |
| `VH_LIVE_BENCH_REPS`, `VH_LIVE_BENCH_MIB` | `2`, `1024` | benchmark repetitions and file size |
| `VH_LIVE_BENCH_OUT` | (none) | also write the benchmark rows as JSON lines to this file |

Each run pairs fresh keys and revokes them at the end, so the suite can run repeatedly against one instance (a
pairing window allows five requests and ten per minute per address: wait a minute between rapid reruns).

## Tear down

```sh
ssh dev 'sudo bash ~/work/vh-instance.sh down'   # stop the daemon, drop the DB, remove /tmp/vhi_interop
```

## Finder (File Provider)

`tools/interop/finder-e2e.py` drives one File Provider domain through POSIX access only (`ls`, `cat`, `dd`, writes,
`mv`, `rm` in `~/Library/CloudStorage/Vaulthalla-<name>`), with the app quit, and checks every step against `vh` on the
node (docs/architecture.md §7). It needs a Team-signed build (the App Group and the shared keychain group), and the
provider switched on once by a person in System Settings ▸ General ▸ Login Items & Extensions ▸ File Providers: nothing
can do that from the command line (desktop#2). Add the domains after that: a domain added while the provider was still
off can stay `needsUserApproval` after the switch, with nothing in System Settings to approve it; removing and adding it
again brings it up enabled (seen on macOS 27.0.1, docs/architecture.md §7).

```sh
# Mac: one signed build, installed as the only registered copy
xcodebuild -project App/Vaulthalla.xcodeproj -scheme Vaulthalla -configuration Debug DEVELOPMENT_TEAM=<team> \
    -allowProvisioningUpdates -derivedDataPath build/SignedData.noindex build
cp -R build/SignedData.noindex/Build/Products/Debug/Vaulthalla.app ~/Applications/
APP=~/Applications/Vaulthalla.app/Contents/MacOS/Vaulthalla
ssh dev '/tmp/vhi_interop/vh device pair'                   # open the window as the seeded user
$APP --developer pair 10.0.0.11:36982 dev-interop           # prints the code; approve it on the node:
ssh dev '/tmp/vhi_interop/vh device pending'                # then: vh device approve <request> --code <code>
$APP --developer add-domain <node id> 3 interop-vault       # prints the CloudStorage root
ssh dev '/tmp/vhi_interop/vh-admin vault recovery set 3 --local-versioning on --yes'
# a 48 MiB /big.bin for the partial read (byte i = (13 i + 5) mod 251), put with `vh fs put`
tools/interop/finder-e2e.py --root ~/Library/CloudStorage/Vaulthalla-interop-vault·dev-interop \
    --domain <node id>.3 --vault 3 --vh "ssh dev /tmp/vhi_interop/vh"
```

A local node is the same with a private, non-installed test-mode daemon on 127.0.0.1 (the server repository's
`tools/macos/test-db.sh` and a `VH_TEST_MODE=1` `vaulthalla-server` from its `build-macos`, as
`tools/macos/storage_smoke.py` runs it). Never pair with an installed Vaulthalla. Afterwards: `--developer
remove-all-domains`, `vh device revoke` on each node, `--developer unpair <node id>`, stop the instances, and
`pluginkit -r` / `lsregister -u` every build copy you registered.

## Findings: direct transport (2026-10-31, server `feat/direct-transport` 372b5bdb, Desktop `feat/direct-transport`)

- Everything above passes against the dev box (`-O0` and `-O3` builds): 11 live tests. The Mac reached the box over
  Wi-Fi 6 (802.11ax, 80 MHz, 864 Mbit/s PHY) through the router, ~3-6 ms RTT: raw TCP 53-59 MB/s up, 62-86 MB/s down.
- Interruptions: a dropped route, a SIGTERM restart and a SIGKILL crash at 40 % each resumed from the node's status;
  after the status the relay carried the gap plus at most ~0.2 MB, and 1.04-1.10× the file in all (the parts in
  flight at the interruption are lost by design).
- 1 GiB, 3 runs each (`-O3` server): legacy whole-file `/upload/session` 25-26 MB/s with ~6.9 s from the last byte to
  the commit; resumable 64 MiB × 2 51-52 MB/s, 0.3-0.4 s; automatic cold 51-55 MB/s, warm 53-57 MB/s (8 parts of
  128 MiB instead of 16); the daemon spends ~34-37 CPU-seconds per GiB in every mode, peak RSS ~100 MiB. Downloads
  55-82 MB/s.
- `testConnection()` reads upload low on this link (27 MB/s against ~52 MB/s achieved): with the 16 MiB budget the
  sink bodies grow 1 → 4 MiB and the 16 MiB step never fits, so the largest sample is a 4 MiB body. The tuner
  corrects within the first parts (cold ≈ fixed above).
- The web listener refuses a part over its 64 MiB cap from the headers (413 `part_too_large`, then closes); a client
  that writes the whole body anyway sees a reset instead of the 413. The browser engine never sends such a part.
- URLSession logs "Stream … is sending an event before being opened" once per streamed part upload (bound stream pair);
  harmless.

## Findings: Finder E2E (2026-10-24, server main 95b10f14)

- Both nodes, 21/21 each with the app quit (the remote dev-box instance, and a private test-mode daemon on this Mac).
- **Server bug (not Desktop's):** `vh fs ls` fails with `[json.exception.type_error.316] invalid UTF-8 byte` for a folder
  holding a long name with a multi-byte character (a conflict copy named after "Cooper’s Mac Studio"). The shell
  table (`core/src/protocols/shell/Table.cpp`) ellipsizes and wraps by bytes at the daemon's 80-column fallback width,
  cutting a UTF-8 sequence, and the CLI answer then can't be serialized. Reproduced with `vh fs put` alone.
  `finder-e2e.py` reads such files with `vh fs get` instead of listing them.

## Findings so far (2026-10-20, server `feat/device-pairing` 7ce0e9fa)

- **URLSession hides HTTP 403 behind `NSURLErrorClientCertificateRequired`** on a connection whose server asked for a
  client certificate, even though one was presented; the response is dropped. The daemon answers 403 for an
  unpaired or revoked key on the lanes (`device_unknown`) and for RBAC refusals. `DeviceHTTPClient` maps that error
  (after presenting its identity) to `DeviceHTTPError.forbidden`; `DeviceHTTPClientTests` pins it on loopback.
- The vendored contract (`contract/`, `ws_hash` 5e94c9e3…) predates the device branch (ece949ad…): the typed commands
  used here still decode, but refresh it (`tools/gen-contract.py`) once the branch lands.
- `storage.vault.list` (and `vh vault list`) return nothing for an `unprivileged` user, even for a vault they own and
  hold the `manager` vault role on: listing follows the admin role's vault policy, not vault roles. Their files are
  reachable by vault id (`fs.list`, `/download`). Desktop's file browser needs another way to discover such vaults.
