/// A command of the daemon's ws contract, tying its `WsCommand` to the payload it takes and the `data` it answers
/// with. Generated per command (`Ws.Auth.Login`, `Ws.Fs.List`, ...) and never instantiated: transport takes the
/// metatype, `client.send(Ws.Meta.Contract.Get.self)`.
public protocol WsRequest: Sendable {
    associatedtype Payload: Encodable & Sendable
    associatedtype Response: Decodable & Sendable
    static var command: WsCommand { get }
}

/// What a session must be before the daemon's router runs a command (core/usage `WsCommandUsage::auth`).
public enum WsAuth: String, Sendable, CaseIterable {
    /// No session needed.
    case `public`
    /// Any socket: the session lifecycle commands.
    case session
    /// A signed-in user (or, on the device listener, a paired device acting as its user).
    case human
    /// A share-link session.
    case share
    /// A pairing-only connection on the device listener: a certificate the daemon doesn't know yet (docs/pairing.md §2).
    case pairing
    /// A paired device's own session on the device listener (key rotation, server identity).
    case device
    /// Every session, signed in or not, pairing-only included (`meta.hello`).
    case any
}

/// The payload of a command whose handler reads nothing from it (contract input `none` or `token`). It is sent as
/// JSON null, as the web console does.
public struct WsNoPayload: Codable, Hashable, Sendable {
    public init() {}

    public init(from decoder: any Decoder) throws {}

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

/// An empty JSON object: the payload of a command that takes one with no members, or a response without data (the
/// daemon leaves `data` out of the envelope then).
public struct WsEmpty: Codable, Hashable, Sendable {
    public init() {}

    public init(from decoder: any Decoder) throws {
        _ = try decoder.container(keyedBy: NoKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        _ = encoder.container(keyedBy: NoKeys.self)
    }

    private enum NoKeys: CodingKey {}
}
