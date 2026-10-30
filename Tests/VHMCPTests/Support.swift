import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
@testable import VHMCP
import VHTransport

/// The daemon's remote MCP as `core/src/protocols/device/Mcp.cpp` and `core/usage/src/mcp/Server.cpp` serve it:
/// stateless per request, `MCP-Protocol-Version` checked when present (unknown → 400), notifications → 202,
/// `initialize` negotiating the newest supported version, `tools/list`, and `tools/call` with the destructive gate's
/// structured `needs_confirmation`. Tests script the catalog, the versions, outages and slow calls.
final class FakeDaemon: Sendable {
    struct State {
        var tools: [JSONValue]
        var versions = ["2025-11-25", "2025-06-18", "2025-03-26"]
        var online = true
        var callDelay: Duration?
        /// Tool calls that reached the daemon: (tool, arguments).
        var calls: [(name: String, arguments: JSONValue)] = []
        var methods: [String] = []
        var headers: [String?] = []
        var cancelledCalls = 0
        var callsStarted = 0
        /// Answer every POST with 404, as a daemon without `/mcp`.
        var missingEndpoint = false
    }

    let name: String
    let state: Mutex<State>

    init(name: String, tools: [JSONValue]) {
        self.name = name
        self.state = Mutex(State(tools: tools))
    }

