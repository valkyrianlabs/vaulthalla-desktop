# Vaulthalla Desktop

The native macOS cockpit for [Vaulthalla](https://github.com/vaulthalla/vaulthalla) deployments: pair your Mac with
each server once, then manage every node, browse vault files, back up vault keys to 1Password, and give AI agents a
safe MCP surface. Swift 6 and SwiftUI, macOS 27+, Apple Silicon.

The web console stays the browser surface for operators and the page share recipients see. Desktop holds no
business logic: every action is an operation the daemon authorizes.

**Status:** foundation. The plan, the pairing protocol and the open decisions are in
[`docs/architecture.md`](docs/architecture.md).

## Layout

| Path | What |
|---|---|
| `Package.swift`, `Sources/`, `Tests/` | VaulthallaKit: `VHCore` (models, secret handling), `VHContract` (generated daemon contract), `VHTransport` (ws client, mTLS), `VHIdentity` (device keys and certificates), `VHOnePassword` (1Password helper client, backup status), `VHMCP` (the MCP bridge) |
| `Sources/vaulthalla-mcp/` | the stdio MCP bridge the app embeds at `Contents/Helpers/vaulthalla-mcp` (see "AI agents" below) |
| `Helpers/vaulthalla-1password/` | the Go helper that backs vault keys up to 1Password (desktop-app authorization); `./build.sh`, see its README |
| `App/` | the Xcode project: SwiftUI app, design system, features. Source folders are synchronized: add files on disk, no project edits |
| `contract/` | `wsContract.json` vendored from the server (`SOURCE.json` records the version); `tools/gen-contract.py` turns it into Swift |
| `tools/interop/` | `vh-instance.sh`: a private daemon test instance for the opt-in live suite `Tests/VHNodesLiveTests` ([`docs/interop-testing.md`](docs/interop-testing.md)) |
| `docs/` | architecture and protocol documents |

## Build

```sh
swift test                                                  # VaulthallaKit
VH_LIVE_NODE=<host>:36982 swift test --filter Live         # against a live daemon (docs/interop-testing.md)
open App/Vaulthalla.xcodeproj                               # or:
xcodebuild -project App/Vaulthalla.xcodeproj -scheme Vaulthalla -derivedDataPath build/DerivedData build
```

Signing is per developer: copy `App/Config/Signing.local.xcconfig.example` to `App/Config/Signing.local.xcconfig`
(gitignored) and set your team. Without it the app is signed to run locally.

UI regression sweep (renders every section at three window sizes from a DEBUG build; catches AppKit layout loops):

```sh
tools/ui/sweep.sh build/DerivedData/Build/Products/Debug/Vaulthalla.app
```

Refresh the contract after a server change:

```sh
python3 tools/gen-contract.py --from ../vaulthalla      # copies the server's generated contract, regenerates Swift
```

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
