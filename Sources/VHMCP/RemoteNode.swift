import Foundation
import VHContract
import VHCore
import VHTransport

/// Why a request to a node's `/mcp` produced no JSON-RPC answer.
enum NodeRequestFailure: Error, Sendable {
    case connect(NodeConnectFailure)
    case http(DeviceHTTPError)
    /// The node answered with an HTTP status the exchange can't use (an older daemon without `/mcp`: 404).
    case status(Int)
    /// The node's answer isn't the MCP the bridge speaks.
    case protocolMismatch(String)
    case deadline(Duration)
    case cancelled

    var message: String {
        switch self {
        case .connect(let failure): failure.message
        case .http(let error): error.message
        case .status(404): "The node has no MCP endpoint (it runs a Vaulthalla version without remote MCP)."
        case .status(let status): "The node's MCP endpoint answered HTTP \(status)."
        case .protocolMismatch(let detail): "The node's MCP endpoint answered unexpectedly (\(detail))."
        case .deadline(let limit): "No answer within \(limit.seconds) s."
        case .cancelled: "Cancelled."
        }
    }

    /// Whether the failure says the node can't be used now (its tools leave the list). A cancelled request says
    /// nothing; neither does a tool call that outlived its deadline (a slow command, not a lost node).
    var meansOffline: Bool {
        switch self {
        case .cancelled, .http(.cancelled), .deadline: false
        default: true
        }
    }
}

