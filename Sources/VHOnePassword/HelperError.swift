/// The helper's stable error codes (Helpers/vaulthalla-1password/internal/backup/errors.go). A struct rather than
/// an enum so a newer helper's codes still decode.
public struct HelperErrorCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    // Protocol and requests.
    public static let badRequest = Self(rawValue: "bad_request")
    public static let unknownOp = Self(rawValue: "unknown_op")
    public static let lineTooLong = Self(rawValue: "line_too_long")
    public static let noSession = Self(rawValue: "no_session")
    public static let `internal` = Self(rawValue: "internal")

    // 1Password connection and authorization.
    public static let integrationDisabled = Self(rawValue: "integration_disabled")
    public static let appNotRunning = Self(rawValue: "app_not_running")
    public static let appNotInstalled = Self(rawValue: "app_not_installed")
    public static let libraryBlocked = Self(rawValue: "library_blocked")
    public static let unsupportedBuild = Self(rawValue: "unsupported_build")
    public static let locked = Self(rawValue: "locked")
    public static let denied = Self(rawValue: "denied")
    public static let accountNotFound = Self(rawValue: "account_not_found")
    public static let accountSwitch = Self(rawValue: "account_switch")
    public static let sessionExpired = Self(rawValue: "session_expired")
    public static let rateLimited = Self(rawValue: "rate_limited")
    public static let onePassword = Self(rawValue: "onepassword_error")

    // Items.
    public static let notFound = Self(rawValue: "not_found")
    public static let ambiguousVault = Self(rawValue: "ambiguous_vault")
    public static let duplicateItem = Self(rawValue: "duplicate_item")
    public static let versionConflict = Self(rawValue: "version_conflict")
    public static let concurrentModification = Self(rawValue: "concurrent_modification")
    public static let verifyFailed = Self(rawValue: "verify_failed")
    /// A key doesn't match its key check (the helper computes checks; the app never does).
    public static let keyCheckMismatch = Self(rawValue: "key_check_mismatch")

    /// Codes the user fixes in 1Password itself (turn on the integration, open or unlock the app, approve).
    public var isUserActionable: Bool {
        [.integrationDisabled, .appNotRunning, .appNotInstalled, .locked, .denied, .accountNotFound].contains(self)
    }
}

public enum OnePasswordHelperError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The helper answered with an error. `hint` is user-facing; `detail` is 1Password's own (redacted) text.
    case refused(code: HelperErrorCode, message: String, hint: String?, detail: String?)
    /// No answer within the timeout. The helper was stopped; the next request starts a new one.
    case timeout(op: String)
    /// The helper exited before answering (crash or kill). The next request starts a new one.
    case exited(status: Int32?)
    /// The helper kept exiting; it isn't restarted again until `resetFailures()`.
    case crashLoop
    case launchFailed(String)
    /// The helper sent something that isn't the protocol.
    case protocolViolation(String)
    /// `close()` was called.
    case closed

    public var code: HelperErrorCode? {
        if case .refused(let code, _, _, _) = self { return code }
        return nil
    }

    public var description: String {
        switch self {
        case .refused(let code, let message, _, _): "1Password helper: \(message) [\(code)]"
        case .timeout(let op): "1Password helper: no answer to \(op) in time"
        case .exited(let status): "1Password helper exited\(status.map { " with status \($0)" } ?? "")"
        case .crashLoop: "1Password helper keeps exiting"
        case .launchFailed(let why): "1Password helper couldn't start: \(why)"
        case .protocolViolation(let why): "1Password helper protocol error: \(why)"
        case .closed: "1Password helper was closed"
        }
    }
}
