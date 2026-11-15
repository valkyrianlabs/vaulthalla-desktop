public import Foundation
public import VHCore
import VHKeykit

/// Which paired node is which server of the account, and which vault is which (docs/cloud-storage.md, "Mapping nodes
/// to deployments"). Pure: the app feeds it the cloud's lists and what each node answered, and shows the result.
///
/// A node is a deployment when the node says so over its own pinned connection (`cloud.link.status`: deployment id
/// and account public id). A deployment's `node_id` equal to the node's `serverNodeID` is only a hint: such a node
/// shows as likely until it answers. A vault is its `vault_uid`; a replica's `(deployment, origin_vault_id)` on a
/// confirmed node is Desktop's `(node id, vault id)`, and both must agree with the uid the node itself reports where
/// it reports one. A mismatch is shown, not resolved.
public enum NodeMapping {
    /// What a paired node said about its cloud link.
    public enum NodeLink: Sendable, Hashable {
        /// Not asked yet, or not answered (offline).
        case unknown
        /// The node has no `cloud.account_key` capability (older Vaulthalla).
        case unsupported
        case notLinked
        /// Linked, as this deployment of this account; nil members when this user may not see the identifiers.
        case linked(deploymentID: String?, accountPublicID: String?)
    }

    /// One paired node's facts.
    public struct Node: Sendable, Hashable {
        public var id: NodeID
        public var name: String
        public var serverNodeID: String?
        public var link: NodeLink
        /// The node's vaults this user sees: id, name and, where the node reports it, the uid.
        public var vaults: [NodeVault]

        public init(id: NodeID, name: String, serverNodeID: String?, link: NodeLink, vaults: [NodeVault] = []) {
            self.id = id
            self.name = name
            self.serverNodeID = serverNodeID
            self.link = link
            self.vaults = vaults
        }
    }

    public struct NodeVault: Sendable, Hashable {
        public var id: Int64
        public var name: String
        public var uid: String?

        public init(id: Int64, name: String, uid: String? = nil) {
            self.id = id
            self.name = name
            self.uid = uid
        }
    }

    /// A row of the Servers pane.
    public enum Server: Sendable, Hashable, Identifiable {
        /// A paired node, confirmed as this deployment of this account.
        case linked(node: NodeID, deployment: CloudDeployment)
        /// A paired node whose server id matches the deployment's, not yet confirmed by the node.
        case likely(node: NodeID, deployment: CloudDeployment)
        /// A server of the account this Mac isn't paired with.
        case unpaired(deployment: CloudDeployment)
        /// A paired node that isn't linked to Vaulthalla Cloud.
        case notLinked(node: NodeID)
        /// A paired node linked to another account: shown, never managed.
        case otherAccount(node: NodeID)
        /// A paired node too old to say (no `cloud.account_key`), with the deployment it likely is.
        case needsUpdate(node: NodeID, deployment: CloudDeployment?)
        /// A paired node that hasn't answered yet and matches no deployment.
        case unknown(node: NodeID)

        public var id: String {
            switch self {
            case .linked(let n, _), .likely(let n, _), .notLinked(let n), .otherAccount(let n), .needsUpdate(let n, _),
                 .unknown(let n):
                "node:\(n.rawValue)"
            case .unpaired(let d): "deployment:\(d.id)"
            }
        }

        public var deployment: CloudDeployment? {
            switch self {
            case .linked(_, let d), .likely(_, let d), .unpaired(let d): d
            case .needsUpdate(_, let d): d
            case .notLinked, .otherAccount, .unknown: nil
            }
        }

        public var node: NodeID? {
            switch self {
            case .linked(let n, _), .likely(let n, _), .notLinked(let n), .otherAccount(let n), .needsUpdate(let n, _),
                 .unknown(let n):
                n
            case .unpaired: nil
            }
        }
    }

    /// One vault of the account, with where it is.
    public struct Vault: Sendable, Hashable, Identifiable {
        public struct Placement: Sendable, Hashable {
            public var deploymentID: String
            public var originVaultID: Int64?
            /// The paired node and its vault id, when the node is confirmed as that deployment and the ids agree.
            public var node: NodeID?
            public var nodeVaultID: Int64?
            /// The node reports a different uid for that vault id: shown, not resolved.
            public var uidMismatch: Bool
        }

        public var uid: String
        public var sealedLabel: String?
        public var placements: [Placement]
        public var id: String { uid }
    }

