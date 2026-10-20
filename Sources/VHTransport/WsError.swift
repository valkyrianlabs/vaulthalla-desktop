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
    /// `refusalCodes`, `message` the question to ask. Resend with the matching acceptance after the human agrees.
    case needsConfirmation(code: String, message: String)
    /// Any other failure: a fault, a rate limit, an unknown command.
    case error(String)
    /// No answer yet. The daemon may still be working on it, so this never means "failed" and callers must not
    /// blindly resend. A late answer arrives on the unsolicited stream.
    case timeout
    /// No connection: lost while waiting for the answer, or not established in time.
    case disconnected
    /// The calling task was cancelled. The request is forgotten; the daemon may still run it.
    case cancelled
    /// The answer's `data` doesn't decode as the contract says (the daemon runs another contract; compare
    /// `meta.contract.get`'s `ws_hash` with `WsContract.wsHash`).
    case contractMismatch(String)

    /// The text to show for a refusal, or a fixed one for the local kinds.
    public var message: String {
        switch self {
        case .unauthorized(let text), .denied(let text), .notFound(let text), .invalid(let text), .conflict(let text),
             .error(let text), .needsConfirmation(_, let text):
            text
        case .timeout: "The server has not answered yet. It may still be working on this."
        case .disconnected: "Not connected to the server."
        case .cancelled: "Request cancelled."
        case .contractMismatch: "The server answered in a shape this version of Vaulthalla doesn't understand."
        }
    }
}

extension WsError {
    /// Maps a response envelope's status, error text and `data.code` the way the web console does.
    static func classify(status: String?, error: String?, code: String?) -> WsError? {
        let status = status?.uppercased() ?? ""
        // A frame with a requestId but no status is an answer, as on the web.
        if status.isEmpty || status == "OK" || status == "SUCCESS" { return nil }

        let text = error.flatMap { $0.isEmpty ? nil : $0 } ?? "The server refused the request"
        if status == "UNAUTHORIZED" { return .unauthorized(text) }
        switch code {
        case "denied": return .denied(text)
        case "not_found": return .notFound(text)
        case "invalid": return .invalid(text)
        case "conflict": return .conflict(text)
        case .some(let code) where !code.isEmpty: return .needsConfirmation(code: code, message: text)
        default:
            // Handlers that refuse without a code (the contract's `untyped_refusals`) still word denials stably.
            return text.contains(deniedText) ? .denied(text) : .error(text)
        }
    }

    private static var deniedText: Regex<Substring> {
        #/(?:permission|not allowed|must be an admin|forbidden|access denied|not authori[sz]ed to)/#.ignoresCase()
    }
}
