public import Foundation

/// An AI app the MCP bridge can be registered with. Each registration starts the bridge with `--client <rawValue>`,
/// so the bridge knows which app it serves (docs/architecture.md §5, "Registration"). The value names the app, not an
/// identity: today every client presents this Mac's device identity; a per-client identity can be looked up by the
/// same value later without changing any registration.
public enum AgentClient: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Claude Code: the CLI, and the Code tab of the Claude desktop app (they share the user configuration).
    case claudeCode = "claude-code"
    /// The Claude desktop app's chat, through an MCP Bundle (`.mcpb`).
    case claudeDesktop = "claude-desktop"
    /// Codex: the CLI, Codex in the ChatGPT desktop app and the IDE extension (they share `~/.codex/config.toml`).
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude"
        case .codex: "Codex"
        }
    }
}

/// Which paired nodes each AI app may use: `agent-access.json` next to the node registry. Only exclusions are
/// recorded, so every node, including one paired later, is available to every app until it is switched off for that
/// app. The app writes the file (atomically); the bridge only reads it, on every registry refresh.
///
/// ```json
/// {"version": 1, "excluded": {"codex": ["<node id>"]}}
/// ```
/// Keys the reader doesn't know (a later client) are ignored; a newer `version` is refused rather than guessed at.
public struct AgentAccess: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "agent-access.json"

    public var version: Int = AgentAccess.currentVersion
    /// Node ids switched off, by client (`AgentClient.rawValue`).
    public var excluded: [String: [String]] = [:]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        excluded = try container.decodeIfPresent([String: [String]].self, forKey: .excluded) ?? [:]
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case unsupportedVersion(Int)

        public var description: String {
            switch self {
            case .unreadable(let why): "agent-access.json can't be read: \(why)"
            case .unsupportedVersion(let version): "agent-access.json was written by a newer Vaulthalla (version \(version))"
            }
        }
    }

    /// The file beside a registry (`nodes.json`).
    public static func fileURL(besideRegistry registry: URL) -> URL {
        registry.deletingLastPathComponent().appending(path: fileName, directoryHint: .notDirectory)
    }

    public func isAvailable(_ node: NodeID, to client: AgentClient) -> Bool {
        !(excluded[client.rawValue] ?? []).contains(node.rawValue)
    }

    public func excludedNodes(for client: AgentClient) -> Set<NodeID> {
        Set((excluded[client.rawValue] ?? []).map(NodeID.init(rawValue:)))
    }

    public mutating func set(_ node: NodeID, available: Bool, to client: AgentClient) {
        var ids = excluded[client.rawValue] ?? []
        ids.removeAll { $0 == node.rawValue }
        if !available { ids.append(node.rawValue) }
        excluded[client.rawValue] = ids.isEmpty ? nil : ids.sorted()
    }

    /// Drops exclusions of nodes no longer in the registry, so a node paired again later under the same id doesn't
    /// inherit an old switch silently.
    public mutating func prune(keeping nodes: some Sequence<NodeID>) {
        let known = Set(nodes.map(\.rawValue))
        for (client, ids) in excluded {
            let kept = ids.filter(known.contains)
            excluded[client] = kept.isEmpty ? nil : kept
        }
    }

    /// The file's contents; a missing file is the default (everything available).
    public static func load(from url: URL) throws(Failure) -> AgentAccess {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return AgentAccess()
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        struct Probe: Decodable { var version: Int }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
            throw .unreadable("not a Vaulthalla agent access file")
        }
        guard probe.version <= currentVersion else { throw .unsupportedVersion(probe.version) }
        do {
            return try JSONDecoder().decode(AgentAccess.self, from: data)
        } catch {
            throw .unreadable("not a Vaulthalla agent access file")
        }
    }

    /// Writes the file durably and atomically (a new file renamed over the old one).
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try RegistryMigration.writeDurably(try encoder.encode(self) + Data([0x0A]), to: url)
    }
}
