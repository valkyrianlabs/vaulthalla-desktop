import Foundation
import Network
import Synchronization

/// An HTTP/1.1 server on 127.0.0.1 over TLS, standing in for the device listener's HTTP routes. Each request goes to
/// `handler`; connections stay open for the next request (keep-alive), as URLSession expects.
///
/// A `router` may take a request before its body is read: refuse it (the answer, then the connection closes, as the
/// daemon refuses a part), or stream the body to a ``BodySink`` chunk by chunk so a large body is never held whole.
/// ``Options`` emulate a link: a bandwidth cap on request bodies shared by every connection (TCP back-pressure slows
/// the client), and a delay before every answer (the round trip).
final class HTTPTestServer: Sendable {
    struct Request: Sendable {
        var method: String
        var target: String
        var headers: [String: String]
        /// Empty when the body was streamed to a sink.
        var body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }

        var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

        var query: [String: String] {
            let items = URLComponents(string: "https://host\(target)")?.queryItems ?? []
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        /// Sends the full Content-Length but only this many body bytes, then drops the connection (a lost transfer).
        var truncateAfter: Int? = nil
        /// Waits this long before answering (on top of ``Options/latency``).
        var delay: Duration? = nil
        /// Closes the connection instead of answering (an answer lost after the request was handled).
        var dropInsteadOfAnswering = false
    }

    typealias Handler = @Sendable (Request) -> Response

    /// What a streamed body's chunks say.
    enum ChunkVerdict: Sendable {
        case proceed
        /// Close the connection now, mid-body.
        case drop
    }

    /// Takes a request's body as it arrives; ``end`` answers once it is complete.
    struct BodySink: Sendable {
        var chunk: @Sendable (Data) -> ChunkVerdict
        var end: @Sendable () -> Response
        /// The body never completed (the client went away, or a chunk said drop).
        var abort: @Sendable () -> Void = {}
    }

    /// What to do with a request whose head arrived.
    enum Plan: Sendable {
        /// Read the whole body, then the handler answers (the default).
        case buffer
        /// Stream the body to the sink.
        case stream(BodySink)
        /// Answer now without reading the body, then close.
        case refuse(Response)
    }

    typealias Router = @Sendable (Request) -> Plan

    struct Options: Sendable {
        /// Request body bytes per second across all connections; nil: unlimited.
        var bandwidth: Double? = nil
        /// Added before every answer.
        var latency: Duration = .zero
        init() {}
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "vh.test.http-server")
    private let handler: Handler
    private let router: Router?
    private let options: Options
    private let connections = Mutex<[NWConnection]>([])
    private let received = Mutex<[Request]>([])
    /// The time the shared link is busy until (the bandwidth cap's token bucket).
    private let linkFree = Mutex<UInt64>(0)

    static func start(tls: NWProtocolTLS.Options, options: Options = Options(), router: Router? = nil,
                      handler: @escaping Handler) async throws -> HTTPTestServer {
        let server = try HTTPTestServer(tls: tls, options: options, router: router, handler: handler)
        try await server.ready()
        return server
    }

