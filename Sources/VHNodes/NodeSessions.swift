import Foundation
public import VHCore

/// The live sessions, one per paired node, keyed by `NodeID`. The app hands it the node list whenever that changes
/// (``sync(_:)``); it starts a session for each paired node, restarts one whose address or pins changed, and tears
/// down sessions of nodes that were removed or are no longer paired.
///
/// **Role.** The sessions are owners while ``keys`` hold the credential lease, and consumers otherwise (``role``,
/// docs/architecture.md §3, "Credential ownership"): only one process on the Mac runs owner sessions. A process that
/// takes the lease over later (the previous owner exited) calls ``sync(_:)`` again, which restarts every session in
/// the new role; one that lets go of it does the same to continue as a consumer.
///
/// Main-actor isolated: it is driven by the app's model, and it delivers every session's events there, in order.
@MainActor
public final class NodeSessions {
    public typealias EventHandler = @MainActor (NodeID, NodeSession.Event) -> Void

    public let keys: DeviceKeys
    /// The registry consumer sessions reload records from after a refusal.
    public let registry: NodeStore?
    public let configuration: NodeSession.Configuration

    private struct Entry {
        let session: NodeSession
        /// What the session was started with, updated with the changes it reported itself, so saving those doesn't
        /// restart it.
        var basis: Basis
        let role: CredentialRole
        let pump: Task<Void, Never>
    }

    /// The parts of a node record a session depends on.
    private struct Basis: Equatable {
        var endpoint: NodeEndpoint
        var pairing: PairingState
        var nextServerSPKISHA256: Data?

        init(_ node: Node) {
            endpoint = node.endpoint
            pairing = node.pairing
            nextServerSPKISHA256 = node.nextServerSPKISHA256
        }
    }

    private var entries: [NodeID: Entry] = [:]
    private let onEvent: EventHandler

    public init(keys: DeviceKeys, registry: NodeStore? = nil, configuration: NodeSession.Configuration = .init(),
                onEvent: @escaping EventHandler) {
        self.keys = keys
        self.registry = registry
        self.configuration = configuration
        self.onEvent = onEvent
    }

    /// The session for a node, if it has one.
    public func session(for id: NodeID) -> NodeSession? {
        entries[id]?.session
    }

    public var nodeIDs: Set<NodeID> { Set(entries.keys) }

    /// The role new sessions get: owner while ``keys`` hold the credential lease.
    public var role: CredentialRole { keys.role }

    /// Brings the sessions in line with `nodes`.
    public func sync(_ nodes: [Node]) {
        var wanted: [NodeID: Node] = [:]
        for node in nodes where node.pairing.isPairedState { wanted[node.id] = node }

        let role = role
        for (id, entry) in entries where wanted[id].map(Basis.init) != entry.basis || entry.role != role {
            stop(id)
        }
        for (id, node) in wanted where entries[id] == nil {
            start(node)
        }
    }

    /// Stops a node's session (removal, re-pairing). Its events end; no status is reported for it afterwards.
    public func stop(_ id: NodeID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.pump.cancel()
        Task { await entry.session.stop() }
    }

    public func stopAll() {
        for id in Array(entries.keys) { stop(id) }
    }

    private func start(_ node: Node) {
        let session = NodeSession(node: node, keys: keys, registry: registry, configuration: configuration)
        let id = node.id
        let pump = Task { [weak self] in
            for await event in session.events {
                guard let self, !Task.isCancelled else { return }
                self.deliver(event, from: id)
            }
        }
        entries[id] = Entry(session: session, basis: Basis(node), role: session.role, pump: pump)
        Task { await session.start() }
    }

    private func deliver(_ event: NodeSession.Event, from id: NodeID) {
        if case .recordChanged(let pairing, let next) = event {
            entries[id]?.basis.pairing = pairing
            entries[id]?.basis.nextServerSPKISHA256 = next
        }
        onEvent(id, event)
    }
}

extension PairingState {
    /// `.paired`, whatever its values.
    var isPairedState: Bool {
        if case .paired = self { return true }
        return false
    }
}
