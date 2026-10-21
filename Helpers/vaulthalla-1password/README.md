# vaulthalla-1password

The helper Vaulthalla Desktop runs to back up vault keys to 1Password (architecture §6, decisions D5–D7). It is a
small Go program on [1Password's official Go SDK](https://github.com/1Password/onepassword-sdk-go) **v0.4.1**
with **desktop-app authorization**: it talks to the running 1Password app, the user approves with Touch ID, and no
service-account token or `op` CLI is involved. The app talks to it over JSON lines on stdin/stdout
(`Sources/VHOnePassword`).

## Build

```sh
./build.sh          # bin/vaulthalla-1password       (release; arm64, CGO, -trimpath, version stamp)
./build.sh --fake   # bin/vaulthalla-1password-fake  (test build: VH_OP_FAKE=1 selects an in-memory 1Password)
go test ./... && go vet ./... && go vet -tags fake ./...
```

`bin/` is gitignored. The version is `VERSION` + the commit (`+<sha>[.dirty]`), set with `-X main.version`.

## How desktop authorization works (verified in the SDK source at v0.4.1)

- `onepassword.NewClient(ctx, onepassword.WithDesktopAppIntegration(account), onepassword.WithIntegrationInfo("Vaulthalla Desktop", version))`.
  `account` is the name shown at the top of 1Password's sidebar, or the account's UUID.
- **CGO is required.** `client_builder_cgo.go` (`//go:build cgo || windows`) provides the option; without CGO,
  `client_builder_no_cgo.go` returns "WithDesktopAppIntegration requires CGO". build.sh sets `CGO_ENABLED=1`.
- The SDK **dlopen()s 1Password's IPC library** (`internal/shared_lib_core.go`, `shared_lib_core_unix.go`):
  `/Applications/1Password.app/Contents/Frameworks/libop_sdk_ipc_client.dylib`, else the same path under
  `~/Applications`, and calls its `op_sdk_ipc_send_message` / `op_sdk_ipc_free_response`. That dylib is signed by
  AgileBits (team `2BUA8C4S2C`) with the hardened-runtime flag.
- The library is bound to the **first account name** the process uses (`GetSharedLibCore` caches it), so one
  helper process serves one account; `account.check` with a different account fails with `account_switch` and the
  app restarts the helper.
- Errors the SDK defines for this path: return code -3 "desktop app connection channel is closed … Integrate with
  other apps" (→ `integration_disabled`), -7 "connection was unexpectedly dropped" (→ `app_not_running`),
  "1Password desktop application not found" (→ `app_not_installed`), "failed to open library" (→
  `library_blocked`), `DesktopSessionExpired` (the SDK re-initializes once itself; → `session_expired`),
  `RateLimitExceeded` (→ `rate_limited`). "Locked" and "denied" come from the 1Password app in wording the SDK
  doesn't publish; they're matched on keywords (`locked`, `denied`/`declined`/`cancelled`/`not authorized`) and
  anything unrecognized stays `onepassword_error` with the (redacted) text in `detail`. Run the self-test with
  1Password locked, and once declining the prompt, to confirm the wording.
- The SDK module also embeds its 9.5 MB WebAssembly core (used for service accounts), so the binary is ~22 MB.

## Signing and entitlements (for the app bundle; not done here)

The helper ships in `Vaulthalla.app/Contents/Helpers/vaulthalla-1password`, signed with the app's team ID:

- **Hardened runtime** (`codesign --options runtime`), required for notarization.
- **`com.apple.security.cs.disable-library-validation` = true** on the helper. With the hardened runtime, library
  validation only admits libraries signed by Apple or the helper's own team; 1Password's dylib is signed by
  another team, so without this entitlement dlopen fails and the helper reports `library_blocked`.
- No `com.apple.security.cs.allow-jit`/`allow-unsigned-executable-memory`: desktop mode doesn't run the wasm core.
  (If a service-account mode is ever added, check whether wazero then needs JIT entitlements.)
- Not sandboxed (direct distribution, D8). The app must sign the helper before signing the app (inside-out), and
  must not use `--deep`.

## Protocol

One JSON object per line on stdin, one response line per request on stdout, in order; requests are handled one at
a time. The helper exits when stdin closes. Lines are limited to 1 MiB; a longer line, or one that isn't a valid
request, is answered with `"id": null` and the stream continues.

```
→ {"id": 1, "op": "<op>", "params": {...}}          id: a number or a short string
← {"id": 1, "ok": true,  "result": {...}}
← {"id": 1, "ok": false, "error": {"code": "...", "message": "...", "hint": "...", "detail": "..."}}
```

| op | params | result |
|---|---|---|
| `account.check` | `account` | `account, connected, vault_count`. Opens the session (approval prompt); required before the others |
| `vault.ensure` | `title` | `vault_id, title, created`. Finds the vault by exact title or creates it; two with that title → `ambiguous_vault` |
| `items.list` | `vault_id` | `items: [{item_id, vault_id, title, node_id, node_name, vault_uuid, vault_name, current_version, key_check, versions: [{version, key_check, state, node_id?, attestation?}], updated_at, backed_up_at, issues}]`. Never key values |
| `item.upsert` | `vault_id, node_id, node_name, vault_uuid, vault_name, current_version, versions: [{version, key_b64, key_check, needed, node_id?, attestation?: {key_id, signature}}]` | `item_id, vault_id, created, written, current_version, key_check, stored_versions: [{version, key_check, state}], updated_at`, read back from 1Password after the write |
| `item.reveal` | `vault_id, item_id, versions?` | `item_id, vault_id, node_id, vault_uuid, current_version, versions: [{version, key_check, state, node_id?, attestation?, key_b64}]` (restore/export only) |

`vault_id` is always the 1Password vault; `vault_uuid` is the Vaulthalla vault's numeric id as ASCII decimal (the
key check binds it). Keys are 32 bytes. Params are strict: unknown fields are `bad_request`.

