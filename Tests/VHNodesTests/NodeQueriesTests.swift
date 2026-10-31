import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
@testable import VHTransport
@testable import VHNodes

/// `NodeQueries` against the mock daemon over a real Device session: caching, deduplicated fetches, invalidation
/// after mutations, polling that pauses with the app, typed denials, stale values through a disconnect, and the
/// needs-confirmation round trip.
extension KeychainSuite {
@Suite struct NodeQueriesTests {
    /// A store on an in-memory node: the cache, deduplication, polling and confirmation logic are the app's own, so
    /// no socket or daemon stands in for the server.
    @MainActor
    private func withStore(_ configure: (inout NodeQueries.Configuration) -> Void = { _ in },
                           _ body: @MainActor (NodeQueries, ScriptedNode) async throws -> Void) async throws {
        let node = ScriptedNode()
        var configuration = NodeQueries.Configuration()
        configure(&configuration)
        try await body(NodeQueries(transport: node, configuration: configuration), node)
    }

    @MainActor @Test func cachesByKeyAndServesFreshValues() async throws {
        try await withStore { store, node in
            node.answer("storage.vault.list") { _ in .ok(["vaults": [Samples.vault(id: 1, name: "Photos")]]) }
            let list = store.query(Ws.Storage.Vault.List.self)
            #expect(store.query(Ws.Storage.Vault.List.self) === list)
            #expect(store.query(Ws.Storage.Vault.Get.self, .init(id: 1))
                !== store.query(Ws.Storage.Vault.Get.self, .init(id: 2)))
            if case .idle = list.state {} else { Issue.record("asking must not fetch") }

            await list.refreshIfStale()
            #expect(list.value?.vaults.map(\.name) == ["Photos"])
            #expect(list.updatedAt != nil)
            #expect(store.hasAnswered)
            // Fresh: a second view appearing doesn't ask again.
            await list.refreshIfStale()
            #expect(node.count(of: "storage.vault.list") == 1)
            // Invalidated: it does.
            list.invalidate()
            await list.refreshIfStale()
            #expect(node.count(of: "storage.vault.list") == 2)
        }
    }

    @MainActor @Test func staleValuesAreRefetched() async throws {
        try await withStore({ $0.staleAfter = .milliseconds(50) }) { store, node in
            node.answer("stats.dashboard.severity") { _ in .ok(Samples.severity("healthy")) }
            let severity = store.query(Ws.Stats.Dashboard.Severity.self)
            await severity.refreshIfStale()
            try await Task.sleep(for: .milliseconds(80))
            #expect(severity.isStale)
            await severity.refreshIfStale()
            #expect(node.count(of: "stats.dashboard.severity") == 2)
        }
    }

    @MainActor @Test func deduplicatesConcurrentFetches() async throws {
        try await withStore { store, node in
            node.answer("stats.dashboard.severity", after: .milliseconds(150)) { _ in .ok(Samples.severity("warning")) }
            let severity = store.query(Ws.Stats.Dashboard.Severity.self)
            async let first: Void = severity.refresh()
            async let second: Void = severity.refresh()
            async let viaKey: Void = store.query(Ws.Stats.Dashboard.Severity.self).refresh()
            _ = await (first, second, viaKey)
            #expect(node.count(of: "stats.dashboard.severity") == 1)
            #expect(severity.value?.stats.overallStatus == "warning")
        }
    }

    @MainActor @Test func keepsTheLastValueWhileRefreshing() async throws {
        try await withStore { store, node in
            let status = Shared("healthy")
            node.answer("stats.dashboard.severity", after: .milliseconds(100)) { _ in .ok(Samples.severity(status.value)) }
            let severity = store.query(Ws.Stats.Dashboard.Severity.self)
            await severity.refresh()
            status.value = "error"
            let refresh = Task { await severity.refresh() }
            try await Task.sleep(for: .milliseconds(30))
            #expect(severity.isFetching)
            #expect(severity.value?.stats.overallStatus == "healthy")
            await refresh.value
            #expect(severity.value?.stats.overallStatus == "error")
        }
    }

