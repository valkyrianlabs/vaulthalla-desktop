import Foundation
import Testing
import VHContract
import VHCore
@testable import VHTransport

/// A plaintext client for a loopback test server, with backoff short enough to watch a reconnect.
private func client(for server: TestServer, tokens: TokenStore = TokenStore()) throws -> WsClient {
    try WsClient(
        configuration: .init(endpoint: NodeEndpoint(host: "127.0.0.1", port: server.port), security: .plaintext,
                             reconnect: ReconnectPolicy(base: .milliseconds(20), cap: .milliseconds(80)),
                             connectTimeout: .seconds(2)),
        tokens: tokens
    )
}

/// Waits (bounded) for the first element of `stream` that satisfies `predicate`.
private func first<T: Sendable>(_ stream: AsyncStream<T>, within timeout: Duration = .seconds(2),
                                where predicate: @escaping @Sendable (T) -> Bool) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await element in stream where predicate(element) { return element }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

/// Runs `body` with a started server and a client for it, and tears both down.
private func withServer(_ body: (TestServer, WsClient) async throws -> Void) async throws {
    let server = try await TestServer.start()
    let ws = try client(for: server)
    defer { server.stop() }
    try await body(server, ws)
    await ws.close()
}

@Suite struct WsClientTests {
    @Test func correlatesOutOfOrderAnswers() async throws {
        try await withServer { server, ws in
            let contract = Task { try await ws.send(Ws.Meta.Contract.Get.self) }
            let group = Task { try await ws.send(Ws.Group.Get.self, payload: .init(id: 7)) }

            let a = try #require(await server.next())
            let b = try #require(await server.next())
            let (contractRequest, groupRequest) = a.command == "meta.contract.get" ? (a, b) : (b, a)
            #expect(contractRequest.frame["payload"] == .null)
            #expect(groupRequest.frame["payload"] == ["id": 7])
            #expect(contractRequest.frame["token"] == nil)
            #expect(contractRequest.requestId != groupRequest.requestId)

            // Answer the later request first.
            groupRequest.ok(["group": [
                "id": 7, "name": "ops", "description": .null, "created_at": "2026-10-20 12:00:00", "members": [],
            ]])
            contractRequest.ok(["contract_version": 2, "contract_hash": "c", "ws_hash": .string(WsContract.wsHash),
                                "models_hash": .string(WsContract.modelsHash)])

            #expect(try await group.value.group.name == "ops")
            #expect(try await contract.value.wsHash == WsContract.wsHash)
        }
    }

    @Test(arguments: [
        ("denied", "Not allowed", WsError.denied("Not allowed")),
        ("not_found", "No such group", .notFound("No such group")),
        ("invalid", "Bad name", .invalid("Bad name")),
        ("conflict", "Exists", .conflict("Exists")),
        ("user_delete", "Delete alice and her 2 vaults?", .needsConfirmation(code: "user_delete",
                                                                            message: "Delete alice and her 2 vaults?")),
        (nil, "You do not have permission to do that", .denied("You do not have permission to do that")),
        (nil, "Rate limit exceeded. Try again in 3s.", .error("Rate limit exceeded. Try again in 3s.")),
    ] as [(String?, String, WsError)])
    func mapsRefusals(code: String?, message: String, expected: WsError) async throws {
        try await withServer { server, ws in
            let payload = Ws.Auth.User.Delete.Payload(id: 2, transferTo: .null)
            let reply = Task { try await ws.send(Ws.Auth.User.Delete.self, payload: payload) }
            let request = try #require(await server.next())
            #expect(request.frame["payload"] == ["id": 2, "transfer_to": .null])
            request.refuse(message, code: code)
            await #expect(throws: expected) { try await reply.value }
        }
    }

