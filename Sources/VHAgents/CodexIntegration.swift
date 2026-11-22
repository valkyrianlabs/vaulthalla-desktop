public import Foundation
public import VHCore

/// Codex (the CLI, Codex in the ChatGPT desktop app and the IDE extension, which share `~/.codex/config.toml`),
/// through the `codex` CLI:
///
/// - status: `codex mcp get vaulthalla-desktop --json` (`transport.command`, `transport.args`, `tool_timeout_sec`;
///   an unknown name exits 1 with "No MCP server named …").
/// - add: `codex mcp add vaulthalla-desktop -- <bridge> --client codex`, which replaces an entry of that name. The CLI
///   can't set a tool timeout, so Vaulthalla then sets `tool_timeout_sec` with ``CodexConfigEdit`` (one line inserted
///   in that server's table, atomically; nothing else in the file changes). If that isn't safe, the timeout stays at
///   Codex's default and the outcome says so.
/// - remove: `codex mcp remove vaulthalla-desktop`.
public struct CodexIntegration: AgentAppIntegration {
    public let client = AgentClient.codex
    public var environment: AgentEnvironment
    public var timeout: Duration = .seconds(30)
    /// The bridge allows a call 10 minutes; Codex's default is 60 s.
    public static let toolTimeout = 600

    public var versionTimeout: Duration = .seconds(10)

    public init(environment: AgentEnvironment) {
        self.environment = environment
    }

    /// `$CODEX_HOME/config.toml`, else `~/.codex/config.toml`, as Codex itself resolves it.
    public var configURL: URL {
        if let home = environment.processEnvironment["CODEX_HOME"], home.hasPrefix("/") {
            return URL(fileURLWithPath: home, isDirectory: true).appending(path: "config.toml")
        }
        return environment.home.appending(path: ".codex/config.toml")
    }

    private func locate() async -> FoundApp? {
        guard let (url, discovery) = environment.locate("codex") else { return nil }
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
            output = try await environment.run(found.url, ["mcp", "get", agentServerName, "--json"], timeout: timeout)
        } catch {
            return .failed(found, detail: "codex \(error)")
        }
        if output.timedOut { return .failed(found, detail: "codex mcp get didn't answer in time") }
        if output.status != 0 {
            let text = output.combinedText
            if text.contains("No MCP server") { return .installed(found, .init(registration: .notAdded)) }
            if looksLikeUnknownCommand(text) {
                return .unsupported(found, detail: "This Codex doesn't offer `codex mcp get --json`: update it.")
            }
            return .failed(found, detail: displayable(output.stderrText.isEmpty ? output.stdoutText : output.stderrText))
        }
        guard let entry = Self.parseGet(output.stdout) else {
            return .unsupported(found, detail: "codex mcp get answered in a form Vaulthalla doesn't know.")
        }
        return .installed(found, .init(registration: bridge.classify(command: entry.command, arguments: entry.arguments),
                                       toolTimeout: entry.toolTimeout))
    }

    public func add(bridge: URL) async -> AgentActionOutcome {
        guard let found = await locate() else { return .failed("Codex isn't installed.") }
        let command = BridgeCommand(executable: bridge, client: client)
        switch await status(found, bridge: command) {
        case .installed(_, let report):
            if report.registration == .current, report.toolTimeout == Double(Self.toolTimeout) { return .done }
        case .unsupported(_, let detail), .failed(_, let detail):
            return .failed(detail)
        case .notInstalled:
            return .failed("Codex isn't installed.")
        }
        let arguments = ["mcp", "add", agentServerName, "--", command.path] + command.arguments
        if case .failed(let why) = await change(found, arguments) { return .failed(why) }

        var note: String?
        switch CodexConfigEdit.setToolTimeout(Self.toolTimeout, server: agentServerName, in: configURL) {
        case .changed, .unchanged:
            break
        case .refused(let why):
            note = "Codex will give each Vaulthalla call its default 60 seconds (\(why)). Longer calls still finish "
                + "on the node; set tool_timeout_sec = \(Self.toolTimeout) under [mcp_servers.\(agentServerName)] "
                + "in \(configURL.path(percentEncoded: false)) to wait for them."
        }

        guard case .installed(_, let report) = await status(found, bridge: command), report.registration == .current
        else { return .failed("Codex took the registration, but doesn't list it as expected. Check again.") }
        if note == nil, report.toolTimeout != Double(Self.toolTimeout) {
            note = "Codex doesn't report the \(Self.toolTimeout)-second timeout Vaulthalla set; calls may stop at 60 s."
        }
        return note.map(AgentActionOutcome.doneWithNote) ?? .done
    }

    public func remove(bridge: URL) async -> AgentActionOutcome {
        guard let found = await locate() else { return .failed("Codex isn't installed.") }
        return await change(found, ["mcp", "remove", agentServerName])
    }

    private func change(_ found: FoundApp, _ arguments: [String]) async -> AgentActionOutcome {
        do {
            let output = try await environment.run(found.url, arguments, timeout: timeout)
            if output.timedOut { return .failed("codex \(arguments[1]) didn't finish in time.") }
            guard output.status == 0 else {
                let text = output.stderrText.isEmpty ? output.stdoutText : output.stderrText
                return .failed("codex \(arguments[1]) failed: \(displayable(text))")
            }
            return .done
        } catch {
            return .failed("codex \(error)")
        }
    }

    // MARK: - Parsing `codex mcp get --json`

    struct Entry: Equatable {
        var command: String
        var arguments: [String]
        var toolTimeout: Double?
    }

    static func parseGet(_ data: Data) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let transport = object["transport"] as? [String: Any] ?? object
        guard let command = transport["command"] as? String else {
            if let type = transport["type"] as? String { return Entry(command: "(\(type))", arguments: []) }
            return nil
        }
        let arguments = (transport["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        let timeout = (object["tool_timeout_sec"] as? NSNumber)?.doubleValue
        return Entry(command: command, arguments: arguments, toolTimeout: timeout)
    }
}
