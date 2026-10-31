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
    /// A conditional write's precondition failed (412 `precondition_failed`): the file changed since that version, or
    /// something is already at the path on create. `currentVersion` is the file's version now, when the node said.
    case preconditionFailed(currentVersion: String?)
    /// The bytes the node stored aren't the bytes this Mac sent (a part's SHA-256 differs, or the node's integrity
    /// check failed): the file wasn't kept.
    case integrity(String)
    /// The file is larger than the node accepts (413 `file_too_large`).
    case fileTooLarge
    /// The vault's key changed before the file was committed (`key_rotated`); uploading it again works.
    case keyRotated
    /// The resumable upload session is gone on the node (404: expired, cancelled, or never this device's).
    case uploadExpired
    /// The local file changed while it was uploading, so the parts already sent no longer match it.
    case sourceChanged(String)

    /// The device listener's HTTP lanes, each announced by a capability.
    public enum Lane: String, Hashable, Sendable, CaseIterable {
        case preview, download, upload
        /// The calibration routes (`/transfer/*`).
        case transfer

        /// The `meta.hello` capability that says the node serves it.
        public var capability: WsCapability {
            switch self {
            case .preview: .previewLane
            case .download: .downloadLane
            case .upload: .uploadLane
            case .transfer: .deviceLanesTransfer
            }
        }

        var noun: String {
            switch self {
            case .preview: "previews"
            case .download: "downloads"
            case .upload: "uploads"
            case .transfer: "connection tests"
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
        case .preconditionFailed: "The file changed on the server since this version."
        case .integrity(let name):
            "The server didn't receive \(name) exactly as it was sent, so it wasn't saved. Upload it again."
        case .fileTooLarge: "This file is larger than the server accepts."
        case .keyRotated: "The vault's key changed while the file was uploading. Upload it again."
        case .uploadExpired: "The upload expired on the server before it finished. Upload it again."
        case .sourceChanged(let name): "\(name) changed on this Mac while it was uploading."
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

    /// Maps a non-2xx answer of the resumable upload and transfer routes (`/upload/sessions`, `/transfer/*`), which
    /// always carry `{error: {code, message}}` (the server's docs/reference/transfer-protocol.md §3.7): by the code,
    /// never by the words. A body without a code falls back to the status alone.
    static func coded(status: Int, body: Data, etag: String? = nil) -> TransferError {
        let error = ServerErrorBody.decode(body)
        return coded(status: status, code: error?.code, message: error?.message, etag: error?.etag ?? etag)
    }

    /// One `{code, message}` (an answer's, or a file's `error` in a session status) as a transfer error.
    static func coded(status: Int?, code: String?, message: String?, etag: String? = nil) -> TransferError {
        let words = message.map { $0.count < 400 ? $0 : "" } ?? ""
        switch code {
        case "forbidden": return .forbidden
        case "not_found": return status == 404 ? .uploadExpired : .notFound
        case "already_exists", "conflict": return .alreadyExists
        case "precondition_failed": return .preconditionFailed(currentVersion: etag)
        case "quota_exceeded", "insufficient_storage": return .quotaExceeded
        case "file_too_large": return .fileTooLarge
        case "key_rotated": return .keyRotated
        case "integrity", "digest_mismatch": return .integrity(words.isEmpty ? "the file" : words)
        case "busy", "too_many_parts_in_flight", "too_many_requests": return .busy
        default: break
        }
        switch status {
        case 403: return .forbidden
        case 404: return .uploadExpired
        case 412: return .preconditionFailed(currentVersion: etag)
        case 413: return .fileTooLarge
        case 429, 503: return .busy
        case 507: return .quotaExceeded
        case let status?: return .status(status, words)
        case nil: return .status(500, words.isEmpty ? "The server couldn't save the file." : words)
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

/// The JSON error body of the resumable routes: `{"error": {"code": "...", "message": "...", "etag": "..."}}`.
struct ServerErrorBody: Decodable, Sendable {
    struct Detail: Decodable, Sendable {
        var code: String?
        var message: String?
        var etag: String?
    }
    var error: Detail?

    static func decode(_ body: Data) -> Detail? {
        guard !body.isEmpty, body.count < 65536 else { return nil }
        return (try? JSONDecoder().decode(ServerErrorBody.self, from: body))?.error
    }
}
