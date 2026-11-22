public import Foundation
public import VHCore

/// Claude Code (the CLI, and the Code tab of the Claude desktop app, which reads the same user configuration),
/// entirely through the `claude` CLI: Vaulthalla never writes Claude's configuration files itself.
///
/// - status: `claude mcp get vaulthalla-desktop` (it prints the scope, Claude Code's health check, the command and
///   its arguments; an unknown name exits 1 with "No MCP server named …").
/// - add: `claude mcp add-json --scope user vaulthalla-desktop <json>`, after `claude mcp remove --scope user` when the
///   user scope already has one (add refuses to replace).
/// - remove: `claude mcp remove --scope user vaulthalla-desktop`. Local and project scopes are never touched.
public struct ClaudeCodeIntegration: AgentAppIntegration {
    public let client = AgentClient.claudeCode
    public var environment: AgentEnvironment
    /// `claude mcp get` starts the server for its health check, so it gets longer than the others.
    public var getTimeout: Duration = .seconds(45)
    public var changeTimeout: Duration = .seconds(30)

    public var versionTimeout: Duration = .seconds(10)

    public init(environment: AgentEnvironment) {
        self.environment = environment
    }

    private func locate() async -> FoundApp? {
        guard let (url, discovery) = environment.locate("claude") else { return nil }
        let version = try? await environment.run(url, ["--version"], timeout: versionTimeout)
        return FoundApp(url: url, discovery: discovery, version: versionString(version))
    }

    public func status(bridge: URL) async -> AgentAppStatus {
        guard let found = await locate() else { return .notInstalled }
        return await status(found, bridge: BridgeCommand(executable: bridge, client: client))
    }

    private func status(_ found: FoundApp, bridge: BridgeCommand) async -> AgentAppStatus {
        let output: ProcessRunner.Output
        do {
            output = try await environment.run(found.url, ["mcp", "get", agentServerName], timeout: getTimeout)
        } catch {
            return .failed(found, detail: "claude \(error)")
        }
        if output.timedOut { return .failed(found, detail: "claude mcp get didn't answer in time") }
        if output.status != 0 {
            let text = output.combinedText
            if text.contains("No MCP server") { return .installed(found, .init(registration: .notAdded)) }
            if looksLikeUnknownCommand(text) {
                return .unsupported(found, detail: "This Claude Code doesn't offer `claude mcp get`: update it.")
            }
            return .failed(found, detail: displayable(output.stderrText.isEmpty ? output.stdoutText : output.stderrText))
        }
        guard let entry = Self.parseGet(output.stdoutText) else {
            return .unsupported(found, detail: "claude mcp get answered in a form Vaulthalla doesn't know.")
        }
        var registration = bridge.classify(command: entry.command, arguments: entry.arguments)
        if !entry.isUserScope { registration = .otherScope(entry.scope) }
        return .installed(found, .init(registration: registration, health: entry.health))
    }

    public func add(bridge: URL) async -> AgentActionOutcome {
        guard let found = await locate() else { return .failed("Claude Code isn't installed.") }
        let command = BridgeCommand(executable: bridge, client: client)
        let before = await status(found, bridge: command)
        switch before {
        case .installed(_, let report):
            switch report.registration {
            case .current:
                return .done
            case .handMade, .stale:
                if case .failed(let why) = await removeUserScope(found) { return .failed(why) }
            case .notAdded, .otherScope, .unknown:
                break
            }
        case .unsupported(_, let detail), .failed(_, let detail):
            return .failed(detail)
        case .notInstalled:
            return .failed("Claude Code isn't installed.")
        }

        let json: [String: Any] = ["type": "stdio", "command": command.path, "args": command.arguments, "env": [:]]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return .failed("The registration couldn't be encoded.") }
        let arguments = ["mcp", "add-json", "--scope", "user", agentServerName, String(decoding: data, as: UTF8.self)]
        switch await change(found, arguments) {
        case .failed(let why): return .failed(why)
        default: break
        }
        if case .installed(_, let report) = await status(found, bridge: command) {
            if report.registration == .current { return .done }
            if case .otherScope(let scope) = report.registration {
                return .doneWithNote("Added for all projects; Claude Code also has one in its \(scope), which wins there.")
            }
        }
        return .failed("Claude Code took the registration, but doesn't list it as expected. Check again.")
    }

    public func remove(bridge: URL) async -> AgentActionOutcome {
        guard let found = await locate() else { return .failed("Claude Code isn't installed.") }
        return await removeUserScope(found)
    }

    private func removeUserScope(_ found: FoundApp) async -> AgentActionOutcome {
        await change(found, ["mcp", "remove", "--scope", "user", agentServerName])
    }

    private func change(_ found: FoundApp, _ arguments: [String]) async -> AgentActionOutcome {
        do {
            let output = try await environment.run(found.url, arguments, timeout: changeTimeout)
            if output.timedOut { return .failed("claude \(arguments[1]) didn't finish in time.") }
            guard output.status == 0 else {
                let text = output.stderrText.isEmpty ? output.stdoutText : output.stderrText
                return .failed("claude \(arguments[1]) failed: \(displayable(text))")
            }
            return .done
        } catch {
            return .failed("claude \(error)")
        }
    }

    // MARK: - Parsing `claude mcp get`

    struct Entry: Equatable {
        var scope: String
        var health: String?
        var command: String
        var arguments: [String]

        var isUserScope: Bool { scope.lowercased().hasPrefix("user") }
    }

    /// ```
    /// vaulthalla-desktop:
    ///   Scope: User config (available in all your projects)
    ///   Status: ✓ Connected
    ///   Type: stdio
    ///   Command: /Applications/Vaulthalla.app/Contents/Helpers/vaulthalla-mcp
    ///   Args: --client claude-code
    /// ```
    /// `Args` is joined with spaces by the CLI, so arguments are split on spaces; the bridge's own never contain one.
    static func parseGet(_ text: String) -> Entry? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard trimmed.count < line.count, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon])
            guard fields[key] == nil else { continue }
            fields[key] = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let command = fields["Command"], !command.isEmpty, let scope = fields["Scope"] else { return nil }
        if let type = fields["Type"], type != "stdio" { return Entry(scope: scope, command: command, arguments: ["(\(type))"]) }
        let health = fields["Status"].map { status in
            displayable(String(status.drop { !$0.isLetter }), limit: 80)
        }
        let arguments = (fields["Args"] ?? "").split(separator: " ").map(String.init)
        return Entry(scope: scope, health: health?.isEmpty == true ? nil : health, command: command,
                     arguments: arguments)
    }
}
