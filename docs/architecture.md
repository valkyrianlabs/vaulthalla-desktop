# Vaulthalla Desktop: architecture and implementation plan

Status: **approved** (2026-10-20). Decisions **[D#]** were settled by the maintainer the same day; see §8. Server paths are relative to the `vaulthalla/vaulthalla` repository.

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
  `ssl::stream`, on port **36972** **[D1]**. It is independent of nginx, Let's Encrypt and browser cookies. It is on
  by default on loopback; "enable remote connections" (web console or `vh device remote enable`, an
  `ops::config` write) rebinds it to all interfaces and it stays that way.
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
Helpers/                vaulthalla-1password (Go, §6); the Swift vaulthalla-mcp bridge (§5) is a package target
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
- **Contract:** a Swift `WsCommand` enum, generated `Codable` payload/response types and server models (`WsModel`),
  the auth level, timeouts and confirmations per command, and the `ws_hash` and `models_hash`.
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

## 4. Pairing protocol (summary; the normative spec is `docs/pairing.md`)

1. **Device identity.** Desktop creates one P-256 key per node in the Secure Enclave (`SecKeyCreateRandomKey`,
   `kSecAttrTokenIDSecureEnclave`, `.privateKeyUsage`, so no prompt per handshake). It wraps the key in a
   self-signed certificate, giving a Keychain `SecIdentity`. The device id is the SPKI SHA-256.
2. **Open a window.** In the web console ("Pair a device") or with `vh device pair`, a signed-in user opens a pairing
   window. It lasts 10 minutes and belongs to that user.
3. **Request.** Desktop connects over TLS to `host:36972` with its certificate and sends `device.pair.request`
   with its name, platform, version and a *commitment* to its nonce. It records the server's SPKI (not trusted
   yet). The daemon refuses while no window is open and answers with its own nonce; Desktop then reveals its nonce
   (`device.pair.confirm`). Committing first stops a man in the middle from grinding the 6-digit code.
4. **Compare.** Both sides derive the code from both SPKIs and both nonces. Desktop shows "Approve on <node>:
   **482 913**". The approval UI shows the device name, platform and source IP with three candidate codes; a man
   in the middle holds a different key on each leg, so his codes can't match.
5. **Approve with one click.** The window owner clicks the code the Mac shows (number matching; `vh device approve
   <id>` asks for it). A wrong pick denies the request. The device row is created, bound to that user; Desktop's
   pending request resolves with the node id and name, and it pins the server SPKI.
6. **Reconnect.** Every later connection is mutual TLS with pinned SPKIs, with no password, token or cookie. Desktop
   reconnects across network changes, because nothing is bound to IP.
7. **Rotation.**
   - Desktop rotates its key every 90 days, or on demand, through `device.identity.rotate` on an authenticated
     session. The old key signs a proof endorsing the new SPKI, and the old SPKI stays valid until the new one is
     first used.
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
- **Catalog.** `mcp::Catalog` in `core/usage` (the library both `vaulthalla-cli` and the daemon link), built from
  the usage book plus the `OperationSpec` catalog. Compiled in, not fetched: `tools/list` works with the daemon down,
  and version skew fails closed because an older daemon rejects options it doesn't know.
  - Typed tools come from operations with a CLI binding (23 of 33 today; every new op adds one). Annotations come
    from `effect`.
  - `vh_help {path}` browses the usage book and its examples.
  - `vh_read {command}` runs read-only CLI leaves (`readOnlyHint`, so clients may auto-approve);
    `vh_run {command}` runs any other leaf (`destructiveHint`). Every CLI leaf declares `effect: read | write |
    destructive`, and a test enforces it.
  - Never exposed (`mcp::exclusions()`, pinned by a test): key and secret export, `secrets update`,
    `setup`/`teardown` (incl. `set-super-admin-password`), and `fs get|put` (until there is a byte-safe design).
- **Local.** `vh mcp` runs the MCP server over stdio inside `vaulthalla-cli` and executes non-interactive CLI frames,
  so authorization is the existing peer-UID mapping.
- **Remote.** `/mcp` (Streamable HTTP) on the device listener, authenticated by the device certificate, executes
  the same catalog through `Router::executeLine(line, deviceUser)`.
- **Confirmations.** A tool never prompts and never passes bypass flags on its own.
  - A refusal for want of confirmation returns `{needs_confirmation, message, how_to_confirm}`; the agent re-calls
    with an explicit `confirm` argument, which the skill says needs the human's approval first.
  - Any destructive leaf additionally needs `confirm.destructive`, enforced in the MCP layer whatever the command's
    own prompt does.
  - Clients that support MCP elicitation may get the prompt directly later.
