public import VHCore
public import VHTransport

extension NodeSession {
    /// The device listener's HTTP lanes as the current connection reaches them: the selected endpoint
    /// (``activeEndpoint``), this Mac's identity for the node and the server's pinned key (and the announced next one).
    /// nil until a connection has picked its identity.
    ///
    /// Fetch it per transfer batch: a key rotation replaces the identity, and a new selection may move the endpoint.
    /// Key a cached client by ``laneIdentityID`` and ``laneEndpoint`` together.
    public func laneConfiguration(timeout: Duration = .seconds(30)) -> DeviceHTTPClient.Configuration? {
        guard let identity, case .paired(let pin, _, _) = node.pairing else { return nil }
        return DeviceHTTPClient.Configuration(
            endpoint: activeEndpoint, identity: identity.secIdentity, serverSPKIPin: pin,
            nextServerSPKIPin: node.nextServerSPKISHA256, timeout: timeout)
    }

    /// The endpoint ``laneConfiguration(timeout:)`` uses now.
    public var laneEndpoint: NodeEndpoint { activeEndpoint }

    /// The identity's device id, to tell whether a lanes client made earlier still presents the current key.
    public var laneIdentityID: String? { identity?.deviceID }

    /// A lane failed with a connection-class error on `endpoint`: selects again (``laneConnectionFailed()``) and waits
    /// up to `within` for the lanes to move to another endpoint (the server's transfer-protocol.md §2, "requests in
    /// flight are retried on the new endpoint"). Returns the lane configuration there, or nil when the route stayed
    /// (nothing else proves the key, the 5 s floor held the selection, or the wait ran out).
    public func rerouteLanes(awayFrom endpoint: NodeEndpoint, within: Duration = .seconds(15),
                             timeout: Duration = .seconds(30)) async -> DeviceHTTPClient.Configuration? {
        laneConnectionFailed()
        let deadline = ContinuousClock.now + within
        while activeEndpoint == endpoint {
            guard ContinuousClock.now < deadline else { return nil }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return nil
            }
        }
        return laneConfiguration(timeout: timeout)
    }
}
