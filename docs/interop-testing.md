# Interop testing against a live daemon

`Tests/VHNodesLiveTests` drives Desktop's real client code (`PairingClient`, `NodeSession`, `WsClient`,
`DeviceHTTPClient`) against a real `vaulthalla-server` built from the server repository, over the network. It is
opt-in: without `VH_LIVE_NODE` every test in it is skipped, so `swift test` and CI never need a daemon.

## What it covers

| Test | Steps |
|---|---|
| `aDecoyCodeDeniesThePairing` | open a window (`vh device pair`), pair, approve with one of the two decoys from `vh device pending`: the client ends `denied`, the key never becomes a device, and the HTTP lanes refuse it (`DeviceHTTPError.forbidden`) |
| `pairsTalksRotatesAndIsRevoked` | 1. pair and approve with the code the client computed (it must be one of the daemon's three); the pin is the daemon's listener key. 2. `NodeSession` online with that pin; `device.server.identity`; `meta.contract.get` (`ws_hash` equals the daemon build's); `storage.vault.list` equals `vh vault list` as the same user; `fs.list` of the seeded vault. 3. `DeviceHTTPClient`: whole file and a `Range` request (206, exact bytes). 4. `/mcp`: `initialize`, `notifications/initialized` (202), `tools/list` (no key export, pairing or remote tools), `vh_run` refuses `vault keys export`, `device approve`, `device remote enable`; `vh_read` lists the vault as the device's user; `vault delete` without `confirm` returns `needs_confirmation: destructive`. 5. `rotateDeviceKey()`: the session reconnects with the new key, `vh device list` shows the new device id with no previous key, and the lanes accept the new key; a credential consumer session on the same Keychain (no lease) comes online with the rotated key and can't rotate, and `CredentialReader.check` reports the key accepted. 6. `vh device revoke`: the session reports `revoked`, keeps no connection, the lanes refuse the key, and the listener has no open connections; the consumer reports `revoked` too (refused, reloaded, refused again) without writing anything, and `check` reports the key refused |

Keys go into the file-based keychain under a namespace unique to the run (`sh.vaulthalla.desktop.test.<uuid>`), and
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

## Run

```sh
VH_LIVE_NODE=<box address>:36982 swift test --scratch-path .build-interop --filter Live
```

| Variable | Default | Meaning |
|---|---|---|
| `VH_LIVE_NODE` | (unset: skip) | the device listener as this Mac reaches it |
| `VH_LIVE_SSH` | `dev` | ssh destination of the box (the tests run `vh` there for the owner's side) |
| `VH_LIVE_RUN` | `/tmp/vhi_interop` | the instance's run directory |

Each run pairs fresh keys and revokes them at the end, so the suite can run repeatedly against one instance (a
pairing window allows five requests and ten per minute per address: wait a minute between rapid reruns).

## Tear down

```sh
ssh dev 'sudo bash ~/work/vh-instance.sh down'   # stop the daemon, drop the DB, remove /tmp/vhi_interop
```

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
