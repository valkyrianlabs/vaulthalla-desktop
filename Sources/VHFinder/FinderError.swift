import Foundation
public import VHNodes
public import VHTransport

/// Why a File Provider call failed, in the File Provider's terms (`NSFileProviderError`, a Cocoa permission error, or
/// a transient failure the system retries). The extension turns each case into the `NSError` the system expects;
/// ``posixCode`` is the underlying error a POSIX caller sees.
///
/// The server decides; this only translates its refusals (``init(_:during:)-(WsError,_)``,
/// ``init(_:during:)-(TransferError,_)``) and the credential consumer's (``init(_:)``).
public enum FinderError: Error, Hashable, Sendable, CustomStringConvertible {
    /// This Mac can't act for the node: not paired, revoked (a refusal that survived reloading the credentials), the
    /// key missing, or the server's key not the pinned one. Fail closed; the system backs off until signalled.
    case notAuthenticated(String)
    /// No connection to the node, or it didn't answer in time. The system retries.
    case serverUnreachable(String)
    /// The item isn't on the server (or not visible to this account any more).
    case noSuchItem
    /// Something with that name is already there.
    case filenameCollision
    case insufficientQuota
    /// The server refused this change, and asking again won't help until something else changes (a permission, a
    /// name the server refuses, a request it can't take). The system shows it and backs off until signalled.
    case cannotSynchronize(String)
    /// Reading refused by the server's access rules (`NSFileReadNoPermissionError`).
    case readNotPermitted(String)
    /// The server refused a delete (or the item changed there since the system's base): the system puts it back.
    case deletionRejected(String)
    /// A non-recursive delete of a folder that isn't empty.
    case directoryNotEmpty
    /// The version asked for isn't the server's any more (a strictly versioned partial read).
    case versionNoLongerAvailable
    /// The upload's base version isn't the server's (the system's fail-on-conflict flow).
    case localVersionConflictingWithServer
    /// The anchor or page isn't this replica's (rebuilt, or from another store): the system re-enumerates.
    case syncAnchorExpired
    /// The item is kept on this Mac only and never sent (symlinks created locally, `.DS_Store`).
    case excludedFromSync
    case cancelled
    /// Anything else; the system retries it.
    case transient(String)

    public var description: String {
        switch self {
        case .notAuthenticated(let why): "not authenticated: \(why)"
        case .serverUnreachable(let why): "server unreachable: \(why)"
        case .noSuchItem: "no such item"
        case .filenameCollision: "filename collision"
        case .insufficientQuota: "insufficient quota"
        case .cannotSynchronize(let why): "cannot synchronize: \(why)"
        case .readNotPermitted(let why): "read not permitted: \(why)"
        case .deletionRejected(let why): "deletion rejected: \(why)"
        case .directoryNotEmpty: "directory not empty"
        case .versionNoLongerAvailable: "version no longer available"
        case .localVersionConflictingWithServer: "local version conflicts with the server's"
        case .syncAnchorExpired: "sync anchor expired"
        case .excludedFromSync: "excluded from sync"
        case .cancelled: "cancelled"
        case .transient(let why): "transient: \(why)"
        }
    }

    /// The errno a POSIX reader or writer sees underneath.
    public var posixCode: Int32 {
        switch self {
        case .notAuthenticated, .readNotPermitted, .deletionRejected: EACCES
        case .serverUnreachable: ETIMEDOUT
        case .noSuchItem: ENOENT
        case .directoryNotEmpty: ENOTEMPTY
        case .filenameCollision: EEXIST
        case .insufficientQuota: ENOSPC
        case .cannotSynchronize: EPERM
        case .versionNoLongerAvailable, .localVersionConflictingWithServer, .syncAnchorExpired: ESTALE
        case .excludedFromSync: ENOTSUP
        case .cancelled: ECANCELED
        case .transient: EIO
        }
    }

    /// What the system was doing, which decides how a refusal reads (a denied read and a denied write are
    /// different File Provider errors).
    public enum Operation: Hashable, Sendable {
        case read, write, delete
    }

    /// A ws refusal or failure.
    public init(_ error: WsError, during operation: Operation) {
        switch error {
        case .unauthorized(let text): self = .notAuthenticated(text)
        case .denied(let text):
            self = switch operation {
            case .read: .readNotPermitted(text)
            case .write: .cannotSynchronize(text)
            case .delete: .deletionRejected(text)
            }
        case .notFound: self = .noSuchItem
        case .conflict: self = .filenameCollision
        case .invalid(let text), .contractMismatch(let text): self = .cannotSynchronize(text)
        case .needsConfirmation(_, let text), .refused(_, let text):
            // `device_unknown`: the node refused this key. The credential consumer reloads and decides; until then
            // this Mac can't act for the node.
            self = DeviceRefusal(error) == .deviceUnknown ? .notAuthenticated(text) : .cannotSynchronize(text)
        case .unknownCommand(let text): self = .cannotSynchronize(text)
        case .protocolUnsupported: self = .cannotSynchronize(error.message)
        case .timeout: self = .serverUnreachable(error.message)
        case .disconnected: self = .serverUnreachable(error.message)
        case .cancelled: self = .cancelled
        case .error(let text): self = .transient(text)
        }
    }

    /// An HTTP lane failure. A 403 reaching here was already told apart from a revocation (``NodeLink``): it is the
    /// account's access.
    public init(_ error: TransferError, during operation: Operation) {
        switch error {
        case .forbidden:
            self = switch operation {
            case .read: .readNotPermitted(error.message)
            case .write: .cannotSynchronize(error.message)
            case .delete: .deletionRejected(error.message)
            }
        case .notFound: self = .noSuchItem
        case .alreadyExists: self = .filenameCollision
        case .quotaExceeded: self = .insufficientQuota
        case .tooManyEntries: self = .cannotSynchronize(error.message)
        case .busy, .connection, .timeout: self = .serverUnreachable(error.message)
        case .pinMismatch: self = .notAuthenticated(error.message)
        case .cancelled: self = .cancelled
        case .disk(let detail): self = .transient(detail)
        case .unexpectedAnswer(let detail): self = .transient(detail)
        case .laneUnavailable, .protocolUnsupported, .fileTooLarge: self = .cannotSynchronize(error.message)
        // A precondition that reaches here wasn't the replica's own check (which reads it as a conflict).
        case .preconditionFailed: self = .filenameCollision
        // Sending the file again works: the system retries.
        case .integrity, .keyRotated, .uploadExpired, .sourceChanged: self = .transient(error.message)
        case .status(let code, let text):
            if code >= 500 || code == 408 {
                self = .transient(error.message)
            } else if code == 416 {
                self = .versionNoLongerAvailable
            } else {
                // 400, 411, 413 (too large for the server), 428: asking again the same way won't help.
                self = .cannotSynchronize(text.isEmpty ? error.message : text)
            }
        }
    }

    /// A credential consumer's failure: every one means this Mac can't present a key the node accepts.
    public init(_ failure: CredentialFailure) {
        self = .notAuthenticated(failure.description)
    }

    /// Any error from below, as one of these.
    public static func from(_ error: any Error, during operation: Operation) -> FinderError {
        switch error {
        case let error as FinderError: error
        case let error as WsError: FinderError(error, during: operation)
        case let error as TransferError: FinderError(error, during: operation)
        case let error as CredentialFailure: FinderError(error)
        case is CancellationError: .cancelled
        default: .transient(String(describing: error))
        }
    }
}
