import Foundation
import Network
import Security
import Synchronization
import Testing
import VHContract
import VHCore
import VHIdentity
@testable import VHMCP
import VHNodes
@testable import VHTransport

/// The bridge end to end over the network: two loopback "nodes" serving `/mcp` like the daemon's device listener
/// (TLS 1.3, a client certificate required, the server key pinned by SPKI), reached with device identities from the
/// Keychain through the production ``KeychainNodeConnector`` and `DeviceHTTPClient`.
///
/// Keychain hygiene as in `Tests/VHIdentityTests/TestSupport.swift`: the file keychain, a namespace unique to the run,
/// only the tags below, everything deleted afterwards (also on failure), and the keychain lock shared with the other
/// targets that write keys.
@Suite(.serialized, .timeLimit(.minutes(1))) struct LoopbackTLSTests {
    static let tags = ["node-a", "node-b", "server-a", "server-b"]

    @Test func aggregatesRoutesAndReportsOfflineOverMutualTLS() async throws {
        try await withKeychain { store in
            let keys = DeviceKeys(primary: store, development: nil)
            let deviceA = try await store.createIdentity(for: "node-a", deviceName: "Test Mac", backend: .software)
            let deviceB = try await store.createIdentity(for: "node-b", deviceName: "Test Mac", backend: .software)
            let serverA = try await store.createIdentity(for: "server-a", deviceName: "Server A", backend: .software)
            let serverB = try await store.createIdentity(for: "server-b", deviceName: "Server B", backend: .software)

            let alpha = FakeDaemon(name: "alpha", tools: Catalog.standard)
            let beta = FakeDaemon(name: "beta", tools: Catalog.standard)
            let listenerA = try await MCPListener.start(identity: serverA, device: deviceA.spkiSHA256, daemon: alpha)
            let listenerB = try await MCPListener.start(identity: serverB, device: deviceB.spkiSHA256, daemon: beta)
            defer { listenerA.stop(); listenerB.stop() }

            let registry = TempRegistry()
            defer { registry.remove() }
            try registry.writer.add(TempRegistry.paired("node-a", name: "Alpha", port: listenerA.port,
                                                       pin: serverA.spkiSHA256))
            try registry.writer.add(TempRegistry.paired("node-b", name: "Beta", port: listenerB.port,
                                                       pin: serverB.spkiSHA256))
            let client = Client(registry: registry.store, connector: KeychainNodeConnector(keys: keys))
            try await client.initialize()

            let tools = try await client.tools()
            #expect(JSONValue.array(tools).toolNames == ["nodes_list", "vh_read", "vh_run", "vaults_delete"])
            let help = tools.first { $0["name"] == "vh_read" }?["inputSchema"]?["properties"]?["node"]?["description"]
            #expect(help?.stringValue?.contains("Alpha (node-a), Beta (node-b)") == true)

            let routed = try await client.call("vh_read", ["node": "Beta", "command": "vault list"])
            #expect(routed["result"]?.text == "beta ran vh_read")
            #expect(beta.calls.first?.arguments == ["command": "vault list"])
            #expect(alpha.calls.isEmpty)

            let refused = try await client.call("vaults_delete", ["node": "node-a", "name": "projects"])
            #expect(refused["result"] == FakeDaemon.needsConfirmation(tool: "vaults_delete"))

            // Each node saw its own device key, POSTs with JSON, no Origin, and the version after initialize.
            #expect(listenerA.clientSPKIs.allSatisfy { $0 == deviceA.spkiSHA256 })
            #expect(listenerB.clientSPKIs.allSatisfy { $0 == deviceB.spkiSHA256 })
            for request in listenerA.requests + listenerB.requests {
                #expect(request.method == "POST" && request.target == "/mcp")
                #expect(request.header("Origin") == nil)
                #expect(request.header("Content-Type") == "application/json")
            }

            // Beta goes away: its tools leave the list, calls to it say so, nodes_list shows it unreachable.
            listenerB.stop()
            let offline = try await client.call("vh_read", ["node": "Beta", "command": "status"])
            #expect(offline["result"]?["isError"] == true)
            let listed = try await client.call("nodes_list", [:])
            let rows = try #require(listed["result"]?["structuredContent"]?["nodes"]?.arrayValue)
            #expect(rows.map { $0["reachable"] } == [true, false])
            let after = try await client.tools()
            let helpAfter = after.first { $0["name"] == "vh_read" }?["inputSchema"]?["properties"]?["node"]?["description"]
            #expect(helpAfter?.stringValue?.contains("Beta") == false)
            await client.bridge.shutdown()
        }
    }

    @Test func aServerWithAnotherKeyIsNeverTrusted() async throws {
        try await withKeychain { store in
            let keys = DeviceKeys(primary: store, development: nil)
            let device = try await store.createIdentity(for: "node-a", deviceName: "Test Mac", backend: .software)
            let impostor = try await store.createIdentity(for: "server-a", deviceName: "Impostor", backend: .software)
            let pinned = try await store.createIdentity(for: "server-b", deviceName: "Server", backend: .software)
            let daemon = FakeDaemon(name: "impostor", tools: Catalog.standard)
            let listener = try await MCPListener.start(identity: impostor, device: device.spkiSHA256, daemon: daemon)
            defer { listener.stop() }

            let registry = TempRegistry()
            defer { registry.remove() }
            try registry.writer.add(TempRegistry.paired("node-a", name: "Alpha", port: listener.port,
                                                       pin: pinned.spkiSHA256))
            let client = Client(registry: registry.store, connector: KeychainNodeConnector(keys: keys))
            #expect(JSONValue.array(try await client.tools()).toolNames == ["nodes_list"])
            let listed = try await client.call("nodes_list", [:])
            let row = try #require(listed["result"]?["structuredContent"]?["nodes"]?.arrayValue?.first)
            #expect(row["reachable"] == false)
            #expect(row["problem"]?.stringValue?.contains("doesn't match") == true)
            #expect(daemon.methods.isEmpty, "nothing was sent to a server with the wrong key")
            await client.bridge.shutdown()
        }
    }

    @Test func aMissingDeviceKeyIsExplained() async throws {
        try await withKeychain { store in
            let registry = TempRegistry()
            defer { registry.remove() }
            try registry.writer.add(TempRegistry.paired("node-a", name: "Alpha", port: 9))
            let client = Client(registry: registry.store,
                                connector: KeychainNodeConnector(keys: DeviceKeys(primary: store, development: nil)))
            let listed = try await client.call("nodes_list", [:])
            let row = try #require(listed["result"]?["structuredContent"]?["nodes"]?.arrayValue?.first)
            #expect(row["reachable"] == false)
            #expect(row["problem"]?.stringValue?.contains("key for the node is missing") == true)
        }
    }

    /// The bridge is a credential consumer: when the owner (the app) rotates this Mac's key, the node refuses the old
    /// one with a 403, and the bridge reloads the Keychain and the registry and retries once with the owner's new key.
    /// When the node revokes the key, the reload changes nothing and the refusal stands: the node is reported revoked.
    @Test func survivesTheOwnersRotationAndReportsARevocation() async throws {
        try await withKeychain { store in
            let registry = TempRegistry()
            defer { registry.remove() }
            let device = try await store.createIdentity(for: "node-a", deviceName: "Test Mac", backend: .software)
            let server = try await store.createIdentity(for: "server-a", deviceName: "Server A", backend: .software)
            let daemon = FakeDaemon(name: "alpha", tools: Catalog.standard)
            let listener = try await MCPListener.start(identity: server, device: device.spkiSHA256, daemon: daemon)
            defer { listener.stop() }
            var node = TempRegistry.paired("node-a", name: "Alpha", port: listener.port, pin: server.spkiSHA256)
            try registry.writer.add(node)

            // The bridge's keys and registry carry no lease.
            let consumerKeys = DeviceKeys(primary: store, development: nil)
            let connector = KeychainNodeConnector(keys: consumerKeys, registry: registry.store)
            #expect(connector.keys.role == .consumer)
            let client = Client(registry: registry.store, connector: connector)
            try await client.initialize()
            let before = try await client.call("vh_read", ["node": "Alpha", "command": "status"])
            #expect(before["result"]?.text == "alpha ran vh_read")

            // The owner rotates: the new key replaces the old in the Keychain, the node accepts only the new one, and
            // the owner records the new device id.
            let owner = DeviceKeys(primary: store, development: nil, preferredBackend: .software, lease: registry.lease)
            _ = try await owner.rotate(for: "node-a", serverSPKISHA256: server.spkiSHA256)
            let rotated = try await owner.completeRotation(for: "node-a")
            listener.accept(rotated.spkiSHA256)
            node.pairing = .paired(serverSPKISHA256: server.spkiSHA256, deviceID: rotated.deviceID, since: .now)
            try registry.writer.update(node)

            let after = try await client.call("vh_read", ["node": "Alpha", "command": "status"])
            #expect(after["result"]?.text == "alpha ran vh_read", "the call survives the rotation")
            #expect(listener.clientSPKIs.first == device.spkiSHA256)
            #expect(listener.clientSPKIs.last == rotated.spkiSHA256)

            // Revoked: refused, reloaded (nothing newer), refused again.
            listener.accept(nil)
            let refused = try await client.call("vh_read", ["node": "Alpha", "command": "status"])
            #expect(refused["result"]?["isError"] == true)
            #expect(refused["result"]?.text.contains("isn't paired with the node any more") == true)
            let listed = try await client.call("nodes_list", [:])
            let row = try #require(listed["result"]?["structuredContent"]?["nodes"]?.arrayValue?.first)
            #expect(row["reachable"] == false)
            #expect(row["problem"]?.stringValue?.contains("revoked this Mac") == true)
            #expect(JSONValue.array(try await client.tools()).toolNames == ["nodes_list"])

            // The bridge changed nothing: the owner's key and record are as the owner left them.
            #expect(try await store.identity(for: "node-a")?.deviceID == rotated.deviceID)
            #expect(try await store.pendingRotation(for: "node-a") == nil)
            let saved = try registry.store.reload().map(\.pairing)
            guard case .paired(_, let savedID, _)? = saved.first, saved.count == 1 else {
                Issue.record("the record changed: \(saved)")
                return
            }
            #expect(savedID == rotated.deviceID)
            await client.bridge.shutdown()
        }
    }

    // MARK: - Keychain

    private func withKeychain(_ body: (DeviceIdentityStore) async throws -> Void) async throws {
        await KeychainLock.shared.acquire()
        let store = DeviceIdentityStore(configuration: .init(
            namespace: "sh.vaulthalla.app.test.\(UUID().uuidString.lowercased())", keychain: .fileBased))
        do {
            try await body(store)
        } catch {
            await cleanUp(store)
            await KeychainLock.shared.release()
            throw error
        }
        await cleanUp(store)
        await KeychainLock.shared.release()
    }

    private func cleanUp(_ store: DeviceIdentityStore) async {
        for tag in Self.tags { try? await store.deleteIdentity(for: tag) }
    }
}

