import VHContract

/// Why a ws request didn't produce a response, with the web console's error kinds (web/src/lib/ws/errors.ts).
/// Server refusals carry the daemon's message, which is written for the user.
public enum WsError: Error, Hashable, Sendable {
    /// The router refused before running the command (no or expired session). Safe to retry after re-auth.
    case unauthorized(String)
    /// Authenticated, but RBAC said no (`data.code` "denied").
    case denied(String)
    case notFound(String)
    case invalid(String)
    case conflict(String)
    /// The operation wants an explicit acceptance first (`ops::NeedsConfirmation`): `code` is one of the command's
    /// `confirmations`, `message` the question to ask. Resend with the matching acceptance after the human agrees.
    case needsConfirmation(code: String, message: String)
    /// A typed refusal whose `data.code` is neither a kind above nor a confirmation the command declares: a
    /// command-specific code (`device_unknown`, `rate_limited`, `export_requires_device`, ...) or one a newer daemon
    /// added. `message` is the daemon's.
    case refused(code: String, message: String)
    /// The daemon doesn't have the command (`data.code` "unknown_command", daemons that announce
    /// `errors.unknown_command_code`). Legacy daemons say so only in words: test with ``isUnknownCommand``.
    case unknownCommand(String)
    /// The node and this build share no protocol version: `meta.hello` answered `protocol_unsupported`, or a feature
    /// call on a node known to be incompatible was refused here without being sent.
    case protocolUnsupported(ProtocolMismatch)
    /// Any other failure without a code: a fault, a rate limit, or a legacy daemon's unknown command.
    case error(String)
    /// No answer yet. The daemon may still be working on it, so this never means "failed" and callers must not
    /// blindly resend. A late answer arrives on the unsolicited stream.
    case timeout
    /// No connection: lost while waiting for the answer, or not established in time.
    case disconnected
    /// The calling task was cancelled. The request is forgotten; the daemon may still run it.
    case cancelled
    /// The answer's `data` doesn't decode as the contract says (the daemon runs another contract: `meta.hello`'s
    /// `contract` identity, or `meta.contract.get`'s `ws_hash`, differs from `WsContract.wsHash`).
    case contractMismatch(String)

    /// The text to show for a refusal, or a fixed one for the local kinds.
    public var message: String {
        switch self {
        case .unauthorized(let text), .denied(let text), .notFound(let text), .invalid(let text), .conflict(let text),
             .error(let text), .needsConfirmation(_, let text), .refused(_, let text), .unknownCommand(let text):
            text
        case .protocolUnsupported(let mismatch): mismatch.message
        case .timeout: "The server has not answered yet. It may still be working on this."
        case .disconnected: "Not connected to the server."
        case .cancelled: "Request cancelled."
        case .contractMismatch: "The server answered in a shape this version of Vaulthalla doesn't understand."
        }
    }

    /// The refusal's `data.code`: the kind for the typed kinds, the code for confirmations and other refusals; nil for
    /// untyped failures and the local kinds.
    public var code: String? {
        switch self {
        case .unauthorized: "unauthorized"
        case .denied: "denied"
        case .notFound: "not_found"
        case .invalid: "invalid"
        case .conflict: "conflict"
        case .needsConfirmation(let code, _), .refused(let code, _): code
        case .unknownCommand: "unknown_command"
        case .protocolUnsupported: "protocol_unsupported"
        case .error, .timeout, .disconnected, .cancelled, .contractMismatch: nil
        }
    }

    /// Whether the daemon doesn't have the command: the typed `unknown_command`, or a legacy daemon's words for it.
    /// The one place the words are matched (``isLegacyUnknownCommand(_:)``); feature code asks the node's
    /// `supports(command:)` first and falls back to this only while that is unknown.
    public var isUnknownCommand: Bool {
        switch self {
        case .unknownCommand: true
        case .error(let text), .notFound(let text), .invalid(let text): Self.isLegacyUnknownCommand(text)
        default: false
        }
    }

    /// A legacy daemon's (≤ 1.18.0) refusal of a command it doesn't have: the router answers ERROR "Unknown command"
    /// without a code; some older handlers said "unknown action" for a sub-command they lacked.
    public static func isLegacyUnknownCommand(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("unknown command")
            || text.localizedCaseInsensitiveContains("unknown action")
    }
}

/// The node and this build share no ws protocol version: the daemon's range and release (nil when it didn't say),
/// against ``WsProtocol/supported``.
public struct ProtocolMismatch: Hashable, Sendable {
    public var serverMin: Int?
    public var serverMax: Int?
    /// The daemon's release ("1.24.0").
    public var serverVersion: String?

