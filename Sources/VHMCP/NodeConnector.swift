import Foundation
import Synchronization
import VHIdentity
public import VHContract
public import VHCore
public import VHNodes
public import VHTransport

/// One node's `/mcp` endpoint: POSTs one JSON-RPC message, returns the HTTP status and the decoded body (nil for
/// 202 and other empty answers). ``DeviceHTTPClient`` is the real one; tests may stand in their own.
public protocol NodeMCPTransport: Sendable {
    func post(_ message: JSONValue, protocolVersion: String?) async throws(DeviceHTTPError)
        -> (status: Int, body: JSONValue?)
    /// Cancels requests in flight and releases the connection.
    func invalidate()
}

extension DeviceHTTPClient: NodeMCPTransport {
    public func post(_ message: JSONValue, protocolVersion: String?) async throws(DeviceHTTPError)
        -> (status: Int, body: JSONValue?)
    {
        try await mcp(message, protocolVersion: protocolVersion)
    }
}

/// Why the bridge has no transport to a node.
public enum NodeConnectFailure: Error, Hashable, Sendable {
    case notPaired
    case revoked
    /// This Mac's key for the node isn't in the Keychain (pair again in Vaulthalla).
    case missingKey
    /// The Keychain refused the lookup (for a development build's file-keychain key: the access prompt was denied).
    case keychain(String)
    case invalidAddress
    /// The node registry can't be read.
    case registry(String)

    /// The consumer's failure in the bridge's terms.
    public init(_ failure: CredentialFailure) {
        switch failure {
        case .unknownNode, .notPaired: self = .notPaired
        case .revoked: self = .revoked
        case .missingKey: self = .missingKey
        case .keychain(let detail): self = .keychain(detail)
        case .registry(let detail): self = .registry(detail)
        }
    }

    public var message: String {
        switch self {
        case .notPaired: "This Mac isn't paired with the node yet. Pair it in Vaulthalla."
        case .revoked: "The node revoked this Mac. Pair it again in Vaulthalla."
        case .missingKey: "This Mac's key for the node is missing. Pair it again in Vaulthalla."
        case .keychain(let detail): "This Mac's key for the node can't be read (\(detail))."
        case .invalidAddress: "The node's address can't be used."
        case .registry(let detail): "The saved node list can't be read (\(detail))."
        }
    }
}

/// Makes the transport for a node.
public protocol NodeMCPConnector: Sendable {
    /// A transport presenting this Mac's identity for `node` and pinning the server's key. `idleTimeout` is how long
    /// a request may wait for the server to say anything.
    func connect(_ node: Node, idleTimeout: Duration) async throws(NodeConnectFailure) -> any NodeMCPTransport

    /// The node refused the last transport made for it (HTTP 403): the owner may have rotated this Mac's key or
    /// promoted a server pin since. Re-reads the credentials and makes a transport with them; returns the record it
    /// used, which may be newer than `node`. The default connects again with `node`.
    func reconnect(afterRefusalOf node: Node, idleTimeout: Duration) async throws(NodeConnectFailure)
        -> (transport: any NodeMCPTransport, node: Node)

    /// Whether the node announced `capability` in `meta.hello` (``NodeProtocol``): the bridge asks for `device.mcp`
    /// when `/mcp` answers 404, to tell a node without remote MCP from a refusal. Unknown for a legacy node, or when
    /// the node couldn't be asked; the default is unknown.
    func support(for capability: WsCapability, of node: Node) async -> ProtocolSupport
}

extension NodeMCPConnector {
    /// No negotiation: unknown, so a missing `/mcp` reads as before (an older daemon).
    public func support(for capability: WsCapability, of node: Node) async -> ProtocolSupport {
        .unknown
    }

    public func reconnect(afterRefusalOf node: Node, idleTimeout: Duration) async throws(NodeConnectFailure)
        -> (transport: any NodeMCPTransport, node: Node)
    {
        (try await connect(node, idleTimeout: idleTimeout), node)
    }
}

/// The app's trust: the device identity the credential owner created for the node (``DeviceKeys``: Secure Enclave in
/// the data protection keychain, or a development build's software key in the file keychain) and the server pins from
/// the node registry. A consumer (docs/architecture.md §3, "Credential ownership"): it reads both through a
/// ``CredentialReader`` and creates, rotates, deletes and writes nothing. After a refusal it reloads the record and
/// the Keychain and presents the newest key that isn't the refused one (the owner's rotated key).
public struct KeychainNodeConnector: NodeMCPConnector {
    public let reader: CredentialReader
    public var keys: DeviceKeys { reader.keys }

    /// The device id last presented to each node, to tell the refused key from a newer one.
    private final class Presented: Sendable {
        let ids = Mutex<[NodeID: String]>([:])
    }
    private let presented = Presented()

    /// `registry`: where a reconnect after a refusal re-reads the record (nil: the bridge's record is used as given).
    public init(keys: DeviceKeys, registry: NodeStore? = nil) {
        self.reader = CredentialReader(registry: registry, keys: keys)
    }

    public func connect(_ node: Node, idleTimeout: Duration) async throws(NodeConnectFailure)
        -> any NodeMCPTransport
    {
        let credentials: NodeCredentials
        do {
            credentials = try await reader.load(node)
        } catch {
            throw NodeConnectFailure(error)
        }
        return try transport(credentials, idleTimeout: idleTimeout)
    }

    public func reconnect(afterRefusalOf node: Node, idleTimeout: Duration) async throws(NodeConnectFailure)
        -> (transport: any NodeMCPTransport, node: Node)
    {
        let refused = presented.ids.withLock { $0[node.id] }
        let credentials: NodeCredentials
        do {
            credentials = try await reader.reload(node, refusing: refused)
        } catch {
            throw NodeConnectFailure(error)
        }
        return (try transport(credentials, idleTimeout: idleTimeout), credentials.node)
    }

    /// One ws connection with the saved credentials and `meta.hello` (``CredentialReader/negotiate(_:timeout:)``).
    public func support(for capability: WsCapability, of node: Node) async -> ProtocolSupport {
        guard let credentials = try? await reader.load(node),
              let settled = await reader.negotiate(credentials)
        else { return .unknown }
        return settled.supports(capability: capability)
    }

    private func transport(_ credentials: NodeCredentials, idleTimeout: Duration) throws(NodeConnectFailure)
        -> any NodeMCPTransport
    {
        let made: DeviceHTTPClient
        do {
            made = try DeviceHTTPClient(configuration: credentials.laneConfiguration(timeout: idleTimeout))
        } catch {
            throw .invalidAddress
        }
        presented.ids.withLock { $0[credentials.node.id] = credentials.identity.deviceID }
        return made
    }
}
