public import Foundation
public import VHContract
public import VHCore
import Dispatch
import Network
import os

/// One WebSocket to a daemon's ws Router, speaking its envelope:
///
///     → {command, payload, requestId, token?}
///     ← {command: "<cmd>.response", status: "OK" | "ERROR" | "UNAUTHORIZED", requestId, data?, error?, token?}
///
/// Requests are matched to answers by `requestId`, so they may be answered in any order. Each waits at most its
/// command's contract timeout (`WsError.timeout` is "no answer yet", never "failed"). Frames nobody waits for go to
/// `unsolicitedMessages()`. The connection reconnects with backoff until `close()`, and immediately when the network
/// changes; requests in flight when it drops fail with `.disconnected`, and requests sent while it is down wait up to
/// `connectTimeout` for it to come back.
///
/// Semantics follow the web console's client (web/src/lib/ws/client.ts) so both behave the same against a daemon.
/// Payloads and responses are never logged; only command names are.
public actor WsClient {
    public struct Configuration: Sendable {
        public var endpoint: NodeEndpoint
        public var security: TransportSecurity
        /// The WebSocket path on the listener.
        public var path: String
        public var reconnect: ReconnectPolicy
        /// How long a request sent while disconnected waits for a connection before failing `.disconnected`. It also
        /// bounds the TCP connect of each attempt.
        public var connectTimeout: Duration

        public init(endpoint: NodeEndpoint, security: TransportSecurity, path: String = "/ws",
                    reconnect: ReconnectPolicy = ReconnectPolicy(), connectTimeout: Duration = .seconds(8)) {
            self.endpoint = endpoint
            self.security = security
            self.path = path
            self.reconnect = reconnect
            self.connectTimeout = connectTimeout
        }
    }

    public enum ConfigurationError: Error, Hashable, Sendable {
        /// `.plaintext` was asked for a host that isn't this machine.
        case plaintextRequiresLoopback(host: String)
        /// The endpoint and path don't make a WebSocket URL.
        case invalidURL
    }

    /// The default wait for a raw command, the daemon's own default client timeout.
    public static let defaultTimeout: Duration = .seconds(15)

    public nonisolated let configuration: Configuration
    /// The envelope token slot (empty for device sessions).
    public nonisolated let tokens: TokenStore

    // Network.framework calls back on this queue, and the actor runs on it too: callbacks enter the actor
    // synchronously (`assumeIsolated`), so frames and state changes are handled in the order they happened.
    private nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let url: URL
    private let log = Logger(subsystem: "sh.vaulthalla.desktop", category: "transport")
    private let pinMismatch = PinMismatch()

    private var state: ConnectionState = .idle
    /// Whether the caller wants a connection (between `connect()` or the first send, and `close()`).
    private var wanted = false
    private var connection: NWConnection?
    /// Identifies the current connection; callbacks from an older one are ignored.
    private var generation = 0
    private var attempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var lastPath: NWPath?
    private var pending: [String: Pending] = [:]
    private var stateObservers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var messageObservers: [UUID: AsyncStream<UnsolicitedMessage>.Continuation] = [:]

    private struct Pending {
        let command: String
        /// The encoded frame while it waits for a connection; nil once sent.
        var frame: Data?
        let timeout: Duration
        let continuation: CheckedContinuation<Result<Data, WsError>, Never>
        var timer: Task<Void, Never>?
    }

    /// Fails for `.plaintext` to a non-loopback host, or an endpoint that doesn't make a URL. Doesn't connect yet.
    public init(configuration: Configuration, tokens: TokenStore = TokenStore()) throws(ConfigurationError) {
        let host = configuration.endpoint.host
        if !configuration.security.isTLS, !TransportSecurity.isLoopback(host) {
            throw .plaintextRequiresLoopback(host: host)
        }
        let scheme = configuration.security.isTLS ? "wss" : "ws"
        let authority = host.contains(":") ? "[\(host)]" : host
        let path = configuration.path.hasPrefix("/") ? configuration.path : "/" + configuration.path
        guard let url = URL(string: "\(scheme)://\(authority):\(configuration.endpoint.port)\(path)") else {
            throw .invalidURL
        }
        self.configuration = configuration
        self.tokens = tokens
        self.url = url
        queue = DispatchSerialQueue(label: "sh.vaulthalla.transport.\(configuration.endpoint)")
    }

    deinit {
        reconnectTask?.cancel()
        connection?.cancel()
        pathMonitor?.cancel()
        for entry in pending.values {
            entry.timer?.cancel()
            entry.continuation.resume(returning: .failure(.disconnected))
        }
        stateObservers.values.forEach { $0.finish() }
        messageObservers.values.forEach { $0.finish() }
    }

    // MARK: - Public API

    /// The current connection state.
    public var connectionState: ConnectionState { state }

    /// Connection states, starting with the current one. Each call returns an independent stream.
    public func states() -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self,
                                                            bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        continuation.yield(state)
        stateObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in self?.onQueue { $0.stateObservers[id] = nil } }
        return stream
    }

    /// Frames no request claimed (see `UnsolicitedMessage`). Each call returns an independent stream that receives
    /// the frames arriving after it was created.
    public func unsolicitedMessages() -> AsyncStream<UnsolicitedMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: UnsolicitedMessage.self,
                                                            bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        messageObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in self?.onQueue { $0.messageObservers[id] = nil } }
        return stream
    }

    /// Starts connecting and keeps the connection up until `close()`. Sending also connects; calling this first
    /// just starts earlier. After `.failed`, tries again.
    public func connect() {
        wanted = true
        if case .failed = state { attempt = 0 }
        startPathMonitor()
        if connection == nil, reconnectTask == nil { open() }
    }

    /// Drops the connection, stops reconnecting, and fails every pending request with `.disconnected`.
    public func close() {
        wanted = false
        reconnectTask?.cancel()
        reconnectTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPath = nil
        generation += 1
        connection?.cancel()
        connection = nil
        attempt = 0
        failAll(.disconnected, includingUnsent: true)
        setState(.idle)
    }

    /// Sends a contract command and decodes its answer. `timeout` defaults to the command's contract timeout.
    public func send<R: WsRequest>(_ request: R.Type, payload: R.Payload, timeout: Duration? = nil)
        async throws(WsError) -> R.Response
    {
        let data = try await exchange(command: R.command.rawValue, payload: payload,
                                      timeout: timeout ?? R.command.clientTimeout)
        return try decodeData(R.Response.self, from: data, command: R.command.rawValue)
    }

    /// Sends a contract command that takes no payload.
    public func send<R: WsRequest>(_ request: R.Type, timeout: Duration? = nil) async throws(WsError) -> R.Response
    where R.Payload == WsNoPayload {
        try await send(request, payload: WsNoPayload(), timeout: timeout)
    }

    /// Sends a command the contract doesn't type yet and returns its `data` (an empty object when the daemon sent
    /// none).
    public func send(command: String, payload: JSONValue, timeout: Duration = WsClient.defaultTimeout)
        async throws(WsError) -> JSONValue
    {
        let data = try await exchange(command: command, payload: payload, timeout: timeout)
        return try decodeData(JSONValue.self, from: data, command: command)
    }

    /// Sends a command whose payload or answer carries key material (`vault.keys.export`, `vault.keys.import`).
    ///
    /// `payload` is the payload object's JSON (build it with `SecretJSONWriter`). The frame is assembled around it in
    /// memory that is zeroed when the last reference to it goes away, including Network.framework's once the bytes
    /// are sent. The answer comes back as the whole frame in `SecretBytes`, for the caller to lift the keys out of
    /// (`SecretJSON.lift`) and decode the rest; refusals still throw `WsError` as for `send`. Nothing is logged but the
    /// command name.
    public func sendSensitive(command: String, payload: SecretBytes, timeout: Duration)
        async throws(WsError) -> SecretBytes
    {
        let requestId = UUID().uuidString.lowercased()
        let head: Data
        let tail: Data
        do {
            head = try Self.encoder.encode(command)
            let id = try Self.encoder.encode(requestId)
            let token = try tokens.token.map { try Self.encoder.encode($0) }
            tail = Data(",\"requestId\":".utf8) + id + (token.map { Data(",\"token\":".utf8) + $0 } ?? Data()) + Data("}".utf8)
        } catch {
            throw .error("The request could not be encoded.")
        }
        let prefix = Data("{\"command\":".utf8) + head + Data(",\"payload\":".utf8)
        let count = prefix.count + payload.count + tail.count
        let storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        prefix.copyBytes(to: storage.assumingMemoryBound(to: UInt8.self), count: prefix.count)
        payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress { (storage + prefix.count).copyMemory(from: base, byteCount: raw.count) }
        }
        tail.copyBytes(to: (storage + prefix.count + payload.count).assumingMemoryBound(to: UInt8.self), count: tail.count)
        let frame = Data(bytesNoCopy: storage, count: count, deallocator: .custom { pointer, size in
            pointer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
            pointer.deallocate()
        })

        var answer = try await exchange(command: command, requestId: requestId, frame: frame, timeout: timeout)
        let secret = SecretBytes(answer)
        answer.resetBytes(in: 0..<answer.count) // zeroes in place when this is the last reference
        return secret
    }

    /// Decodes a frame's `data` as `T` (a sensitive answer once its keys were lifted out): the same rules as `send`.
    public static func decodeAnswer<T: Decodable>(_ type: T.Type, frame: Data, command: String) throws(WsError) -> T {
        do {
            if let data = try decoder.decode(DataEnvelope<T>.self, from: frame).data { return data }
            return try decoder.decode(T.self, from: Data("{}".utf8))
        } catch {
            throw .contractMismatch("\(command): the answer doesn't match the contract")
        }
    }

    // MARK: - Requests

    private func exchange(command: String, payload: some Encodable & Sendable, timeout: Duration)
        async throws(WsError) -> Data
    {
        let requestId = UUID().uuidString.lowercased()
        let frame: Data
        do {
            let envelope = RequestEnvelope(command: command, payload: payload, requestId: requestId,
                                           token: tokens.token)
            frame = try Self.encoder.encode(envelope)
        } catch {
            log.error("could not encode \(command, privacy: .public)")
            throw .error("The request could not be encoded.")
        }
        return try await exchange(command: command, requestId: requestId, frame: frame, timeout: timeout)
    }

    private func exchange(command: String, requestId: String, frame: Data, timeout: Duration)
        async throws(WsError) -> Data
    {
        if Task.isCancelled { throw .cancelled }
        if case .failed = state { throw .disconnected }
        if !wanted { connect() }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(requestId: requestId, command: command, frame: frame, timeout: timeout,
                        continuation: continuation)
            }
        } onCancel: {
            onQueue { $0.settle(requestId, .failure(.cancelled)) }
        }
        return try result.get()
    }

    private func enqueue(requestId: String, command: String, frame: Data, timeout: Duration,
                         continuation: CheckedContinuation<Result<Data, WsError>, Never>) {
        // Cancelled before the entry existed: the cancellation handler found nothing to settle.
        if Task.isCancelled { return continuation.resume(returning: .failure(.cancelled)) }
        pending[requestId] = Pending(command: command, frame: frame, timeout: timeout, continuation: continuation)
        if case .connected = state, let connection {
            transmit(requestId, on: connection)
        } else {
            // Waits for the connection; `connectionReady` sends it.
            pending[requestId]?.timer = expire(requestId, after: configuration.connectTimeout)
        }
    }

    private func transmit(_ requestId: String, on connection: NWConnection) {
        guard var entry = pending[requestId], let frame = entry.frame else { return }
        entry.frame = nil
        entry.timer?.cancel()
        entry.timer = expire(requestId, after: entry.timeout)
        pending[requestId] = entry
        log.debug("send \(entry.command, privacy: .public)")

        let context = NWConnection.ContentContext(identifier: "vh.ws.request",
                                                  metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: frame, contentContext: context, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
                            guard error != nil else { return }
                            self?.assumeIsolated { $0.settle(requestId, .failure(.disconnected)) }
                        })
    }

    /// After `delay`, fails the request: `.timeout` once sent, `.disconnected` while it still waits for a connection.
    private func expire(_ requestId: String, after delay: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.expired(requestId)
        }
    }

    private func expired(_ requestId: String) {
        guard let entry = pending[requestId] else { return }
        if entry.frame == nil {
            log.info("no answer yet to \(entry.command, privacy: .public)")
            settle(requestId, .failure(.timeout))
        } else {
            settle(requestId, .failure(.disconnected))
        }
    }

    private func settle(_ requestId: String, _ result: Result<Data, WsError>) {
        guard let entry = pending.removeValue(forKey: requestId) else { return }
        entry.timer?.cancel()
        entry.continuation.resume(returning: result)
    }

    /// Fails requests already sent on a lost connection; unsent ones keep waiting for the next one unless
    /// `includingUnsent`.
    private func failAll(_ error: WsError, includingUnsent: Bool) {
        for (requestId, entry) in pending where includingUnsent || entry.frame == nil {
            settle(requestId, .failure(error))
        }
    }

    private func decodeData<T: Decodable>(_ type: T.Type, from frame: Data, command: String) throws(WsError) -> T {
        do {
            if let data = try Self.decoder.decode(DataEnvelope<T>.self, from: frame).data { return data }
            // The daemon leaves `data` out when the handler returned an empty object.
            return try Self.decoder.decode(T.self, from: Data("{}".utf8))
        } catch let error as DecodingError {
            log.error("\(command, privacy: .public) answer does not match the contract")
            throw .contractMismatch(Self.describe(error, command: command))
        } catch {
            throw .contractMismatch("\(command): \(error.localizedDescription)")
        }
    }

    /// Where and why decoding failed, without the offending value.
    private static func describe(_ error: DecodingError, command: String) -> String {
        let (context, what): (DecodingError.Context?, String) = switch error {
        case .keyNotFound(let key, let context): (context, "missing \(key.stringValue)")
        case .typeMismatch(let type, let context): (context, "expected \(type)")
        case .valueNotFound(let type, let context): (context, "null where \(type) is required")
        case .dataCorrupted(let context): (context, "malformed")
        @unknown default: (nil, "undecodable")
        }
        let path = (context?.codingPath ?? []).map { $0.intValue.map(String.init) ?? $0.stringValue }
        return "\(command) \(path.joined(separator: ".")): \(what)"
    }

    // MARK: - Incoming frames

    private func received(_ frame: Data) {
        guard let header = try? Self.decoder.decode(FrameHeader.self, from: frame) else {
            log.error("dropped a frame that is not a JSON object")
            return
        }
        if let token = header.token, !token.isEmpty { tokens.token = token }

        if let requestId = header.requestId, pending[requestId] != nil {
            if let error = WsError.classify(status: header.status, error: header.error, code: header.data?.code) {
                settle(requestId, .failure(error))
            } else {
                settle(requestId, .success(frame))
            }
            return
        }

        guard !messageObservers.isEmpty, let value = try? Self.decoder.decode(JSONValue.self, from: frame) else {
            return
        }
        let message = UnsolicitedMessage(command: header.command ?? "", status: header.status,
                                         requestId: header.requestId, data: value["data"],
                                         message: header.error ?? header.message, frame: value)
        for observer in messageObservers.values { observer.yield(message) }
    }

    // MARK: - Connection

    private func open() {
        generation += 1
        let current = generation
        setState(.connecting)
        log.info("connecting to \(self.configuration.endpoint, privacy: .private)")

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(configuration.connectTimeout.components.seconds))
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters: NWParameters
        switch configuration.security {
        case .plaintext:
            parameters = NWParameters(tls: nil, tcp: tcp)
        case .mutualTLS(let identity, let pin, let onServerSPKI):
            let tls = TransportSecurity.tlsOptions(identity: identity, pin: pin, onServerSPKI: onServerSPKI,
                                                   mismatch: pinMismatch)
            parameters = NWParameters(tls: tls, tcp: tcp)
        }
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)

        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.assumeIsolated { $0.connectionStateChanged(state, generation: current) }
        }
        connection.start(queue: queue)
    }

    private func connectionStateChanged(_ newState: NWConnection.State, generation current: Int) {
        guard current == generation, let connection else { return }
        switch newState {
        case .ready:
            attempt = 0
            setState(.connected)
            log.info("connected")
            receiveNext(on: connection, generation: current)
            for (requestId, entry) in pending where entry.frame != nil {
                transmit(requestId, on: connection)
            }
        case .waiting(let error), .failed(let error):
            // `.waiting` would sit until the path changes; our own backoff and path monitor decide instead.
            connectionLost(reason: "\(error)")
        case .cancelled:
            connectionLost(reason: "cancelled")
        default:
            break
        }
    }

    private func receiveNext(on connection: NWConnection, generation current: Int) {
        connection.receiveMessage { [weak self] content, context, _, error in
            self?.assumeIsolated { client in
                guard current == client.generation else { return }
                if let error {
                    return client.connectionLost(reason: "\(error)")
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                switch metadata?.opcode {
                case .close:
                    return client.connectionLost(reason: "closed by the server")
                case .text, .binary:
                    if let content, !content.isEmpty { client.received(content) }
                default:
                    // Nothing and no WebSocket metadata: the stream ended.
                    if content == nil, metadata == nil, context?.isFinal ?? true {
                        return client.connectionLost(reason: "connection ended")
                    }
                }
                client.receiveNext(on: connection, generation: current)
            }
        }
    }

    private func connectionLost(reason: String) {
        generation += 1
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        failAll(.disconnected, includingUnsent: false)

        if let spki = pinMismatch.take() {
            log.error("server identity does not match the pinned SPKI")
            wanted = false
            failAll(.disconnected, includingUnsent: true)
            let observed = spki.map { String(format: "%02x", $0) }.joined()
            return setState(.failed(reason: "The server's identity changed (SPKI SHA-256 \(observed))."))
        }
        log.info("connection lost: \(reason, privacy: .public)")
        guard wanted else { return setState(.idle) }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        attempt += 1
        let delay = configuration.reconnect.delay(attempt: attempt)
        setState(.reconnecting(attempt: attempt, after: delay))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reconnectNow()
        }
    }

    private func reconnectNow() {
        reconnectTask = nil
        if wanted, connection == nil { open() }
    }

    /// Retries at once when the network comes back or changes, instead of waiting out the backoff.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.assumeIsolated { $0.pathChanged(path) }
        }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }

    private func pathChanged(_ path: NWPath) {
        defer { lastPath = path }
        // The first update is the current path, not a change.
        guard let lastPath, path.status == .satisfied, path != lastPath else { return }
        guard reconnectTask != nil else { return }
        log.info("network changed, reconnecting now")
        reconnectTask?.cancel()
        reconnectTask = nil
        attempt = 0
        open()
    }

    private func setState(_ newState: ConnectionState) {
        guard newState != state else { return }
        state = newState
        for observer in stateObservers.values { observer.yield(newState) }
    }

    /// Runs `body` on the actor from a context that can't await (cancellation handlers, stream terminations).
    private nonisolated func onQueue(_ body: @escaping @Sendable (isolated WsClient) -> Void) {
        queue.async { [weak self] in
            self?.assumeIsolated { body($0) }
        }
    }

    // MARK: - Coding

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

/// `{command, payload, requestId, token?}`; the token key is left out when there is none.
private struct RequestEnvelope<Payload: Encodable>: Encodable {
    let command: String
    let payload: Payload
    let requestId: String
    let token: String?
}

/// The members of an incoming frame the client routes on; `data` is decoded separately once the frame is claimed.
private struct FrameHeader: Decodable {
    var command: String?
    var status: String?
    var requestId: String?
    var error: String?
    var message: String?
    var token: String?
    var data: RefusalData?
}

/// `data.code` when `data` is an object with a string code; nil for any other `data`.
private struct RefusalData: Decodable {
    var code: String?

    init(from decoder: any Decoder) throws {
        code = try? decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .code)
    }

    private enum Keys: CodingKey { case code }
}

private struct DataEnvelope<T: Decodable>: Decodable {
    var data: T?
}