    public struct Result: Sendable, Hashable {
        public var servers: [Server]
        public var vaults: [Vault]
    }

    public static func map(deployments: [CloudDeployment], vaults: [CloudVault], nodes: [Node],
                           accountPublicID: String) -> Result {
        var servers: [Server] = []
        var confirmed: [String: Node] = [:]  // deployment id → node
        var claimed = Set<String>()
        for node in nodes {
            let hinted = node.serverNodeID.flatMap { id in deployments.first { $0.nodeId == id } }
            switch node.link {
            case .linked(let deploymentID, let account):
                if let account, account != accountPublicID {
                    servers.append(.otherAccount(node: node.id))
                } else if let deploymentID, account != nil, let d = deployments.first(where: { $0.id == deploymentID }) {
                    servers.append(.linked(node: node.id, deployment: d))
                    confirmed[d.id] = node
                    claimed.insert(d.id)
                } else if let hinted {
                    // Linked, but either another account's deployment we can't see or identifiers withheld from this user.
                    servers.append(.likely(node: node.id, deployment: hinted))
                    claimed.insert(hinted.id)
                } else {
                    servers.append(account == nil ? .unknown(node: node.id) : .otherAccount(node: node.id))
                }
            case .notLinked:
                servers.append(.notLinked(node: node.id))
            case .unsupported:
                servers.append(.needsUpdate(node: node.id, deployment: hinted))
                if let hinted { claimed.insert(hinted.id) }
            case .unknown:
                if let hinted {
                    servers.append(.likely(node: node.id, deployment: hinted))
                    claimed.insert(hinted.id)
                } else {
                    servers.append(.unknown(node: node.id))
                }
            }
        }
        for d in deployments where !claimed.contains(d.id) { servers.append(.unpaired(deployment: d)) }

        let mapped = vaults.map { v in
            Vault(uid: v.vaultUid, sealedLabel: v.label, placements: v.replicas.map { r in
                var p = Vault.Placement(deploymentID: r.deploymentId, originVaultID: r.originVaultId, node: nil,
                                        nodeVaultID: nil, uidMismatch: false)
                if let node = confirmed[r.deploymentId], let origin = r.originVaultId,
                   let local = node.vaults.first(where: { $0.id == origin }) {
                    if let uid = local.uid, uid != v.vaultUid {
                        p.uidMismatch = true
                    } else {
                        p.node = node.id
                        p.nodeVaultID = local.id
                    }
                }
                return p
            })
        }
        return Result(servers: servers, vaults: mapped)
    }
}

/// What to offer for a server's pin of the account key (`cloud.key.status`), against the key this Mac holds
/// (docs/cloud-storage.md: "Use this account's recovery key on *nas*"; no digits compared).
public enum ServerKeyAdvice: Sendable, Hashable {
    /// Pinned to the key this Mac holds.
    case pinned
    /// The server waits for a confirmation of exactly the key this Mac holds: offer to confirm it.
    case confirm(fingerprint: String)
    /// The server waits for a key that isn't the one this Mac holds: a warning, never confirmed from here.
    case mismatch(waiting: String)
    /// Pinned to another key (an older generation the server hasn't followed yet, or another key).
    case pinnedOther(fingerprint: String)
    /// Nothing to do from here: not linked, no key yet, this Mac doesn't hold the key, or the server is another
    /// account's.
    case none(String)

    public static func advise(state: String, accountPublicID: String?, pinned: String?, waiting: String?,
                              held: String?, ourAccount: String) -> ServerKeyAdvice {
        if let accountPublicID, accountPublicID != ourAccount { return .none("Linked to a different Vaulthalla Cloud account.") }
        guard let held else { return .none("This Mac doesn't hold the recovery key.") }
        switch state {
        case "unlinked": return .none("Not connected to Vaulthalla Cloud.")
        case "none", "unchecked": return .none("The server hasn't seen a recovery key yet.")
        case "tampered": return .none("The server found the account's recovery key altered and stopped using it.")
        default: break
        }
        if let waiting {
            return same(waiting, held) ? .confirm(fingerprint: held) : .mismatch(waiting: waiting)
        }
        if let pinned { return same(pinned, held) ? .pinned : .pinnedOther(fingerprint: pinned) }
        return .none("The server hasn't seen a recovery key yet.")
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        guard let x = try? Fingerprint(text: a, lenient: true), let y = try? Fingerprint(text: b, lenient: true) else { return false }
        return x == y
    }
}
