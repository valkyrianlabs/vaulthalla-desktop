public import VHContract
public import VHTransport

/// How a node's queries and mutations reach its daemon: one typed request, one typed answer or a `WsError`.
public protocol NodeTransport: Sendable {
    func send<R: WsRequest>(_ request: R.Type, payload: R.Payload) async throws(WsError) -> R.Response
}

extension NodeSession: NodeTransport {
    /// Sends on the session's current connection, fetched per request because a key rotation replaces it.
    /// `.disconnected` while there is none.
    public nonisolated func send<R: WsRequest>(_ request: R.Type, payload: R.Payload)
        async throws(WsError) -> R.Response
    {
        guard let client = await client else { throw .disconnected }
        return try await client.send(request, payload: payload)
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
}
