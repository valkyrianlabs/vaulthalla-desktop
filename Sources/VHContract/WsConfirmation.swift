import Foundation

/// A NeedsConfirmation refusal a command declares (contract `confirmations`): the daemon answered ERROR with
/// `data.code` == `code` (`WsError.needsConfirmation(code:message:)`) because a person must accept something first.
/// Ask them (the error's message is the question), then resend with `acceptField` set.
public struct WsConfirmation: Hashable, Sendable {
    /// The refusal's `data.code`.
    public var code: String
    /// The payload member a resend sets to accept it, dotted for nested members (`provision.accept_adoption`). A
    /// boolean flag unless `summary` says otherwise (`recovery.restore` takes the plan's token). nil when no resend
    /// accepts it: `summary` says what to do instead (plan again, ...).
    public var acceptField: String?
    /// What the refusal means and how to accept it.
    public var summary: String

    public init(code: String, acceptField: String?, summary: String) {
        self.code = code
        self.acceptField = acceptField
        self.summary = summary
    }
}

/// Why an acceptance payload couldn't be built.
public enum WsAcceptanceError: Error, Hashable, Sendable {
    /// The command declares no confirmation with this code (another command's, or a newer daemon's).
    case unknownCode(command: WsCommand, code: String)
    /// No resend accepts this one; its `summary` says what to do instead.
    case notAcceptable(WsConfirmation)
    /// The payload isn't a JSON object along the accept field's path, or no longer decodes with it set.
    case payloadShape(String)
}

extension WsCommand {
    /// The confirmation the command declares for a refusal code (`WsError.needsConfirmation(code:message:)`).
    public func confirmation(_ code: String) -> WsConfirmation? {
        confirmations.first { $0.code == code }
    }

    /// The payload member (dotted path) a resend sets to accept the refusal `code`; nil when the command doesn't
    /// declare `code` or no resend accepts it.
    public func acceptField(for code: String) -> String? {
        confirmation(code)?.acceptField
    }

    /// `payload` with the acceptance for `code` set (`true`, or `value` for a member that takes something else).
    /// For raw payloads (`WsClient.send(command:payload:)`); typed requests use `WsRequest.payload(_:accepting:)`.
    public func payload(_ payload: JSONValue, accepting code: String, value: JSONValue = true)
        throws(WsAcceptanceError) -> JSONValue
    {
        guard let confirmation = confirmation(code) else { throw .unknownCode(command: self, code: code) }
        guard let field = confirmation.acceptField else { throw .notAcceptable(confirmation) }
        let path = field.split(separator: ".").map(String.init)
        guard let accepted = Self.setting(path[...], to: value, in: payload) else {
            throw .payloadShape("\(rawValue): \(field) can't be set in the payload")
        }
        return accepted
    }

    /// `value` at `path` inside `object`, creating the objects along the way.
    private static func setting(_ path: ArraySlice<String>, to value: JSONValue, in object: JSONValue) -> JSONValue? {
        guard let key = path.first, var members = object.objectValue else { return nil }
        if path.count == 1 {
            members[key] = value
        } else {
            guard let nested = setting(path.dropFirst(), to: value, in: members[key] ?? .object([:])) else { return nil }
            members[key] = nested
        }
        return .object(members)
    }
}

extension WsRequest where Payload: Decodable {
    /// The typed payload to resend once a person accepted the refusal `code`: `payload` with the command's accept
    /// field set (`true`, or `value` for a member that takes something else, such as `recovery.restore`'s token).
    ///
    ///     catch .needsConfirmation(let code, let question) where await ask(question) {
    ///         let accepted = try Ws.Auth.User.Delete.payload(payload, accepting: code)
    ///         try await client.send(Ws.Auth.User.Delete.self, payload: accepted)
    ///     }
    public static func payload(_ payload: Payload, accepting code: String, value: JSONValue = true)
        throws(WsAcceptanceError) -> Payload
    {
        let raw: JSONValue
        do {
            raw = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload))
        } catch {
            throw .payloadShape("\(command.rawValue): the payload doesn't encode")
        }
        let accepted = try command.payload(raw, accepting: code, value: value)
        do {
            return try JSONDecoder().decode(Payload.self, from: JSONEncoder().encode(accepted))
        } catch {
            throw .payloadShape("\(command.rawValue): the payload doesn't decode with the acceptance set")
        }
    }
}
