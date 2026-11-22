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
/// {"version": 2, "excluded": {"codex": ["<node id>"]},
///  "pairing": {"codex": {"own": true, "macPairing": ["<node id>"]}}}
/// ```
/// `pairing` says which identity an app may present where it has no pairing of its own (``AgentIdentityChoice``):
/// with no entry, this Mac's (what every registration did before apps had their own); with `own`, only the nodes
/// listed in `macPairing` get this Mac's, the others are unavailable to the app until it has its own. A file with any
/// `pairing` entry is written as version 2, so a bridge from before (which would ignore it and present this Mac's
/// identity) refuses the file and fails closed instead. Keys the reader doesn't know (a later client) are ignored; a
/// newer `version` is refused rather than guessed at.
public struct AgentAccess: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public static let fileName = "agent-access.json"

    /// As read; written as 1, or 2 when the file carries pairing choices.
    public var version: Int = 1
    /// Node ids switched off, by client (`AgentClient.rawValue`).
    public var excluded: [String: [String]] = [:]
    /// Which identity each app may present where it has no pairing of its own, by client.
    public var pairing: [String: PairingChoice] = [:]

    public struct PairingChoice: Codable, Equatable, Sendable {
        /// The app gets its own pairing on each node; this Mac's only where listed in `macPairing`.
        public var own: Bool
        /// Node ids where the person chose this Mac's pairing for the app.
        public var macPairing: [String]

        public init(own: Bool, macPairing: [String] = []) {
            self.own = own
            self.macPairing = macPairing
        }
    }

    public init() {}

    /// The same switches and choices (the version they were read with doesn't matter).
    public static func == (lhs: AgentAccess, rhs: AgentAccess) -> Bool {
        lhs.excluded == rhs.excluded && lhs.pairing == rhs.pairing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        excluded = try container.decodeIfPresent([String: [String]].self, forKey: .excluded) ?? [:]
        pairing = try container.decodeIfPresent([String: PairingChoice].self, forKey: .pairing) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pairing.isEmpty ? 1 : 2, forKey: .version)
        try container.encode(excluded, forKey: .excluded)
        if !pairing.isEmpty { try container.encode(pairing, forKey: .pairing) }
    }

    private enum CodingKeys: String, CodingKey {
        case version, excluded, pairing
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

    /// Whether the app may present this Mac's identity to `node` where it has no pairing of its own.
    public func usesMacPairing(_ node: NodeID, for client: AgentClient) -> Bool {
        guard let choice = pairing[client.rawValue], choice.own else { return true }
        return choice.macPairing.contains(node.rawValue)
    }

    /// Whether the app gets its own pairing on each node.
    public func prefersOwnPairing(_ client: AgentClient) -> Bool {
        pairing[client.rawValue]?.own == true
    }

    /// On: the app gets its own pairing on each node (this Mac's only where chosen per node). Off: this Mac's
    /// pairing wherever the app has none of its own, as before.
    public mutating func setOwnPairing(_ own: Bool, for client: AgentClient) {
        if own {
            pairing[client.rawValue] = PairingChoice(own: true, macPairing: pairing[client.rawValue]?.macPairing ?? [])
        } else {
            pairing[client.rawValue] = nil
        }
    }

    /// The person's per-node choice of this Mac's pairing for an app that otherwise gets its own.
    public mutating func setMacPairing(_ allowed: Bool, on node: NodeID, for client: AgentClient) {
        var choice = pairing[client.rawValue] ?? PairingChoice(own: true)
        choice.macPairing.removeAll { $0 == node.rawValue }
        if allowed { choice.macPairing.append(node.rawValue) }
        choice.macPairing.sort()
        pairing[client.rawValue] = choice
    }

    /// Drops exclusions of nodes no longer in the registry, so a node paired again later under the same id doesn't
    /// inherit an old switch silently.
    public mutating func prune(keeping nodes: some Sequence<NodeID>) {
        let known = Set(nodes.map(\.rawValue))
        for (client, ids) in excluded {
            let kept = ids.filter(known.contains)
            excluded[client] = kept.isEmpty ? nil : kept
        }
        for (client, choice) in pairing {
            pairing[client]?.macPairing = choice.macPairing.filter(known.contains)
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
