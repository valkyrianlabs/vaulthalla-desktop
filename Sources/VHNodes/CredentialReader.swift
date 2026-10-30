public import Foundation
public import VHCore
public import VHIdentity
public import VHTransport
import VHContract

/// A node's credentials as the owner last saved them: the registry record (address, server pins, pairing state) and
/// the device identity this Mac presents to it.
public struct NodeCredentials: Sendable {
    public let node: Node
    public let identity: DeviceIdentity

    public init(node: Node, identity: DeviceIdentity) {
        self.node = node
        self.identity = identity
    }

    /// The pinned server key (empty unless the record is paired).
    public var serverPin: Data {
        if case .paired(let pin, _, _) = node.pairing { return pin }
        return Data()
    }

    /// The device listener's HTTP lanes with these credentials: this identity, the pinned server key and the
    /// announced next one.
    public func laneConfiguration(timeout: Duration = .seconds(30)) -> DeviceHTTPClient.Configuration {
        DeviceHTTPClient.Configuration(endpoint: node.endpoint, identity: identity.secIdentity, serverSPKIPin: serverPin,
                                       nextServerSPKIPin: node.nextServerSPKISHA256, timeout: timeout)
    }
}

/// Why a consumer has no credentials to present to a node.
public enum CredentialFailure: Error, Hashable, Sendable, CustomStringConvertible {
    /// The registry has no such node (it was removed).
    case unknownNode(NodeID)
    case notPaired
    /// The node no longer accepts this Mac: the owner recorded a revocation, or the node kept refusing this Mac's key
    /// after a reload. Fail closed; only pairing again (in the owner) helps.
    case revoked
    /// This Mac's key for the node isn't in the Keychain.
    case missingKey
    /// The Keychain refused the lookup.
    case keychain(String)
    /// The registry can't be read.
    case registry(String)

    public var description: String {
        switch self {
        case .unknownNode(let id): "No node \(id) is saved on this Mac."
        case .notPaired: "This Mac isn't paired with the node."
        case .revoked: "The node no longer accepts this Mac. Pair it again in Vaulthalla."
        case .missingKey: "This Mac's key for the node is missing. Pair it again in Vaulthalla."
        case .keychain(let detail): "This Mac's key for the node can't be read (\(detail))."
        case .registry(let detail): "The saved node list can't be read (\(detail))."
        }
    }
}

/// What a node said about a key when asked directly (``CredentialReader/check(_:timeout:)``).
public enum DeviceCheck: Hashable, Sendable {
    /// A Device session: the node accepts the key.
    case accepted
    /// `device_unknown`: the node doesn't accept the key (unknown or revoked; the daemon doesn't say which).
    case refused
    /// No answer that decides it (unreachable, a server key that doesn't match, an older daemon).
    case inconclusive(String)
}

/// Read-only access to the credentials the owner maintains, for every process that isn't the owner: the app while
/// another process owns, the File Provider extension, `vaulthalla-mcp` (docs/architecture.md §3, "Credential
/// ownership"). It reads the registry and the Keychain and changes neither; its `DeviceKeys` and `NodeStore` need no
/// lease.
///
/// The consumer's contract, generalized from the MCP bridge:
/// - Present what the owner saved. When the node refuses it (`device_unknown` on the ws, HTTP 403 on the lanes),
///   the owner may have rotated the key, or promoted a server pin, since it was read: reload both and retry once
///   (``reload(after:)``; ``withCredentials(for:checkTimeout:_:)`` does the whole round).
/// - A refusal that survives the reload is a revocation (``CredentialFailure/revoked``): fail closed. A lane 403 can
///   also be an RBAC refusal, so before calling it a revocation the node is asked directly (``check(_:timeout:)``).
/// - Never rotate, complete or cancel a rotation, delete a key or write the registry: none of that is reachable from
///   here, and the `DeviceKeys`/`NodeStore` a consumer holds refuse it.
public struct CredentialReader: Sendable {
    /// The registry the owner writes. nil: records come from the caller only (a session given its record).
    public let registry: NodeStore?
    public let keys: DeviceKeys

    public init(registry: NodeStore?, keys: DeviceKeys) {
        self.registry = registry
        self.keys = keys
    }

    /// Which refusals mean "this key may no longer be accepted".
    public enum Refusal: Hashable, Sendable {
        /// The ws `device_unknown`: the node doesn't accept the key.
        case deviceUnknown
        /// An HTTP 403 on the lanes: the key isn't accepted, or the account may not do this.
        case forbidden
    }

    /// The refusal `error` carries, if it is one.
    public static func refusal(in error: any Error) -> Refusal? {
        if let error = error as? WsError, DeviceRefusal(error) == .deviceUnknown { return .deviceUnknown }
        if let error = error as? DeviceHTTPError, error == .forbidden { return .forbidden }
        if let error = error as? TransferError, error == .forbidden { return .forbidden }
        if let error = error as? CredentialFailure, error == .revoked { return .deviceUnknown }
        return nil
    }

    // MARK: - Reading

    /// The node's record as the registry holds it now (re-read from disk); nil without a registry.
    public func record(_ id: NodeID) throws(CredentialFailure) -> Node? {
        guard let registry else { return nil }
        let nodes: [Node]
        do {
            nodes = try registry.reload()
        } catch {
            throw .registry((error as? NodeStore.Failure)?.description ?? String(describing: error))
        }
        guard let node = nodes.first(where: { $0.id == id }) else { throw .unknownNode(id) }
        return node
    }

    /// The node's credentials as saved now: the registry's record and the current identity.
    public func load(_ id: NodeID) async throws(CredentialFailure) -> NodeCredentials {
        guard let node = try record(id) else { throw .registry("no registry to read") }
        return try await load(node)
    }

