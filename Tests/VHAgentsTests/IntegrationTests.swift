import Foundation
import Testing
import VHCore
@testable import VHAgents

/// Claude Code and Codex through stub CLIs in a temporary HOME: detection, add (and repair), remove, and the typed
/// states for a missing, too old, slow or unexpected CLI. The real CLIs and the real configuration are never used.
@Suite(.timeLimit(.minutes(1))) struct ClaudeCodeTests {
    let stubs: StubHome
    let claude: ClaudeCodeIntegration

    init() throws {
        stubs = try StubHome()
        var claude = ClaudeCodeIntegration(environment: stubs.environment)
        claude.getTimeout = .seconds(2)
        claude.changeTimeout = .seconds(2)
        claude.versionTimeout = .seconds(1)
        self.claude = claude
    }

    @Test func missingCLIIsNotInstalled() async throws {
        defer { stubs.remove() }
        try FileManager.default.removeItem(at: stubs.bin.appending(path: "claude"))
        #expect(await claude.status(bridge: stubs.bridge) == .notInstalled)
        #expect(await claude.add(bridge: stubs.bridge) == .failed("Claude Code isn't installed."))
    }

    @Test func addsWithAnArgumentArrayAndVerifies() async throws {
        defer { stubs.remove() }
        let before = await claude.status(bridge: stubs.bridge)
        guard case .installed(let found, let report) = before else { Issue.record("\(before)"); return }
        #expect(found.version == "2.1.318 (Claude Code)")
        #expect(found.discovery == .loginShellPath)
        #expect(report.registration == .notAdded)

        #expect(await claude.add(bridge: stubs.bridge) == .done)
        let after = await claude.status(bridge: stubs.bridge)
        #expect(after.registration == .current)
        if case .installed(_, let report) = after { #expect(report.health == "Connected") }

        // The path with quotes, spaces and shell syntax reached the CLI as one JSON argument, untouched.
        let add = try #require(stubs.subcommands.first { $0.starts(with: ["mcp", "add-json"]) })
        #expect(Array(add.prefix(5)) == ["mcp", "add-json", "--scope", "user", "vaulthalla-desktop"])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(add[5].utf8)) as? [String: Any])
        #expect(json["command"] as? String == stubs.bridge.path)
        #expect(json["args"] as? [String] == ["--client", "claude-code"])
        #expect(json["type"] as? String == "stdio")
        #expect(!FileManager.default.fileExists(atPath: stubs.root.appending(path: "work/pwned").path))
        #expect(!FileManager.default.fileExists(atPath: stubs.root.appending(path: "pwned").path))

        // Adding again changes nothing.
        let count = stubs.subcommands.count
        #expect(await claude.add(bridge: stubs.bridge) == .done)
        #expect(stubs.subcommands.dropFirst(count).allSatisfy { $0.starts(with: ["mcp", "get"]) })
    }

    @Test func repairsAStaleOrHandMadeRegistration() async throws {
        defer { stubs.remove() }
        try #"{"type":"stdio","command":"/Volumes/Vaulthalla/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp","args":[]}"#
            .write(to: stubs.claudeState, atomically: true, encoding: .utf8)
        #expect(await claude.status(bridge: stubs.bridge).registration
            == .stale(registered: "/Volumes/Vaulthalla/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp"))

        let handMade = try JSONSerialization.data(withJSONObject: ["type": "stdio", "command": stubs.bridge.path,
                                                                   "args": [String]()])
        try handMade.write(to: stubs.claudeState)
        #expect(await claude.status(bridge: stubs.bridge).registration == .handMade)

        #expect(await claude.add(bridge: stubs.bridge) == .done)
        #expect(await claude.status(bridge: stubs.bridge).registration == .current)
        let changes = stubs.subcommands.filter { $0.count > 1 && $0[1] != "get" }.map { Array($0.prefix(4)) }
        #expect(changes == [["mcp", "remove", "--scope", "user"], ["mcp", "add-json", "--scope", "user"]])
    }

    @Test func removesFromTheUserScopeOnly() async throws {
        defer { stubs.remove() }
        #expect(await claude.add(bridge: stubs.bridge) == .done)
        #expect(await claude.remove(bridge: stubs.bridge) == .done)
        #expect(await claude.status(bridge: stubs.bridge).registration == .notAdded)
        #expect(stubs.subcommands.last == ["mcp", "get", "vaulthalla-desktop"])
        #expect(stubs.subcommands.contains(["mcp", "remove", "--scope", "user", "vaulthalla-desktop"]))
        // Removing what isn't there is reported, not hidden.
        guard case .failed(let why) = await claude.remove(bridge: stubs.bridge) else { Issue.record(); return }
        #expect(why.contains("No user-scoped MCP server"))
    }

    @Test func oldUnexpectedAndSlowCLIsAreTypedStates() async throws {
        defer { stubs.remove() }
        try stubs.setMode("claude", "old")
        guard case .unsupported = await claude.status(bridge: stubs.bridge) else { Issue.record("old"); return }
        guard case .failed = await claude.add(bridge: stubs.bridge) else { Issue.record("old add"); return }
        #expect(!stubs.subcommands.contains { $0.count > 1 && $0[1] == "add-json" })

        try stubs.setMode("claude", "garbage")
        guard case .unsupported = await claude.status(bridge: stubs.bridge) else { Issue.record("garbage"); return }

        try stubs.setMode("claude", "hang")
        let start = ContinuousClock.now
        guard case .failed(_, let detail) = await claude.status(bridge: stubs.bridge) else {
            Issue.record("hang"); return
        }
        #expect(detail.contains("in time"))
        #expect(ContinuousClock.now - start < .seconds(20))
    }

    @Test func parsesTheGetOutput() {
        let text = """
            vaulthalla-desktop:
              Scope: Local config (private to you in this project)
              Status: ✘ Failed to connect
              Issue: ENOENT
              Type: stdio
              Command: /Applications/My Apps/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp
              Args: --client claude-code
              Environment:
            """
        let entry = ClaudeCodeIntegration.parseGet(text)
        #expect(entry == .init(scope: "Local config (private to you in this project)", health: "Failed to connect",
                               command: "/Applications/My Apps/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp",
                               arguments: ["--client", "claude-code"]))
        #expect(ClaudeCodeIntegration.parseGet("vaulthalla-desktop:\n  Type: http\n") == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) struct CodexTests {
    let stubs: StubHome
    let codex: CodexIntegration

    init() throws {
        stubs = try StubHome()
        var codex = CodexIntegration(environment: stubs.environment)
        codex.timeout = .seconds(2)
        codex.versionTimeout = .seconds(1)
        self.codex = codex
    }

    static let prefix = "# my settings\nmodel = \"x\"\r\n\n[mcp_servers.other]\ncommand = \"true\"\ntool_timeout_sec = 5\n\n"
    static let suffix = "\n[profiles.fast]\nmodel = \"y\"  # trailing\n"

    @Test func addsSetsTheTimeoutAndChangesNothingElse() async throws {
        defer { stubs.remove() }
        try Self.prefix.write(to: stubs.home.appending(path: "codex-prefix.toml"), atomically: true, encoding: .utf8)
        try Self.suffix.write(to: stubs.home.appending(path: "codex-suffix.toml"), atomically: true, encoding: .utf8)
        #expect(await codex.status(bridge: stubs.bridge).registration == .notAdded)
        #expect(await codex.add(bridge: stubs.bridge) == .done)

        let status = await codex.status(bridge: stubs.bridge)
        #expect(status == .installed(FoundApp(url: stubs.bin.appending(path: "codex"), discovery: .loginShellPath,
                                              version: "codex-cli 0.171.0"),
                                     .init(registration: .current, toolTimeout: 600)))
        let add = try #require(stubs.subcommands.first { $0.starts(with: ["mcp", "add"]) })
        #expect(add == ["mcp", "add", "vaulthalla-desktop", "--", stubs.bridge.path, "--client", "codex"])

        let escaped = stubs.bridge.path.replacingOccurrences(of: "\"", with: "\\\"")
        let expected = Self.prefix + "[mcp_servers.vaulthalla-desktop]\ntool_timeout_sec = 600\ncommand = \"\(escaped)\"\n"
            + "args = [\"--client\", \"codex\"]\n" + Self.suffix
        #expect(try String(contentsOf: stubs.codexConfig, encoding: .utf8) == expected)
        // No backup or temporary file beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: stubs.codexConfig.deletingLastPathComponent().path)
            == ["config.toml"])

        // Again: nothing to do.
        let count = stubs.subcommands.count
        #expect(await codex.add(bridge: stubs.bridge) == .done)
        #expect(stubs.subcommands.dropFirst(count).allSatisfy { $0.starts(with: ["mcp", "get"]) })

        #expect(await codex.remove(bridge: stubs.bridge) == .done)
        #expect(stubs.subcommands.contains(["mcp", "remove", "vaulthalla-desktop"]))
        #expect(await codex.status(bridge: stubs.bridge).registration == .notAdded)
    }

    @Test func staleAndHandMadeRegistrationsAreReplaced() async throws {
        defer { stubs.remove() }
        try #"{"name":"vaulthalla-desktop","transport":{"type":"stdio","command":"/old/vaulthalla-mcp","args":[]},"tool_timeout_sec":null}"#
            .write(to: stubs.home.appending(path: "codex-registered.json"), atomically: true, encoding: .utf8)
        #expect(await codex.status(bridge: stubs.bridge).registration == .stale(registered: "/old/vaulthalla-mcp"))
        #expect(await codex.add(bridge: stubs.bridge) == .done)
        #expect(await codex.status(bridge: stubs.bridge).registration == .current)
    }

    @Test func aConfigThatCantBeEditedSafelyKeepsTheDefaultAndSaysSo() async throws {
        defer { stubs.remove() }
        // A second table of the same name (invalid, but ours to leave alone): the edit is refused.
        try "[mcp_servers.vaulthalla-desktop]\ncommand = \"a\"\n\n"
            .write(to: stubs.home.appending(path: "codex-suffix.toml"), atomically: true, encoding: .utf8)
        guard case .doneWithNote(let note) = await codex.add(bridge: stubs.bridge) else { Issue.record(); return }
        #expect(note.contains("60 seconds") && note.contains("tool_timeout_sec = 600"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: stubs.codexConfig.deletingLastPathComponent().path)
            == ["config.toml"])
    }

    @Test func oldAndUnexpectedCLIsAreTypedStates() async throws {
        defer { stubs.remove() }
        try stubs.setMode("codex", "old")
        guard case .unsupported = await codex.status(bridge: stubs.bridge) else { Issue.record("old"); return }
        try stubs.setMode("codex", "garbage")
        guard case .unsupported = await codex.status(bridge: stubs.bridge) else { Issue.record("garbage"); return }
        guard case .failed = await codex.add(bridge: stubs.bridge) else { Issue.record("garbage add"); return }
        #expect(!stubs.subcommands.contains { $0.starts(with: ["mcp", "add"]) })
    }
}

