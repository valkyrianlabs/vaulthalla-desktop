# Desktop-only vaults

A vault with no server: this Mac encrypts it with vl-vaultfmt's engine and keeps it in a Vaulthalla Cloud managed
bucket. Unfinished and **off by default**: nothing here has run in a signed app.

```sh
defaults write sh.vaulthalla.app cloud.enabled -bool YES               # the Vaulthalla Cloud section
defaults write sh.vaulthalla.app cloud.desktopVaults.enabled -bool YES # this feature (DesktopVaultsFeature)
```

The cloud's contract is vaulthalla-cloud `docs/design/account-model.md` ("As built" 16 to 22), `managed-storage.md`
("As built" 25 to 27) and `key-manager.md` ("As built" 14 and 20); the engine's is vl-vaultfmt `docs/engine.md`.

## Pieces

| Where | What |
| --- | --- |
| `tools/vaultfmt/` | `VLVaultfmt.xcframework` from the vendored vl-vaultfmt 0.3.0 source (pin, tarball, build script), built against VLKeykit's vl-keykit source; the archive holds vl-vaultfmt alone (vl-keykit and libcrypto are VLKeykit's). `live-s3.sh`: the live test |
| `Sources/VHVault/Vault.swift`, `Bridge.swift` | the engine's C API (`vl_vaultfmt_engine.h`) in Swift: the store, keys and state tables, every call run off the cooperative pool, the state file `flock`ed to one process |
| `SigV4.swift`, `S3Store.swift` | Signature Version 4 with CryptoKit; the bucket over `URLSession` (path-style, whole and ranged reads, streamed content PUTs through a file of sealed bytes, conditional PUT headers, version listings, deletes by version id), the key lent per request by `DeviceAccess`, a 401/403 reported through `providerRefusedKey()` |
| `Sources/VHCloud/VaultKeyStore.swift` | vault keys in the account's app-only keychain items (`vault-key.<uid>`, `vault-key.<uid>.<version>`), as `BucketKeyStore` keeps the bucket key; enrollment (`PUT /v1/recovery/vaults/{uid}`) and the envelope fetch (`GET /v1/keys/vaults/{uid}/envelopes`) |
| `DesktopVaults.swift`, `DesktopVaultSession.swift` | the lifecycle and one session per open vault (its `DeviceAccess` loop and the sync) |
| `EngineReplica.swift`, `Sources/VHFinder/FinderReplica.swift` | the File Provider side behind the seam both kinds of vault use |
| `App/Vaulthalla/Features/Cloud/DesktopVaultsModel.swift` | the app: Vaulthalla Cloud ▸ Storage ▸ Vaults kept by a Mac |

## Lifecycle

- **Create** (gated: linked, the account recovery key held, its offline copy confirmed, a plan with `storage_access`
  `full`; the sheet leads to Recovery Key otherwise): a new vault key in the keychain; KEV1 to the account key's X25519
  key; a local record; **enrolled** (which registers the vault as this Mac's) before anything is stored; registered
  (idempotent); storage switched on; `DeviceAccess` waits for the bucket and gets the key; the engine creates the vault,
  adds key 1 with its envelope (PUT before the version is recorded) and publishes. A bucket not ready within two
  minutes leaves the vault registered and enrolled; its session finishes the creation when the key arrives.
- **Open**: from the state file (no network needed to list), else a re-anchor from the bucket.
- **Adopt** (the account holder placed the vault on this Mac): the cloud's envelopes opened with the account key, every
  version into the keychain, a re-anchor, `join`, publish.
- **Stop holding**: `DELETE /v1/vaults/{uid}/replica` through `DeviceAccess.release()`; the session closes; the state,
  the local files and the keys stay (the keys are recovery material).
- **Sync**: publish two seconds after the last local change, refresh every minute (one HEAD while nothing moved), GC
  once a day. Each vault's state is said in words (`DesktopVaultSession.Status.sentence`): syncing, up to date, changes
  waiting, paused and why, waiting for storage and why, needs an update (the writer floor), a refused root, stopped
  (released, moved, revoked...), two-sided content conflicts (both versions kept) and files recovered unnamed.

What the sheet says before anything is made: one Mac writes for now; no share links or server-side search; recovering
it without this Mac needs the account recovery key; a lost Mac loses the names of changes it hadn't published (their
bytes stay in the bucket and come back under "Recovered").

## Finder

