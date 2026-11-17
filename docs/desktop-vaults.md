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
| `tools/vaultfmt/` | `VLVaultfmt.xcframework` from the vendored vl-vaultfmt 0.4.1 source (pin, tarball, build script), built against VLKeykit's vl-keykit source; the archive holds vl-vaultfmt alone (vl-keykit and libcrypto are VLKeykit's). `live-s3.sh`: the live test |
| Modules | `VHVaultKeys` (keychain items: the app-only group and the group shared with the extension), `VHVaultEngine` (the engine, the S3 store, the Finder replica, the extension's host; **no cloud client**), `VHVault` (the lifecycle and `DeviceAccess`; re-exports `VHVaultEngine`). The File Provider extension links `VHVaultEngine` only |
| `Sources/VHVaultEngine/Vault.swift`, `Bridge.swift` | the engine's C API (`vl_vaultfmt_engine.h`) in Swift: the store, keys and state tables, every call run off the cooperative pool, the state file `flock`ed to one process |
| `SigV4.swift`, `S3Store.swift` | Signature Version 4 with CryptoKit; the bucket over `URLSession` (path-style, whole and ranged reads, streamed content PUTs through a file of sealed bytes, conditional PUT headers, version listings, deletes by version id), the key lent per request by `DeviceAccess`, a 401/403 reported through `providerRefusedKey()` |
| `Sources/VHVaultKeys/` | `VaultKeyStore` (`vault-key.<uid>`, `vault-key.<uid>.<version>`) and `BucketKeyStore` (`storage-key.<uid>`, `storage-key.<uid>.<key id>`) in the shared group, `VaultItems` (the move from the app-only group), `KeyRefusalSignal`, `SharedKeyState`; `Sources/VHCloud/DesktopVaultRoutes.swift`: enrollment (`PUT /v1/recovery/vaults/{uid}`) and the envelope fetch (`GET /v1/keys/vaults/{uid}/envelopes`) |
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
  version into the keychain, a re-anchor, and a publish that **takes the vault over** (its first root names this Mac
  alone; no `join`, see "One Mac writes a vault").
- **Stop holding**: `DELETE /v1/vaults/{uid}/replica` through `DeviceAccess.release()`; the session closes; the state,
  the local files and the keys stay (the keys are recovery material).
- **Sync**: publish two seconds after the last local change, refresh every minute (one HEAD while nothing moved), GC
  once a day. Each vault's state is said in words (`DesktopVaultSession.Status.sentence`): syncing, up to date, changes
  waiting, paused and why, waiting for storage and why, needs an update (the writer floor), a refused root, stopped
  (released, moved, revoked...), two-sided content conflicts (both versions kept) and files recovered unnamed.

What the sheet says before anything is made: one Mac writes for now; no share links or server-side search; recovering
it without this Mac needs the account recovery key; a lost Mac loses the names of changes it hadn't published (their
bytes stay in the bucket and come back under "Recovered").

## One Mac writes a vault

A Desktop-only vault has exactly one writer, the Mac that holds it. Every Desktop-only vault is on a version_log bucket
(Backblaze B2), and Backblaze orders a key's versions by when their upload **started**, not when it finished (measured
live 2026-11-16; vl-vaultfmt 0.4.0's CHANGELOG): another writer's slow root PUT can land below a root this Mac already
settled, which nothing in the protocol makes safe yet (vaulthalla-server `design/encryption/06-publish-without-preconditions.md`
§11 has the proposal). So the engine refuses a second writer on such a bucket: `join` answers `writers_refused`
(status 632) and records nothing, and a root naming several writers is never published. Moving a vault to another Mac
is the account holder's (the portal), and that Mac takes it over.