- **External clients and future embedded agents.** Most MCP clients can't present a client certificate. Desktop
  therefore ships a `vaulthalla-mcp` stdio bridge at `Vaulthalla.app/Contents/Helpers/vaulthalla-mcp` (as built:
  `Sources/VHMCP` + `Sources/vaulthalla-mcp`; the Xcode tool target of the same name is embedded by the app's
  "Embed MCP Bridge" phase and signed on copy with the app's identity when signing is on).
  - **Trust.** It reads the node registry (`nodes.json`) and presents the device identity the app created for each
    node (`DeviceKeys`), pinning the server SPKI from the record, exactly like the app's HTTP lanes. It creates,
    rotates and deletes nothing. A Secure Enclave key lives in the data protection keychain, so the helper must be
    signed by the same team with the app's `keychain-access-groups` (`$(AppIdentifierPrefix)sh.vaulthalla.desktop`);
    that entitlement is restricted on macOS and a bare executable can't carry a provisioning profile, so the release
    build (D7) wraps the helper in a minimal bundle with an embedded profile if the plain binary is refused. Unsigned
    and development builds use the file-keychain software key, whose access list names the app: the Keychain may
    ask whether `vaulthalla-mcp` may use it (an ad hoc signature changes with every build).
  - **One server for every paired node.** `tools/list` returns `nodes_list` (id, name, host, port, pairing state,
    reachable now?) and each reachable node's tools from its `/mcp`, each with an added required `node` argument
    (the node id or display name). Annotations pass through unchanged. Tools are listed once per name; when nodes on
    different versions define a name differently, the variant offered by the most nodes (ties: the first in the
    operator's order) keeps the name and the others are listed as `<name>_v2`, `_v3`, … with their own unchanged
    definitions and a note naming their nodes; a call reaches only the nodes that define it that way, so annotations
    are never merged. The bridge adds no tool besides `nodes_list`, never one the daemon doesn't offer, and drops
    (defensively; the daemon never offers them) tools named for key or secret export/import, and refuses `vh_run`
    command lines that would export or import keys.
  - **Calls.** `tools/call` goes to the named node's `/mcp` with the arguments minus `node`; the node's result
    (`isError`, structured `needs_confirmation`) or JSON-RPC error comes back verbatim, so the destructive gate and
    confirmations work exactly as with `vh mcp`.
  - **Per node:** `initialize` lazily, once per connection; `MCP-Protocol-Version` on every later request; a 400
    (refused before anything ran) re-initializes and retries once; a 403 retries once on a fresh connection (the
    app may have rotated the key), then reports that the node no longer accepts this Mac.
  - **Deadlines and cancellation.** A call is abandoned after `VAULTHALLA_MCP_TIMEOUT` seconds (default 600, `0`:
    none), the daemon's own variable and default; the node may still finish it. `notifications/cancelled` cancels the
    call's HTTP request and its answer is never sent. Calls run concurrently; `ping` is always answered.
  - **Offline nodes** lose their tools; calls to them return an `isError` result that says why. After
    `notifications/initialized` the bridge polls every 60 s and sends `notifications/tools/list_changed` when the
    list changes (it advertises `tools.listChanged`).
  - **Hygiene.** stdout carries only protocol messages; logs go to stderr (`VAULTHALLA_MCP_LOG`) and never include
    tool arguments or results.
  - **Implementation choice.** The small JSON-RPC surface (`initialize`, `notifications/initialized`, `ping`,
    `tools/list`, `tools/call`, `notifications/cancelled`) is implemented directly over `JSONValue` instead of
    `modelcontextprotocol/swift-sdk`: results must pass through as raw JSON rather than be re-encoded through the
    SDK's typed models, and the SDK's package graph brings swift-nio, swift-log, swift-system, eventsource and a
    branch-pinned docc plugin into an app that otherwise depends on swift-certificates alone.
  - **Registration** (Settings → Agents shows the app's actual path and copies these; Desktop never runs them):
    `claude mcp add --scope user vaulthalla-desktop -- "/Applications/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp"`
    and `codex mcp add vaulthalla-desktop -- "/Applications/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp"` (or
    `[mcp_servers.vaulthalla-desktop]` with `command = "…"` and `tool_timeout_sec = 600` in `~/.codex/config.toml`).
  - Desktop's own future agent uses the same library (`VHMCP`) in process.
- **Agent skills.** `vh skill install --agent <claude|codex> [--scope user|project]` runs on the client side and
  needs no daemon.
  - It writes a `vaulthalla` skill: hand-written safety guidance plus references generated from the catalog.
  - Locations: Claude Code `~/.claude/skills/vaulthalla` (project: `.claude/skills/`); Codex
    `~/.agents/skills/vaulthalla` (project: `.agents/skills/`).
  - It registers the MCP server through the agent's own CLI when one is present (`claude mcp add …`,
    `codex mcp add …`), and otherwise prints the command (or the Codex TOML stanza).
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
  - `account.check {account}`
  - `vault.ensure {title: "Vaulthalla"}`
  - `items.list {vault_id}`, returning metadata fields only
  - `item.upsert`, returning what 1Password holds after the write (read back)
  - `item.reveal {vault_id, item_id, versions?}`, for restore only
  - As built: `Helpers/vaulthalla-1password/README.md` (protocol, item layout, signing) and `Sources/VHOnePassword`.
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
  - Section "Key versions": one concealed field per version (`v3`, `v2`, …) with its key check. A rotation adds the
    new version and moves `credential` to it; a version is never overwritten, and none is removed while the daemon
    still reports it as needed.
  - Tags `vaulthalla`, `vaulthalla/<node>`.
  - Notes: how to restore.
  - The item is found by its stable identifiers (node id + vault id fields), never by title, so renames are safe.
- **Status per vault:** `backed up` (1Password's version and key check equal the daemon's), `needs backup` (never or
  stale after a rotation), `rotating` (waits for the rotation to complete, and keeps the old key in the item
  meanwhile), `mismatch` (key check differs), `unknown` (node offline). A macOS notification fires when vaults need
  backup. One "Sync all" button covers every node.
- **Restore [D7]:** in milestones.
  1. Verify: re-check the stored key against the daemon's key check.
  2. Export: write the CLI-format export JSON to a file the user chooses (native save panel; no clipboard).
  3. Import: Desktop sends the stored versions to the daemon's `vault.keys.import` (S6) over the paired connection,
     the same operation as `vh vault keys import`. Only then does Desktop call this full recovery support.
- **Hygiene:** keys never enter MCP results or agent context (the export is refused for MCP at the daemon), logs or
  caches. The 1Password item id is the only thing Desktop stores per vault.

## 7. Workstreams and order

| # | Workstream | Repo | Depends on | Parallel with |
|---|---|---|---|---|
| D1 | Foundation: package, contract codegen, transport, identity primitives, app shell + theme, node registry, Bonjour browse | desktop | none (in progress) | S1 |
| S1 | Device listener, TLS, `devices` migration, Device session mode, pairing ops/CLI/ws, web Devices UI | server + web | none (in progress) | D1 |
| D2 | Pairing client + node onboarding UX, reconnect, revocation handling | desktop | S1 protocol frozen | S4 |
| S4 | Contract coverage for Desktop's commands; CLI `effect` metadata | server | none | S1, D2 |
| D3 | Admin features per area (health, vaults, access, shares, conflicts, cost, gateway) | desktop | S4 per area | D4–D6 |
| D4 | Files browser + transfers over the device HTTP lanes | desktop + server | S1 lanes | D3 |
| S2 + D5 | Key status/export/confirm; 1Password helper and backup UI | both | S1 | D3 |
| S6 | `vh vault keys import`: restoring a vault's key from a backup (needed before full recovery support is claimed) | server | S2 | D3–D6 |
| S3 + D6 | MCP catalog, `vh mcp`, `/mcp`, `vh skill install`; Desktop MCP bridge | both | S1 (remote), S4 (effect) | D3 |
| D7 | Release: signed, notarized DMG, Sparkle updates, optional Homebrew cask `vaulthalla-desktop` | desktop + tap | Developer ID | any |

Each workstream is a self-contained brief for a subagent with disjoint files. Server workstreams go through
`/verify` and their parity tests. Desktop workstreams prove themselves with `swift test` and `xcodebuild`, plus the
Xcode MCP (`xcrun mcpbridge`) for previews and UI checks once it is enabled.

## 8. Decisions (approved 2026-10-20)

- **D1. Opt-in remote listener.** The device listener runs by default on loopback only, so a Desktop on the same
  machine pairs without setup. One action in the web console or CLI (`vh device remote enable`) binds it to all
  interfaces; it then stays enabled so trusted devices keep reconnecting. No manual configuration.
- **D2. Self-signed certificates with mutual pinning, no CA.** Generation, renewal and trust persistence are
  automatic on both sides; the matching pairing code verifies the first handshake.
- **D3. Devices inherit the approving user's RBAC.** Any authenticated user can pair their own devices. Permission
  changes, deactivation and deletion propagate to live device sessions automatically (canonical identity objects,
  `revokeSessions`).
- **D4. Key export only through paired connections or the local CLI.** Never through the browser or MCP.
- **D5. A bundled helper on 1Password's official Go SDK**, with desktop-app authorization and Touch ID. No Mac App
  Store build.
- **D6. One 1Password item per vault**, keyed by stable identifiers (node id + vault id), holding every key version
  as versioned fields. A version still needed for restoration is never overwritten or dropped.
- **D7. Real restoration.** Backup verification and export to a file (preferred over the clipboard) are the first
  milestones; full recovery support is not claimed until the daemon has `vh vault keys import` (workstream S6).
- **D8. Public AGPL-3.0 repository, direct distribution:** a signed, notarized DMG with Sparkle updates and an
  optional Homebrew cask. Local development signing until a paid Apple Developer membership exists.
