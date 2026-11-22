public import Foundation
public import VHCore

/// The name every AI app lists the bridge under.
public let agentServerName = "vaulthalla-desktop"

/// What a registration must start: this app's bridge, told which app it serves.
public struct BridgeCommand: Sendable, Equatable {
    public var executable: URL
    public var client: AgentClient

    public init(executable: URL, client: AgentClient) {
        self.executable = executable
        self.client = client
    }

    public var path: String { executable.path(percentEncoded: false) }
    public var arguments: [String] { ["--client", client.rawValue] }

    /// How a registration an app reports relates to this command.
    func classify(command: String, arguments: [String]) -> Registration {
        guard Self.samePath(command, path) else { return .stale(registered: command) }
        if arguments == self.arguments { return .current }
        if arguments.isEmpty { return .handMade }
        return .stale(registered: ([command] + arguments).joined(separator: " "))
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let left = URL(fileURLWithPath: a).standardizedFileURL, right = URL(fileURLWithPath: b).standardizedFileURL
        if left == right { return true }
        return left.resolvingSymlinksInPath() == right.resolvingSymlinksInPath()
    }
}

/// An AI app's command-line tool or application, and how it was found.
public struct FoundApp: Sendable, Equatable {
    public enum Discovery: String, Sendable, Equatable {
        case wellKnownLocation, loginShellPath, applicationRegistry
    }

    public var url: URL
    public var discovery: Discovery
    public var version: String?

    public init(url: URL, discovery: Discovery, version: String?) {
        self.url = url
        self.discovery = discovery
        self.version = version
    }
}

/// Whether the bridge is added to an AI app.
public enum Registration: Sendable, Equatable {
    case notAdded
    /// This app's bridge with this app's `--client`.
    case current
    /// This app's bridge without `--client` (added by hand): it works, but the per-node switches don't apply.
    case handMade
    /// Something else under the bridge's name, usually this app's bridge at a path it no longer has (the app moved).
    case stale(registered: String)
    /// Only in another scope than the user's (Claude Code's local or project servers); the user scope is untouched.
    case otherScope(String)
    /// The AI app keeps it where Vaulthalla can't tell (Claude's own install list): see ``AgentAppStatus``.
    case unknown
}

public enum AgentAppStatus: Sendable, Equatable {
    /// The AI app isn't on this Mac (none of the places Vaulthalla looks).
    case notInstalled
    /// Present, but its tool doesn't offer what Vaulthalla needs (too old) or answered in a form Vaulthalla doesn't
    /// know; nothing was changed.
    case unsupported(FoundApp, detail: String)
    /// Present, but asking it failed (it timed out, or reported an error).
    case failed(FoundApp, detail: String)
    case installed(FoundApp, Report)

    public struct Report: Sendable, Equatable {
        public var registration: Registration
        /// The AI app's own word on the server (Claude Code's health check: "Connected", "Failed to connect").
        public var health: String?
        /// Codex: the registered tool timeout in seconds; nil: Codex's default (60 s).
        public var toolTimeout: Double?

        public init(registration: Registration, health: String? = nil, toolTimeout: Double? = nil) {
            self.registration = registration
            self.health = health
            self.toolTimeout = toolTimeout
        }
    }

    public var registration: Registration? {
        if case .installed(_, let report) = self { report.registration } else { nil }
    }
}

public enum AgentActionOutcome: Sendable, Equatable {
    case done
    /// Done, with something the person should know (for example, Codex's timeout was left at its default).
    case doneWithNote(String)
    /// The bundle to open with the app at `application`, whose own install sheet finishes the job.
    case openBundle(URL, application: URL)
    /// Vaulthalla can't do this; the text says what to do in the AI app.
    case manual(String)
    case failed(String)
}

/// One AI app the bridge can be added to.
public protocol AgentAppIntegration: Sendable {
    var client: AgentClient { get }
    func status(bridge: URL) async -> AgentAppStatus
    func add(bridge: URL) async -> AgentActionOutcome
    func remove(bridge: URL) async -> AgentActionOutcome
}

/// Text from another program shown to the person: one paragraph, no control characters, at most `limit` characters.
func displayable(_ text: String, limit: Int = 300) -> String {
    let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
        CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
    }))
    let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
}

/// Whether a CLI's refusal means it doesn't know a subcommand or option (an older version).
func looksLikeUnknownCommand(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return ["unknown command", "unknown option", "unrecognized subcommand", "unexpected argument",
            "unrecognized option", "invalid choice"].contains { lowered.contains($0) }
}

func versionString(_ output: ProcessRunner.Output?) -> String? {
    guard let output, output.status == 0, !output.timedOut else { return nil }
    let first = output.stdoutText.split(separator: "\n").first.map(String.init) ?? ""
    let text = displayable(first, limit: 60)
    return text.isEmpty ? nil : text
}