    private init(tls: NWProtocolTLS.Options, options: Options, router: Router?, handler: @escaping Handler) throws {
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
        self.router = router
        self.options = options
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    /// Every request served so far, in order (streamed ones without their body).
    var requests: [Request] { received.withLock { $0 } }

    func stop() {
        for connection in connections.withLock({ $0 }) { connection.cancel() }
        listener.cancel()
    }

    private func ready() async throws {
        let once = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                let result: Result<Void, any Error>? = switch state {
                case .ready: .success(())
                case .failed(let error): .failure(error)
                default: nil
                }
                guard let result, once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.withLock { $0.append(connection) }
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    // MARK: Reading

    private func receive(_ connection: NWConnection, _ next: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { content, _, done, error in
            guard error == nil else { connection.cancel(); return next(nil) }
            if done && content == nil { connection.cancel(); return next(nil) }
            next(content ?? Data())
        }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        if let (head, length, rest) = Self.parseHead(buffer) {
            let plan = router?(head) ?? .buffer
            switch plan {
            case .refuse(var response):
                received.withLock { $0.append(head) }
                response.headers["Connection"] = "close"
                respond(connection, response, then: nil)
            case .stream(let sink):
                received.withLock { $0.append(head) }
                stream(connection, sink: sink, remaining: length, buffer: rest)
            case .buffer:
                guard rest.count >= length else { return more(connection, buffer: buffer) }
                var request = head
                request.body = Data(rest.prefix(length))
                received.withLock { $0.append(request) }
                respond(connection, handler(request), then: Data(rest.dropFirst(length)))
            }
            return
        }
        more(connection, buffer: buffer)
    }

    private func more(_ connection: NWConnection, buffer: Data) {
        receive(connection) { [weak self] content in
            guard let self, let content else { return }
            var next = buffer
            next.append(content)
            read(connection, buffer: next)
        }
    }

    /// Feeds `remaining` body bytes to `sink` (some may already be in `buffer`), throttled by the link.
    private func stream(_ connection: NWConnection, sink: BodySink, remaining: Int, buffer: Data) {
        var remaining = remaining
        var leftover = Data()
        if !buffer.isEmpty {
            let take = min(remaining, buffer.count)
            if take > 0 {
                if case .drop = sink.chunk(Data(buffer.prefix(take))) {
                    sink.abort()
                    return connection.cancel()
                }
                remaining -= take
            }
            leftover = Data(buffer.dropFirst(take))
            throttle(take)
        }
        guard remaining > 0 else { return respond(connection, sink.end(), then: leftover) }
        let wait = throttleDelay()
        let left = remaining
        let next: @Sendable () -> Void = { [weak self] in
            guard let server = self else { return sink.abort() }
            server.receive(connection) { content in
                guard let content else { return sink.abort() }
                server.stream(connection, sink: sink, remaining: left, buffer: content)
            }
        }
        if wait > 0 { queue.asyncAfter(deadline: .now() + wait, execute: next) } else { next() }
    }

    /// Books `bytes` on the shared link.
    private func throttle(_ bytes: Int) {
        guard let rate = options.bandwidth, rate > 0, bytes > 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        linkFree.withLock { free in
            free = max(free, now) + UInt64(Double(bytes) / rate * 1e9)
        }
    }

    /// Seconds until the link is free again.
    private func throttleDelay() -> Double {
        guard options.bandwidth != nil else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        let free = linkFree.withLock { $0 }
        return free > now ? Double(free - now) / 1e9 : 0
    }

    // MARK: Answering

    /// Sends `response` after the latency and its delay, then reads the next request from `rest` (nil: close).
    private func respond(_ connection: NWConnection, _ response: Response, then rest: Data?) {
        let delay = Self.seconds(options.latency) + Self.seconds(response.delay ?? .zero)
        let send: @Sendable () -> Void = { [weak self] in self?.send(connection, response, then: rest) }
        if delay > 0 { queue.asyncAfter(deadline: .now() + delay, execute: send) } else { send() }
    }

    private func send(_ connection: NWConnection, _ response: Response, then rest: Data?) {
        if response.dropInsteadOfAnswering {
            connection.cancel()
            return
        }
        if let cut = response.truncateAfter {
            let encoded = Self.encode(response)
            // Close a moment later: an immediate cancel resets the connection before the client reads the bytes.
            connection.send(content: encoded.prefix(encoded.count - response.body.count + cut),
                            completion: .contentProcessed { [queue] _ in
                                queue.asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
                            })
            return
        }
        if response.headers["Connection"] == "close" || rest == nil {
            // Like the daemon: the response, then the connection ends.
            connection.send(content: Self.encode(response), isComplete: true,
                            completion: .contentProcessed { [queue] _ in
                                queue.asyncAfter(deadline: .now() + 0.05) { connection.cancel() }
                            })
            return
        }
        connection.send(content: Self.encode(response), completion: .contentProcessed { _ in })
        read(connection, buffer: rest ?? Data())
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// A request head at the front of `buffer`: the request (no body), its Content-Length, and what follows the head.
    private static func parseHead(_ buffer: Data) -> (Request, Int, Data)? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let request = Request(method: String(start[0]), target: String(start[1]), headers: headers, body: Data())
        return (request, length, Data(buffer[end.upperBound...]))
    }

    private static func encode(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + response.body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 411: "Length Required"
        case 412: "Precondition Failed"
        case 413: "Content Too Large"
        case 428: "Precondition Required"
        case 429: "Too Many Requests"
        case 503: "Service Unavailable"
        case 416: "Range Not Satisfiable"
        case 507: "Insufficient Storage"
        default: "Status"
        }
    }
}