    public init(serverMin: Int?, serverMax: Int?, serverVersion: String?) {
        self.serverMin = serverMin
        self.serverMax = serverMax
        self.serverVersion = serverVersion
    }

    /// Which side has to move.
    public enum Side: Hashable, Sendable {
        /// The daemon only speaks protocols newer than this build: update Vaulthalla Desktop.
        case desktopTooOld
        /// The daemon only speaks protocols older than this build: update Vaulthalla on the node.
        case serverTooOld
        /// The ranges don't say (missing or overlapping): neither side is clearly older.
        case unclear
    }

    public var side: Side {
        if let serverMin, serverMin > WsProtocol.maximum { return .desktopTooOld }
        if let serverMax, serverMax < WsProtocol.minimum { return .serverTooOld }
        return .unclear
    }

    /// "Vaulthalla 1.24.0", or "Vaulthalla" when the daemon didn't say.
    public var serverLabel: String {
        serverVersion.map { "Vaulthalla \($0)" } ?? "Vaulthalla"
    }

    /// The sentence for the overview and for refused feature calls.
    public var message: String {
        switch side {
        case .desktopTooOld:
            "This node runs \(serverLabel), which needs a newer Vaulthalla Desktop. Update Vaulthalla Desktop."
        case .serverTooOld:
            "This node runs \(serverLabel), which speaks an older protocol: update Vaulthalla on the node."
        case .unclear:
            "This node runs \(serverLabel), which shares no protocol version with this Vaulthalla Desktop "
                + "(it speaks \(serverRange), this app \(WsProtocol.minimum)–\(WsProtocol.maximum))."
        }
    }

    /// "2–3", or "?" when the daemon didn't say.
    private var serverRange: String {
        switch (serverMin, serverMax) {
        case (let low?, let high?): low == high ? "\(low)" : "\(low)–\(high)"
        case (let low?, nil): "\(low) and newer"
        case (nil, let high?): "up to \(high)"
        case (nil, nil): "an unknown range"
        }
    }
}

extension WsError {
    /// What an ERROR answer's `data` carries: the code and, for `protocol_unsupported`, the daemon's range.
    struct Refusal: Sendable {
        var code: String?
        var serverMin: Int?
        var serverMax: Int?
        var serverVersion: String?

        init(code: String?, serverMin: Int? = nil, serverMax: Int? = nil, serverVersion: String? = nil) {
            self.code = code
            self.serverMin = serverMin
            self.serverMax = serverMax
            self.serverVersion = serverVersion
        }
    }

    /// Maps a response envelope's status, error text and `data` the way the web console does. `command` decides
    /// which codes are confirmations: those the command declares (`WsCommand.confirmations`), or, for a command the
    /// contract doesn't type, those any command declares. Every other unrecognized code is ``refused(code:message:)``,
    /// never a question to put to a person.
    static func classify(status: String?, error: String?, refusal: Refusal?, command: String?) -> WsError? {
        let status = status?.uppercased() ?? ""
        // A frame with a requestId but no status is an answer, as on the web.
        if status.isEmpty || status == "OK" || status == "SUCCESS" { return nil }

        let text = error.flatMap { $0.isEmpty ? nil : $0 } ?? "The server refused the request"
        if status == "UNAUTHORIZED" { return .unauthorized(text) }
        switch refusal?.code {
        case "denied": return .denied(text)
        case "not_found": return .notFound(text)
        case "invalid": return .invalid(text)
        case "conflict": return .conflict(text)
        case "unknown_command": return .unknownCommand(text)
        case "protocol_unsupported":
            return .protocolUnsupported(ProtocolMismatch(serverMin: refusal?.serverMin, serverMax: refusal?.serverMax,
                                                         serverVersion: refusal?.serverVersion))
        case .some(let code) where !code.isEmpty:
            return isConfirmation(code, of: command) ? .needsConfirmation(code: code, message: text)
                : .refused(code: code, message: text)
        default:
            // Handlers that refuse without a code (the contract's `untyped_refusals`) still word denials stably.
            return text.contains(deniedText) ? .denied(text) : .error(text)
        }
    }

    /// Whether `code` is a NeedsConfirmation refusal of `command`.
    static func isConfirmation(_ code: String, of command: String?) -> Bool {
        if let typed = command.flatMap(WsCommand.init(rawValue:)) { return typed.confirmation(code) != nil }
        return allConfirmationCodes.contains(code)
    }

    /// Every confirmation code the contract declares, for commands it doesn't type.
    private static let allConfirmationCodes: Set<String> =
        Set(WsCommand.allCases.flatMap { $0.confirmations.map(\.code) })

    private static var deniedText: Regex<Substring> {
        #/(?:permission|not allowed|must be an admin|forbidden|access denied|not authori[sz]ed to)/#.ignoresCase()
    }
}
