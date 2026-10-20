# Vaulthalla Desktop: architecture and implementation plan

Status: **proposed** (2026-10-20). Decisions marked **[D#]** need the maintainer's approval before the work that
depends on them starts. Server paths are relative to the `vaulthalla/vaulthalla` repository.

Vaulthalla Desktop is a native Swift 6 / SwiftUI app for macOS 27+ on Apple Silicon. It is the administrative
cockpit for every Vaulthalla deployment the operator has paired. It covers administration, filesystem browsing, MCP
for agents, and 1Password backups of vault keys. The web console stays as the browser surface and the guest/share
surface. Desktop holds no business logic: the daemon's `ops::` layer authorizes and executes everything, and
Desktop speaks the daemon's generated command contract.

## 1. What already exists and gets reused

| Existing piece | Where | Reuse |
|---|---|---|
| `ops::` operations: actor-authorized, typed refusals (`denied`, `not_found`, `invalid`, `conflict`, `NeedsConfirmation{code}`) | `core/{include,src}/ops/` | Every Desktop, MCP and pairing action ends in an op. No new RBAC. |
| ws command surface: about 200 handlers, envelope `{command, payload, requestId, token}` / `{status, data, error}` | `core/src/protocols/ws/` | Desktop's transport. The same envelope rides the new device listener. |
| Generated ws contract (`vh_usage --json` → `wsContract.json`: payload/response fields, auth level, timeouts, refusal codes, `ws_hash`) | `core/usage/src/contract/`, `tools/contracts/ws_contract.py` | Swift types and timeouts are generated from it. `meta.contract.get` detects server upgrades. |
| CLI usage book (184 nodes, 148 leaves, 360 examples) + `OperationSpec` catalog (33 ops: typed fields, `requires_any`, `effect`, CLI/ws bindings) | `core/usage/` | Source of the MCP tool catalog and the agent skill. |
| `shell::Router::executeLine(line, User, io, transfer)` → `CommandResult` | `core/src/protocols/shell/Router.cpp:138` | Runs any `vh` command for a given actor without a socket. Remote MCP executes through it. |
| Machine-credential → `User` precedent (S3 gateway credentials map to a principal user) | `core/src/protocols/s3/Auth.cpp` | Model for "a paired device acts as its user". |
| Sealed secrets (`crypto::secrets::KeyProvider`: TPM2 on Linux, file backend on macOS) | `core/src/crypto/secrets/` | Holds the daemon's device-listener TLS key. |
| `vh vault keys export` (JSON: base64 key, version, historical keys) + export tracking (`vault_keys.exported_version/at`, migration 106) | `core/src/protocols/shell/commands/vault/keys.cpp` | Same payload and tracking for 1Password backups. |
| Design tokens (near-black canvas `#05080d`, one cyan accent `#22d3ee`, translucent surfaces, status tones; the backend owns severity) | `web/src/app/globals.css` | Ported to a SwiftUI theme. |
| Harness "agent gateway" (tool catalog from actor-side ops, per-principal scope) | `tools/harness/vhh/gateway.py` | Prior art for the MCP tool shape. Test-only, not reused as code. |

What the audit found missing:
- The daemon never terminates TLS; nginx does. It has no X.509 code.
- There is no bearer or device credential: native clients replay the browser's `refresh` cookie, and that token is
  bound to IP + User-Agent.
- There is no server push; the only unsolicited frame is the session-timeout notice.
- The ws contract book types only 76 of about 200 commands.
- CLI usage metadata has no value types and no read/write/destructive marker.
- There is no key import or restore.
- Nothing records an event on key creation or rotation.
- An export taken mid-rotation omits the outgoing key, which still decrypts files that haven't been re-encrypted.

## 2. Changes to the daemon and the web console

All of these land in `vaulthalla/vaulthalla` under its own rules: silent builds, unity hygiene, the next migration
number, `.release/*_NEXT.md`, ops parity tests, and `.claude/context` kept true.

**S1. Device listener and pairing** (the foundation; everything remote depends on it)
- **New listener** `device_server`: TLS 1.3 only, terminated by the daemon itself with OpenSSL 3 through Boost.Asio
  `ssl::stream`, on the default port **36971** **[D1]**. It is independent of nginx, Let's Encrypt and browser
  cookies.
  - Server identity: an ECDSA P-256 self-signed certificate whose key is sealed through `KeyProvider`. Clients pin
    its SPKI hash.
  - Client authentication: every client presents a certificate. The verify callback accepts any certificate and then
    authorizes by SPKI SHA-256 against the `devices` table. A connection whose SPKI isn't known reaches only the
    pairing endpoints.
  - Routes: `/ws` (the existing Router, new session mode **Device**) and `/mcp` (S3). The HTTP lanes `/preview`,
    `/download` and `/upload` (the same handlers with a device actor) are needed by Desktop's file browser.
  - Implementation choice for the implementer: make `ws::Session`/`http::Session` generic over the stream type
    (preferred), or hand decrypted bytes to the existing sessions over a socketpair with the identity attached
    out-of-band.
- **Migration 112:** `devices` and `device_pairing_requests` (the next free number at implementation time).
  - `devices`: `id, user_id → users ON DELETE CASCADE, name, platform, app_version, spki_sha256 UNIQUE,
    previous_spki_sha256, approved_by, created_at, last_seen_at, last_ip, revoked_at`.
  - `device_pairing_requests`: short-lived rows with `window_owner, spki, device name, nonce, SAS, expiry`.
- **Session mode Device:** the user comes from the device row and goes through the canonical `identities::Manager`
  object, so `authorizing()` applies. There is no refresh token, and `rbac::Actor::human(user)` is used, so RBAC is
  unchanged. Audit entries carry `device_id`. The allowlist is the Human set minus `auth.login`/`auth.refresh`, plus
  the device-only commands. Revoking a device, or `revokeSessions` on its user, closes its live sessions.
- **Commands:** ws `device.pairing.open|close|pending|approve|deny`, `device.list|rename|revoke`,
  `device.identity.rotate` (Device mode only); CLI `vh device pair|approve|deny|list|revoke`. Each is an op in
  `ops::devices` with a parity test.
- **Web console:** Account → Devices (list, rename, revoke), a "Pair a device" dialog that opens the window and
  shows pending requests with their SAS code, and a super-admin view of all devices.
- **Discovery (S5, small):** Bonjour `_vaulthalla._tcp` carrying a TXT record (node id, display name, device port,
  contract version). macOS uses `dns_sd` in the daemon. Linux ships a static `/etc/avahi/services/vaulthalla.service`
  (avahi in Recommends). Manual address entry always works.

**S2. Key backup surface** (for 1Password)
- `vault.keys.status` (needs the same view permission as `vh vault keys inspect`) returns, per vault the caller may
  see:
  - `version`, `exported_version`, `exported_at`
  - `rotation_in_progress`
  - `key_check`: BLAKE2b-128 keyed by the vault key over `"vh-key-check-v1" ‖ vault_id ‖ version`. It identifies the
    key without revealing it.
  - the versions still needed (`historical`).
- `vault.keys.export` is **refused outside Device sessions**. That keeps the rule that keys never pass through the
  browser, and MCP is refused too. It needs the same export permission as the CLI and returns the CLI's JSON shape.
  It also includes every version whose rotation hasn't completed, which fixes the mid-rotation gap for the CLI as
  well.
- `vault.keys.export.confirm {vault_id, version, key_check}` marks the key exported. It succeeds only if that version
  is still current and the key check matches, so Desktop records "backed up" only after 1Password has stored the key.
- Change detection: Desktop polls `vault.keys.status` (cheap, one query). A pushed `vault.keys.changed` event comes
  later, if ws push lands for other reasons.

**S3. MCP and agent skills** (see §5)

**S4. Contract coverage.** Extend the `WsCommandUsage` book to every command Desktop uses: `fs.*`,
`storage.vault.*`, `stats.*`, `share.*`, `role.*`, `pricing.*`, `sync.*`, `s3.gateway.*`. The web gains from it too.
Add an `effect` (`read | write | destructive`) to CLI usage nodes.

**S5.** Bonjour advertisement (above).

The web console's other behavior is unchanged.

## 3. Desktop architecture

**Repository** (`vaulthalla/desktop`, versioned and released on its own):

```
Package.swift           VaulthallaKit: the app's logic as Swift packages (unit-testable with `swift test`)
  Sources/VHCore        node and endpoint models, typed errors, redaction, logging
  Sources/VHContract    Swift generated from contract/wsContract.json (never hand-edited)
  Sources/VHTransport   ws client over Network.framework: TLS 1.3 + client identity, SPKI pinning, request map,
                        per-command timeouts, reconnect with backoff, unsolicited-frame stream
  Sources/VHIdentity    device keys (Secure Enclave P-256), self-signed X.509, Keychain identity, SAS
App/                    Xcode project (thin): SwiftUI scenes, feature views, design system
contract/               vendored wsContract.json (+ the server version it came from); tools/gen-contract.py
Helpers/                vaulthalla-1password (Go, §6) and vaulthalla-mcp (Swift, §5): later phases
docs/                   this plan, the pairing protocol, release notes
```

**App structure**
- One `NavigationSplitView`. The sidebar lists the nodes (status dot, contract mismatch badge, pairing state); the
  feature sections below it apply to the selected node.
  - Feature sections: Overview/Health, Files, Vaults, Shares, Access (users, groups, roles), Sync conflicts, Cost,
    S3 gateway, Recovery keys, Settings.
  - "All nodes" views cover what spans deployments: overview, key backup status, devices.
  - ⌘1–9 switch nodes, ⌘K opens a command palette, and a menu bar extra shows health.
- Each node is an `@Observable NodeSession` actor-backed model that owns one `WsClient` and a small query cache. The
  cache is the TanStack Query idea, minimal: keyed results, invalidate-after-mutation, polling only while a view is
  visible and the app is active. Swift 6 strict concurrency throughout.
- **Theme:**
  - A dark scheme with the web's tokens as named `Color`s and one cyan tint.
  - Native materials (Liquid Glass sidebar and toolbars) over the `#05080d` canvas.
  - Status tones only as the backend reports them; unknown is never green.
- **Contract:** a Swift `WsCommand` enum, generated `Codable` payload/response types, the auth level and timeouts per
  command, and the `ws_hash`.
  - Desktop compares the `ws_hash` with `meta.contract.get` and degrades per command ("needs Vaulthalla ≥ x"), never
    the whole node.
  - Desktop supports the current and the previous server minor.
- **Files:** a virtualized `Table`/grid backed by `fs.*`. Downloads and uploads use the HTTP lanes on the device
  listener (URLSession with the same identity). Quick Look previews come from `/preview`, and drag-and-drop works
  with Finder.
- **Persistence:** in Application Support, node records (id, name, endpoints, pinned server SPKI, device id). Device
  keys live in the Keychain and Secure Enclave. Nothing secret goes in `UserDefaults` or in logs.
  - `Logger` uses `.private` for everything user-derived.
  - Key material is held in a `SecretBytes` type that zeroes on deinit and has no `description`.

## 4. Pairing protocol (summary; full spec in `docs/pairing.md` once S1 is approved)

1. **Device identity.** Desktop creates one P-256 key per node in the Secure Enclave (`SecKeyCreateRandomKey`,
   `kSecAttrTokenIDSecureEnclave`, `.privateKeyUsage`, so no prompt per handshake). It wraps the key in a
   self-signed certificate, giving a Keychain `SecIdentity`. The device id is the SPKI SHA-256.
2. **Open a window.** In the web console ("Pair a device") or with `vh device pair`, a signed-in user opens a pairing
   window. It lasts 10 minutes and belongs to that user.
3. **Request.** Desktop connects over TLS to `host:36971` with its certificate and sends `device.pair.request
   {name: "Cooper's MacBook Pro", platform, app_version, nonce}`. It records the server's SPKI (not trusted yet). The
   daemon refuses while no window is open.
4. **Compare.** Both sides compute `SAS = 6 digits of SHA-256("vh-pair-v1" ‖ server_spki ‖ device_spki ‖ nonce_d ‖
   nonce_s)`.
   - Desktop shows "Approve on <node>: **482 913**".
   - The approval UI shows the device name, platform, source IP and the same code.
   - A man in the middle would hold different SPKIs on each leg, so the codes would differ.
5. **Approve.** The window owner clicks Approve (or runs `vh device approve <id>`). The device row is created, bound
   to that user. Desktop's pending request resolves with the node id and name, and it pins the server SPKI.
6. **Reconnect.** Every later connection is mutual TLS with pinned SPKIs, with no password, token or cookie. Desktop
   reconnects across network changes, because nothing is bound to IP.
7. **Rotation.**
   - Desktop rotates its key every 90 days, or on demand, through `device.identity.rotate` on an authenticated
     session. The new certificate is signed by the old key, and the old SPKI stays valid until the new one is first
     used.
   - The daemon rotates its server key by announcing the next SPKI ahead of the switch.
8. **Revocation.** Revoke in the web console, CLI or Desktop. The daemon closes the device's live sessions and
   refuses its SPKI. Desktop shows "This Mac was unpaired from <node>" and offers to pair again.

Approval follows ordinary account semantics **[D3]**:
- A device acts as the user who approved it, with that user's RBAC.
- Any user may pair devices to their own account.
- Super admins may list and revoke every device.

There is no device-scoped permission system.

## 5. MCP design

**One catalog, two transports, one execution engine.**
- **Catalog.** Built in the daemon (`mcp::Catalog`) from the usage book plus the `OperationSpec` catalog.
  - Typed tools come from operations. Today there are 33, and every new op adds one. Their annotations come from
    `effect`: `readOnlyHint`, `destructiveHint`, `idempotentHint`.
  - `vh_help {path}` browses the usage book and its examples.
  - `vh_run {command}` runs any CLI leaf. Its annotation comes from the new per-node `effect`.
  - Never exposed: key and secret export, `secrets update`, `setup`/`teardown`, `set-super-admin-password`, and
    `fs get|put` (until there is a byte-safe design).
- **Local.** `vh mcp` runs the MCP server over stdio inside `vaulthalla-cli`. It fetches the catalog over the CLI
  socket and executes non-interactive CLI frames, so authorization is the existing peer-UID mapping.
- **Remote.** `/mcp` (Streamable HTTP) on the device listener, authenticated by the device certificate, executes
  through `Router::executeLine(line, deviceUser)`.
- **Confirmations.** A tool never prompts silently.
  - A `NeedsConfirmation` refusal returns a structured result `{needs_confirmation: code, how: "re-call with
    confirm: \"<code>\""}`. The skill tells the agent to ask the human first.
  - Clients that support MCP elicitation get the prompt directly.
- **External clients and future embedded agents.** Most MCP clients can't present a client certificate. Desktop
  therefore ships a `vaulthalla-mcp` stdio bridge in `Contents/Helpers`.
  - It shares the app's Keychain access group, so it uses the device identities.
  - It aggregates every paired node: tools take a `node` argument, and `nodes.list` comes first.
  - Registration: `claude mcp add vaulthalla -- "/Applications/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp"`.
  - Desktop's own future agent uses the same client library in process.
- **Agent skills.** `vh skill install --agent <claude|codex> [--scope user|project]` runs on the client side and
  needs no daemon.
  - It writes a `vaulthalla` skill: hand-written safety guidance plus references generated from the catalog.
  - It registers the MCP server through the agent's own CLI when one is present (`claude mcp add …`, Codex
    `config.toml`), and prints the command otherwise.
  - The guidance covers: read before you write, never bypass confirmations without the human, prefer typed tools,
    and keys are never handled by agents.
