public import Foundation
import VHContract
public import VHCore
public import VHTransport

/// A server one node is linked with, as that node reports it (`peer.list`): the server link of the server's
/// design/peers/link.md, experimental and off by default (`peers.experimental` in the node's config.yaml).
public struct LinkedServer: Identifiable, Hashable, Sendable {
    /// The row's number on the reporting node (what `peer.unlink` and `peer.rename` name).
    public var id: Int64
    /// The linked server's install id.
    public var serverNodeID: String
    /// What the reporting node calls it (renamable there).
    public var name: String
    /// The linked server's key, as the reporting node pins it (SPKI SHA-256).
    public var serverSPKISHA256: Data?
    /// Who compared the pairing code: `person` or `desktop`.
    public var comparedBy: String
    public var linkedAt: Date
    public var productVersion: String
    public var revoked: Bool
    public var health: Health

    public struct Health: Hashable, Sendable {
        public var connected: Bool
        /// Connected (or not) since.
        public var since: Date?
        public var dialedBy: Dialer?
        /// The address the connection runs over.
        public var address: String?
        public var roundTrip: Duration?
        public var peerVersion: String?
        /// False when the linked server speaks an older peer protocol (everything over the link pauses).
        public var protocolCompatible: Bool?
        public var lastError: String?
        public var nextAttemptAt: Date?

        public init(connected: Bool = false, since: Date? = nil, dialedBy: Dialer? = nil, address: String? = nil,
                    roundTrip: Duration? = nil, peerVersion: String? = nil, protocolCompatible: Bool? = nil,
                    lastError: String? = nil, nextAttemptAt: Date? = nil) {
            self.connected = connected
            self.since = since
            self.dialedBy = dialedBy
            self.address = address
            self.roundTrip = roundTrip
            self.peerVersion = peerVersion
            self.protocolCompatible = protocolCompatible
            self.lastError = lastError
            self.nextAttemptAt = nextAttemptAt
        }
    }

    /// Which side opened the live connection, from the reporting node's point of view.
    public enum Dialer: Hashable, Sendable {
        case thisServer
        case peer
        case other(String)

        init?(_ text: String?) {
            switch text {
            case nil: return nil
            case "this_server": self = .thisServer
            case "peer": self = .peer
            case let other?: self = .other(other)
            }
        }
    }

    public init(id: Int64, serverNodeID: String, name: String, serverSPKISHA256: Data?, comparedBy: String,
                linkedAt: Date, productVersion: String, revoked: Bool = false, health: Health = Health()) {
        self.id = id
        self.serverNodeID = serverNodeID
        self.name = name
        self.serverSPKISHA256 = serverSPKISHA256
        self.comparedBy = comparedBy
        self.linkedAt = linkedAt
        self.productVersion = productVersion
        self.revoked = revoked
        self.health = health
    }

    init(_ row: Ws.Peer.List.Response.Peer) {
        let health = row.health
        self.init(id: row.id, serverNodeID: row.nodeID, name: row.name,
                  serverSPKISHA256: Hex.decode(row.spkiSha256, length: 32), comparedBy: row.comparedBy,
                  linkedAt: Date(timeIntervalSince1970: TimeInterval(row.linkedAt)),
                  productVersion: row.productVersion, revoked: row.revoked,
                  health: Health(connected: health.connected, since: health.since.map(Self.date),
                                 dialedBy: Dialer(health.dialedBy), address: health.address,
                                 roundTrip: health.rttMs.map { .milliseconds($0) }, peerVersion: health.peerVersion,
                                 protocolCompatible: health.protocolCompatible, lastError: health.lastError,
                                 nextAttemptAt: health.nextAttemptAt.map(Self.date)))
    }

    private static func date(_ seconds: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
}

/// What a node says about linking servers, for deciding whether the app shows anything about it at all.
public enum ServerLinkAvailability: Hashable, Sendable {
    /// The switch is on and this Mac may link servers there: the node's live links.
    case on([LinkedServer])
    /// The switch is on, but this Mac's account or connection may not link servers there (the reason names the node).
    case notPermitted(ServerLinking.Failure)
    /// `peers.experimental` is off on the node (`peers_experimental`).
    case off
    /// The node's Vaulthalla has no `peer.*` commands.
    case unsupported
    /// The node couldn't be asked (offline, or another failure): nothing is known.
    case unknown(String)

    /// Whether the node has the feature switched on: only then does the app mention linking at all.
    public var isOn: Bool {
        switch self {
        case .on, .notPermitted: true
        case .off, .unsupported, .unknown: false
        }
    }

    public var links: [LinkedServer] {
        if case .on(let links) = self { links } else { [] }
    }
}

/// Reading and changing one node's linked servers over this Mac's Device session. Linking two servers is
/// ``ServerLinking``.
public enum LinkedServers {
    /// Asks the node (`peer.list`), which checks everything linking needs except the code: the switch, a super admin,
    /// and a full-access, directly connected device (`peer_forbidden` otherwise). `name` is the node's, for messages.
    public static func availability(on transport: any NodeTransport, name: String) async -> ServerLinkAvailability {
        if await transport.commandSupport(.peerList) == .no { return .unsupported }
        do {
            let answer = try await transport.send(Ws.Peer.List.self, payload: .init())
            return .on(answer.peers.map(LinkedServer.init).filter { !$0.revoked })
        } catch {
            switch ServerLinking.Failure.precondition(error, name: name) {
            case .switchedOff: return .off
            case .olderServer: return .unsupported
            case .offline(let name): return .unknown("\(name) isn't connected.")
            case let failure where failure.isPermission: return .notPermitted(failure)
            case let failure: return .unknown(failure.description)
            }
        }
    }

    /// Unlinks `peerID` on the node (`peer.unlink`): its row is revoked there, its connections close, and the other
    /// server is told if it can be reached (it then revokes its own row too).
    public static func unlink(_ peerID: Int64, on transport: any NodeTransport) async throws(WsError) {
        _ = try await transport.send(Ws.Peer.Unlink.self, payload: .init(peer: String(peerID)))
    }

    /// Renames `peerID` on the node only (`peer.rename`, 1-64 characters).
    public static func rename(_ peerID: Int64, to name: String, on transport: any NodeTransport) async throws(WsError) {
        _ = try await transport.send(Ws.Peer.Rename.self, payload: .init(peer: String(peerID), name: name))
    }

    /// Links that only one side records: `node` lists a live link to a server this Mac knows as another of its nodes,
    /// whose own list (known) has no live link back to `node`'s key. The server documents how this can happen (the
    /// dialling side failing after the other approved); unlinking the leftover row is the fix.
    public static func oneSided(nodes: [Node], links: [NodeID: [LinkedServer]]) -> [ServerLinking.HalfLink] {
        var out: [ServerLinking.HalfLink] = []
        for node in nodes {
            guard let rows = links[node.id], let nodePin = node.serverPin else { continue }
            for row in rows where !row.revoked {
                guard let other = nodes.first(where: { $0.id != node.id && $0.serverPin != nil
                    && $0.serverPin == row.serverSPKISHA256 }),
                    let back = links[other.id]
                else { continue }
                if !back.contains(where: { !$0.revoked && $0.serverSPKISHA256 == nodePin }) {
                    out.append(ServerLinking.HalfLink(node: node.id, nodeName: node.displayName, peerID: row.id,
                                                      peerName: row.name, otherName: other.displayName))
                }
            }
        }
        return out
    }
}

extension Node {
    /// This Mac's pin for the node's server key, while paired.
    public var serverPin: Data? {
        if case .paired(let pin, _, _) = pairing { pin } else { nil }
    }
}
