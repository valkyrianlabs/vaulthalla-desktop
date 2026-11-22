public import Foundation
public import VHCore
public import VHIdentity
import VHContract
import os

/// The credential owner's bookkeeping of AI apps' own pairings (docs/architecture.md §3, "AI apps' own pairings"):
/// pairing one and saving it in the node's record, removing one (revoke on the node, delete the key, drop the record,
/// or queue the revocation while the node can't be reached), retrying what is queued, noticing an identity the node
/// no longer accepts, and cleaning up when a node is removed. Every change needs the lease: `store` and `keys` are the
/// owner's, so a consumer's attempt throws before touching anything.
public struct AgentPairings: Sendable {
    public let store: NodeStore
    public let keys: DeviceKeys
    /// How long a revocation on the app's own one-shot session may take to connect and answer.
    public var ownSessionTimeout: Duration = .seconds(10)
    private let log = Logger(subsystem: "sh.vaulthalla.app", category: "agent-pairing")

    public init(store: NodeStore, keys: DeviceKeys) {
        self.store = store
        self.keys = keys
    }

    private func record(_ id: NodeID) -> Node? {
        (try? store.reload())?.first { $0.id == id }
    }

    /// Pairs the app with the node (``AgentPairing``) and saves the identity in its record. If the record can't be
    /// saved, the new device is revoked and its key deleted, so nothing is left half-made.
    public func pair(_ id: NodeID, client: AgentClient, using pairing: AgentPairing, macName: String,
                     appVersion: String) async -> Result<AgentIdentity, AgentPairing.Failure> {
        guard let node = record(id) else { return .failure(.macNotPaired) }
        // An identity this replaces (repairing after the node refused it) is revoked and dropped first.
        if node.agentIdentities[client.rawValue] != nil {
            _ = await remove(client, from: id, macSession: pairing.session)
        }
        guard let fresh = record(id) else { return .failure(.macNotPaired) }
        let outcome = await pairing.pair(fresh, client: client, macName: macName, appVersion: appVersion)
        guard case .success(let identity) = outcome else { return outcome }
        do {
            guard var latest = record(id) else { throw NodeStore.Failure.notFound(id) }
            latest.agentIdentities[client.rawValue] = identity
            _ = try store.update(latest)
            return .success(identity)
        } catch {
            _ = await AgentRevocation.revoke(deviceID: identity.deviceID, macSession: pairing.session)
            try? await keys.deleteIdentity(for: AgentIdentity.keyTag(node: id, client: client))
            return .failure(.refused("The pairing couldn't be saved on this Mac (\(error)), so it was undone."))
        }
    }

    public enum Removal: Hashable, Sendable {
        /// The node revoked it (or no longer knew it); its key and record are gone.
        case revoked
        /// Its key and record are gone; the node couldn't be reached, so the revocation is queued.
        case queued(String)
        case nothingToRemove
    }

    /// Removes the app's own pairing with the node: revoked on the node (this Mac's session, else the app's own),
    /// the key deleted now either way, the record dropped; a revocation that didn't go through is queued.
    public func remove(_ client: AgentClient, from id: NodeID, macSession: (any NodeTransport)?) async -> Removal {
        guard let node = record(id), let own = node.agentIdentities[client.rawValue] else { return .nothingToRemove }
        let tag = AgentIdentity.keyTag(node: id, client: client)
        var ownSession: (any NodeTransport)?
        if own.refusedAt == nil, let identity = try? await keys.identity(for: tag) {
            ownSession = OneShotDeviceTransport(credentials: Self.credentials(node, own: own, identity: identity),
                                                timeout: ownSessionTimeout)
        }
        let outcome = await AgentRevocation.revoke(deviceID: own.deviceID, macSession: macSession,
                                                   ownSession: ownSession)
        do {
            try await keys.deleteIdentity(for: tag)
        } catch {
            log.error("an AI app's key couldn't be deleted: \(String(describing: error), privacy: .public)")
        }
        guard var latest = record(id) else { return .revoked }
        latest.agentIdentities[client.rawValue] = nil
        var result = Removal.revoked
        if case .pending(let problem) = outcome {
            latest.pendingAgentRevocations.append(PendingAgentRevocation(
                client: client, deviceID: own.deviceID, deviceName: own.deviceName, since: Date(),
                lastAttempt: Date(), lastProblem: problem))
            result = .queued(problem)
        }
        _ = try? store.update(latest)
        return result
    }

