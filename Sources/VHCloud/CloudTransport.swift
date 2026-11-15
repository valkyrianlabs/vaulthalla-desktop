public import Foundation

/// How Desktop reaches Vaulthalla Cloud: ``URLSessionCloudTransport``, or a fake in tests and previews.
public protocol CloudTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Vaulthalla Cloud's answers as Desktop handles them. `paymentRequired` and `rateLimited` are their own cases: the
/// first means the plan doesn't cover it (the person goes to billing), the second that Desktop must wait.
public enum CloudError: Error, Sendable, Equatable {
    case invalidEndpoint(String)
    case unreachable(String)
    /// 401: the request signature was refused. For a linked Mac this means the link was revoked (or the clock is off).
    case unauthenticated(String)
    /// 402 `payment_required`: the account's plan doesn't cover it.
    case paymentRequired(String)
    /// 429 `rate_limited`: try again later (after `retryAfter` seconds when the cloud said).
    case rateLimited(retryAfter: Int?, message: String)
    case forbidden(String)
    case notFound(String)
    case conflict(String)
    case invalid(String)
    case unavailable(String)
    /// Any other refusal.
    case refused(status: Int, code: String?, message: String)
    case notLinked
    case malformed(String)
    /// The answer is larger than Desktop accepts (1 MiB).
    case tooLarge
    /// A comparison code the cloud sent isn't the one Desktop computes from the key it was given.
    case codeMismatch
    /// Nothing in the vault's records opens with this key.
    case noEnvelopeOpens
    /// The cloud's key statement or chain doesn't verify, or isn't the key this Mac holds.
    case keyMismatch(String)
    /// A refusal whose error body carries a `reason` (vaulthalla-cloud `vhc::Error`'s third argument, for answers a
    /// client must tell apart: `held_by_desktop`, `no_such_vault`, `bucket_not_ready`...) and its optional `details`
    /// (strings: the holder of `held_by_*`, the action of `step_up_required`, the cause of `payment_required`). `code` is
    /// the envelope's. 401 and 429 keep their own cases whatever their reason.
    case declined(status: Int, code: String?, reason: String, message: String, details: [String: String])

    /// The message for a person.
    public var message: String {
        switch self {
        case .invalidEndpoint(let e): "Not a Vaulthalla Cloud address: \(e)"
        case .unreachable: "Vaulthalla Cloud can't be reached right now."
        case .unauthenticated: "Vaulthalla Cloud didn't accept this Mac's signature. It may have been unlinked."
        case .paymentRequired(let m): m.isEmpty ? "Your plan doesn't cover this." : m
        case .rateLimited(let after, _):
            after.map { "Too many requests. Try again in \($0) seconds." } ?? "Too many requests. Try again in a moment."
        case .forbidden(let m), .notFound(let m), .conflict(let m), .invalid(let m), .unavailable(let m): m
        case .refused(_, _, let m): m
        case .notLinked: "This Mac isn't linked to Vaulthalla Cloud."
        case .malformed: "Vaulthalla Cloud answered in a way this version of Vaulthalla doesn't understand."
        case .tooLarge: "Vaulthalla Cloud's answer was too large."
        case .codeMismatch: "The codes don't match. Nothing was sent."
        case .noEnvelopeOpens: "This key doesn't open any of this vault's keys."
        case .keyMismatch(let m): m
        case .declined(_, _, _, let m, _): m
        }
    }

    /// Maps an HTTP status and the daemon's error body.
    static func from(status: Int, body: Data, retryAfter: String?) -> CloudError {
        let parsed = try? JSONDecoder().decode(CloudErrorBody.self, from: body)
        let code = parsed?.error?.code
        let message = parsed?.error?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
        if let reason = parsed?.error?.reason, !reason.isEmpty, status != 401, status != 429 {
            return .declined(status: status, code: code, reason: reason, message: message, details: parsed?.error?.details ?? [:])
        }
        switch (status, code) {
        case (402, _), (_, "payment_required"): return .paymentRequired(message)
        case (429, _), (_, "rate_limited"): return .rateLimited(retryAfter: retryAfter.flatMap { Int($0) }, message: message)
        case (401, _): return .unauthenticated(message)
        case (403, _): return .forbidden(message)
        case (404, _): return .notFound(message)
        case (409, _): return .conflict(message)
        case (400, _): return .invalid(message)
        case (503, _): return .unavailable(message)
        default: return .refused(status: status, code: code, message: message)
        }
    }
}

/// The transport for the real cloud (docs/cloud-storage.md, Engineering): its own ephemeral session with no cookie
/// store, cache or credential storage, redirects refused, TLS 1.2 at least with system trust (the trust that matters is
/// the VHC1 signature and the key chain, checked here), answers capped at 1 MiB.
public final class URLSessionCloudTransport: CloudTransport {
    public static let maximumResponse = 1 << 20

    private let session: URLSession

    public init() {
        session = URLSession(configuration: Self.configuration(), delegate: RefuseRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// The session's configuration, separate so tests check it.
    public static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCredentialStorage = nil
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        c.httpMaximumConnectionsPerHost = 4
        return c
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.unreachable("not an HTTP response") }
        if http.expectedContentLength > Int64(Self.maximumResponse) { throw CloudError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > Self.maximumResponse { throw CloudError.tooLarge }
        }
        return (data, http)
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