    @MainActor @Test func mutationsInvalidateRelatedQueries() async throws {
        try await withStore { store, node in
            let name = Shared("Photos")
            node.answer("storage.vault.list") { _ in .ok(["vaults": [Samples.vault(id: 1, name: name.value)]]) }
            node.answer("storage.vault.update") { payload in
                name.value = payload["name"]?.stringValue ?? name.value
                return .ok(["vault": Samples.vault(id: 1, name: name.value)])
            }
            let list = store.query(Ws.Storage.Vault.List.self)
            let unrelated = store.query(Ws.Stats.Dashboard.Severity.self)
            node.answer("stats.dashboard.severity") { _ in .ok(Samples.severity("healthy")) }
            let observer = Task { await list.observe() }
            let other = Task { await unrelated.observe() }
            try await waitFor { list.value != nil && unrelated.value != nil }

            let result = await store.perform(Ws.Storage.Vault.Update.self, .init(id: 1, name: .value("Pictures")),
                                             invalidating: ["storage.vault"])
            guard case .success(let response) = result else { throw TestFailure("update failed: \(result)") }
            #expect(response.vault.name == "Pictures")
            // The observed list refetches by itself; the unrelated query doesn't.
            try await waitFor { list.value?.vaults.first?.name == "Pictures" }
            #expect(node.count(of: "storage.vault.list") == 2)
            #expect(node.count(of: "stats.dashboard.severity") == 1)
            observer.cancel()
            other.cancel()
        }
    }

    @MainActor @Test func pollsOnlyWhileObservedAndActive() async throws {
        try await withStore { store, node in
            node.answer("stats.dashboard.severity") { _ in .ok(Samples.severity("healthy")) }
            let severity = store.query(Ws.Stats.Dashboard.Severity.self)
            let observer = Task { await severity.observe(polling: .milliseconds(60)) }
            try await waitFor { node.count(of: "stats.dashboard.severity") >= 3 }

            // The app resigns active: polling pauses.
            store.isActive = false
            try await Task.sleep(for: .milliseconds(80))
            let paused = node.count(of: "stats.dashboard.severity")
            try await Task.sleep(for: .milliseconds(250))
            #expect(node.count(of: "stats.dashboard.severity") == paused)

            // Back: the overdue value is fetched at once, then polling continues.
            store.isActive = true
            try await waitFor(within: .milliseconds(150)) { node.count(of: "stats.dashboard.severity") > paused }
            try await waitFor { node.count(of: "stats.dashboard.severity") >= paused + 3 }

            // No view observes it any more: polling stops.
            observer.cancel()
            try await Task.sleep(for: .milliseconds(80))
            let stopped = node.count(of: "stats.dashboard.severity")
            try await Task.sleep(for: .milliseconds(250))
            #expect(node.count(of: "stats.dashboard.severity") == stopped)
        }
    }

    @MainActor @Test func typedDenialsFailTheQuery() async throws {
        try await withStore { store, node in
            node.answer("stats.dashboard.overview") { _ in .refuse("Permission denied: admin.stats.view", code: "denied") }
            let overview = store.query(Ws.Stats.Dashboard.Overview.self, .init())
            await overview.refresh()
            guard case .failed(.denied(let message)) = overview.state else {
                throw TestFailure("expected a denial, got \(overview.state)")
            }
            #expect(message.contains("admin.stats.view"))
        }
    }

    @MainActor @Test func keepsDataThroughADisconnect() async throws {
        try await withStore { store, node in
            node.answer("storage.vault.list") { _ in .ok(["vaults": [Samples.vault(id: 1, name: "Photos")]]) }
            let list = store.query(Ws.Storage.Vault.List.self)
            await list.refresh()
            node.stop()
            store.connectionChanged(online: false)
            #expect(!store.isConnected)
            await list.refresh()
            #expect(list.value?.vaults.count == 1)
            #expect(list.refreshError == .disconnected || list.refreshError == .timeout)
        }
    }

    @MainActor @Test func confirmationRoundTrip() async throws {
        try await withStore { store, node in
            node.answer("storage.vault.remove") { payload in
                if payload["accept_key_loss"]?.boolValue != true {
                    return .refuse("The key of “Photos” was never exported.", code: "vault_upstream_key_loss")
                }
                if payload["now"]?.boolValue == true, payload["confirm_now"]?.boolValue != true {
                    return .refuse("Delete “Photos” now?", code: "vault_delete_now")
                }
                return .ok(["deletion": .null])
            }
            node.answer("storage.vault.list") { _ in .ok(["vaults": []]) }
            let list = store.query(Ws.Storage.Vault.List.self)
            await list.refresh()

            // Delete now, typed name given in the view (vault_delete_now pre-accepted); the key loss is asked.
            let first = await store.perform(Ws.Storage.Vault.Remove.self, .init(id: 1, now: true),
                                            invalidating: ["storage.vault"], accepting: ["vault_delete_now"])
            guard case .needsConfirmation(let request) = first else { throw TestFailure("expected a question") }
            #expect(request.code == "vault_upstream_key_loss")
            #expect(request.message.contains("never exported"))
            #expect(request.isAcceptable)
            #expect(request.confirmation?.acceptField == "accept_key_loss")

            let second = await store.accept(request)
            guard case .success = second else { throw TestFailure("expected success, got \(second)") }
            let sent = node.payloads(of: "storage.vault.remove")
            // Asked, accepted key loss (resent), then delete-now answered from the view's acceptance (resent).
            #expect(sent.count == 4)
            #expect(sent.last?["accept_key_loss"]?.boolValue == true)
            #expect(sent.last?["confirm_now"]?.boolValue == true)
            #expect(list.isStale)
        }
    }