**Key checks.** `key_check` = lowercase hex of BLAKE2b-128 (16-byte digest, `golang.org/x/crypto/blake2b`) keyed by
the 32 key bytes, over `"vh-key-check-v1" ‖ vault_uuid ‖ UInt32BE(version)`: the daemon's `vault/KeyCheck.hpp`, byte
for byte (vectors in `internal/backup/keycheck_test.go`). The helper computes it, never the app, so key bytes touch
as little code as possible: `item.upsert` refuses a version whose key doesn't match its check
(`key_check_mismatch`, nothing read or written), the read-back after a write recomputes every stored version's check
(`verify_failed`), `items.list` reports a stored key that doesn't match its check as an issue, and `item.reveal`
refuses to return one (`key_check_mismatch`).

Error codes: `bad_request`, `unknown_op`, `line_too_long`, `no_session`, `internal`; connection
`integration_disabled`, `app_not_running`, `app_not_installed`, `library_blocked`, `unsupported_build`, `locked`,
`denied`, `account_not_found`, `account_switch`, `session_expired`, `rate_limited`, `onepassword_error`; items
`not_found`, `ambiguous_vault`, `duplicate_item`, `version_conflict`, `concurrent_modification`, `verify_failed`,
`key_check_mismatch`.
Connection errors carry a user-facing `hint` (e.g. "In 1Password, open Settings → Developer and turn on “Integrate
with other apps”.").

## The item

One API Credential item per (node, Vaulthalla vault) in the `Vaulthalla` vault:

- Title `Vaulthalla · <vault> · <node>`; tags `vaulthalla`, `vaulthalla/<node-slug>`; notes with restore steps
  (written at creation, then left to the user).
- `credential` (concealed): the current key, base64.
- Section **Vaulthalla**: `vh_node_id`, `vh_node_name`, `vh_vault_id`, `vh_vault_name`, `vh_key_version`,
  `vh_key_check`, `vh_backed_up_at`, `vh_format` (`vaulthalla-key-backup/1`).
- Section **Key versions**: per version `vN` (concealed, base64 key), `vN_check`, `vN_state`
  (`current` | `needed` | `retired`), newest first; and, when the node attested the version, the non-secret text
  fields `vN_node_id`, `vN_attest_key_id` and `vN_attest_sig` (the node's Ed25519 attestation over
  `"vh-key-attest-v1" ‖ node_id ‖ UInt64BE(vault_id) ‖ UInt32BE(version) ‖ key_check`). The helper never verifies
  attestations (the daemon does on import); it stores and returns them byte for byte. A version backed up without
  one gets it on a later backup that carries it (a re-backup refreshes the attestation; the key and its check never
  change), and an upsert without attestations keeps the stored ones.

Rules: the item is found by `vh_node_id` + `vh_vault_id`, never by title (renames are safe; two matches →
`duplicate_item`). An existing `vN` is never modified or removed: an incoming `vN` with different bytes or key
check fails with `version_conflict` and nothing is written. New versions are added, `credential` moves to the
current version, and versions the daemon no longer lists stay (marked `retired`). A re-upsert of the same state
writes nothing (`written: false`). Fields, tags and notes the helper doesn't own are kept. After a write the item
is read back and checked against the request (`verify_failed` otherwise), so the app confirms the export to the
daemon only on what 1Password actually holds.

## Secrets

Key bytes arrive only on stdin and leave only on stdout (`item.reveal`): never argv, environment, files or logs.
stderr carries op names, ids, error codes and timings; error details are scrubbed of every key value the request
touched. Request lines, decoded keys and response buffers are wiped after use (own line reader instead of bufio,
JSON aliasing instead of copies, reveal results encoded into a buffer that wipes on growth). That is best effort:
the GC may have moved a slice before it was wiped, and the SDK takes field values as Go strings, which can't be
wiped. The helper runs for a sync and exits.

## Fake mode (tests only)

`go build -tags fake` adds `VH_OP_FAKE=1`: an in-memory 1Password plus fault ops (`fake.crash`, `fake.sleep`,
`fake.stats`, `fake.noise`); accounts `fake:<code>` fail `account.check` with the SDK's message for that
condition. Release builds don't contain this code and ignore the variable (`fake_off.go`, tested).

## Manual self-test (maintainer, by hand)

Read-only: connects (1Password may ask for Touch ID), lists vaults, and if a `Vaulthalla` vault exists, prints its
backup items' metadata. It never creates a vault, never writes, never reads a key value out.

```sh
cd Helpers/vaulthalla-1password && ./build.sh
./bin/vaulthalla-1password self-test --account "<account name as shown in 1Password's sidebar>"
```

A local build is ad-hoc signed by the Go linker without the hardened runtime, so it can load 1Password's library
without the entitlement. If 1Password declines an ad-hoc-signed caller, sign the binary with your development
certificate and try again. Useful runs: normal (expect `ok` lines), with 1Password locked, with “Integrate with
other apps” off, and declining the prompt once; each failure should print its code and hint.

Verified 2026-10-20 on macOS 27.0.1 with 1Password 8.12.40 and SDK v0.4.1: an ad-hoc-signed local build connects
through desktop-app authorization (normal run). The locked, integration-off and declined cases are still unverified,
so their codes rest on keyword matching until someone runs them.