`EngineReplica` serves a `desktop-<uid>` domain: enumeration of the working content, anchors from `vault_changes`
(`g<generation>`: another generation, or an anchor too old, is expired and the system enumerates again), whole and
ranged authenticated reads, streamed creates and edits with `expected_generation` (an edit from an older generation keeps
both: this Mac's current, the other a version), rename, move, and delete into the vault's trash (an edit beats a
delete). 128-bit uids get item numbers (`desktop-<uid>.ids`), assigned, never hashed. Everything below the extension is
tested by `swift test`; **nothing is proven in Finder**: a File Provider extension can't run unsigned.

One engine per vault: while a vault is shown in Finder the extension runs it (its session, `DeviceAccess` included) and
the app closes its own. **In a signed build the extension can't open it yet**: the link, the bucket key and the vault
key are in the app-only keychain group `<TEAM>.sh.vaulthalla.app.account`, which the extension isn't entitled to
(`docs/cloud-storage.md`, "Who may touch it"); Finder then says "Finder can't read this Mac's Vaulthalla Cloud link".
Deciding that (the group for the extension, a separate vault group, or the app serving the extension over XPC) is
Cooper's; the entitlements and profiles weren't touched.

## Decisions (each with its undo)

1. **One vl-keykit in the app.** VLVaultfmt is compiled against VLKeykit's vl-keykit source and holds no vl-keykit or
   libcrypto. *Undo:* use the library's own `scripts/build-xcframework.sh` once both libraries pin the same vl-keykit.
2. **Vault keys in the account's app-only keychain group** (as the bucket key). *Undo:* `VaultKeyStore` takes any
   `AccountItemStore`.
3. **Vault key bytes from the seed.** vl-keykit keeps an opened vault key inside its handle and the engine's keys table
   needs bytes, so adoption opens the envelopes with the seed's recipient in VHRecovery's KEV1 (`CloudAccount.openVaultKeys`).
   *Undo:* a vl-keykit call that copies an opened key into a caller's buffer.
4. **Enroll before register.** Enrollment registers the vault; `POST /v1/vaults` follows as a no-op check. *Undo:* swap them.
5. **The engine's node id is the cloud installation id.** *Undo:* any stable per-Mac id.
6. **Uploads through a file of sealed bytes**, hashed as they arrive, one PUT up to 5 GiB; larger files are refused.
   *Undo:* multipart uploads (`vl_vaultfmt_part_size`).
7. **Deletes go to the vault's trash**, as a server vault's delete does; Finder never purges. *Undo:* `purge` in `delete`.
8. **The app runs the sessions unless Finder shows the vault.** *Undo:* follows the keychain decision above.

## Not done, and what the contracts didn't give

- The sealed vault label (the portal shows the uid), the ejection conversion report, Keep Downloaded, thumbnails, and
  multipart uploads.
- The engine's C API: no paging of `vault_changes`, no list of a root's writers (the UI can't name who wrote), and
  after an adoption the old Mac stays a named writer, so purges never delete (vl-vaultfmt `docs/engine.md`, "Limits").
- vl-keykit: no export of an opened vault key (decision 3).
- **A server can't adopt a Desktop-only vault canonically** (found by the drill, 2026-11-16). vaulthalla-server's
  restore proves each key version by its origin's attestation (D1: a signature by the origin node's attestation key
  over its node id, vault id, version and key check, recorded at enrollment). Desktop attests nothing: it enrolls the
  envelope only, so `vh vault recover --from-cloud` refuses `salvage_required`, and only `--salvage` (the server
  re-encrypts under a key of its own) takes the vault over. Making it canonical needs a Desktop attestation key (where
  it lives, what anchors it) or a server rule for a Desktop origin: a trust decision, left to Cooper (the keychain
  layout is changing separately).
- The fake cloud has one installation, so the adoption test's "replacement Mac" is a fresh keychain and container on
  the same installation id.

## Tests

- `swift test --filter VHVaultTests`: SigV4 against AWS's SigV4 test suite cases; the engine through the C API on an
  in-memory B2-like bucket (the library's own C lifecycle, write conflicts, store failures, the state lock); the S3
  store's requests and answers; the engine-backed Finder replica.
- **The drill** (`tools/vaultfmt/desktop-drill.sh`, opt-in): Desktop's real client code against the real Vaulthalla
  Cloud daemon, moto, the portal and a Vaulthalla server on `ssh dev`, which vaulthalla-cloud's `ci/milestone --only
  desktop` brings up there (its `tests/milestone/README.md`, "Desktop-only vaults, end to end"; checkouts at
  `/srv/wave4-{cloud,server,portal}` on dev by default, synced from this Mac first). `LiveDesktopDrillTests` links this
  Mac, creates the account key and has it approved, creates a vault with `DesktopVaults.create`, writes, renames,
  trashes and publishes, lives through a renewal and an expired key refused by moto, has the bucket inspected and the
  portal read it back, then delivers a server's restore and sees the vault moved. Everything stays in a
  `MemoryAccountItemStore` and a temporary container (no keychain item, no app data); the Mac reaches dev's loopback
  only, through tunnels on the same port numbers. About 15 minutes after dev's builds.
- `swift test --filter DesktopVaultLifecycleTests`: the lifecycle against `FakeDeviceCloud` (extended from the daemon's
  `Enrollment.cpp` and `KeyManager.cpp`) with a bucket that checks the bucket key.
- `tools/vaultfmt/live-s3.sh <vaulthalla-cloud checkout>`: opt-in, against moto on `ssh dev` (vaulthalla-cloud's
  `tests/live/s3dev-moto.sh`, credentials and signatures checked): a versioned bucket and a key scoped to it, a whole
  vault lifecycle through VHVault, a wrong secret refused. The administrator key never leaves dev's container; the Mac
  reaches moto through an SSH tunnel to dev's loopback for the run only.
