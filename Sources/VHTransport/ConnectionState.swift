public import VHContract
import Synchronization

/// Where a `WsClient`'s connection stands.
public enum ConnectionState: Hashable, Sendable {
    /// Not connecting: never asked to, or `close()`d.
    case idle
    /// An attempt is under way (the first one, or a retry after `reconnecting`).
    case connecting
    case connected
    /// The connection dropped or an attempt failed; the next attempt (1-based) starts after the delay, or sooner when
    /// the network changes.
    case reconnecting(attempt: Int, after: Duration)
    /// The client gave up and won't retry on its own: the server's identity didn't match the pin, or the
    /// configuration can't work. `connect()` tries again.
    case failed(reason: String)
}

/// Exponential backoff with jitter between reconnect attempts: attempt n waits a random time between half and all of
/// `min(cap, base × 2ⁿ⁻¹)`, so many clients dropped together don't come back in lockstep.
public struct ReconnectPolicy: Hashable, Sendable {
    public var base: Duration
    public var cap: Duration

    public init(base: Duration = .milliseconds(500), cap: Duration = .seconds(30)) {
        self.base = base
        self.cap = cap
    }

    public func delay(attempt: Int) -> Duration {
        let exponent = min(max(attempt - 1, 0), 30)
        let ceiling = min(cap, base * (1 << exponent))
        return ceiling / 2 + ceiling / 2 * Double.random(in: 0...1)
    }
}

/// A frame no pending request claimed: a server notice (no `requestId`), the parse-error frame, or the late answer
/// to a request that already timed out or was cancelled (its `requestId` is set).
public struct UnsolicitedMessage: Sendable {
    /// The frame's `command` ("error" for parse errors, "<cmd>.response" for late answers); empty when absent.
    public var command: String
    public var status: String?
    public var requestId: String?
    public var data: JSONValue?
    /// `error`, or the parse-error frame's `message`.
    public var message: String?
    /// The whole frame. It can hold user data: never log it.
    public var frame: JSONValue
}

/// The envelope `token` slot. Device sessions authenticate by their certificate and leave it empty; a
/// password-session path (development against a daemon without the device listener) can fill it. When set, every
/// request carries it, and a token the daemon returns in a response envelope replaces it.
public final class TokenStore: Sendable {
    private let value: Mutex<String?>

    public init(token: String? = nil) {
        value = Mutex(token)
    }

    public var token: String? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
