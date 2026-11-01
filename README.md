# Vaulthalla Desktop

The native macOS cockpit for [Vaulthalla](https://github.com/valkyrianlabs/vaulthalla-server) deployments: pair your Mac with
each server once, then manage every node, browse vault files, show vaults in Finder, back up vault keys to 1Password,
and give AI agents a safe MCP surface. Swift 6 and SwiftUI, macOS 27+, Apple Silicon.

The web console stays the browser surface for operators and the page share recipients see. Desktop holds no
business logic: every action is an operation the daemon authorizes.

**Status:** foundation. The plan, the pairing protocol and the open decisions are in
[`docs/architecture.md`](docs/architecture.md).

## Finder

Settings ▸ Finder lists every vault of every paired node, each with a **Show in Finder** switch. A vault you show
appears in Finder under Locations, like iCloud Drive: files download when you open them, and macOS removes downloaded
copies when it needs the space. Finder shows exactly what your Vaulthalla account may see, whatever the vault's
backing (local, or S3 with smart cache). The first time, macOS asks you to allow Vaulthalla under System Settings ▸
General ▸ Login Items & Extensions ▸ File Providers; the Finder tab links there.

## Layout

| Path | What |
|---|---|
| `Package.swift`, `Sources/`, `Tests/` | VaulthallaKit: `VHCore` (models, secret handling), `VHContract` (generated daemon contract), `VHTransport` (ws client, mTLS), `VHIdentity` (device keys and certificates), `VHOnePassword` (1Password helper client, backup status), `VHMCP` (the MCP bridge), `VHFinder` (File Provider domains and the replica: items, versions, errors, conflicts, the per-domain database) |
| `Sources/vaulthalla-mcp/` | the stdio MCP bridge the app embeds at `Contents/Helpers/vaulthalla-mcp` (see "AI agents" below) |
| `Helpers/vaulthalla-1password/` | the Go helper that backs vault keys up to 1Password (desktop-app authorization); `./build.sh`, see its README |
| `App/` | the Xcode project: SwiftUI app, design system, features. Source folders are synchronized: add files on disk, no project edits |
| `App/Extensions/FileProvider/` | the File Provider extension (`sh.vaulthalla.app.fileprovider`, embedded in `Contents/PlugIns`): Finder integration: browse, read (whole and ranges), create, edit with conflict copies, rename, move, delete, thumbnails ([`docs/architecture.md`](docs/architecture.md) §7) |
| `contract/` | `wsContract.json` vendored from the server (`SOURCE.json` records the version) and `compat-baseline.json`, the oldest supported server's contract (1.17.0); `tools/gen-contract.py` turns them into Swift ([`docs/architecture.md`](docs/architecture.md) §3, "Protocol negotiation") |
| `tools/interop/` | `vh-instance.sh`: a private daemon test instance for the opt-in live suite `Tests/VHNodesLiveTests` ([`docs/interop-testing.md`](docs/interop-testing.md)) |
| `tools/keychain-proof/` | `run.sh <TEAM_ID>`: a team-signed proof that device identities work in the data protection keychain (Secure Enclave create, find, rotate, delete), which unsigned `swift test` and CI can't reach |
| `docs/` | architecture and protocol documents |

## Build

Needs Xcode 27 and Go (`brew install go`): the app embeds the Go 1Password helper and builds it from source.

```sh
swift test                                                  # VaulthallaKit
VH_LIVE_NODE=<host>:36982 swift test --filter Live         # against a live daemon (docs/interop-testing.md)
open App/Vaulthalla.xcodeproj                               # or:
xcodebuild -project App/Vaulthalla.xcodeproj -scheme Vaulthalla -derivedDataPath build/DerivedData.noindex build
```

Build products go under `build/*.noindex`, which Spotlight skips. Otherwise every dev build shows up next to the
installed app. Dev builds share the shipped bundle ids (`sh.vaulthalla.app`, `.fileprovider`, `.mcp`), so launching
one can make macOS elect its File Provider extension over the installed one. Run `lsregister -u <app>` afterwards
(`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`). Test a
release by installing it into `/Applications`, not from the build folder.

Signed builds use the Valkyrian Labs LLC team: copy `App/Config/Signing.local.xcconfig.example` to
`App/Config/Signing.local.xcconfig` (gitignored), or pass `DEVELOPMENT_TEAM=ZG2G6V7GLC -allowProvisioningUpdates` to
`xcodebuild`. Never sign with a personal team, which would claim the bundle ids for good. A team
switches on the App Group (`<TEAM>.sh.vaulthalla.app`) and the shared keychain group, so the app and the File
Provider extension share the node registry and device keys; the registry moves into the group container on first
launch, keeping the old file as a backup. Without a team the app is signed to run locally and keeps its registry in
Application Support ([`docs/architecture.md`](docs/architecture.md) §3, "Signing and the shared container").

### What the tests cover

The server owns the protocol: `core/usage/protocol` defines every command, the server's contract tests keep it from
drifting, and `contract/` vendors it here with its `ws_hash`. Desktop's tests stay on what Desktop owns:

- **The contract:** `VHContractTests` round-trips the server's generated samples for every command and model.
- **Wire mechanics** against fixtures that know no commands: ws framing, answer correlation, timeouts, reconnects,
  error envelopes, TLS 1.3 with mutual auth and SPKI pinning, HTTP ranges and status mapping.
- **Client logic** with no network or fed scripted answers in memory: endpoint selection, the transfer tuner, upload
  part arithmetic, the query cache, the credential lease, Finder mapping, the MCP bridge.

No test re-implements a server transaction (pairing, rotation, revocation, upload sessions, conditional writes, vault
key export) in Swift. Those run against a real daemon in the opt-in live suite before a release
([`docs/interop-testing.md`](docs/interop-testing.md)). A bug found in real use gets a regression test at the lowest of
these levels that reproduces it.

The data protection keychain (Secure Enclave device keys) needs a team-signed process, so `swift test` covers it
only through the pure query tests (`KeychainQueriesTests`). After changing `Sources/VHIdentity`'s Keychain code, run
the signed proof with the LLC team (it cleans up every item it writes). Never use a personal team here: it would
register the proof's bundle id under `sh.vaulthalla.app` on that team for good.

```sh
tools/keychain-proof/run.sh ZG2G6V7GLC
```

UI regression sweep (renders every section at three window sizes from a DEBUG build; catches AppKit layout loops):

```sh
tools/ui/sweep.sh build/DerivedData.noindex/Build/Products/Debug/Vaulthalla.app
```

Refresh the contract after a server change:

```sh
python3 tools/gen-contract.py --from ../vaulthalla      # copies the server's generated contract, regenerates Swift
python3 tools/gen-contract.py --baseline-from ../vaulthalla --baseline-ref v1.17.0   # moves the compatibility baseline
python3 tools/gen-contract.py --check && python3 tools/test_gen_contract.py          # what CI runs
```

Response members newer than the baseline are generated optional, so Desktop decodes every server from the baseline
on. Raising the baseline (dropping support for older servers) also raises `WsProtocol.oldestServer`.

## Release

`.github/workflows/release.yml` builds the Developer ID release with `tools/release/build.sh`: a Release archive
signed by `tools/release/DeveloperID.xcconfig` (each target picks its Developer ID profile by bundle id), the app
notarized and stapled, then a signed DMG notarized and stapled too, and the Sparkle `appcast.xml` offering it
(signed with the EdDSA key in `SPARKLE_ED_PRIVATE_KEY`). Pushing a tag `v<VERSION>` publishes the DMG, its `.sha256`
and the appcast as the latest GitHub release; the app's update feed is `releases/latest/download/appcast.xml`, so a
release is never marked prerelease. It then commits the rendered cask to `valkyrianlabs/homebrew-tap`
(`brew install --cask valkyrianlabs/tap/vaulthalla-desktop`; template `tools/release/homebrew/vaulthalla-desktop.rb.in`,
checked with `brew style` and `brew audit` in every run). That cask is the app alone. The `valkyrianlabs/tap/vaulthalla`
meta cask (published by vaulthalla-server) depends on it and on `vaulthalla-server`, so each upgrades to its own latest
release. A pull request that touches the release tooling rehearses everything except publishing. The build number is
the commit count. Debug builds never check for updates.

Locally, with the Developer ID identity in the keychain and both profiles installed for Xcode:

```sh
tools/release/build.sh                                      # signed DMG in build/release
VH_NOTARY_PROFILE=<notarytool profile> tools/release/build.sh   # also notarized and stapled
VH_SPARKLE_KEY_FILE=<key file> tools/release/build.sh            # also appcast.xml (generate_keys -x exports the key)
```

## Connecting to nodes

Desktop reaches each node over the best address that proves the node's pinned server key: this Mac, the local
network, a VPN, then the internet (the node advertises its addresses; Bonjour is the last resort). When a route
drops, Desktop selects again and carries transfers over to the new one. The web console's "Pair a device" dialog
offers a `vaulthalla://pair?…` link: opening it fills in Add Node with an address that answers with the server's
key, and pairing then refuses any other server. You still approve with the six-digit code. When the node runs on
this Mac, the pairing sheet can do the approving for you through `vh`, once you agree.

Pairing once is enough: Desktop stays signed in across quits, restarts and reboots, separately for each macOS account.
Turn off **Keep me signed in on this Mac** (Settings ▸ General) on a Mac that isn't yours: quitting or logging out
then signs this Mac out of every node, revokes it there, deletes its keys and removes its vaults from Finder. **Sign
Out** does the same at any time. Settings ▸ General ▸ Security can ask for Touch ID before Recovery Keys,
Credentials and Access show.

On a node that supports them (server 1.20), uploads go in resumable parts: Retry, a dropped route or quitting the app
picks an upload up where the node left it, and the part size and parts in flight adapt to the link. The node's
Overview has a Connection panel: the route in use, its round trip, live throughput and tuning, an Automatic tuning
switch (off: fixed 64 MiB parts, two at a time) and, when a better route wasn't used, why. Test Connection checks
every address again and, where the node serves the calibration lanes, measures throughput both ways. Design:
[`docs/architecture.md`](docs/architecture.md) §3, "Endpoints and route selection", "Resumable uploads and tuning"
and "Connection panel".

## AI agents (MCP)

Vaulthalla Desktop bundles `vaulthalla-mcp`, a stdio MCP server that gives an agent (Claude Code, Codex) the tools of
every node this Mac is paired with, through the same pairing the app uses. Each tool takes a `node` argument (the
node's id or name; the `nodes_list` tool lists them). On each node the agent acts as the Vaulthalla account the Mac
was paired by; destructive commands still wait for your approval, and vault keys are never reachable over MCP.
Settings → Agents shows the path of your copy and copies these commands; register it yourself:

```sh
claude mcp add --scope user vaulthalla-desktop -- "/Applications/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp"
codex mcp add vaulthalla-desktop -- "/Applications/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp"
```

or, for Codex by hand, in `~/.codex/config.toml`:

```toml
[mcp_servers.vaulthalla-desktop]
command = "/Applications/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp"
tool_timeout_sec = 600
```

A call may take up to 10 minutes (`VAULTHALLA_MCP_TIMEOUT` in seconds, `0` for no limit). A development build keeps
its device keys in the login keychain, so macOS may ask whether `vaulthalla-mcp` may use them. Design:
[`docs/architecture.md`](docs/architecture.md) §5.

## Agent tooling

Xcode 27's MCP server gives coding agents builds, tests, previews and diagnostics. Turn on Xcode → Settings →
Intelligence → "Allow external agents to use Xcode tools", then `claude mcp add --transport stdio xcode -- xcrun
mcpbridge`. Keep the project open in Xcode while an agent works.