    /// Retries the node's queued revocations on this Mac's session; returns those still owed.
    @discardableResult
    public func retryPending(on id: NodeID, macSession: (any NodeTransport)?) async -> [PendingAgentRevocation] {
        guard let node = record(id), !node.pendingAgentRevocations.isEmpty else { return [] }
        var remaining: [PendingAgentRevocation] = []
        for var pending in node.pendingAgentRevocations {
            switch await AgentRevocation.revoke(deviceID: pending.deviceID, macSession: macSession) {
            case .revoked, .alreadyGone:
                continue
            case .pending(let problem):
                pending.lastAttempt = Date()
                pending.lastProblem = problem
                remaining.append(pending)
            }
        }
        if var latest = record(id) {
            let settled = Set(node.pendingAgentRevocations.map(\.deviceID)).subtracting(remaining.map(\.deviceID))
            latest.pendingAgentRevocations = latest.pendingAgentRevocations.filter { !settled.contains($0.deviceID) }
                .map { entry in remaining.first { $0.deviceID == entry.deviceID } ?? entry }
            _ = try? store.update(latest)
        }
        return remaining
    }

    /// Asks the node about each of its apps' own identities (one connection with each key) and records the ones it
    /// refuses (`device_unknown`: revoked on the node), so the app shows them and the bridge never falls back.
    /// Returns what each check said.
    @discardableResult
    public func checkAccepted(on id: NodeID, timeout: Duration = .seconds(10)) async -> [AgentClient: DeviceCheck] {
        guard let node = record(id) else { return [:] }
        let reader = CredentialReader(registry: nil, keys: keys)
        var results: [AgentClient: DeviceCheck] = [:]
        for (raw, own) in node.agentIdentities where own.refusedAt == nil {
            guard let client = AgentClient(rawValue: raw) else { continue }
            guard let identity = try? await keys.identity(for: AgentIdentity.keyTag(node: id, client: client)) else {
                results[client] = .inconclusive("its key is missing on this Mac")
                continue
            }
            results[client] = await reader.check(Self.credentials(node, own: own, identity: identity), timeout: timeout)
        }
        let refused = results.filter { $0.value == .refused }.map(\.key.rawValue)
        if !refused.isEmpty, var latest = record(id) {
            for raw in refused { latest.agentIdentities[raw]?.refusedAt = Date() }
            _ = try? store.update(latest)
        }
        return results
    }

    /// When the node itself is removed from this Mac (`node` is its last record): revokes every app's own device on
    /// it and deletes their keys, writing nothing. Returns the devices the node couldn't be told about (their names),
    /// which the person must revoke in the node's web console: with the record gone nothing here can retry them.
    public func revokeAll(of node: Node, macSession: (any NodeTransport)?) async -> [String] {
        var left: [String] = []
        for pending in node.pendingAgentRevocations {
            if case .pending = await AgentRevocation.revoke(deviceID: pending.deviceID, macSession: macSession) {
                left.append(pending.deviceName)
            }
        }
        for (raw, own) in node.agentIdentities {
            guard let client = AgentClient(rawValue: raw) else { continue }
            let tag = AgentIdentity.keyTag(node: node.id, client: client)
            var ownSession: (any NodeTransport)?
            if own.refusedAt == nil, let identity = try? await keys.identity(for: tag) {
                ownSession = OneShotDeviceTransport(credentials: Self.credentials(node, own: own, identity: identity),
                                                    timeout: ownSessionTimeout)
            }
            if case .pending = await AgentRevocation.revoke(deviceID: own.deviceID, macSession: macSession,
                                                            ownSession: ownSession) {
                left.append(own.deviceName)
            }
        }
        for client in AgentClient.allCases {
            try? await keys.deleteIdentity(for: AgentIdentity.keyTag(node: node.id, client: client))
        }
        return left
    }

    /// The app's own credentials for a node: its key, with the record presenting its device id and pin.
    static func credentials(_ node: Node, own: AgentIdentity, identity: DeviceIdentity) -> NodeCredentials {
        var presented = node
        presented.pairing = .paired(serverSPKISHA256: own.serverSPKISHA256, deviceID: own.deviceID, since: own.pairedAt)
        presented.nextServerSPKISHA256 = nil
        return NodeCredentials(node: presented, identity: identity)
    }
}