/// The bridge's MCP client for one node: Streamable HTTP as the daemon's `/mcp` serves it (POST only, JSON
/// responses, 202 for notifications, no MCP session id). `initialize` runs lazily, once per transport; the negotiated
/// version rides every later request in `MCP-Protocol-Version`, and a 400 (a version or framing refusal, sent before
/// anything runs) re-initializes and retries once. A 403 retries once on a fresh transport, because the app may have
/// rotated this Mac's key since the transport was made.
actor RemoteNode {
    /// Versions the bridge can relay, newest first (the daemon's `kProtocolVersions`).
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    nonisolated let id: NodeID
    private(set) var node: Node
    private let connector: any NodeMCPConnector
    private let idleTimeout: Duration
    private let clientVersion: String

    private var transport: (any NodeMCPTransport)?
    /// Counts transports, so an `initialize` that finished after its transport was replaced records nothing.
    private var generation = 0
    private var protocolVersion: String?
    private var nextRequestID: Int64 = 1

    /// The last catalog the node returned; empty while it is unreachable.
    private(set) var tools: [JSONValue] = []
    /// nil until the first attempt.
    private(set) var reachable: Bool?
    private(set) var problem: String?
    private var fetchedAt: ContinuousClock.Instant?

    init(node: Node, connector: any NodeMCPConnector, idleTimeout: Duration, clientVersion: String) {
        self.id = node.id
        self.node = node
        self.connector = connector
        self.idleTimeout = idleTimeout
        self.clientVersion = clientVersion
    }

    /// Takes a newer registry record. A changed address, pairing or pin drops the transport and the MCP session.
    func update(_ record: Node) {
        guard record != node else { return }
        let reconnect = record.endpoint != node.endpoint || record.pairing != node.pairing
            || record.nextServerSPKISHA256 != node.nextServerSPKISHA256
        node = record
        if reconnect {
            dropTransport()
            tools = []
            reachable = nil
            problem = nil
            fetchedAt = nil
        }
    }

    func close() {
        transport?.invalidate()
        dropTransport()
    }

    var isPaired: Bool {
        if case .paired = node.pairing { return true }
        return false
    }

    /// Whether the catalog was fetched within `maxAge`.
    func isFresh(maxAge: Duration) -> Bool {
        guard let fetchedAt else { return false }
        return ContinuousClock.now - fetchedAt < maxAge
    }

    // MARK: - Requests

    /// Fetches the node's `tools/list` (every page) within `timeout`. On failure the node's tools disappear.
    @discardableResult
    func refreshTools(timeout: Duration) async -> Bool {
        guard isPaired else {
            tools = []
            reachable = nil
            problem = nil
            return false
        }
        do {
            var collected: [JSONValue] = []
            var cursor: JSONValue?
            for _ in 0..<20 {
                let params: JSONValue = cursor.map { ["cursor": $0] } ?? [:]
                let answer = try await exchange("tools/list", params: params, timeout: timeout)
                guard let result = answer["result"] else {
                    throw NodeRequestFailure.protocolMismatch("tools/list failed: \(Self.errorText(answer))")
                }
                guard let page = result["tools"]?.arrayValue else {
                    throw NodeRequestFailure.protocolMismatch("tools/list without tools")
                }
                collected += page
                guard let next = result["nextCursor"], !next.isNull else { break }
                cursor = next
            }
            tools = collected
            reachable = true
            problem = nil
            fetchedAt = .now
            return true
        } catch {
            let failure = error as? NodeRequestFailure ?? .protocolMismatch(String(describing: error))
            // An unanswered listing counts as offline, unlike a slow tool call.
            if case .deadline = failure { markOffline(failure) } else if failure.meansOffline { markOffline(failure) }
            return false
        }
    }

    /// Runs `tools/call` on the node and returns its JSON-RPC answer as it came. A transport failure after the
    /// request was sent is reported, never retried: the node may have run the command.
    func call(name: String, arguments: JSONValue, deadline: Duration?) async throws(NodeRequestFailure) -> JSONValue {
        do {
            return try await exchange("tools/call", params: ["name": .string(name), "arguments": arguments],
                                      timeout: deadline)
        } catch {
            if error.meansOffline { markOffline(error) }
            throw error
        }
    }

    private func markOffline(_ failure: NodeRequestFailure) {
        tools = []
        reachable = false
        problem = failure.message
        fetchedAt = .now
    }

    /// One request and its JSON-RPC answer, with the retries described on the type.
    private func exchange(_ method: String, params: JSONValue, timeout: Duration?) async throws(NodeRequestFailure)
        -> JSONValue
    {
        var retried = false
        while true {
            try checkCancellation()
            let transport = try await currentTransport()
            let version = try await initialize(transport, timeout: timeout)
            let id = nextRequestID
            nextRequestID += 1
            let (status, body) = try await post(transport, RPC.request(id: id, method: method, params: params),
                                                version: version, timeout: timeout)
            switch status {
            case 200:
                guard let body, body["result"] != nil || body["error"] != nil else {
                    throw .protocolMismatch("HTTP 200 without a JSON-RPC answer")
                }
                return body
            case 400 where !retried:
                // Refused before anything ran (the version header, the framing): start a new MCP session.
                retried = true
                protocolVersion = nil
                continue
            case 403:
                if !retried {
                    retried = true
                    dropTransport()
                    continue
                }
                throw .http(.forbidden)
            default:
                throw .status(status)
            }
        }
    }

    /// POSTs `message`; a 403 the transport reports as an error comes back as status 403.
    private func post(_ transport: any NodeMCPTransport, _ message: JSONValue, version: String?,
                      timeout: Duration?) async throws(NodeRequestFailure) -> (Int, JSONValue?)
    {
        do {
            return try await Deadline.run(timeout) { () async throws(DeviceHTTPError) -> (Int, JSONValue?) in
                let (status, body) = try await transport.post(message, protocolVersion: version)
                return (status, body)
            }
        } catch {
            switch error {
            case .failed(.forbidden):
                return (403, nil)
            case .cancelled, .failed(.cancelled):
                throw .cancelled
            case .timedOut(let limit):
                throw .deadline(limit)
            case .failed(let failure):
                // The connection is gone or unusable: the next request starts over.
                dropTransport()
                throw .http(failure)
            }
        }
    }

    private func currentTransport() async throws(NodeRequestFailure) -> any NodeMCPTransport {
        if let transport { return transport }
        do {
            let made = try await connector.connect(node, idleTimeout: idleTimeout)
            if let transport { return transport }  // another request connected meanwhile
            transport = made
            generation += 1
            protocolVersion = nil
            return made
        } catch {
            throw .connect(error)
        }
    }

    /// Forgets the transport. Requests in flight on it keep it alive until they finish (it invalidates itself when
    /// released), so one request's failure never cancels another's.
    private func dropTransport() {
        transport = nil
        generation += 1
        protocolVersion = nil
    }

    /// The negotiated version; runs `initialize` and `notifications/initialized` first if this transport hasn't.
    private func initialize(_ transport: any NodeMCPTransport, timeout: Duration?) async throws(NodeRequestFailure)
        -> String
    {
        if let protocolVersion { return protocolVersion }
        let started = generation
        let id = nextRequestID
        nextRequestID += 1
        let request = RPC.request(id: id, method: "initialize", params: [
            "protocolVersion": .string(Self.protocolVersions[0]),
            "capabilities": [:],
            "clientInfo": ["name": "vaulthalla-desktop-bridge", "version": .string(clientVersion)],
        ])
        let (status, body) = try await post(transport, request, version: nil, timeout: timeout)
        guard status != 403 else { throw .http(.forbidden) }
        guard status == 200, let body else { throw .status(status) }
        guard let version = body["result"]?["protocolVersion"]?.stringValue else {
            throw .protocolMismatch("initialize failed: \(Self.errorText(body))")
        }
        guard Self.protocolVersions.contains(version) else {
            throw .protocolMismatch("MCP version \(version) isn't supported")
        }
        let (noticeStatus, _) = try await post(transport, RPC.notification("notifications/initialized"),
                                               version: version, timeout: timeout)
        guard noticeStatus == 202 || noticeStatus == 200 else { throw .status(noticeStatus) }
        if generation == started { protocolVersion = version }
        return version
    }

    private func checkCancellation() throws(NodeRequestFailure) {
        if Task.isCancelled { throw .cancelled }
    }

    static func errorText(_ answer: JSONValue) -> String {
        answer["error"]?["message"]?.stringValue ?? "no result"
    }
}

/// Runs work against a deadline; past it, the work is cancelled (a URLSession request stops).
enum Deadline {
    enum Outcome<Failure: Error>: Error {
        case failed(Failure)
        case timedOut(Duration)
        case cancelled
    }

    static func run<T: Sendable, Failure: Error>(
        _ limit: Duration?, _ work: @escaping @Sendable () async throws(Failure) -> T
    ) async throws(Outcome<Failure>) -> T {
        let result: Result<T, Outcome<Failure>> = await withTaskGroup(of: Result<T, Outcome<Failure>>?.self) { group in
            group.addTask {
                do throws(Failure) {
                    return .success(try await work())
                } catch {
                    if Task.isCancelled { return .failure(.cancelled) }
                    return .failure(.failed(error))
                }
            }
            if let limit {
                group.addTask {
                    do {
                        try await Task.sleep(for: limit)
                    } catch {
                        return nil  // cancelled: the work finished first, or the caller was cancelled
                    }
                    return .failure(.timedOut(limit))
                }
            }
            defer { group.cancelAll() }
            while let next = await group.next() {
                if let next { return next }
            }
            return .failure(.cancelled)
        }
        if Task.isCancelled, case .failure = result { throw .cancelled }
        return try result.get()
    }
}

extension Duration {
    /// Whole seconds, for messages.
    var seconds: Int64 { components.seconds }
}
