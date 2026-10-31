# Vaulthalla Desktop: architecture and implementation plan

Status: **approved** (2026-10-20). Decisions **[D#]** were settled by the maintainer the same day; see §9. Server paths are relative to the `valkyrianlabs/vaulthalla-server` repository.

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
| Generated ws contract (`vh_usage --json` → `wsContract.json`: payload/response fields, auth level, timeouts, refusal codes, `ws_hash`) | `core/usage/src/contract/`, `tools/contracts/ws_contract.py` | Swift types and timeouts are generated from it. `meta.hello` reports the server's release, protocol and capabilities (§3, "Protocol negotiation"). |
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

All of these land in `valkyrianlabs/vaulthalla-server` under its own rules: silent builds, unity hygiene, the next migration
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

**S5.** Bonjour advertisement (above). Desktop reads TXT `node_id`, `port` and `name`/`display_name`; the endpoint
selector uses Bonjour only as its last source (§3, "Endpoints and route selection").

The web console's other behavior is unchanged.

## 3. Desktop architecture

**Repository** (`valkyrianlabs/vaulthalla-desktop`, versioned and released on its own):

```
Package.swift           VaulthallaKit: the app's logic as Swift packages (unit-testable with `swift test`)
  Sources/VHCore        node and endpoint models, typed errors, redaction, logging
  Sources/VHContract    Swift generated from contract/wsContract.json (never hand-edited)
  Sources/VHTransport   ws client over Network.framework: TLS 1.3 + client identity, SPKI pinning, request map,
                        per-command timeouts, reconnect with backoff, unsolicited-frame stream
  Sources/VHIdentity    device keys (Secure Enclave P-256), self-signed X.509, Keychain identity, SAS
  Sources/VHFinder      File Provider domains, the extension's readiness, and the vault replica (§7)
App/                    Xcode project (thin): SwiftUI scenes, feature views, design system
  Extensions/FileProvider  the File Provider extension (§7)
contract/               vendored wsContract.json (+ the server version it came from); tools/gen-contract.py
Helpers/                vaulthalla-1password (Go, §6); the Swift vaulthalla-mcp bridge (§5) is a package target
docs/                   this plan, the pairing protocol, release notes
```

**App structure**
- One `NavigationSplitView`. The sidebar lists the nodes (status dot, an incompatibility badge when the node's
  protocol range doesn't overlap this build's, pairing state); the feature sections below it apply to the selected
  node.
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
  the auth level, timeouts and confirmations per command, the `ws_hash` and `models_hash`, and (contract_version 3)
  the daemon's protocol range and capabilities. Response members newer than the compatibility baseline are optional
  (see "Protocol negotiation" below). Desktop degrades per command and per capability, never the whole node, except
  when the protocols don't overlap at all.
- **Files:** a virtualized `Table`/grid backed by `fs.*`. Downloads and uploads use the HTTP lanes on the device
  listener (URLSession with the same identity). Quick Look previews come from `/preview`, and drag-and-drop works
  with Finder.
- **Persistence:** node records (id, name, configured endpoint, advertised endpoints and the last good one, pinned
  server SPKI, device id) in `nodes.json`: in the App Group container for signed builds, in Application Support
  otherwise (see "Signing and the shared container" below).
  Device keys live in the Keychain and Secure Enclave. Nothing secret goes in `UserDefaults` or in logs.
  - `Logger` uses `.private` for everything user-derived.
  - Key material is held in a `SecretBytes` type that zeroes on deinit and has no `description`.
- **Protocol negotiation.** Server and Desktop release independently, so every connection settles what both speak
  before any feature runs (`VHNodes.NodeProtocol`, the server's `docs/reference/ws-protocol.md`).
  - **Versions.** The ws protocol is an integer the daemon bumps only for a breaking change; protocol 1 starts with
    the first daemon that answers `meta.hello` (1.19). This build speaks `WsProtocol.minimum...maximum` (1...1), the
    one place the range is kept. Compatible changes (new commands, new response members, new capabilities) never
    bump it.
  - **Handshake.** Right after connecting, before the session reports online, `NodeSession` sends `meta.hello`
    `{client: {name: "vaulthalla-desktop", version: CFBundleShortVersionString}, protocol: {min, max}}`. The daemon
    answers `{server: {name, version}, protocol: {version, min, max}, capabilities, commands, contract}`; the session
    keeps it (`nodeProtocol`, reported as `Event.protocolNegotiated`), and every reconnect negotiates again, so an
    upgraded node is picked up. Then `device.server.identity` runs as before (skipped only when the node announces it
    lacks `device.server.identity`).
  - **Pairing.** `PairingClient` sends `meta.hello` on the pairing-only connection before `device.pair.request`. An
    incompatible server stops the attempt before anything is requested (`PairingFailure.incompatible`, the same
    message, the sheet stays open with Try Again); a legacy server, which refuses it there with `device_unknown` like
    every command but `device.pair.*`, pairs as before; a negotiated one pairs, and the sheet shows its release under
    the code.
  - **Outcomes.** *Negotiated*: a version in range; `supports(command:)` answers from `commands`,
    `supports(capability:)` from `capabilities` (yes or no). *Legacy*: a daemon ≤ 1.18.0 refuses `meta.hello` with
    "Unknown command" and no code; protocol 1 is assumed, release, capabilities and commands are unknown, and every
    support check is *unknown*: feature code then tries the command and reads "Unknown command" as before
    (`WsError.isUnknownCommand`, the only place those words are matched). *Incompatible*: `protocol_unsupported`
    (`data {code, server_min, server_max, server_version}`), or a version outside the range. The session stays
    connected so the node shows what it runs, but feature calls through it are refused here, unsent
    (`WsError.protocolUnsupported`), as are the HTTP lanes. The message names the side to update: "This node runs
    Vaulthalla X, which needs a newer Vaulthalla Desktop", or "…speaks an older protocol: update Vaulthalla on the
    node".
  - **Supported range.** The oldest daemon Desktop works with is the compatibility baseline,
    `contract/compat-baseline.json` (server 1.17.0's contract, recorded in `compat-baseline.SOURCE.json`).
    `tools/gen-contract.py` generates every response member the current contract requires but the baseline doesn't
    guarantee as optional (`WsContract.relaxedMembers`), so a newer member never breaks decoding against an older
    daemon; request types stay as the current contract says, and `--check` validates the baseline too. On a legacy
    node a decode failure (`contractMismatch`) says Desktop needs Vaulthalla 1.17 or later.
  - **Refusals.** Device sessions on a 1.19+ daemon answer an unknown command with `data.code` "unknown_command"
    (`WsError.unknownCommand`, capability `errors.unknown_command_code`). Only codes the command declares in its
    `confirmations` are `needsConfirmation`; any other code is `refused(code:message:)`, never a question.
  - **Capabilities Desktop reads** (`WsCapability`, checked against the vendored contract's list):
    `device.lanes.preview|download|upload` (a 404 on a lane the node doesn't announce is the missing lane, not a
    missing item), `device.mcp` (the MCP bridge asks it over its own `meta.hello` when `/mcp` answers 404),
    `device.server.identity`, `errors.unknown_command_code`, `fs.entry.metadata_version`, `device.endpoints` (the
    session asks for the node's addresses, "Endpoints and route selection" below), `device.lanes.transfer` and
    `http.upload.resumable` ("Resumable uploads and tuning" below). A capability the spec defines before the vendored
    contract declares it sits in `WsCapability.awaitingContract` (now `http.upload.resumable`). Command presence
    always comes from `commands`.
  - **UI.** The node overview shows "Vaulthalla 1.19.0 · protocol 1" (legacy: "Vaulthalla 1.18 or earlier") and the
    contract identity from the hello; an incompatible node gets a sidebar badge, an "Incompatible" header badge and,
    where its sections would be, the message saying which side to update.
- **Endpoints and route selection** (the server's `docs/reference/transfer-protocol.md` §1–§2, normative). A node is
  reached over the best address that proves its server key, not only the one the operator typed.
  - **Record.** `Node.endpoint` stays the configured address. `Node.endpoints` keeps the node's last
    `device.endpoints` answer (host, port, kind, source, interface), `lastGood` the endpoint the last Device session
    came up on (with time and class), `lastAdvertisedAt` when the list last changed. All optional on disk, decoded
    leniently (a malformed entry is dropped, never the record); the envelope stays version 1. Only the credential
    owner writes them: an owner session reports `NodeSession.Event.endpointsChanged`, and the app saves it without
    restarting the session (routing hints aren't part of `NodeSessions`' restart basis). The File Provider extension
    and `vaulthalla-mcp` read them and select on their own, never writing.
  - **Candidates** (`VHNodes.EndpointCandidate`), merged and de-duplicated by (host lowercased, port): `127.0.0.1` and
    `::1` at the listener's port for every node (the pin decides whether that server is this node), the configured
    endpoint, the advertised list, the last good endpoint; Bonjour results whose TXT `node_id` equals `serverNodeID`
    only after all of those failed (`BonjourServiceBrowser.endpoints(forNode:within:)`, a 1.5 s browse).
  - **Probe** (`VHTransport.TLSEndpointProber`): a TLS 1.3 handshake on a fresh connection with the device identity
    and the node's pins (current, then announced next) through the same verify path as `WsClient`, then close. TCP
    alone never counts. Outcomes: `ok` (TCP handshake RTT, address reached, interface, which pin), `refused`,
    `timeout`, `identity_mismatch`, `tls_error`, `unresolved`.
  - **Selection** (`VHNodes.EndpointSelector`): at most 4 probes in flight, started in priority order 150 ms apart (at
    once after a failure), 3 s each, 6 s overall; after the first success it waits up to 250 ms for a better probe
    still in flight. The class is that of the address actually reached (`VHTransport.EndpointClassifier`: loopback;
    lan = RFC 1918, ULA, link-local; vpn = 100.64/10 or a tunnel interface `utun*`, `wg*`, `tailscale*`, `zt*`, …;
    wan; passthrough as the server declared it), so split-horizon names work; within a class last good first, then
    server order. A key mismatch at an address other than the configured one marks only that candidate (another
    server lives there) and never asks to pair again; only a mismatch at the configured address with nothing verified
    is the old pin failure. With nothing verified the session connects to the configured address as before.
  - **When** (`RouteSchedule`): on connect, when the network path changes, after two failed reconnects in a row,
    after a lane's connection failure (`NodeSession.laneConnectionFailed()`), every 30 min while on a class worse than
    lan, and on Test Connection; never more often than every 5 s. A working connection moves only to a better class
    or off a route whose probe failed, so there are no reconnect storms. A selected endpoint that later presents
    another key is selected away from, not re-paired.
  - **Lanes** follow the route: `NodeSession.laneConfiguration` uses `activeEndpoint`; the app's `NodeFileLanes` and
    the extension's `NodeLink` key cached clients by identity and endpoint (a client whose endpoint moved is left to
    finish what it carries; a rotated identity cancels it); the MCP bridge selects per node through a read-only
    `RouteCache` (reused 5 min, dropped after a failure). The extension's and the helper's Info.plists carry
    `NSBonjourServices` and `NSLocalNetworkUsageDescription`, since they open their own LAN connections.
  - **Route changes** (§2: "requests in flight are retried on the new endpoint"). A lane's connection-class failure
    calls `NodeSession.rerouteLanes(awayFrom:)`: `laneConnectionFailed()` (a throttled re-selection), then up to 15 s
    for the lanes to move. Once they did, a download or a session-flow upload runs once more there (previews and Test
    Connection don't wait), and a resumable upload resumes its session from `GET /upload/sessions/<id>` on the new
    endpoint (session ids are the node's, not the endpoint's; at most 3 moves per upload). A request cancelled because
    its client was replaced counts as a dropped connection, never as the user's cancel. Without another route the
    usual retries apply.
  - **Advertisement.** After connecting, a node that announces the `device.endpoints` capability is asked for its
    addresses (`EndpointAdvertisementSource`); an answer naming another `node_id` is ignored, candidates are validated
    and capped at 32.
  - **Pairing links.** `vaulthalla://pair?node=&spki=&endpoints=` (registered URL scheme, §1.2) is untrusted input:
    `VHNodes.PairLink` refuses anything malformed, the Add Node sheet probes the link's endpoints (accepted when the
    server presents the link's key) and is prefilled with the best one, and `PairingClient` pins every pairing
    connection to the link's key from the start (`PairingFailure.unexpectedServerIdentity` otherwise). The code
    (docs/pairing.md) stays authoritative.
- **Resumable uploads and tuning** (the server's `docs/reference/transfer-protocol.md` §3 and §4; `VHTransport`). They
  run over the route the session selected ("Endpoints and route selection" above).
  - **Gate.** A node announcing `http.upload.resumable` gets resumable uploads; otherwise (`no`, or a legacy node's
    `unknown`) the `/upload/session` flow and `PUT /upload/content` run exactly as before. `device.lanes.transfer`
    gates calibration (both in `WsCapability.used`; `http.upload.resumable` waits in `awaitingContract`).
  - **Sessions** (`ResumableUploader`). `POST /upload/sessions` with up to 500 files, each with its precondition
    (`duplicate_policy: "reject"` for the Files browser, `if_none_match` / `if_match` for the File Provider). Each file
    goes as byte ranges, `PUT /upload/sessions/<id>/files/<f>?offset=n`, carved left to right so no piece below the
    server's `part.min_bytes` is ever left in front of a stored range.
  - **Streaming.** A part is streamed from disk through a bound stream pair (`uploadTask(withStreamedRequest:)`): a
    thread `pread`s the range into one 256 KiB buffer, hashes it and writes it into the pair's 256 KiB buffer, so a
    part never sits in memory whatever its size (no temporary copy either). The SHA-256 must equal the answer's
    `sha256`; a mismatch cancels the session at once (`DELETE`, before the file's last gap can close and commit) and
    the file starts over (`TransferError.integrity` once its restarts are spent). Before a part's last chunk the
    source's identity (size, mtime, inode, device) is checked again: a file edited mid-part abandons the request
    before its body completes, so the node never records it, and the file starts over.
  - **Retries.** A failed part goes again as exactly the same range, after a backoff (800 ms doubling to 30 s) or
    `Retry-After` on 429/503, at most 5 times; a resend after a lost answer carries `Content-Digest` of the bytes sent
    the first time, and the node acknowledges identical bytes again (200). 409 `part_overlap`/`file_state` re-sync
    from `GET /upload/sessions/<id>`; `part_conflict` means the local file isn't what was sent, and it starts over.
    Errors are mapped by the JSON `{error: {code}}` (`TransferError.coded`), never by their words.
  - **Resume.** When parts run out of retries the session isn't deleted: the session-level loop backs off and resumes
    from the node's status (its `ranges` are the durable truth), sending only the gaps, up to 5 times (progress resets
    the count). A dropped connection doesn't wait for that: with another route possible the session run stops at once
    and asks for one (`VaultLanes.reroute`, see "Route changes" above), and the same session resumes from its status
    on the new endpoint. Progress is persisted per upload (`ResumableStore`: Application
    Support/Vaulthalla/Uploads/<node>/ <id>.json, 0600, at most once a second): the session id, each file's identity
    and acknowledged ranges. The Transfers panel's Retry resumes the same upload instead of starting from 0; quitting
    suspends running uploads (`UploadControl.suspend()`, nothing is deleted); opening the node's Files section on the
    next launch queues what didn't finish, and a file changed since is started over in a new session. Cancel, and
    clearing a failed upload, delete the session. `finish` is polled while it answers 202; a file the node fails
    (`already_exists`, `precondition_failed`, `key_rotated`, …) is reported per file while the others stand
    (`key_rotated` starts over).
  - **Tuning** (`TransferTuner`, pure; `TransferMonitor` shares one per node). Aggregate throughput is bytes over time
    times the time-weighted parallelism of the recent parts (an EWMA of that); answer latency (a part's last byte to
    its answer, less `Server-Timing` sync) is compared only with its own recent minimum. Part size = per-stream
    throughput × 2 s rounded to MiB, held inside soft speed bounds (slow links 8–32 MiB, typical 32–128, fast LANs
    128–512), the client's bounds, the server's `part.min_bytes`/`max_bytes` and a 1 GiB in-flight budget; it starts
    at 64 MiB, changes by ≥ 25 % and only after measured parts, never from latency alone, and only parts not yet
    started take it. Concurrency is AIMD in `[1, min(4, part.max_in_flight)]` from 2: one more part after a steady
    epoch, kept only for ≥ 10 % more throughput (a failed probe holds 30 s, doubling); halved on 429/503 and on
    bursts of timeouts or drops; one fewer when answer latency rises and the part it added doesn't pay; never more
    while `Server-Timing` shows the server's write and sync taking most of each part. Tuning can be switched off per
    node (the Connection panel's Automatic tuning switch, `TransferMonitor.setTuningEnabled(false)`: 64 MiB × 2 within
    the server's limits); the nodes with it off are kept in UserDefaults (`transfers.automaticTuningOff`, node ids
    only) and applied when the app makes the node's lanes. The File Provider extension always tunes.
  - **Estimates** (`TransferEstimateCache`, Application Support/Vaulthalla/transfer-estimates.json): the last estimate
    per node and endpoint class (loopback, lan, vpn, wan, passthrough), 24 h. The class is the selected route's
    (`TransferEndpointClass(endpoint:route:)` from `NodeRoute.transportClass`, set at lane creation and on every
    `.route` event); the literal-address heuristic `TransferEndpointClass(host:)` is only the fallback without a route
    for that endpoint. A move to another class resets the tuner and drops the estimate. A new upload starts from it.
  - **Calibration** (`TransferCalibrator`). `GET /transfer/probe` (RTT), `POST /transfer/sink` and
    `GET /transfer/source` from 1 MiB up, at most 16 MiB and 3 s each way. It runs only before an upload of 256 MiB
    or more with no fresh estimate (never on a reconnect), and the first real parts replace what it guessed.
    `VaultLanes.testConnection()` runs it on demand (Test Connection, see "Connection panel" below) and returns RTT,
    MB/s each way and the part size and concurrency uploads would start with; nothing is written on the node.
  - **Stats.** `TransferMonitor.updates()` streams `TransferTuningSnapshot` (up/down bytes/s over 3 s, part size,
    concurrency allowed and parts in flight, tuning on/off, the estimate, RTT, its source, server-bound, endpoint
    class), at most ~4 a second while something moves; `snapshot` reads it once. Downloads feed the down meter. The
    app's `TransferStatsFeed` turns them into `VHCore.TransferStats` on `TransferStatsBoard` (nil once idle) for the
    Connection panel.
  - **Proof.** `swift test` covers the uploader's own arithmetic (part carving, stored ranges, error codes, headers)
    and the tuner through simulated links. The session exchange runs against a real daemon: `LiveTransferBenchmarks`
    in the live suite ([`interop-testing.md`](interop-testing.md)).
- **Connection panel** (node Overview; `ConnectionPanel`). How this Mac reaches the node now, with nothing secret in
  it (no keys or session material): the route class (Localhost, LAN, VPN, Direct WAN, Passthrough), endpoint, address
  reached, the verified key (current or next) and the handshake RTT; throughput each way, part size, parts in flight
  of those allowed, what the tuning works from (defaults, the cached estimate, a calibration, this transfer) and
  whether the server's disk or the network limits it (`TransferStats`, "—" while nothing reports); the Automatic
  tuning switch; and why a better class wasn't used, per candidate in plain words with a technical disclosure.
  - **Test Connection** runs `AppModel.connectionTest`, `ConnectionTests.calibrating` for live sessions: a fresh
    selection (`NodeSession.testRoute()`, the connection moves if a better route answers), then, where the node
    announces `device.lanes.transfer`, the node lanes' `testConnection()` over the route it settled on. Measured
    bytes/s fill the Upload and Download tiles until transfers report, and the note says what uploads would start
    with; a calibration that fails leaves the route result with the reason in plain words. Previews run the route
    test only.
  - **Lanes.** `AppModel` owns each node's `NodeFileLanes` (made on first use, shared by Files and the panel); making
    them applies the node's tuning switch and route class and starts its `TransferStatsFeed`.
- **Credential ownership: one owner, every other process a consumer** (desktop#3). A rotation in one process would
  strand every other process presenting the old key, because the daemon clears `previous_spki_sha256` on the first
  handshake with the new key (`docs/pairing.md` §4). So exactly one process on the Mac, the *owner*, creates, rotates
  and deletes device keys and writes the registry (pairing outcomes, rotated device ids, server pin announcements and
  promotions, revocations, node edits). The background agent is the intended owner; until it ships, the app is.
  - **The lease.** Ownership is an exclusive BSD `flock(2)` lease on `credential-owner.lease` next to `nodes.json`
    (`VHCore.CredentialLease`), taken without waiting. The kernel ties it to the open file, so it is released when the
    owner exits or crashes, with nothing stale to clean up; two handles conflict even within one process; the file is
    close-on-exec and never deleted. The holder writes its name and pid into the file for diagnostics only. The lease
    location is derived from the registry location, which is injected (`NodeStore(fileURL:lease:)`), so moving the
    registry to the App Group container (for the File Provider extension; see "Signing and the shared container")
    moves the lease with it, and the agent takes over by taking the same lease. Nothing is hardcoded to the app.
  - **Enforced, not conventional.** `NodeStore` and `DeviceKeys` take the lease handle and check it before every
    change: without a held lease (and, for the store, the lease of *its* registry) every mutation throws
    (`NodeStore.Failure.notOwner`, `CredentialOwnershipError.notOwner`) before touching the file or the Keychain. A
    process that never takes the lease can't reach the rotation or registry-mutation paths.
  - **Roles.** `NodeSession.role` / `NodeSessions.role` is `.owner` while the session's `DeviceKeys` hold the lease,
    else `.consumer`. A consumer session presents the identity the owner saved, never rotates (`rotateDeviceKey()`
    throws), never resumes, completes or cancels the owner's rotation, and reports no `recordChanged` (an announced or
    promoted server key stays in its memory). `NodeSessions.sync` restarts sessions whose role changed, so a takeover
    needs no rebuild.
  - **Consumers reload, then fail closed** (`VHNodes.CredentialReader`, generalized from the MCP bridge's retry and
    shared by the app as consumer, the File Provider extension and `vaulthalla-mcp`). When a node refuses the key a
    consumer presented (`device_unknown` on the ws, 403 on the lanes or `/mcp`), it re-reads the registry and the
    Keychain and retries once with the newest identity that isn't the refused one: the owner's rotated key, or the
    pending replacement of a rotation whose answer was lost (the owner's reconnect with it already ended the old key's
    grace). A refusal that survives the reload is a revocation: `NodeSession` reports `.revoked`,
    `CredentialReader.withCredentials` throws `CredentialFailure.revoked`, the bridge reports the node revoked and
    drops its tools. A lane 403 can also be an RBAC refusal, so `withCredentials` asks the node directly first
    (`check`: one ws `device.server.identity` with that key). A record the owner marked revoked ends every consumer at
    once. The owner records the revocation (`recordChanged(.revoked)`); consumers only report it.
  - **The app.** `VaulthallaApp` takes the lease at launch. If another process holds it (a second app instance today,
    the agent later), the app runs as a consumer: the sidebar says read-only and who owns, edits are refused with a
    message, pairing, Rotate Key Now and Unpair This Mac are disabled, sessions are consumers, and it re-reads the
    registry every 2 s and takes the lease over as soon as the owner lets go. When the agent ships, the app stops
    taking the lease and talks to the agent instead (an XPC client), and the agent becomes the only owner; a handoff
    between a running app and a starting agent is part of that work.
  - `vaulthalla-mcp` never takes the lease: its registry and keys are read-only by construction.
  - Desktop still holds no business logic, and neither the pairing protocol nor the server changed.
- **Signing and the shared container** (desktop#4; evidence from the desktop#2 spike). The File Provider extension
  is sandboxed and must read the same registry and device keys as the app, so signed builds share an App Group and a
  keychain access group.
  - **Signing variants.** Signed builds use the Valkyrian Labs LLC team (`ZG2G6V7GLC`): `App/Config/Signing.local.xcconfig` (gitignored) or
    `DEVELOPMENT_TEAM=ZG2G6V7GLC -allowProvisioningUpdates`. Never sign with a personal team: automatic signing
    registers the bundle ids on whichever team builds first, and a free team then keeps them (that is how
    `sh.vaulthalla.desktop` was lost). Builds without the LLC team are Unsigned.
    `Base.xcconfig` derives `VH_SIGNING` from `DEVELOPMENT_TEAM`: **Team** when it is set, **Unsigned** otherwise. The
    targets use `Vaulthalla.$(VH_SIGNING).entitlements` and `FileProvider.$(VH_SIGNING).entitlements`. Team signs with
    Apple Development; Unsigned signs ad hoc (or not at all in CI, `CODE_SIGNING_ALLOWED=NO`) and names no group,
    because the group entitlements need a team.

    | Bundle | Id | Team entitlements | Unsigned |
    |---|---|---|---|
    | app | `sh.vaulthalla.app` | `application-groups` `$(TeamIdentifierPrefix)sh.vaulthalla.app`, `keychain-access-groups` `$(AppIdentifierPrefix)sh.vaulthalla.app`; **unsandboxed** (1Password IPC, D5), hardened runtime | none |
    | File Provider extension | `sh.vaulthalla.app.fileprovider` | `app-sandbox`, `network.client`, the same App Group and keychain group | `app-sandbox`, `network.client` |
    | `vaulthalla-mcp.app` (minimal bundle, §5) | `sh.vaulthalla.app.mcp` | the app's: the same App Group and keychain group | none |

    All three App IDs are registered on the LLC team, each with a Developer ID profile for release. Their profiles carry only
    `keychain-access-groups = <TEAM>.*`. The team-prefixed App Group (macOS style, not `group.`) needs no portal
    registration or profile entry, and File Provider needs no capability (desktop#2 E2, E3). The extension's
    `NSExtensionFileProviderDocumentGroup` is the same group (`VH_APP_GROUP`). At run time a process learns its group
    from its own signature (`VHCore.AppGroup.entitledIdentifier()`, `SecTaskCopyValueForEntitlement`), so nothing is
    configured twice.
  - **Container layout.**

    ```
    ~/Library/Group Containers/<TEAM>.sh.vaulthalla.app/   signed builds
      nodes.json                  the registry (the owner writes, everyone else reads)
      credential-owner.lease      the owner's flock lease, next to the registry
      File Provider Storage/      fileproviderd's own (not Desktop's)
      (desktop#4) the per-domain databases
    ~/Library/Application Support/Vaulthalla/                 before the move, and builds without a team
      nodes.json                  the registry of builds without the App Group
      nodes.json.migrated         after the move: the old registry, byte for byte (backup; removed in a later release)
      nodes.json.moved            after the move: the marker {registry, appGroup, sha256, migratedAt}
      credential-owner.lease      the old lease; the owner holds it after the move
    ```
  - **Migration** (`VHCore.RegistryMigration`, run by `RegistryOwnership.open` when the owner starts). The owner takes
    the App Group registry's lease, which makes it the only migrator. It then takes the Application Support lease too,
    so no other process can write either file meanwhile. If an older Desktop owns the old location, the migration
    waits for a later launch and the app opens the old registry read-only, as before. The steps are copy, verify, then
    switch, and nothing is ever deleted:
    1. write `nodes.json.migrating` in the group (`F_FULLFSYNC`, then an atomic rename) and read it back (bytes and
       nodes);
    2. move it to `nodes.json` without replacing anything (`RENAME_EXCL`), and read that back;
    3. write the marker (the switch);
    4. rename the old file to `nodes.json.migrated`, then keep holding the old lease, so an older build started
       alongside stays read-only.

    Each crash point resumes. An interrupted copy is redone. A group registry identical to the old one, with no
    marker, gets the marker. A marker with the old file still in place (the same hash) gets the rename. Running it
    again changes nothing. It refuses instead of guessing in three cases, and the old file is never touched: an
    unreadable or newer-format registry (`failed`: the app keeps the old location and reports the file as before),
    two registries that differ with no marker (`conflict`: the group's started fresh and wins), and a marker naming
    another team's container (`pointsElsewhere`: a team change; keys don't cross teams either, so nodes are paired
    again).
  - **Who reads which registry** (`RegistryLocation`). The owner: what `RegistryOwnership.open` returns. Consumers
    (`vaulthalla-mcp`, a second app instance): `resolve`. With the group, the group's registry, unless an unmigrated
    one still sits in Application Support. Without the group, wherever the marker points, else Application Support.
    So an unsigned build or the plain `vaulthalla-mcp` binary follows a migration and uses the same registry and
    lease as the signed app. The extension: only the group's registry (`RegistryLocation.appGroup`), since the sandbox
    can't see Application Support.
  - **Proof.** `swift test` covers every step and crash point (`RegistryMigrationTests`). The signed check
    (desktop#4 PR) migrated an existing `nodes.json` byte for byte. Both the signed and the plain `vaulthalla-mcp`
    then served the group's registry, and the sandboxed extension read it and found an app-created Secure Enclave key.

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
  `Sources/VHMCP` + `Sources/vaulthalla-mcp`). The Xcode target of the same name builds a minimal background-only
  bundle, `Contents/Helpers/vaulthalla-mcp.app`, which the app's "Embed MCP Bridge" phase copies and signs; "Link MCP
  Bridge" then points `Contents/Helpers/vaulthalla-mcp` at its executable, the path clients are given.
  - **Trust.** It reads the node registry (`nodes.json`, wherever the app keeps it: `RegistryLocation.resolve`, §3
    "Signing and the shared container") and presents the device identity the app created for each node
    (`DeviceKeys`), pinning the server SPKI from the record, exactly like the app's HTTP lanes. It is a
    credential consumer (§3, "Credential ownership"): it never takes the lease, so it creates, rotates, deletes and
    writes nothing. A Secure Enclave key lives in the data protection keychain, so the helper must be
    signed by the same team with the app's `keychain-access-groups` (`$(AppIdentifierPrefix)sh.vaulthalla.app`).
    That entitlement is restricted on macOS and a bare executable can't carry a provisioning profile (AMFI kills it),
    which is why the bridge is a bundle: it embeds its own profile (Developer ID "Vaulthalla Desktop MCP" in release)
    and carries the app's App Group too, so it reads the same registry without a cross-app data prompt. Unsigned
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
    (refused before anything ran) re-initializes and retries once; a 403 retries once on a fresh connection made from
    the reloaded registry record and Keychain (the owner may have rotated the key, §3), then reports the node revoked.
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
  - `item.attest`, adding the node's attestations to versions an item holds (metadata only, no key)
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
  - Section "Key versions": one concealed field per version (`v3`, `v2`, …) with its key check and, when the node
    recorded one, its attestation (`vN_attest_key_id`, `vN_attest_sig`: the daemon's `{key_id, signature}`, public
    metadata stored and returned unchanged). A rotation adds the new version and moves `credential` to it; a version
    is never overwritten, and none is removed while the daemon still reports it as needed. Attestations the node
    reports in `vault.keys.status` and the item lacks (backups from before the server recorded attestations) are
    added by the next sync (`item.attest`, no key moves) when the node's key check equals the item's, and after a
    restore for the versions the node just verified. Backing up again is needed only when the node has no
    attestation for a version either (it never unsealed it on a release that records them).
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
  3. Import: Desktop sends the stored versions, with their attestations, to the daemon's `vault.keys.import` (S6)
     over the paired connection, the same operation as `vh vault keys import`. Recover (the default) restores only
     versions the vault had, proven by the node's own attestation, never a key of the caller's own; a version it
     can't prove comes back `needs_salvage` with nothing written, one the vault never had `refused`. Salvage
     (`mode: "salvage"`, its own confirmation) is a separate, explicit step: the node re-encrypts the files the key
     opens under a new key it creates, reports the files it couldn't open, and never stores the backed-up key.
     A version 1Password holds without a well-formed attestation is sent with the node's own record of it
     (`needed_versions[].attestation`, top-level `attestation`, matched on vault and version; 1Password's is
     preferred and never replaced), so backups made before the node recorded attestations need no redoing: the
     daemon recomputes the key check from the key sent and verifies the signature itself. The restore sheet says
     which versions use which, and the attestations the node verified are then stored in the item.
     The server's design of record is `.claude/context/key-backup.md` in the vaulthalla repository.
- **Hygiene:** keys never enter MCP results or agent context (the export is refused for MCP at the daemon), logs or
  caches. The 1Password item id is the only thing Desktop stores per vault.

## 7. Finder integration (File Provider)

Epic desktop#1 (Stages A to D). The MVP is desktop#4. Spike findings are on desktop#2.

- **Shape.** One `NSFileProviderReplicatedExtension` (`App/Extensions/FileProvider`, `sh.vaulthalla.app.fileprovider`,
  embedded in `Contents/PlugIns`). It serves one domain per vault the operator selects, with
  `supportsSyncingTrash = false` (deletes go to the server's trash and recovery). The extension holds the device
  identity itself, as a read-only consumer (§3), so Finder keeps working with the app quit (desktop#2 E7, E8).
- **Domains** (`Sources/VHFinder`, pure and tested by `swift test`).
  - The identifier is `<node id>.<vault id>` (`VaultDomainID`). It survives renames and never contains `/` or `:`.
    Node ids are limited to ASCII letters, digits, `-` and `_`, which every id Desktop makes satisfies.
  - The display name is `<vault> · <node label>` (`VaultDomain`). Finder drops spaces from the folder name:
    `~/Library/CloudStorage/Vaulthalla-<name>`.
  - `DomainPlan.reconcile` turns the existing domains into the wanted ones (add, remove, and rename by remove and
    add). `DomainRegistrar` is the seam: `FileProviderDomains` (`NSFileProviderManager`) in the app, a fake in tests.
    The system ties every domain to the extension embedded in the calling app, so only Vaulthalla's own executable
    can manage them.
- **The consent gate.** A new domain stays `userEnabled == false`, showing nothing and starting no extension (FP
  -2011), until the operator turns Vaulthalla on under System Settings ▸ General ▸ Login Items & Extensions ▸ File
  Providers. No API does it. The testing-mode bypass needs a paid team (desktop#2 E5, E6). `DomainSnapshot.state`
  reports `needsUserApproval`, and `FileProviderSettings.fileProvidersURL` deep-links to the list
  (`x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fileprovider-nonui`).
  - **Order matters (desktop#4, macOS 27.0.1).** The switch is per provider, and System Settings lists no domains.
    Domains added after the provider is on start enabled with no further consent. Two domains added before it was on
    were not both enabled by the switch: one came up active, the other stayed `needsUserApproval` (`fileproviderctl
    dump`: `enabled: no`) with nothing in System Settings to approve it. Removing it and adding it again brought it
    up enabled at once. Onboarding (desktop#6, #7) therefore needs an approval state per vault, adds domains only once
    the provider is on where it can, and offers "remove and add again" for a domain stuck in `needsUserApproval`
    while another domain of the provider is enabled.
- **As built (the MVP, desktop#4).** The extension (`App/Extensions/FileProvider`) is a thin adapter: every call goes to
  the domain's `VaultReplica` (`Sources/VHFinder`; its mapping and store are tested by `swift test`, the whole path by
  `tools/interop/finder-e2e.py` against a real daemon), which maps and caches. The server decides; Swift holds no storage, encryption, RBAC or sealing logic.
  - **Identity.** `NodeLink` is a read-only credential consumer (§3): a consumer `NodeSession` for ws (it reloads the
    credentials after `device_unknown` and reports `.revoked` when the refusal survives), and `VaultLanes` for the
    identity that session presents, made again when it changes. A lane 403 reloads and retries once; a 403 that survives
    is checked with `CredentialReader.check`: a refused key fails closed, an accepted one is the account's access. After
    a revocation, a missing key or an unpaired record every call is `NSFileProviderError.notAuthenticated` until the
    extension starts again.
  - **Items.** The identifier is `e<FsEntry.id>` (stable across rename and move, vaulthalla/server#257); the root, the
    working set and the trash are the system's own. `itemVersion` is `{content_version, metadata_version}` for files
    (the content half is the strong ETag, quotes included, so it doubles as `If-Range` and `If-Match`) and
    `metadata_version` for both halves of folders and symlinks. Capabilities are conservative and never derived from
    RBAC: read, write, rename, reparent and delete for files and folders (symlinks: no write), no trashing
    (`supportsSyncingTrash = false`). The root carries `contentPolicy = downloadLazilyAndEvictOnRemoteUpdate`.
  - **Replica database** (`ReplicaStore`, SQLite): `<App Group>/FileProvider/<domain>.sqlite`. Entry id, parent, name,
    path, kind, size, dates, versions, and whether the system enumerated the folder. A cache, never a source of truth:
    one it can't open is deleted and made again with a new store id. The app deletes it with its domain.
  - **Enumeration and changes.** A folder's first page lists it (`fs.dir.list`, Lookup-filtered by the server,
    vaulthalla/server#255) and marks it enumerated; later pages come from the database. The working set is every entry
    the database knows. Without a change journal (vaulthalla/server#259), `enumerateChanges` lists every enumerated
    folder again (parents first, each by its current path) and diffs: every new, changed or gone row takes the next
    revision, and the anchor is `vh1:a:<store id>:<revision>` (pages `vh1:p:<offset>`, both under 500 bytes). A folder
    that is gone or no longer listable goes with its subtree: lost visibility arrives as deletions. An anchor from
    another store expires (`syncAnchorExpired`).
  - **Contents.** `fetchContents` streams `/download/content` (resumable) into the domain's temporary directory and
    returns the item at the ETag of those bytes. `fetchPartialContents` widens the range to the system's alignment and
    sends `Range` + `If-Range: <content_version>`. With `strictVersioning`, a changed file is
    `versionNoLongerAvailable` (the reader sees ESTALE and asks again); otherwise the new version is fetched whole.
  - **Writes.** Create: a file is `PUT /upload/content` with `If-None-Match: *` (412 or 409 is a filename collision),
    a folder `fs.dir.create` (an existing folder is the answer under `mayAlreadyExist`); symlinks and `.DS_Store` are
    excluded from sync. Modify: rename or move first (`fs.entry.rename`, or `fs.entry.move` into another folder; the
    server authorizes the destination, vaulthalla/server#256; paths below a moved folder follow), then the contents with
    `If-Match: <base content_version>`.
  - **Large writes** (a node with `http.upload.resumable`). A file over 8 MiB goes as a single-file resumable session
    (§3, "Resumable uploads and tuning") carrying the same precondition: `if_none_match: "*"` to create, `if_match`
    to replace. A precondition failing at create (412) or at commit (`precondition_failed` + `etag`) is the same
    conflict as a 412 from `PUT /upload/content`, so conflict copies work unchanged. Parts are retried within the
    operation and a dropped connection resumes from the session's status, on a new endpoint when the extension's
    session selected another route (§3, "Route changes"); a write that can't complete deletes its session. Smaller files stay one `PUT` (nothing to resume, one request instead of three), and so does everything
    on a node without the capability. The extension doesn't persist sessions across its own relaunch: the system
    retries the write, which starts a new session (an abandoned one expires on the node after 24 h idle).
  - **Conflicts: never an overwrite.** The server's version is checked before the upload, and the upload itself is
    conditional. When the server's file changed since the edit's base (the check, a 412, or a lost answer after which
    the version moved), the local edit is uploaded as `"<name> (conflict from <Mac name> <yyyy-MM-dd HHmm>)<.ext>"`
    beside it (with `If-None-Match: *`, a counter when that name is taken), the server's version stays the item, the
    system downloads it again, and the working set is signalled so the copy appears. With the system's
    `failOnConflict` option the extension answers `localVersionConflictingWithServer` instead. The extension doesn't
    declare `NSExtensionFileProviderSupportsFailingUploadOnConflict` yet, so the conflict copy is the path in use.
  - **Delete.** `fs.entry.delete`, into the server's trash and recovery (`recovery.*`). A file changed on the server
    since the base is `deletionRejected`; a non-empty folder without `.recursive` is `directoryNotEmpty`.
  - **Thumbnails.** `NSFileProviderThumbnailing` asks `/preview/batch` for readiness and fetches `/preview` for the
    ready ones; others get none.
  - **Errors.** `FinderError` maps refusals: `notAuthenticated`, `serverUnreachable`, `noSuchItem`,
    `filenameCollision`, `insufficientQuota`, `cannotSynchronize` (a write the server refused), a Cocoa read-permission
    error for a refused read, `deletionRejected`, `versionNoLongerAvailable`, `syncAnchorExpired`, `excludedFromSync`,
    with the POSIX code underneath. Anything else is transient and retried by the system.
  - **Debug UX.** Domain management stays developer-only: Settings ▸ Finder (Debug builds) and
    `Vaulthalla.app/Contents/MacOS/Vaulthalla --developer registry|domains|add-domain|remove-domain|remove-all-domains|
    pair|unpair|signal`. `pair <host:port> [name]` pairs as the credential owner with the app quit and prints the code
    to approve; `signal <domain>` asks the extension for the working set's changes (the agent's job later, desktop#5).
    `VH_FILEPROVIDER_SELFCHECK=<domain> <appex>/Contents/MacOS/VaulthallaFileProvider` checks readiness in the
    extension's own sandbox.
  - Several builds of the extension on one Mac compete. pluginkit elects one copy of
    `sh.vaulthalla.app.fileprovider`, and domain calls from a build whose own copy isn't the elected one fail with
    -2001 (underlying -2014). Unregister stale copies (`pluginkit -r <appex>`, `lsregister -u <app>`), or check
    `pluginkit -m -v -D -i sh.vaulthalla.app.fileprovider`.
- **Background agent: packaging decision** (desktop#2 E11; not built yet). The future per-user agent is **the app's
  own main executable in a headless mode** (`Contents/MacOS/Vaulthalla` with an argument), registered with
  `SMAppService.agent` (a LaunchAgent plist whose `BundleProgram` is the app's executable) or `SMAppService.mainApp`.
  - Not a nested `Contents/Library/LoginItems/*.app`. The File Provider client framework takes the provider from
    the caller's main bundle, and a nested app embeds no extension, so `signalEnumerator` fails (-2001, underlying
    -2014) and fileproviderd logs "provider identifier shouldn't be nil".
  - Not a bare tool in `Contents/MacOS`. `keychain-access-groups` is restricted and needs a provisioning profile,
    which a bare executable can't embed: AMFI kills it (-413). Without that entitlement it can't read the device key.
  - The app's executable under launchd does both: it reads the shared key and signals the working set. The agent
    takes over the credential lease from the app (§3) and signals domains when the server reports changes. The
    `--developer` commands are not the agent: they run one command and exit.
- **Next.** Freshness from a background agent that signals the working set (desktop#5), the real Finder UX (desktop#6),
  the local plaintext policy (desktop#8), and the server's change journal and push (vaulthalla/server#259, #260).

## 8. Workstreams and order

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

## 9. Decisions (approved 2026-10-20)

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