    var calls: [(name: String, arguments: JSONValue)] { state.withLock { $0.calls } }
    var methods: [String] { state.withLock { $0.methods } }
    var headers: [String?] { state.withLock { $0.headers } }
    var cancelledCalls: Int { state.withLock { $0.cancelledCalls } }
    var callsStarted: Int { state.withLock { $0.callsStarted } }
    func set(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    /// One POST to `/mcp`.
    func respond(_ message: JSONValue, protocolVersion: String?) -> (status: Int, body: JSONValue?) {
        let versions = state.withLock { state in
            state.methods.append(message["method"]?.stringValue ?? "?")
            state.headers.append(protocolVersion)
            return state.missingEndpoint ? [] : state.versions
        }
        if versions.isEmpty { return (404, nil) }
        if let protocolVersion, !versions.contains(protocolVersion) {
            return (400, RPC.error(id: .null, code: -32600, message: "Unsupported MCP-Protocol-Version: \(protocolVersion)"))
        }
        guard let id = message["id"] else { return (202, nil) }
        let params = message["params"] ?? [:]
        switch message["method"]?.stringValue {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = versions.contains(requested) ? requested : versions[0]
            return (200, RPC.response(id: id, result: [
                "protocolVersion": .string(version), "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "vaulthalla", "version": "test"],
            ]))
        case "tools/list":
            return (200, RPC.response(id: id, result: ["tools": .array(state.withLock { $0.tools })]))
        case "tools/call":
            return (200, call(id: id, params: params))
        default:
            return (200, RPC.error(id: id, code: -32601, message: "Method not found"))
        }
    }

    private func call(id: JSONValue, params: JSONValue) -> JSONValue {
        let name = params["name"]?.stringValue ?? ""
        let arguments = params["arguments"] ?? [:]
        guard let tool = state.withLock({ $0.tools.first { $0["name"]?.stringValue == name } }) else {
            return RPC.error(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
        state.withLock { $0.calls.append((name, arguments)) }
        if tool["annotations"]?["destructiveHint"] == true, arguments["confirm"]?["destructive"] != true {
            return RPC.response(id: id, result: Self.needsConfirmation(tool: name))
        }
        return RPC.response(id: id, result: [
            "content": [["type": "text", "text": .string("\(self.name) ran \(name)")]],
            "isError": false,
        ])
    }

    static func needsConfirmation(tool: String) -> JSONValue {
        let structured: JSONValue = [
            "needs_confirmation": "destructive", "confirm_options": ["destructive"], "command": "vh vault delete",
            "message": "vault delete is destructive.",
            "how_to_confirm": .string("Nothing was changed. ... call \(tool) again with \"confirm\": {\"destructive\": true}"),
        ]
        return ["content": [["type": "text", "text": "{...}"]], "structuredContent": structured, "isError": true]
    }
}

/// The catalog shapes `core/usage/src/mcp/Catalog.cpp` emits.
enum Catalog {
    static func annotations(_ effect: String, title: String) -> JSONValue {
        [
            "title": .string(title), "readOnlyHint": .bool(effect == "read"),
            "destructiveHint": .bool(effect == "destructive"), "idempotentHint": .bool(effect == "read"),
            "openWorldHint": false,
        ]
    }

    static func runSchema() -> JSONValue {
        [
            "type": "object",
            "properties": [
                "command": ["type": "string", "minLength": 1, "description": "The vh command line without 'vh'."],
                "confirm": ["type": "object", "additionalProperties": ["type": ["boolean", "string"]]],
            ],
            "required": ["command"], "additionalProperties": false,
        ]
    }

    static let vhRead: JSONValue = [
        "name": "vh_read", "title": "Run a read-only vh command", "description": "Runs a read-only vh command.",
        "inputSchema": runSchema(), "annotations": annotations("read", title: "Run a read-only vh command"),
    ]
    static let vhRun: JSONValue = [
        "name": "vh_run", "title": "Run a vh command", "description": "Runs any vh command available to agents.",
        "inputSchema": runSchema(), "annotations": annotations("destructive", title: "Run a vh command"),
    ]
    static let vaultsDelete: JSONValue = [
        "name": "vaults_delete", "title": "Delete a vault", "description": "Deletes a vault. Destructive.",
        "inputSchema": [
            "type": "object",
            "properties": ["name": ["type": "string"], "confirm": ["type": "object"]],
            "required": ["name"], "additionalProperties": false,
        ],
        "annotations": annotations("destructive", title: "vh vault delete"),
    ]
    /// Never offered by a real daemon (D4); the bridge must drop it anyway.
    static let keyExport: JSONValue = [
        "name": "vault_keys_export", "description": "Exports a key.", "inputSchema": ["type": "object"],
        "annotations": annotations("read", title: "export"),
    ]
    /// Declares `node` itself: can't be routed unambiguously.
    static let declaresNode: JSONValue = [
        "name": "cluster_info", "description": "Has a node argument.",
        "inputSchema": ["type": "object", "properties": ["node": ["type": "string"]]],
    ]
    /// A daemon's own tool named like the bridge's.
    static let nodesList: JSONValue = ["name": "nodes_list", "inputSchema": ["type": "object"]]

    static let standard = [vhRead, vhRun, vaultsDelete]
}

/// An in-memory `/mcp`: the daemon's answers without the network. Offline nodes fail like a refused connection; a
/// slow call waits (cancellably) before the daemon answers.
struct FakeTransport: NodeMCPTransport {
    let daemon: FakeDaemon

    func post(_ message: JSONValue, protocolVersion: String?) async throws(DeviceHTTPError)
        -> (status: Int, body: JSONValue?)
    {
        let (online, delay) = daemon.state.withLock { ($0.online, $0.callDelay) }
        guard online else { throw .transport("Could not connect to the server.") }
        if message["method"] == "tools/call", let delay {
            daemon.set { $0.callsStarted += 1 }
            do {
                try await Task.sleep(for: delay)
            } catch {
                daemon.set { $0.cancelledCalls += 1 }
                throw .cancelled
            }
        }
        return daemon.respond(message, protocolVersion: protocolVersion)
    }

    func invalidate() {}
}

struct FakeConnector: NodeMCPConnector {
    let daemons: [NodeID: FakeDaemon]
    /// What every node announced for `device.mcp` (nil: the protocol default, unknown).
    var mcp: ProtocolSupport? = nil

    func support(for capability: WsCapability, of node: Node) async -> ProtocolSupport {
        capability == .deviceMCP ? (mcp ?? .unknown) : .unknown
    }

    func connect(_ node: Node, idleTimeout: Duration) async throws(NodeConnectFailure) -> any NodeMCPTransport {
        guard case .paired = node.pairing else { throw .notPaired }
        guard let daemon = daemons[node.id] else { throw .missingKey }
        return FakeTransport(daemon: daemon)
    }
}

/// A node registry in a temporary directory, removed by ``remove()``. The test plays the credential owner, which
/// writes it (``writer``, holding the lease); the bridge gets the read-only ``store`` every consumer has.
struct TempRegistry {
    let directory: URL
    let lease: CredentialLease
    let writer: NodeStore
    let store: NodeStore

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "vh-mcp-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "nodes.json")
        lease = CredentialLease(forRegistry: fileURL, holder: "test")
        try? lease.acquire()
        writer = NodeStore(fileURL: fileURL, lease: lease)
        store = NodeStore(fileURL: fileURL)
    }

    func remove() {
        lease.release()
        try? FileManager.default.removeItem(at: directory)
    }

    static func paired(_ id: String, name: String, host: String = "127.0.0.1", port: UInt16 = 36972,
                       pin: Data = Data(repeating: 7, count: 32)) -> Node {
        Node(id: NodeID(rawValue: id), displayName: name, endpoint: NodeEndpoint(host: host, port: port),
             pairing: .paired(serverSPKISHA256: pin, deviceID: String(repeating: "ab", count: 32), since: .now),
             isNamedByUser: true)
    }
}

/// Drives an `MCPBridge` as a client would: lines in, the messages it writes collected.
final class Client: Sendable {
    private final class Written: Sendable {
        let items = Mutex<[JSONValue]>([])
    }

    let bridge: MCPBridge
    private let written = Written()
    private let nextID = Mutex<Int64>(100)

    init(registry: NodeStore, connector: any NodeMCPConnector, settings: MCPBridge.Settings = Client.settings()) {
        let written = self.written
        bridge = MCPBridge(registry: registry, connector: connector, settings: settings) { data in
            #expect(data.last == 0x0A)
            #expect(data.dropLast().contains(0x0A) == false, "one message per line")
            let message = try! JSONDecoder().decode(JSONValue.self, from: data)
            written.items.withLock { $0.append(message) }
        }
    }

    static func settings(deadline: Duration? = .seconds(30), poll: Duration? = nil) -> MCPBridge.Settings {
        var settings = MCPBridge.Settings()
        settings.callDeadline = deadline
        settings.listTimeout = .seconds(3)
        settings.catalogMaxAge = .zero
        settings.pollInterval = poll
        settings.version = "test"
        return settings
    }

    var messages: [JSONValue] { written.items.withLock { $0 } }

    func send(_ message: JSONValue) async {
        await bridge.receive(try! JSONEncoder().encode(message))
    }

    func sendRaw(_ text: String) async {
        await bridge.receive(Data(text.utf8))
    }

    /// Sends a request and waits for its answer.
    func request(_ method: String, _ params: JSONValue = [:], id: JSONValue? = nil,
                 within timeout: Duration = .seconds(10)) async throws -> JSONValue {
        let id = id ?? .integer(nextID.withLock { value in defer { value += 1 }; return value })
        await send(["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params])
        return try #require(await answer(to: id, within: timeout), "no answer to \(method)")
    }

    func answer(to id: JSONValue, within timeout: Duration = .seconds(10)) async -> JSONValue? {
        await first(within: timeout) { $0["id"] == id && $0["method"] == nil }
    }

    func first(within timeout: Duration = .seconds(10), where predicate: (JSONValue) -> Bool) async -> JSONValue? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let match = messages.first(where: predicate) { return match }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func initialize() async throws {
        _ = try await request("initialize", [
            "protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"],
        ])
        await send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    func tools() async throws -> [JSONValue] {
        try #require(try await request("tools/list")["result"]?["tools"]?.arrayValue)
    }

    func call(_ name: String, _ arguments: JSONValue, id: JSONValue? = nil) async throws -> JSONValue {
        try await request("tools/call", ["name": .string(name), "arguments": arguments], id: id)
    }

    var listChangedCount: Int {
        messages.filter { $0["method"] == "notifications/tools/list_changed" }.count
    }
}

extension JSONValue {
    var toolNames: [String] { arrayValue?.compactMap { $0["name"]?.stringValue } ?? [] }
    var text: String { self["content"]?.arrayValue?.first?["text"]?.stringValue ?? "" }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
