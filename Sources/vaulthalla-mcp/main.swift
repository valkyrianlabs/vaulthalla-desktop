// vaulthalla-mcp: Vaulthalla Desktop's MCP bridge. An MCP client (Claude Code, Codex) starts it as a stdio server; it
// reaches every node this Mac is paired with through the node's remote MCP, with the device keys the app created.
// See docs/architecture.md §5 and Sources/VHMCP.
//
// stdout carries only protocol messages; diagnostics go to stderr (VAULTHALLA_MCP_LOG=debug|info|warning|error) and
// never include tool arguments or results.
//
// Environment:
//   VAULTHALLA_MCP_TIMEOUT   seconds a tool call may take (default 600, 0 = no limit)
//   VAULTHALLA_MCP_REGISTRY  the node registry to read (default ~/Library/Application Support/Vaulthalla/nodes.json)

import Foundation
import VHCore
import VHMCP
import VHNodes

signal(SIGPIPE, SIG_IGN)

let environment = ProcessInfo.processInfo.environment
let level: BridgeLog.Level = switch environment["VAULTHALLA_MCP_LOG"]?.lowercased() {
case "debug": .debug
case "warning": .warning
case "error": .error
default: .info
}
let log = BridgeLog.standardError(minimum: level)

var settings = MCPBridge.Settings()
settings.version = Bundle.vaulthallaVersion
if !settings.apply(environment: environment) {
    log(.warning, "VAULTHALLA_MCP_TIMEOUT isn't a number of seconds; using the default")
}

let registryURL = environment["VAULTHALLA_MCP_REGISTRY"].map { URL(fileURLWithPath: $0) } ?? NodeStore.defaultFileURL()
// A credential consumer (docs/architecture.md §3): no lease, so the registry and the keys are read-only here.
let registry = NodeStore(fileURL: registryURL)
let writer = StandardIO.Writer()
let bridge = MCPBridge(
    registry: registry,
    connector: KeychainNodeConnector(keys: .standard(), registry: registry),
    settings: settings,
    log: log,
    output: { data in await writer.write(data) })

log(.info, "serving \(registryURL.path) over stdio")
await bridge.run(lines: StandardIO.lines())
exit(0)

extension Bundle {
    /// The enclosing app's version when the helper runs from `Vaulthalla.app/Contents/Helpers`, else "dev".
    static var vaulthallaVersion: String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", let bundle = Bundle(url: app),
              let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return "dev" }
        return version
    }
}