    @Test func mapsUnauthorized() async throws {
        try await withServer { server, ws in
            let reply = Task { try await ws.send(Ws.Meta.Contract.Get.self) }
            try #require(await server.next()).refuse("You must be authenticated to perform this action.",
                                                     status: "UNAUTHORIZED")
            await #expect(throws: WsError.unauthorized("You must be authenticated to perform this action.")) {
                try await reply.value
            }
        }
    }

    @Test func reportsAnswersThatBreakTheContract() async throws {
        try await withServer { server, ws in
            let reply = Task { try await ws.send(Ws.Meta.Contract.Get.self) }
            try #require(await server.next()).ok(["contract_version": 1])
            await #expect {
                try await reply.value
            } throws: { error in
                guard case WsError.contractMismatch(let detail) = error else { return false }
                return detail.contains("meta.contract.get") && detail.contains("missing")
            }
        }
    }

    @Test func timeoutMeansNoAnswerYetAndTheLateAnswerIsUnsolicited() async throws {
        try await withServer { server, ws in
            let unsolicited = await ws.unsolicitedMessages()
            let reply = Task { try await ws.send(command: "stats.slow", payload: [:], timeout: .milliseconds(100)) }
            let request = try #require(await server.next())
            await #expect(throws: WsError.timeout) { try await reply.value }

            request.ok(["late": true])
            let late = await first(unsolicited) { $0.requestId == request.requestId }
            #expect(late?.data == ["late": true])
        }
    }

    @Test func cancellingTheTaskCancelsTheRequest() async throws {
        try await withServer { server, ws in
            let task = Task { try await ws.send(command: "fs.dir.list", payload: ["vault_id": 1]) }
            let request = try #require(await server.next())
            task.cancel()
            await #expect(throws: WsError.cancelled) { try await task.value }

            // The request is forgotten: its answer no longer resolves anything.
            let unsolicited = await ws.unsolicitedMessages()
            request.ok()
            #expect(await first(unsolicited) { $0.requestId == request.requestId } != nil)
        }
    }

    @Test func connectionLossFailsPendingRequestsAndReconnects() async throws {
        try await withServer { server, ws in
            let states = await ws.states()
            let reply = Task { try await ws.send(command: "fs.dir.list", payload: [:]) }
            _ = try #require(await server.next())
            server.dropConnections()
            await #expect(throws: WsError.disconnected) { try await reply.value }

            // Backoff, then a new connection on which requests work again.
            let reconnecting = await first(states) {
                if case .reconnecting = $0 { return true }
                return false
            }
            #expect(reconnecting != nil)
            #expect(await first(states) { $0 == .connected } != nil)

            let again = Task { try await ws.send(command: "fs.dir.list", payload: [:]) }
            try #require(await server.next()).ok(["files": []])
            #expect(try await again.value == ["files": []])
        }
    }

    @Test func deliversServerNotices() async throws {
        try await withServer { server, ws in
            let unsolicited = await ws.unsolicitedMessages()
            await ws.connect()
            #expect(await first(await ws.states()) { $0 == .connected } != nil)

            server.broadcast(["command": "error", "status": "parse_error", "message": "Invalid JSON"])
            let notice = try #require(await first(unsolicited) { _ in true })
            #expect(notice.command == "error")
            #expect(notice.status == "parse_error")
            #expect(notice.message == "Invalid JSON")
            #expect(notice.requestId == nil)
        }
    }

    @Test func closeFailsPendingRequestsAndStops() async throws {
        let server = try await TestServer.start()
        defer { server.stop() }
        let ws = try client(for: server)
        let reply = Task { try await ws.send(command: "fs.dir.list", payload: [:]) }
        _ = try #require(await server.next())
        await ws.close()
        await #expect(throws: WsError.disconnected) { try await reply.value }
        #expect(await ws.connectionState == .idle)
    }

    @Test func carriesAndRotatesTheEnvelopeToken() async throws {
        let server = try await TestServer.start()
        defer { server.stop() }
        let tokens = TokenStore(token: "first")
        let ws = try client(for: server, tokens: tokens)
        let reply = Task { try await ws.send(command: "auth.refresh", payload: .null) }
        let request = try #require(await server.next())
        #expect(request.frame["token"] == "first")
        request.ok(["user": [:]], token: "second")
        _ = try await reply.value
        #expect(tokens.token == "second")
        await ws.close()
    }

    @Test(arguments: ["example.com", "10.0.0.1", "fe80::1", "localhost.example.com"])
    func refusesPlaintextBeyondLoopback(host: String) {
        #expect(throws: WsClient.ConfigurationError.plaintextRequiresLoopback(host: host)) {
            try WsClient(configuration: .init(endpoint: NodeEndpoint(host: host), security: .plaintext))
        }
    }

    @Test(arguments: ["127.0.0.1", "127.8.9.10", "::1", "localhost", "LOCALHOST"])
    func allowsPlaintextOnLoopback(host: String) throws {
        _ = try WsClient(configuration: .init(endpoint: NodeEndpoint(host: host), security: .plaintext))
    }

    @Test func backoffGrowsWithJitterUpToTheCap() {
        let policy = ReconnectPolicy(base: .milliseconds(500), cap: .seconds(30))
        for attempt in 1...12 {
            let ceiling = min(Duration.seconds(30), .milliseconds(500) * (1 << (attempt - 1)))
            let delay = policy.delay(attempt: attempt)
            #expect(delay >= ceiling / 2 && delay <= ceiling)
        }
    }
}
