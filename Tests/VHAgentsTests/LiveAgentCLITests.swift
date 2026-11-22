import Foundation
import Testing
@testable import VHAgents

/// The integrations against the real `claude` and `codex` command-line tools, in a temporary HOME and CODEX_HOME so
/// the person's own configuration is never read or written. Opt-in (the stubs in the other suites stand in for the
/// tools everywhere else, CI included):
///
///   VH_LIVE_AGENT_CLIS=1
///   VH_LIVE_AGENT_PATH    the directories holding the real `claude` and `codex` (colon-separated)
///   VH_LIVE_AGENT_BRIDGE  a bridge to register (an installed Vaulthalla.app's Contents/Helpers/vaulthalla-mcp)
///
/// It proves what the stubs can't: that the tools accept the exact arguments the app sends, that their answers parse
/// as the app reads them, and that Codex still loads its config.toml after the one-line timeout edit.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VH_LIVE_AGENT_CLIS"] != nil), .serialized)
struct LiveAgentCLITests {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: "vh-agents-live-\(UUID().uuidString)", directoryHint: .isDirectory)

    func environment() throws -> (AgentEnvironment, URL) {
        let env = ProcessInfo.processInfo.environment
        let directories = try #require(env["VH_LIVE_AGENT_PATH"]).split(separator: ":").map(String.init)
        let bridge = URL(fileURLWithPath: try #require(env["VH_LIVE_AGENT_BRIDGE"]))
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let work = root.appending(path: "work", directoryHint: .isDirectory)
        for directory in [home, work, home.appending(path: ".codex")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let environment = AgentEnvironment(
            home: home, searchPath: directories,
            processEnvironment: ["PATH": (directories + ["/usr/bin", "/bin"]).joined(separator: ":"), "HOME": home.path,
                                 "CODEX_HOME": home.appending(path: ".codex").path],
            workingDirectory: work, wellKnownDirectories: [])
        return (environment, bridge)
    }

    @Test func claudeCodeAddsReportsAndRemoves() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (environment, bridge) = try environment()
        let claude = ClaudeCodeIntegration(environment: environment)
        #expect(await claude.status(bridge: bridge).registration == .notAdded)
        let added = await claude.add(bridge: bridge)
        print("LIVE claude add:", added)
        let status = await claude.status(bridge: bridge)
        print("LIVE claude status:", status)
        #expect(status.registration == .current)
        let removed = await claude.remove(bridge: bridge)
        print("LIVE claude remove:", removed)
        #expect(await claude.status(bridge: bridge).registration == .notAdded)
    }

    /// Builds the Claude desktop bundle for the bridge at VH_LIVE_AGENT_BRIDGE into VH_LIVE_AGENT_BUNDLE_DIR and leaves
    /// it there, for a person to open with Claude and see its install sheet (the one step no test can take).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VH_LIVE_AGENT_BUNDLE_DIR"] != nil))
    func theClaudeDesktopBundleIsBuiltForAPersonToOpen() async throws {
        let env = ProcessInfo.processInfo.environment
        let bridge = URL(fileURLWithPath: try #require(env["VH_LIVE_AGENT_BRIDGE"]))
        let out = URL(fileURLWithPath: try #require(env["VH_LIVE_AGENT_BUNDLE_DIR"]), isDirectory: true)
        let bundle = try await MCPBundle(bridge: bridge, version: env["VH_LIVE_AGENT_BUNDLE_VERSION"] ?? "0.0.0").build(in: out)
        print("LIVE bundle:", bundle.path(percentEncoded: false))
        #expect(FileManager.default.fileExists(atPath: bundle.path(percentEncoded: false)))
    }

    @Test func codexAddsWithItsTimeoutReportsAndRemoves() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (environment, bridge) = try environment()
        let codex = CodexIntegration(environment: environment)
        #expect(await codex.status(bridge: bridge).registration == .notAdded)
        let added = await codex.add(bridge: bridge)
        print("LIVE codex add:", added)
        let status = await codex.status(bridge: bridge)
        print("LIVE codex status:", status)
        #expect(status.registration == .current)
        if case .installed(_, let report) = status { #expect(report.toolTimeout == 600) }
        let removed = await codex.remove(bridge: bridge)
        print("LIVE codex remove:", removed)
        #expect(await codex.status(bridge: bridge).registration == .notAdded)
    }
}
