import Foundation
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

    public var message: String {
        switch self {
        case .notPaired: "This Mac isn't paired with the node yet. Pair it in Vaulthalla."
        case .revoked: "The node revoked this Mac. Pair it again in Vaulthalla."
        case .missingKey: "This Mac's key for the node is missing. Pair it again in Vaulthalla."
        case .keychain(let detail): "This Mac's key for the node can't be read (\(detail))."
        case .invalidAddress: "The node's address can't be used."
        }
    }
}

/// Makes the transport for a node.
public protocol NodeMCPConnector: Sendable {
    /// A transport presenting this Mac's identity for `node` and pinning the server's key. `idleTimeout` is how long
    /// a request may wait for the server to say anything.
    func connect(_ node: Node, idleTimeout: Duration) async throws(NodeConnectFailure) -> any NodeMCPTransport
}

/// The app's trust: the device identity the app created for the node (``DeviceKeys``: Secure Enclave in the data
/// protection keychain, or a development build's software key in the file keychain) and the server pins from the
/// node registry. Nothing here creates, rotates or deletes a key.
public struct KeychainNodeConnector: NodeMCPConnector {
    public let keys: DeviceKeys

    public init(keys: DeviceKeys) {
        self.keys = keys
    }

    public func connect(_ node: Node, idleTimeout: Duration) async throws(NodeConnectFailure)
        -> any NodeMCPTransport
    {
        let pin: Data
        switch node.pairing {
        case .paired(let serverSPKISHA256, _, _): pin = serverSPKISHA256
        case .revoked: throw .revoked
        case .unpaired, .pending: throw .notPaired
        }
        let identity: DeviceIdentity
        do {
            guard let found = try await keys.identity(for: node.id.rawValue) else { throw NodeConnectFailure.missingKey }
            identity = found
        } catch let failure as NodeConnectFailure {
            throw failure
        } catch {
            throw .keychain(String(describing: error))
        }
        do {
            return try DeviceHTTPClient(configuration: .init(
                endpoint: node.endpoint, identity: identity.secIdentity, serverSPKIPin: pin,
                nextServerSPKIPin: node.nextServerSPKISHA256, timeout: idleTimeout))
        } catch {
            throw .invalidAddress
        }
    }
}
