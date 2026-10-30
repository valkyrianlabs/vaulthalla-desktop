import Foundation
public import VHContract

/// Why a transfer on the device listener's HTTP lanes stopped, in terms a person can act on.
public enum TransferError: Error, Hashable, Sendable {
    /// The node answered 403: the account this Mac acts for may not do this, or this Mac isn't paired any more.
    case forbidden
    /// 404: the item isn't there any more.
    case notFound
    /// 413 on a folder download: more entries than one ZIP may hold.
    case tooManyEntries
    /// 409, or the upload coordinator's "already exists": a file with that name is already in the folder.
    case alreadyExists
    /// The upload is larger than the vault has room for.
    case quotaExceeded
    /// 429 or 503: the node is busy.
    case busy
    /// Any other answer outside 2xx, with the node's own words when it sent a short text.
    case status(Int, String)
    /// The node's key doesn't match the pinned one.
    case pinMismatch
    /// No connection, or it dropped.
    case connection(String)
    case timeout
    case cancelled
    /// Reading or writing a local file failed.
    case disk(String)
    /// The node's answer couldn't be read (a JSON body without the expected members).
    case unexpectedAnswer(String)
    /// The node's Vaulthalla doesn't serve this lane to devices (its `meta.hello` doesn't announce the lane's
    /// capability), so a 404 there means the lane is missing, not the item.
    case laneUnavailable(Lane)
    /// The node and this build share no protocol version; nothing was sent.
    case protocolUnsupported(String)

    /// The device listener's HTTP lanes, each announced by a capability.
    public enum Lane: String, Hashable, Sendable, CaseIterable {
        case preview, download, upload

        /// The `meta.hello` capability that says the node serves it.
        public var capability: WsCapability {
            switch self {
            case .preview: .previewLane
            case .download: .downloadLane
            case .upload: .uploadLane
            }
        }

        var noun: String {
            switch self {
            case .preview: "previews"
            case .download: "downloads"
            case .upload: "uploads"
            }
        }
    }

    /// The sentence for the Transfers panel.
    public var message: String {
        switch self {
        case .forbidden: "Not allowed. The account this Mac acts for may not do this, or this Mac was unpaired."
        case .notFound: "This item no longer exists."
        case .tooManyEntries: "This folder has too many items to download as one archive. Download its subfolders instead."
        case .alreadyExists: "A file with that name already exists here."
        case .quotaExceeded: "This upload is larger than the vault has room for."
        case .busy: "The server is busy. Try again in a moment."
        case .status(let code, let text): text.isEmpty ? "The server refused the transfer (HTTP \(code))." : text
        case .pinMismatch: "The server's identity doesn't match the one this Mac paired with."
        case .connection(let detail): "The connection to the server failed (\(detail))."
        case .timeout: "The server stopped answering."
        case .cancelled: "Cancelled."
        case .disk(let detail): "The file couldn't be written or read on this Mac (\(detail))."
        case .unexpectedAnswer(let detail): "The server's answer couldn't be read (\(detail))."
        case .laneUnavailable(let lane):
            "This node's Vaulthalla doesn't serve \(lane.noun) to Desktop. Update Vaulthalla on the node."
        case .protocolUnsupported(let message): message
        }
    }

    /// Whether trying again soon may work: connection trouble, timeouts, a busy node or a server fault.
    public var isRetryable: Bool {
        switch self {
        case .connection, .timeout, .busy: true
        case .status(let code, _): code >= 500 || code == 408
        default: false
        }
    }

    init(_ error: DeviceHTTPError) {
        switch error {
        case .pinMismatch: self = .pinMismatch
        case .forbidden: self = .forbidden
        case .transport(let detail): self = .connection(detail)
        case .timeout: self = .timeout
        case .cancelled: self = .cancelled
        case .invalidURL: self = .connection("the node's address can't be used")
        }
    }

    /// A lane failure read against what the node announced for `lane`: when it is known not to serve the lane, a 404
    /// (and anything else that only says "not here") is ``laneUnavailable(_:)``. Known to serve it, or unknown (a
    /// legacy node), the failure stands: a 404 is the item.
    public func interpreted(for lane: Lane, support: ProtocolSupport) -> TransferError {
        guard support == .no else { return self }
        switch self {
        case .notFound, .status(404, _), .status(405, _), .status(501, _): return .laneUnavailable(lane)
        default: return self
        }
    }

    /// Maps a non-2xx answer. `body` is the node's text (`makeErrorResponse` writes the reason as the body).
    static func answer(status: Int, body: Data, isDirectory: Bool = false) -> TransferError {
        let text = Self.text(body)
        let lower = text.lowercased()
        if lower.contains("already exists") { return .alreadyExists }
        if lower.contains("exceeds") && (lower.contains("quota") || lower.contains("available vault storage")) {
            return .quotaExceeded
        }
        switch status {
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .alreadyExists
        case 413 where isDirectory: return .tooManyEntries
        case 429, 503: return .busy
        default:
            if lower.contains("session not found") {
                return .status(status, "The upload session expired on the server. Try again.")
            }
            return .status(status, text)
        }
    }

    /// The node's error text when it's short enough to be a sentence: plain text, or a JSON `error`/`message`.
    static func text(_ body: Data) -> String {
        guard !body.isEmpty, body.count < 2048 else { return "" }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            for key in ["error", "message"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
            return ""
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count < 400 ? text : ""
    }
}