One writer is safe under that ordering since vl-vaultfmt 0.4.0: a root PUT whose reply was lost and that lands later,
below roots this Mac published since, is recognized as this Mac's own superseded attempt and removed (or adopted when it
landed first), never refused as `order_violation`; for 15 minutes after such a PUT the engine lists the root's versions
instead of trusting one HEAD. `S3Store` bounds every request so a stalled PUT can't land much later
(`S3Store.Bounds`, vaulthalla-server's values): the root PUT 60 s in all, a body's first byte within 30 s, no progress
for 60 s fails any request, content uploads have no total deadline; a bound cancels the task (the connection closes)
and a write cut short is "outcome unknown", never "failed". A root PUT of unknown outcome that no listing shows ends the
publish as `store_outcome_unknown` (603) from the engine itself since vl-vaultfmt 0.4.1 (0.4.0 ended it as `internal`,
which `Vault` used to remap); `LateRootTests` checks it.

## Finder

`EngineReplica` serves a `desktop-<uid>` domain: enumeration of the working content, anchors from `vault_changes`
(`g<generation>`: another generation, or an anchor too old, is expired and the system enumerates again), whole and
ranged authenticated reads, streamed creates and edits with `expected_generation` (an edit from an older generation keeps
both: this Mac's current, the other a version), rename, move, and delete into the vault's trash (an edit beats a
delete). 128-bit uids get item numbers (`desktop-<uid>.ids`), assigned, never hashed. Everything below the extension is
tested by `swift test`; **nothing is proven in Finder**: a File Provider extension can't run unsigned.

### Keys: a keychain group shared with the extension (decided 2026-11-16)

- **The group** `<TEAM>.sh.vaulthalla.app.vault` (`VaultKeychain`, service `sh.vaulthalla.app.vault`), in both targets'
  `keychain-access-groups` (`App/Vaulthalla.Team.entitlements`, `FileProvider.Team.entitlements`). It holds only each
  Desktop-only vault's key versions and its bucket key in force (metadata and secret). The link identity and the
  account key stay in the app-only group `<TEAM>.sh.vaulthalla.app.account`.
- **Attributes:** data protection keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable,
  raw bytes. After first unlock, because the extension runs in the background with no UI, while the screen is locked
  included (`WhenUnlocked` would fail it then); this device only, because a vault key or bucket key must never be
  restored onto another Mac or synced (the cloud's envelopes are the way to another Mac).
- **Who writes:** the app alone (it holds the credential lease and alone talks to the cloud): it runs `DeviceAccess`
  for every vault it holds, Finder-shown or not, and writes each renewed bucket key to the shared group. The extension
  reads it per request and makes no cloud call: `VHVaultEngine` doesn't depend on `VHCloud`, and the extension links
  only it (checked by `SharedKeysTests.theExtensionCannotReachTheCloudClient` against `Package.swift` and the project).
- **The move:** items the unreleased build kept in the app-only group move on first use: written to the shared group,
  read back and compared, then deleted from the old group, never the other order. A failed read-back keeps the old
  item; a crash between the write and the delete leaves both (equal), and the next use deletes the old one; an old item
  that differs from the shared one is never deleted on a guess. No other compatibility path.
- **A refusal in the extension** (401/403): the key is dropped there and the app is told by `KeyRefusalSignal`: a
  marker file per vault in the App Group container (`FileProvider/desktop-<uid>.refused`) and a Darwin notification
  (`<App Group>.vault-key-refused`, no payload). The file is the record (an app that wasn't running finds it at launch
  and on each refresh); the notification wakes an app that is running, whose `DeviceAccess` then reads the cloud's view
  and asks for a new key. Chosen because it needs nothing beyond the App Group both already have.
- **The app not running:** Finder keeps working on the key in the shared group until it expires (24 hours from issue,
  renewed from 12); then reads that need the bucket pause with *"Paused: this vault's storage key expired while
  Vaulthalla wasn't running. Open Vaulthalla to renew it. Your files and changes on this Mac are kept and are sent
  once it is renewed."* Local changes stay journalled in the state; nothing is lost. The background agent
  (`SMAppService.agent`, registered while any vault is in Finder, as for server vaults) now also signals Desktop-only
  domains, but as a read-only consumer it renews no key; no login item was added.
- **One engine per vault:** while Finder shows the vault the extension runs it (`ExtensionEngineHost`: publish two
  seconds after a change, refresh every minute while it runs) and the app's session hands its engine over
  (`handOverEngine`: publishes what it can, releases the state lock) but keeps `DeviceAccess`; hiding it gives it back.

### Unproven without a signed build

- The Developer ID profiles allow `<TEAM>.sh.vaulthalla.app.vault` for the app and the extension.
- The extension reads both items after login without UI, and while the screen is locked.
- The extension's Darwin notification reaches the app, and the marker file is written in the group container.
- Finder enumerates, opens, saves, renames and deletes in a `desktop-<uid>` domain; the agent's signal refreshes it.
- The move from the app-only group on a Mac that ran the earlier build.

## Decisions (each with its undo)

1. **One vl-keykit in the app.** VLVaultfmt is compiled against VLKeykit's vl-keykit source and holds no vl-keykit or
   libcrypto. *Undo:* use the library's own `scripts/build-xcframework.sh` once both libraries pin the same vl-keykit.
2. **Vault keys and the bucket key in a group shared with the extension** (decided 2026-11-16, above). *Undo:*
   `VaultItems` over the app-only group, the entitlement lines removed, and the extension back to an XPC or app-run
   design.
3. **Vault key bytes from the seed.** vl-keykit keeps an opened vault key inside its handle and the engine's keys table
   needs bytes, so adoption opens the envelopes with the seed's recipient in VHRecovery's KEV1 (`CloudAccount.openVaultKeys`).
   *Undo:* a vl-keykit call that copies an opened key into a caller's buffer.
4. **Enroll before register.** Enrollment registers the vault; `POST /v1/vaults` follows as a no-op check. *Undo:* swap them.
5. **The engine's node id is the cloud installation id.** *Undo:* any stable per-Mac id.
6. **Uploads through a file of sealed bytes**, hashed as they arrive, one PUT up to 5 GiB; larger files are refused.
   *Undo:* multipart uploads (`vl_vaultfmt_part_size`).
7. **Deletes go to the vault's trash**, as a server vault's delete does; Finder never purges. *Undo:* `purge` in `delete`.
8. **The app runs every held vault's `DeviceAccess`; the engine runs in the extension while Finder shows the vault.**
   *Undo:* `DesktopVaults.open(_:engine:)` with `engine: true` always, and no domain.
9. **The refusal signal is a marker file plus a Darwin notification.** *Undo:* `KeyRefusalSignal`; anything that
   reaches `DesktopVaults.followRefusals()`.
10. **Modules split for the extension** (`VHVaultKeys`, `VHVaultEngine`), re-exported (`@_exported`) by `VHCloud` and
    `VHVault` so their clients didn't change. *Undo:* fold them back, at the cost of the extension linking the cloud
    client.

## Key provenance: this Mac attests the versions it creates (2026-11-17)

A server takes a Mac's vault over canonically only if each key version is proven by its origin (vaulthalla-server
`design/encryption/03-metadata-recovery.md` §6.5; found by the drill, decided by Cooper 2026-11-17). So this Mac signs
for every key version it creates exactly as a server does, with vl-keykit's one implementation (`VHKeykit.Provenance`
over its C API; no Swift copy of the formats):

- **The origin**: node id = this Mac's Vaulthalla Cloud installation id; vault id = `macOriginVaultId(uid)`, a number
  derived from the vault uid in a server vault id's range (nothing stored). The key check is over that vault id.
- **The signing key**: an Ed25519 seed in the item `attestation-key` of the account's **app-only** keychain group
  (this device only, like the link and the account key); never in the group shared with the File Provider extension.
  Not the Secure Enclave: it signs only P-256, and the format is Ed25519. Made on first need; its id is derived from
  its public key, and every attestation carries the public key.
- **When**: creating a vault enrolls version 1 with its key check and attestation, before anything is stored. Opening
  a vault this Mac created (`adopted` false) enrolls them again, which backfills a vault enrolled before this change
  (the cloud lets the enrolling Mac fill a bare version once). An adopted vault's versions keep their original
  origin; this Mac attests only versions it creates (none yet: Desktop doesn't rotate).
- **What a server then proves**: the same rule as for a server's versions; a missing or wrong attestation is still
  `salvage_required` (the drill checks both).
- The bucket's root doesn't carry the attestation (the engine's C API takes a key check only, and its root names no
  producer vault id): the proof travels in the cloud's records, as a server's does in a kit or export.

## Not done, and what the contracts didn't give

- The sealed vault label (the portal shows the uid), the ejection conversion report, Keep Downloaded, thumbnails, and
  multipart uploads.
- The engine's C API: no paging of `vault_changes`, no list of a root's writers (the UI can't name who wrote), and
  after an adoption the old Mac stays a named writer, so purges never delete (vl-vaultfmt `docs/engine.md`, "Limits").
- vl-keykit: no export of an opened vault key (decision 3).
- The fake cloud has one installation, so the adoption test's "replacement Mac" is a fresh keychain and container on
  the same installation id.

## Tests

- `swift test --filter VHVaultTests`: SigV4 against AWS's SigV4 test suite cases; the engine through the C API on an
  in-memory B2-like bucket (the library's own C lifecycle, write conflicts, store failures, the state lock); the S3
  store's requests and answers; the engine-backed Finder replica.
- `swift test --filter SharedKeysTests`: the shared-group stores (the extension reads, can't write), the item
  attributes, the move (first use, a crash between write and delete, a failed read-back, an old item that differs),
  the extension unable to reach the cloud client, the refusal signal, and an expired key with the app not running.
- `swift test --filter DesktopVaultHandOverTests`: the engine handed to Finder with the key still renewed here, and a
  signalled refusal followed.
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
