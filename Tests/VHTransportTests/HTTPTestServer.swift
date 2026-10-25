import Foundation
import Network
import Synchronization

/// An HTTP/1.1 server on 127.0.0.1 over TLS, standing in for the device listener's HTTP routes. Each request goes to
/// `handler`; connections stay open for the next request (keep-alive), as URLSession expects.
final class HTTPTestServer: Sendable {
    struct Request: Sendable {
        var method: String
        var target: String
        var headers: [String: String]
        var body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
        /// Sends the full Content-Length but only this many body bytes, then drops the connection (a lost transfer).
        var truncateAfter: Int? = nil
    }

    typealias Handler = @Sendable (Request) -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "vh.test.http-server")
    private let handler: Handler
    private let connections = Mutex<[NWConnection]>([])
    private let received = Mutex<[Request]>([])

    static func start(tls: NWProtocolTLS.Options, handler: @escaping Handler) async throws -> HTTPTestServer {
        let server = try HTTPTestServer(tls: tls, handler: handler)
        try await server.ready()
        return server
    }

    private init(tls: NWProtocolTLS.Options, handler: @escaping Handler) throws {
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    /// Every request served so far, in order.
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

    private func read(_ connection: NWConnection, buffer: Data) {
        if let (request, rest) = Self.parse(buffer) {
            received.withLock { $0.append(request) }
            let response = handler(request)
            if let cut = response.truncateAfter {
                let encoded = Self.encode(response)
                // Close a moment later: an immediate cancel resets the connection before the client reads the bytes.
                connection.send(content: encoded.prefix(encoded.count - response.body.count + cut),
                                completion: .contentProcessed { [queue] _ in
                                    queue.asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
                                })
                return
            }
            if response.headers["Connection"] == "close" {
                // Like the daemon: the response, then the connection ends.
                connection.send(content: Self.encode(response), isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            connection.send(content: Self.encode(response), completion: .contentProcessed { _ in })
            return read(connection, buffer: rest)
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, done, error in
            guard let self, error == nil else { return connection.cancel() }
            var next = buffer
            if let content { next.append(content) }
            if done && content == nil { return connection.cancel() }
            read(connection, buffer: next)
        }
    }

    /// One complete request at the front of `buffer` (header, then Content-Length bytes), and what follows it.
    private static func parse(_ buffer: Data) -> (Request, Data)? {
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
        guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(end.upperBound, offsetBy: length)
        let request = Request(method: String(start[0]), target: String(start[1]), headers: headers,
                              body: Data(buffer[end.upperBound..<bodyEnd]))
        return (request, Data(buffer[bodyEnd...]))
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
        case 206: "Partial Content"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 411: "Length Required"
        case 412: "Precondition Failed"
        case 413: "Content Too Large"
        case 428: "Precondition Required"
        case 503: "Service Unavailable"
        case 416: "Range Not Satisfiable"
        default: "Status"
        }
    }
}