    /// `node` (as given) with its current identity.
    public func load(_ node: Node) async throws(CredentialFailure) -> NodeCredentials {
        try checkPaired(node)
        let current: DeviceIdentity?
        do {
            current = try await keys.identity(for: node.id.rawValue)
        } catch {
            throw .keychain(String(describing: error))
        }
        guard let current else { throw .missingKey }
        return NodeCredentials(node: node, identity: current)
    }

    /// The credentials to retry with once after the node refused `refused`.
    public func reload(after refused: NodeCredentials) async throws(CredentialFailure) -> NodeCredentials {
        try await reload(refused.node, refusing: refused.identity.deviceID)
    }

    /// Re-reads the record (the registry's, else `node`) and the Keychain after the node refused the key with
    /// `refusedDeviceID` (nil: unknown). The identity to retry with is the newest one that isn't the refused key: the
    /// current one if the owner replaced it, else the pending replacement of a rotation in flight (the owner's
    /// reconnect with it may already have ended the old key's grace, docs/pairing.md §4), else the current one again.
    /// A record the owner marked revoked or unpaired ends it.
    public func reload(_ node: Node, refusing refusedDeviceID: String?) async throws(CredentialFailure)
        -> NodeCredentials
    {
        let fresh = try record(node.id) ?? node
        try checkPaired(fresh)
        let tag = fresh.id.rawValue
        let current: DeviceIdentity?
        let pending: DeviceIdentity?
        do {
            current = try await keys.identity(for: tag)
            pending = try await keys.pendingRotation(for: tag)
        } catch {
            throw .keychain(String(describing: error))
        }
        let candidates = [current, pending].compactMap(\.self)
        guard let chosen = candidates.first(where: { $0.deviceID != refusedDeviceID }) ?? current else {
            throw .missingKey
        }
        return NodeCredentials(node: fresh, identity: chosen)
    }

    private func checkPaired(_ node: Node) throws(CredentialFailure) {
        switch node.pairing {
        case .paired: return
        case .revoked: throw .revoked
        case .unpaired, .pending: throw .notPaired
        }
    }

    // MARK: - The consumer round

    /// Runs `operation` with the node's credentials as saved now. When the node refuses them (``refusal(in:)``), the
    /// credentials are reloaded and `operation` runs once more; when that is refused too, the key is revoked:
    /// `device_unknown` throws ``CredentialFailure/revoked`` at once, a 403 does after ``check(_:timeout:)`` confirms
    /// it (otherwise the 403 itself is rethrown: the account may not do this). Other errors pass through unchanged.
    ///
    /// `operation` runs at most twice, and the second time only after a refusal: a refused request never ran.
    public func withCredentials<T>(
        for id: NodeID, checkTimeout: Duration = .seconds(10),
        _ operation: (NodeCredentials) async throws -> T
    ) async throws -> T {
        let first = try await load(id)
        do {
            return try await operation(first)
        } catch {
            guard Self.refusal(in: error) != nil else { throw error }
        }
        let fresh = try await reload(after: first)
        do {
            return try await operation(fresh)
        } catch {
            switch Self.refusal(in: error) {
            case nil: throw error
            case .deviceUnknown: throw CredentialFailure.revoked
            case .forbidden:
                if await check(fresh, timeout: checkTimeout) == .refused { throw CredentialFailure.revoked }
                throw error
            }
        }
    }

    /// Asks the node directly whether it accepts `credentials`: one ws connection with that identity, pinning the
    /// saved server keys, and `device.server.identity`, which only a Device session may send. Changes nothing.
    public func check(_ credentials: NodeCredentials, timeout: Duration = .seconds(10)) async -> DeviceCheck {
        await check(credentials, pin: credentials.serverPin, timeout: timeout, tryingNext: true)
    }

    /// Asks the node what it speaks (`meta.hello`, ``NodeProtocol``) over one ws connection with `credentials`, for
    /// a process without a session of its own (the MCP bridge). nil when it decided nothing (unreachable, no answer).
    public func negotiate(_ credentials: NodeCredentials, timeout: Duration = .seconds(10)) async -> NodeProtocol? {
        let client: WsClient
        do {
            client = try WsClient(configuration: .init(
                endpoint: credentials.node.endpoint,
                security: .mutualTLS(identity: credentials.identity.secIdentity, serverSPKIPin: credentials.serverPin,
                                     onServerSPKI: { _ in }),
                connectTimeout: timeout))
        } catch {
            return nil
        }
        defer { Task { await client.close() } }
        return await client.negotiate(timeout: timeout)
    }

    private func check(_ credentials: NodeCredentials, pin: Data, timeout: Duration, tryingNext: Bool) async
        -> DeviceCheck
    {
        let client: WsClient
        do {
            client = try WsClient(configuration: .init(
                endpoint: credentials.node.endpoint,
                security: .mutualTLS(identity: credentials.identity.secIdentity, serverSPKIPin: pin,
                                     onServerSPKI: { _ in }),
                connectTimeout: timeout))
        } catch {
            return .inconclusive("The node's address \(credentials.node.endpoint) can't be used.")
        }
        defer { Task { await client.close() } }
        do {
            _ = try await client.send(ServerIdentityAnnouncement.self, payload: WsNoPayload(), timeout: timeout)
            return .accepted
        } catch {
            if DeviceRefusal(error) == .deviceUnknown { return .refused }
            if tryingNext, case .failed = await client.connectionState,
               let next = credentials.node.nextServerSPKISHA256, next != pin {
                // The server may have switched to the key it announced.
                await client.close()
                return await check(credentials, pin: next, timeout: timeout, tryingNext: false)
            }
            return .inconclusive(error.message)
        }
    }
}