@Suite struct CodexConfigEditTests {
    func edit(_ text: String) -> Result<String?, CodexConfigEdit.Refusal> {
        CodexConfigEdit.edit(text, seconds: 600, server: "vaulthalla-desktop")
    }

    @Test func insertsOrRewritesOneLine() throws {
        #expect(try edit("[mcp_servers.vaulthalla-desktop]\ncommand = \"a\"\n").get()
            == "[mcp_servers.vaulthalla-desktop]\ntool_timeout_sec = 600\ncommand = \"a\"\n")
        #expect(try edit("[mcp_servers.\"vaulthalla-desktop\"] # mine\r\ncommand = \"a\"\r\n").get()
            == "[mcp_servers.\"vaulthalla-desktop\"] # mine\r\ntool_timeout_sec = 600\r\ncommand = \"a\"\r\n")
        #expect(try edit("[mcp_servers.vaulthalla-desktop]\n  tool_timeout_sec=60\n[x]\ntool_timeout_sec = 1\n").get()
            == "[mcp_servers.vaulthalla-desktop]\n  tool_timeout_sec = 600\n[x]\ntool_timeout_sec = 1\n")
        #expect(try edit("[mcp_servers.vaulthalla-desktop]\ntool_timeout_sec = 600\n").get() == nil)
        // The server's env subtable is another table: the line goes in the server's own.
        #expect(try edit("[mcp_servers.vaulthalla-desktop.env]\nA = \"1\"\n[mcp_servers.vaulthalla-desktop]\n").get()
            == "[mcp_servers.vaulthalla-desktop.env]\nA = \"1\"\n[mcp_servers.vaulthalla-desktop]\ntool_timeout_sec = 600\n")
    }

    @Test func refusesShapesItDoesntWrite() {
        // Inline table, dotted keys, a header inside a multi-line string, none at all.
        for text in ["[mcp_servers]\nvaulthalla-desktop = { command = \"a\" }\n",
                     "mcp_servers.vaulthalla-desktop.command = \"a\"\n",
                     "notes = \"\"\"\n[mcp_servers.vaulthalla-desktop]\n\"\"\"\n",
                     "notes = '''\n[mcp_servers.vaulthalla-desktop]\n",
                     ""] {
            guard case .failure = edit(text) else { Issue.record("edited: \(text)"); continue }
        }
    }

    @Test func writesThroughASymlinkAndKeepsPermissions() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "vh-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appending(path: "dotfiles/config.toml")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appending(path: ".codex"), withIntermediateDirectories: true)
        try "[mcp_servers.vaulthalla-desktop]\ncommand = \"a\"\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
        let link = directory.appending(path: ".codex/config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(CodexConfigEdit.setToolTimeout(600, server: "vaulthalla-desktop", in: link) == .changed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8).contains("tool_timeout_sec = 600\n"))
        let mode = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int
        #expect(mode == 0o640)
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.deletingLastPathComponent().path)
            == ["config.toml"])
        #expect(CodexConfigEdit.setToolTimeout(600, server: "vaulthalla-desktop", in: link) == .unchanged)
    }
}
