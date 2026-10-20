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
| `Package.swift`, `Sources/`, `Tests/` | VaulthallaKit: `VHCore` (models, secret handling), `VHContract` (generated daemon contract), `VHTransport` (ws client, mTLS), `VHIdentity` (device keys and certificates) |
| `App/` | the Xcode project: SwiftUI app, design system, features. Source folders are synchronized: add files on disk, no project edits |
| `contract/` | `wsContract.json` vendored from the server (`SOURCE.json` records the version); `tools/gen-contract.py` turns it into Swift |
| `docs/` | architecture and protocol documents |

## Build

```sh
swift test                                                  # VaulthallaKit
open App/Vaulthalla.xcodeproj                               # or:
xcodebuild -project App/Vaulthalla.xcodeproj -scheme Vaulthalla -derivedDataPath build/DerivedData build
```

Signing is per developer: copy `App/Config/Signing.local.xcconfig.example` to `App/Config/Signing.local.xcconfig`
(gitignored) and set your team. Without it the app is signed to run locally.

Refresh the contract after a server change:

```sh
python3 tools/gen-contract.py --from ../vaulthalla      # copies the server's generated contract, regenerates Swift
```

## Agent tooling

Xcode 27's MCP server gives coding agents builds, tests, previews and diagnostics. Turn on Xcode → Settings →
Intelligence → "Allow external agents to use Xcode tools", then `claude mcp add --transport stdio xcode -- xcrun
mcpbridge`. Keep the project open in Xcode while an agent works.
