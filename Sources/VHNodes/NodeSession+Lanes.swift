public import VHTransport

extension NodeSession {
    /// The device listener's HTTP lanes as the current connection reaches them: this Mac's identity for the node and
    /// the server's pinned key (and the announced next one). nil until a connection has picked its identity.
    ///
    /// Fetch it per transfer batch: a key rotation replaces the identity, and the old one stops being accepted.
    public func laneConfiguration(timeout: Duration = .seconds(30)) -> DeviceHTTPClient.Configuration? {
        guard let identity, case .paired(let pin, _, _) = node.pairing else { return nil }
        return DeviceHTTPClient.Configuration(
            endpoint: node.endpoint, identity: identity.secIdentity, serverSPKIPin: pin,
            nextServerSPKIPin: node.nextServerSPKISHA256, timeout: timeout)
    }

    /// The identity's device id, to tell whether a lanes client made earlier still presents the current key.
    public var laneIdentityID: String? { identity?.deviceID }
}
