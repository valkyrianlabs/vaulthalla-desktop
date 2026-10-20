import Foundation
import Network
import Synchronization
import VHContract

/// A WebSocket server on 127.0.0.1 that stands in for the daemon's ws Router. Tests take the frames it receives
/// with `next()` and answer them (or not) explicitly, which keeps ordering and timing deterministic.
final class TestServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "vh.test.server")
    private let peers = Mutex<[ObjectIdentifier: Peer]>([:])
    private let inbox = Mutex(Inbox())

    private struct Inbox {
        var frames: [Received] = []
        var waiter: (id: UUID, continuation: CheckedContinuation<Received?, Never>)?
    }

    /// A frame the server received, with the connection it came on.
    struct Received: Sendable {
        let frame: JSONValue
        let peer: Peer

        var command: String { frame["command"]?.stringValue ?? "" }
        var requestId: String { frame["requestId"]?.stringValue ?? "" }

        /// Answers like the Router's `Response::SUCCESS`: `data` is left out when there is none.
        func ok(_ data: JSONValue? = nil, token: String? = nil) {
            var object: JSONObject = ["command": .string(command + ".response"), "status": "OK",
                                      "requestId": .string(requestId)]
            object["data"] = data
            object["token"] = token.map(JSONValue.string)
            peer.send(.object(object))
        }

        /// Answers like `respondWithCurrentError`: an ops refusal carries `data.code`.
        func refuse(_ message: String, code: String? = nil, status: String = "ERROR") {
            var object: JSONObject = ["command": .string(command + ".response"), "status": .string(status),
                                      "requestId": .string(requestId), "error": .string(message)]
            object["data"] = code.map { ["code": .string($0)] }
            peer.send(.object(object))
        }
    }

    final class Peer: Sendable {
        let connection: NWConnection

        init(_ connection: NWConnection) { self.connection = connection }

        func send(_ value: JSONValue) {
            let data = try! JSONEncoder().encode(value)
            let context = NWConnection.ContentContext(identifier: "test",
                                                      metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }

    /// Starts listening on an ephemeral loopback port; with `tls`, the WebSocket runs over it.
    static func start(tls: NWProtocolTLS.Options? = nil) async throws -> TestServer {
        let server = try TestServer(tls: tls)
        try await server.ready()
        return server
    }

    private init(tls: NWProtocolTLS.Options?) throws {
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
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

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection)
        peers.withLock { $0[ObjectIdentifier(connection)] = peer }
        connection.start(queue: queue)
        receive(peer)
    }

    private func receive(_ peer: Peer) {
        peer.connection.receiveMessage { [weak self] content, _, _, error in
            guard let self, error == nil else { return }
            if let content, let frame = try? JSONDecoder().decode(JSONValue.self, from: content) {
                deliver(Received(frame: frame, peer: peer))
            }
            receive(peer)
        }
    }

    private func deliver(_ received: Received) {
        let waiter = inbox.withLock { inbox in
            defer { inbox.waiter = nil }
            if inbox.waiter == nil { inbox.frames.append(received) }
            return inbox.waiter
        }
        waiter?.continuation.resume(returning: received)
    }

    /// The next frame the server receives, or nil if none arrives within `timeout`.
    func next(within timeout: Duration = .seconds(2)) async -> Received? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let ready = inbox.withLock { inbox -> Received? in
                if !inbox.frames.isEmpty { return inbox.frames.removeFirst() }
                inbox.waiter = (id, continuation)
                return nil
            }
            if let ready { return continuation.resume(returning: ready) }
            let (seconds, attoseconds) = timeout.components
            let interval = Double(seconds) + Double(attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + interval) {
                let expired = self.inbox.withLock { inbox -> CheckedContinuation<Received?, Never>? in
                    guard let waiter = inbox.waiter, waiter.id == id else { return nil }
                    inbox.waiter = nil
                    return waiter.continuation
                }
                expired?.resume(returning: nil)
            }
        }
    }

    /// Sends a frame on every open connection (a server notice).
    func broadcast(_ value: JSONValue) {
        for peer in peers.withLock({ Array($0.values) }) { peer.send(value) }
    }

    /// Drops every connection, as a daemon restart would.
    func dropConnections() {
        for peer in peers.withLock({ peers in defer { peers.removeAll() }; return Array(peers.values) }) {
            peer.connection.cancel()
        }
    }

    func stop() {
        dropConnections()
        listener.cancel()
    }
}