- **Spec target.** MCP 2025-11-25, the version `modelcontextprotocol/swift-sdk` 0.12.x implements. The daemon side is
  a small JSON-RPC handler in C++: `initialize`, `tools/list`, `tools/call`, `ping`, plus elicitation. 2026-07-28
  (stateless) follows once the SDKs do.

## 6. 1Password strategy

**Approach: a bundled helper on 1Password's official Go SDK with desktop-app authentication** **[D5]**.
- There is no Swift SDK. Desktop-app auth (Go SDK ≥ 0.4) talks to the running 1Password app over its IPC. The user
  approves with Touch ID, and no service-account token or CLI install is involved. Vault create/list and item
  create/update with tags and sections are all supported.
- The user turns on 1Password → Settings → Developer → "Integrate with other apps" once. Desktop detects when it is
  off and explains.
- `vaulthalla-1password` (Go, signed with our team ID, in `Contents/Helpers`, hardened runtime plus
  `disable-library-validation` to load 1Password's IPC dylib) speaks JSON lines on stdin/stdout. It exposes:
  - `account.check`
  - `vault.ensure {title: "Vaulthalla"}`
  - `items.list {tag}`, returning metadata fields only
  - `item.upsert`
  - `item.reveal`, for restore only
- Key bytes cross the pipe only: never argv, environment, disk or logs. The helper is launched for a sync and exits.
- Rejected alternatives:
  - The `op` CLI: an extra install, a second setting, and text parsing.
  - Python/JS SDKs: they need a bundled runtime.
  - Calling 1Password's IPC dylib from Swift: undocumented.
  - Service accounts: they can't reach personal vaults and have low write limits.
- **Items.** One item per (node, vault) **[D6]**, category API Credential, in the dedicated `Vaulthalla` vault
  (created on first sync, or the user picks one).
  - Title `Vaulthalla · <vault> · <node>`.
  - `credential` = the current key (base64).
  - Section "Vaulthalla": vault id, vault name, node name and id, key version, key check, backed-up time.
  - Section "Previous keys": the versions still needed.
  - Tags `vaulthalla`, `vaulthalla/<node>`.
  - Notes: how to restore.
  - Rotation updates the same item, and 1Password's item history keeps every earlier state.
- **Status per vault:** `backed up` (1Password's version and key check equal the daemon's), `needs backup` (never or
  stale after a rotation), `rotating` (waits for the rotation to complete, and keeps the old key in the item
  meanwhile), `mismatch` (key check differs), `unknown` (node offline). A macOS notification fires when vaults need
  backup. One "Sync all" button covers every node.
- **Restore [D7]:** the daemon has no key import today. Phase 1 restore:
  - Verify: re-check the stored key against the daemon's key check.
  - Write the CLI-format export JSON to a file the user chooses, or copy the key to the clipboard with auto-clear.
    Either feeds today's documented recovery.
  - A daemon `vh vault keys import` for disaster recovery is a separate security project.
- **Hygiene:** keys never enter MCP results or agent context (the export is refused for MCP at the daemon), logs or
  caches. The 1Password item id is the only thing Desktop stores per vault.

## 7. Workstreams and order

| # | Workstream | Repo | Depends on | Parallel with |
|---|---|---|---|---|
| D1 | Foundation: package, contract codegen, transport, identity primitives, app shell + theme, node registry, Bonjour browse | desktop | none (**started now**) | S1 |
| S1 | Device listener, TLS, `devices` migration, Device session mode, pairing ops/CLI/ws, web Devices UI | server + web | D1-D4 approved | D1 |
| D2 | Pairing client + node onboarding UX, reconnect, revocation handling | desktop | S1 protocol frozen | S4 |
| S4 | Contract coverage for Desktop's commands; CLI `effect` metadata | server | none | S1, D2 |
| D3 | Admin features per area (health, vaults, access, shares, conflicts, cost, gateway) | desktop | S4 per area | D4–D6 |
| D4 | Files browser + transfers over the device HTTP lanes | desktop + server | S1 lanes | D3 |
| S2 + D5 | Key status/export/confirm; 1Password helper and backup UI | both | S1, [D5-D7] | D3 |
| S3 + D6 | MCP catalog, `vh mcp`, `/mcp`, `vh skill install`; Desktop MCP bridge | both | S1 (remote), S4 (effect) | D3 |
| D7 | Release: signing, notarization, Homebrew cask `vaulthalla-desktop`, updates | desktop + tap | [D8] | any |

Each workstream is a self-contained brief for a subagent with disjoint files. Server workstreams go through
`/verify` and their parity tests. Desktop workstreams prove themselves with `swift test` and `xcodebuild`, plus the
Xcode MCP (`xcrun mcpbridge`) for previews and UI checks once it is enabled.

## 8. Decisions for the maintainer

- **D1** A daemon-terminated mTLS listener on a new port (36971), on all interfaces when enabled. Default on for new
  installs, or opt-in via `vh setup devices`?
- **D2** Pinned self-signed certificates on both sides, with no CA. A device CA is the alternative.
- **D3** A device acts as its approving user, with full RBAC. No device-scoped permissions.
- **D4** Key export over ws, allowed **only** on Device sessions (never browser, never MCP), plus
  `export.confirm`-based tracking.
- **D5** The 1Password integration is a bundled Go helper on the official SDK, which needs `disable-library-validation`
  on the helper. Desktop ships outside the Mac App Store, because the sandbox blocks the IPC.
- **D6** Item granularity: one item per (node, vault) with previous versions inside it (recommended), or one item per
  key version.
- **D7** Restore in phase 1 is verify + export file/clipboard. A daemon key import is a separate project.
- **D8** Distribution: Developer ID + notarization needs a paid Apple Developer Program team (this Mac has only a
  free personal team, enough for local development). Updates via Sparkle or the Homebrew cask only? License: AGPL-3.0
  like the server? Repository visibility (created private)?
