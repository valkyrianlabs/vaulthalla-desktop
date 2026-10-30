public import VHContract
public import VHCore
public import VHTransport

/// How a node's queries and mutations reach its daemon: one typed request, one typed answer or a `WsError`.
public protocol NodeTransport: Sendable {
    func send<R: WsRequest>(_ request: R.Type, payload: R.Payload) async throws(WsError) -> R.Response

    /// A command whose payload or answer carries key material (`WsClient.sendSensitive`): the payload's JSON in, the
    /// answer's whole frame out, both zeroing. Only a live Device session carries it.
    func sendSensitive(_ command: WsCommand, payload: SecretBytes) async throws(WsError) -> SecretBytes

    /// Whether the node has the command, as its session negotiated (`meta.hello`): ask before sending a command an
    /// older node may lack, and fall back to `WsError.isUnknownCommand` while it is unknown (a legacy node).
    func commandSupport(_ command: WsCommand) async -> ProtocolSupport
}

extension NodeTransport {
    /// Transports without a negotiation (previews, test stubs) don't know.
    public func commandSupport(_ command: WsCommand) async -> ProtocolSupport { .unknown }

    /// Transports that never carry key material (previews, test stubs) refuse.
    public func sendSensitive(_ command: WsCommand, payload: SecretBytes) async throws(WsError) -> SecretBytes {
        throw .error("This connection doesn't carry vault keys.")
    }
}

extension NodeSession: NodeTransport {
    /// Sends on the session's current connection, fetched per request because a key rotation replaces it.
    /// `.disconnected` while there is none; `.protocolUnsupported`, unsent, on a node this build can't speak to.
    public nonisolated func send<R: WsRequest>(_ request: R.Type, payload: R.Payload)
        async throws(WsError) -> R.Response
    {
        let client = try await featureClient()
        return try await client.send(request, payload: payload)
    }

    public nonisolated func commandSupport(_ command: WsCommand) async -> ProtocolSupport {
        await supports(command: command)
    }

    public nonisolated func sendSensitive(_ command: WsCommand, payload: SecretBytes) async throws(WsError) -> SecretBytes {
        let client = try await featureClient()
        return try await client.sendSensitive(command: command.rawValue, payload: payload, timeout: command.clientTimeout)
    }
}

/// The transport of a node whose session may be replaced (re-pairing, a changed address): it looks the session up
/// for every request, so a query store outlives the sessions behind it.
public struct SessionTransport: NodeTransport {
    private let session: @MainActor @Sendable () -> NodeSession?

    public init(_ session: @escaping @MainActor @Sendable () -> NodeSession?) {
        self.session = session
    }

    public func send<R: WsRequest>(_ request: R.Type, payload: R.Payload) async throws(WsError) -> R.Response {
        guard let session = await session() else { throw .disconnected }
        return try await session.send(request, payload: payload)
    }

    public func sendSensitive(_ command: WsCommand, payload: SecretBytes) async throws(WsError) -> SecretBytes {
        guard let session = await session() else { throw .disconnected }
        return try await session.sendSensitive(command, payload: payload)
    }

    public func commandSupport(_ command: WsCommand) async -> ProtocolSupport {
        guard let session = await session() else { return .unknown }
        return await session.supports(command: command)
    }
}
