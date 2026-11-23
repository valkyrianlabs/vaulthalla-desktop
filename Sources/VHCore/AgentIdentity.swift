public import Foundation

/// An AI app's own pairing with one node (docs/architecture.md §3, "AI apps' own pairings"): a device of its own on
/// the node, separate from this Mac's, so the node lists it by name and it can be revoked alone. On the node it is a
/// device of the same account, with the same permissions: it restricts nothing.
///
/// Its private key is a device key like this Mac's, in the same keychain group, filed under ``keyTag(node:client:)``.
/// Only the credential owner creates and deletes it and writes these records; the bridge reads them.
public struct AgentIdentity: Codable, Hashable, Sendable {
    /// SHA-256 of the key's SPKI, hex: the device id the node knows it by.
    public var deviceID: String
    /// What the node's device list shows ("Claude Code on Cooper's Mac Studio").
    public var deviceName: String
    /// The certificate presented (DER; public).
    public var certificate: Data
    /// The server key pinned when it paired. The Mac's pin and this one are the same key; it is kept here so the
    /// identity doesn't depend on the Mac's record staying paired.
    public var serverSPKISHA256: Data
    public var pairedAt: Date
    /// The scope the node confirmed when it paired (``DeviceScope``); nil: the node couldn't limit it (an older server),
    /// or it was paired before scopes. What the node reports now (`device.list`) is what the app shows.
    public var scope: DeviceScope?
    /// When the owner found the node no longer accepts it. Set, the node is unavailable to the app (never this Mac's
    /// pairing instead) until the person pairs it again or chooses this Mac's pairing.
    public var refusedAt: Date?

    public init(deviceID: String, deviceName: String, certificate: Data, serverSPKISHA256: Data, pairedAt: Date,
                scope: DeviceScope? = nil, refusedAt: Date? = nil) {
        self.scope = scope
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.certificate = certificate
        self.serverSPKISHA256 = serverSPKISHA256
        self.pairedAt = pairedAt
        self.refusedAt = refusedAt
    }

    /// The keychain tag of the app's key for the node, beside the Mac's (`<node id>`).
    public static func keyTag(node: NodeID, client: AgentClient) -> String {
        "\(node.rawValue).agent.\(client.rawValue)"
    }
}

/// How much a paired device may do on the node (server 1.23, capability `device.scope`): a ceiling over its user's
/// permissions, never more than the account has. `destructive` is what every pairing could do before scopes. This Mac's
/// own pairing is never scoped by Desktop; only AI apps' own pairings ask for one.
public enum DeviceScope: String, Codable, CaseIterable, Comparable, Sendable, Identifiable {
    case read
    case write
    case destructive

    public var id: String { rawValue }

    public static func < (lhs: DeviceScope, rhs: DeviceScope) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var displayName: String {
        switch self {
        case .read: "Read only"
        case .write: "Read and change"
        case .destructive: "Everything"
        }
    }

    /// What it means, for the person choosing.
    public var explanation: String {
        switch self {
        case .read: "It can list and read, and the node refuses anything that changes data."
        case .write: "It can also create, edit and move, but the node refuses destructive commands."
        case .destructive:
            "It can do anything the account can, destructive commands included (they still wait for your approval)."
        }
    }
}

/// A revocation still owed to a node: the app's device was removed on this Mac (its key is already deleted) while the
/// node couldn't be reached. The owner retries it on this Mac's session until the node answers.
public struct PendingAgentRevocation: Codable, Hashable, Sendable {
    public var client: AgentClient
    public var deviceID: String
    public var deviceName: String
    public var since: Date
    public var lastAttempt: Date?
    /// Why the last attempt didn't go through, for the person.
    public var lastProblem: String?

    public init(client: AgentClient, deviceID: String, deviceName: String, since: Date, lastAttempt: Date? = nil,
                lastProblem: String? = nil) {
        self.client = client
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.since = since
        self.lastAttempt = lastAttempt
        self.lastProblem = lastProblem
    }
}

/// Which identity an AI app presents to a node. Never this Mac's because the app's own was refused or revoked.
public enum AgentIdentityChoice: Hashable, Sendable {
    /// The app's own pairing.
    case own(AgentIdentity)
    /// This Mac's pairing: no client (a registration made by hand), or the person chose it for this app and node.
    case mac
    /// Neither: the reason, in plain words for `nodes_list`.
    case unavailable(String)

    public static func choose(for node: Node, client: AgentClient?, access: AgentAccess) -> AgentIdentityChoice {
        guard let client else { return .mac }
        if let own = node.agentIdentities[client.rawValue] {
            guard own.refusedAt == nil else {
                return .unavailable("\(node.displayName) no longer accepts \(client.displayName)'s own pairing (it was "
                    + "revoked on the node). Pair \(client.displayName) with it again in Vaulthalla → Settings → Agents.")
            }
            return .own(own)
        }
        if access.usesMacPairing(node.id, for: client) { return .mac }
        return .unavailable("\(client.displayName) has no pairing of its own with \(node.displayName) yet. Give it one, "
            + "or choose this Mac's pairing for it, in Vaulthalla → Settings → Agents.")
    }
}