/// The keychain lock every test target that writes keys takes (see VHIdentityTests): the file keychain fails under
/// concurrent writers, and `swift test` runs all targets in one process.
actor KeychainLock {
    static let shared = KeychainLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let file = open(
        FileManager.default.temporaryDirectory.appending(path: "sh.vaulthalla.app.test.keychain.lock").path,
        O_CREAT | O_RDWR, 0o600)

    func acquire() async {
        if held {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            held = true
        }
        while flock(file, LOCK_EX | LOCK_NB) != 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        flock(file, LOCK_UN)
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}

/// `/mcp` on 127.0.0.1 over TLS 1.3 with a required client certificate, answering through a ``FakeDaemon`` the way
/// the daemon's device listener does: only the paired device's key gets an answer (anything else: 403), only POST,
/// no `Origin`, JSON content type. HTTP/1.1 with keep-alive, as URLSession expects.
final class MCPListener: Sendable {
    struct Request: Sendable {
        var method: String
        var target: String
        var headers: [String: String]
        var body: Data
        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "vh.test.mcp-listener")
    private let daemon: FakeDaemon
    /// The one device key the node accepts (nil: none, every key is revoked).
    private let device: Mutex<Data?>
    private let connections = Mutex<[ObjectIdentifier: (NWConnection, Data?)]>([:])
    private let received = Mutex<[Request]>([])
    private let peers = Mutex<[Data]>([])

    static func start(identity: DeviceIdentity, device: Data, daemon: FakeDaemon) async throws -> MCPListener {
        let listener = try MCPListener(identity: identity, device: device, daemon: daemon)
        try await listener.ready()
        return listener
    }

    private init(identity: DeviceIdentity, device: Data, daemon: FakeDaemon) throws {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_local_identity(security, sec_identity_create(identity.secIdentity)!)
        sec_protocol_options_set_peer_authentication_required(security, true)
        // Like the daemon: accept any certificate at the handshake, authorize by SPKI afterwards.
        sec_protocol_options_set_verify_block(security, { _, _, complete in complete(true) }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.daemon = daemon
        self.device = Mutex(device)
    }

    /// The device row's key changes (a rotation the owner made), or is revoked (nil).
    func accept(_ spki: Data?) {
        device.withLock { $0 = spki }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var requests: [Request] { received.withLock { $0 } }
    var clientSPKIs: [Data] { peers.withLock { $0 } }

    func stop() {
        for (connection, _) in connections.withLock({ $0.values }) { connection.cancel() }
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
        connections.withLock { $0[ObjectIdentifier(connection)] = (connection, nil) }
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            let spki = Self.peerSPKI(connection)
            if let spki { peers.withLock { $0.append(spki) } }
            connections.withLock { $0[ObjectIdentifier(connection)] = (connection, spki) }
            read(connection, buffer: Data())
        }
        connection.start(queue: queue)
    }

    private static func peerSPKI(_ connection: NWConnection) -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        var leaf: SecCertificate?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if leaf == nil { leaf = sec_certificate_copy_ref(certificate).takeRetainedValue() }
        }
        return leaf.flatMap(CertificateSPKI.sha256(of:))
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        if let (request, rest) = Self.parse(buffer) {
            received.withLock { $0.append(request) }
            let spki = connections.withLock { $0[ObjectIdentifier(connection)]?.1 }
            let (status, body) = answer(request, from: spki)
            connection.send(content: Self.encode(status: status, body: body), completion: .contentProcessed { _ in })
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

    private func answer(_ request: Request, from spki: Data?) -> (Int, Data) {
        guard let spki, spki == device.withLock({ $0 }) else { return (403, Data(#"{"error":"device_unknown"}"#.utf8)) }
        guard request.target == "/mcp" else { return (404, Data()) }
        guard request.header("Origin") == nil else { return (403, Data(#"{"error":"Origin not allowed"}"#.utf8)) }
        guard request.method == "POST" else { return (405, Data()) }
        guard request.header("Content-Type")?.contains("application/json") == true,
              let message = try? JSONDecoder().decode(JSONValue.self, from: request.body)
        else { return (400, Data()) }
        let (status, body) = daemon.respond(message, protocolVersion: request.header("MCP-Protocol-Version"))
        return (status, body.map { try! JSONEncoder().encode($0) } ?? Data())
    }

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

    private static func encode(status: Int, body: Data) -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}
