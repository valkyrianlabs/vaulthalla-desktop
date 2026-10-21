public import Foundation
public import Security
public import VHContract
public import VHCore
import Synchronization
import os

/// Why a device HTTP request produced no response.
public enum DeviceHTTPError: Error, Hashable, Sendable {
    /// The server's key isn't the pinned one (or its certificate didn't parse). Nothing was sent.
    case pinMismatch(observedSPKISHA256: Data?)
    /// The node answered 403: this key isn't a paired device (unknown or revoked: the daemon's `device_unknown`), or
    /// the device's user may not do this. URLSession doesn't hand over that response (see ``DeviceHTTPClient``), so
    /// its body isn't available; the Device session tells a revocation apart (`device_unknown` on reconnect).
    case forbidden
    /// No connection, or it dropped (including a refused client certificate).
    case transport(String)
    case timeout
    case cancelled
    /// The endpoint and path don't make a URL.
    case invalidURL

    public var message: String {
        switch self {
        case .pinMismatch: "The server's identity doesn't match the one this Mac paired with."
        case .forbidden: "The server refused the request: this Mac isn't paired with it, or the account may not do this."
        case .transport(let detail): "The connection to the server failed (\(detail))."
        case .timeout: "The server didn't answer in time."
        case .cancelled: "Request cancelled."
        case .invalidURL: "The node's address can't be used."
        }
    }
}

/// The device listener's HTTP routes (docs/architecture.md §2: `/download`, `/preview`, `/upload`, `/mcp`) over
/// URLSession, with the same trust as ``WsClient``: TLS 1.3, this device's `SecIdentity` as the client certificate,
/// and the server accepted by its SPKI SHA-256 alone (``CertificateSPKI``, no system trust store, no hostname check).
///
/// The session is ephemeral: no cookies, no cache, no credential storage. Call ``invalidate()`` when done; the
/// session holds its delegate (and the identity) until then.
///
/// Answers come back whatever their status, except 403: on a connection whose server asked for a client certificate,
/// URLSession reports an HTTP 403 as `NSURLErrorClientCertificateRequired` and drops the response (seen on macOS 27
/// against the daemon and the loopback test server alike). This client always presents its identity, so that error
/// after presenting it is the node's 403 and becomes ``DeviceHTTPError/forbidden``.
public final class DeviceHTTPClient: Sendable {
    public struct Configuration: Sendable {
        public var endpoint: NodeEndpoint
        /// The device identity. `@unchecked` in `TransportSecurity` for the same reason: an immutable CF reference.
        public var identity: SecIdentity { identityBox.value }
        /// The pinned server SPKI hash, and the announced next one (docs/pairing.md §5) if any.
        public var serverSPKIPins: [Data]
        /// Per request: how long the server may stay silent.
        public var timeout: Duration

        let identityBox: IdentityBox

        public init(endpoint: NodeEndpoint, identity: SecIdentity, serverSPKIPin: Data, nextServerSPKIPin: Data? = nil,
                    timeout: Duration = .seconds(30)) {
            self.endpoint = endpoint
            self.identityBox = IdentityBox(identity)
            self.serverSPKIPins = [serverSPKIPin] + (nextServerSPKIPin.map { [$0] } ?? [])
            self.timeout = timeout
        }
    }

    public let configuration: Configuration
    private let session: URLSession
    private let trust: TrustDelegate
    private let baseURL: URL

    public init(configuration: Configuration) throws(DeviceHTTPError) {
        let host = configuration.endpoint.host
        let authority = host.contains(":") ? "[\(host)]" : host
        guard let base = URL(string: "https://\(authority):\(configuration.endpoint.port)") else { throw .invalidURL }
        let seconds = Double(configuration.timeout.components.seconds)
            + Double(configuration.timeout.components.attoseconds) / 1e18

        let settings = URLSessionConfiguration.ephemeral
        settings.tlsMinimumSupportedProtocolVersion = .TLSv13
        settings.urlCache = nil
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.urlCredentialStorage = nil
        settings.timeoutIntervalForRequest = seconds
        settings.waitsForConnectivity = false
        settings.httpAdditionalHeaders = ["User-Agent": "Vaulthalla Desktop"]

        self.configuration = configuration
        self.baseURL = base
        self.trust = TrustDelegate(identity: configuration.identityBox, pins: configuration.serverSPKIPins)
        self.session = URLSession(configuration: settings, delegate: trust, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Cancels requests in flight and releases the session.
    public func invalidate() {
        session.invalidateAndCancel()
    }

    /// The URL of `path` (with its query) on the listener.
    public func url(path: String, query: [URLQueryItem] = []) throws(DeviceHTTPError) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw .invalidURL }
        components.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            components.queryItems = query
            // `+` is a literal in URLComponents but a space to the daemon's form decoder.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw .invalidURL }
        return url
    }