    @MainActor @Test func mutationObjectPresentsTheConfirmation() async throws {
        try await withStore { store, node in
            node.answer("storage.vault.remove") { payload in
                payload["confirm_now"]?.boolValue == true
                    ? .ok(["deletion": .null]) : .refuse("Delete “Photos” now?", code: "vault_delete_now")
            }
            let remove = NodeMutation(Ws.Storage.Vault.Remove.self, on: store, invalidating: ["storage.vault"])
            #expect(await remove.run(.init(id: 1, now: true)) == nil)
            #expect(remove.confirmation?.message == "Delete “Photos” now?")
            #expect(await remove.confirm() != nil)
            #expect(remove.confirmation == nil)
            if case .succeeded = remove.phase {} else { Issue.record("expected success") }
        }
    }

    /// Polls `condition` until it holds.
    @MainActor
    private func waitFor(within timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestFailure("condition not met within \(timeout)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
}

/// A node answering typed requests from scripted JSON, decoded with the contract's own types; refusals go through
/// `WsError.classify` as an ERROR frame would. `stop()` makes it unreachable.
final class ScriptedNode: NodeTransport {
    enum Reply: Sendable {
        case ok(JSONValue)
        case refuse(String, code: String)
    }

    typealias Responder = @Sendable (JSONValue) -> Reply

    private struct State {
        var responders: [String: (delay: Duration?, respond: Responder)] = [:]
        var sent: [(command: String, payload: JSONValue)] = []
        var stopped = false
    }

    private let state = Mutex(State())

    func answer(_ command: String, after delay: Duration? = nil, _ respond: @escaping Responder) {
        state.withLock { $0.responders[command] = (delay, respond) }
    }

    func payloads(of command: String) -> [JSONValue] {
        state.withLock { $0.sent.filter { $0.command == command }.map(\.payload) }
    }

    func count(of command: String) -> Int { payloads(of: command).count }

    func stop() { state.withLock { $0.stopped = true } }

    func send<R: WsRequest>(_ request: R.Type, payload: R.Payload) async throws(WsError) -> R.Response {
        let command = R.command.rawValue
        let json: JSONValue
        do {
            json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload))
        } catch {
            throw .error("\(command): payload didn't encode: \(error)")
        }
        let (stopped, scripted) = state.withLock { state in
            if !state.stopped { state.sent.append((command, json)) }
            return (state.stopped, state.responders[command])
        }
        if stopped { throw .disconnected }
        guard let (delay, respond) = scripted else { throw .error("no answer scripted for \(command)") }
        if let delay { try? await Task.sleep(for: delay) }
        switch respond(json) {
        case .ok(let data):
            do {
                return try JSONDecoder().decode(R.Response.self, from: JSONEncoder().encode(data))
            } catch {
                throw .contractMismatch("\(command): \(error)")
            }
        case .refuse(let message, let code):
            throw WsError.classify(status: "ERROR", error: message, refusal: .init(code: code), command: command)
                ?? .error(message)
        }
    }
}

/// A value the scripted node's responders read and tests change.
final class Shared<Value: Sendable>: Sendable {
    private let storage: Synchronization.Mutex<Value>
    init(_ value: Value) { storage = .init(value) }
    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// Answers shaped like the contract's models.
enum Samples {
    static func vault(id: Int64, name: String) -> JSONValue {
        [
            "id": .integer(id), "name": .string(name), "slug": .string(name.lowercased()), "fuse_name": .null,
            "effective_fuse_name": .string(name.lowercased()), "type": "local", "description": "", "quota": 0,
            "owner_id": 1, "mount_point": .string(name.lowercased()), "allow_fs_write": true, "is_active": true,
            "created_at": "2026-10-20T12:00:00Z", "owner": "admin",
        ]
    }

    static func severity(_ status: String) -> JSONValue {
        ["stats": ["overall_status": .string(status), "error_count": 0, "warning_count": 0, "checked_at": 1_790_000_000]]
    }
}