    /// Sends `request` (its URL from ``url(path:query:)``) and returns the body and response, whatever the status.
    public func data(for request: URLRequest) async throws(DeviceHTTPError) -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw DeviceHTTPError.transport("not HTTP") }
            return (data, http)
        } catch let error as DeviceHTTPError {
            throw error
        } catch let error as URLError {
            throw trust.classify(error)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .transport(error.localizedDescription)
        }
    }

    /// A vault file through `/download/content`. With `range`, asks for those bytes (`Range: bytes=a-b`); the
    /// daemon answers 206 with exactly them, or 416.
    public func download(vaultID: Int64, path: String, range: ClosedRange<Int64>? = nil)
        async throws(DeviceHTTPError) -> (Data, HTTPURLResponse)
    {
        var request = URLRequest(url: try url(path: "/download/content", query: [
            URLQueryItem(name: "vault_id", value: String(vaultID)), URLQueryItem(name: "path", value: path),
        ]))
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        return try await data(for: request)
    }

    /// POSTs one JSON-RPC message to `/mcp` (Streamable HTTP, JSON responses). Returns the HTTP status and the
    /// decoded body (nil for 202 and other empty answers).
    public func mcp(_ message: JSONValue, protocolVersion: String? = nil)
        async throws(DeviceHTTPError) -> (status: Int, body: JSONValue?)
    {
        var request = URLRequest(url: try url(path: "/mcp"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let protocolVersion { request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        do {
            request.httpBody = try JSONEncoder().encode(message)
        } catch {
            throw .transport("the MCP message could not be encoded")
        }
        let (data, response) = try await data(for: request)
        guard !data.isEmpty else { return (response.statusCode, nil) }
        return (response.statusCode, try? JSONDecoder().decode(JSONValue.self, from: data))
    }
}

/// A `SecIdentity` that crosses concurrency domains (immutable CF reference; see `TransportSecurity`).
final class IdentityBox: @unchecked Sendable {
    let value: SecIdentity
    init(_ value: SecIdentity) { self.value = value }
}

/// Answers the TLS challenges: the client certificate, and the server's key against the pins. Shared with
/// `DeviceTransferClient`, whose streaming session answers the same way.
final class TrustDelegate: NSObject, URLSessionDelegate, Sendable {
    private let identity: IdentityBox
    private let pins: [Data]
    /// The last SPKI a challenge was refused for, so the failed request reports a pin mismatch.
    private let refused = Mutex<Data??>(nil)
    /// Whether a server asked for, and got, the device identity.
    private let presented = Mutex(false)
    private let log = Logger(subsystem: "sh.vaulthalla.desktop", category: "device-http")

    init(identity: IdentityBox, pins: [Data]) {
        self.identity = identity
        self.pins = pins
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            presented.withLock { $0 = true }
            return (.useCredential, URLCredential(identity: identity.value, certificates: nil, persistence: .none))
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  let spki = CertificateSPKI.sha256(of: leaf)
            else {
                refused.withLock { $0 = .some(nil) }
                return (.cancelAuthenticationChallenge, nil)
            }
            guard pins.contains(where: { Self.constantTimeEqual($0, spki) }) else {
                log.error("server identity does not match the pinned SPKI")
                refused.withLock { $0 = .some(spki) }
                return (.cancelAuthenticationChallenge, nil)
            }
            return (.useCredential, URLCredential(trust: trust))
        default:
            return (.performDefaultHandling, nil)
        }
    }

    func classify(_ error: URLError) -> DeviceHTTPError {
        if let observed = refused.withLock({ value in defer { value = nil }; return value }) {
            return .pinMismatch(observedSPKISHA256: observed)
        }
        switch error.code {
        case .clientCertificateRequired where presented.withLock({ $0 }): return .forbidden
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        default: return .transport(error.localizedDescription)
        }
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
