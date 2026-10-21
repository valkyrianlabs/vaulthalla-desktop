public import Foundation
import VHContract
public import VHCore

/// The `vaulthalla-mcp` server: MCP over stdio for an external client (Claude Code, Codex) or an embedded agent, in
/// front of every paired node's remote MCP (`/mcp` on the device listener, mutual TLS with this Mac's device key).
///
/// - `tools/list`: the bridge's `nodes_list`, then the tools of every paired, reachable node with a required `node`
///   argument (``ToolCatalog`` describes the deduplication). The bridge adds no tool of its own besides
///   `nodes_list`, and it never strips a node's confirmation gate: arguments other than `node` go to the node as given.
/// - `tools/call`: routed to the named node's `/mcp` with the arguments minus `node`; the node's result (including
///   `isError` and a structured `needs_confirmation`) or JSON-RPC error comes back verbatim.
/// - Each call runs on its own task: `ping`, other calls and `notifications/cancelled` are handled meanwhile.
///   Cancelling a call cancels its HTTP request, and its answer is never sent. A call has a deadline
///   (``Settings/callDeadline``); past it the request is abandoned (the node may still finish the command).
/// - Nodes that stop answering lose their tools; once the client has sent `notifications/initialized`, the bridge
///   polls the nodes and sends `notifications/tools/list_changed` when the list changes.
///
/// Answers are written through `output`, one JSON-RPC message per call, never anything else.
public actor MCPBridge {
    public struct Settings: Sendable {
        /// How long a `tools/call` may take. nil: no limit.
        public var callDeadline: Duration? = .seconds(600)
        /// How long fetching one node's tool list may take.
        public var listTimeout: Duration = .seconds(8)
        /// A node's tool list younger than this is reused by `tools/list`.
        public var catalogMaxAge: Duration = .seconds(30)
        /// How often nodes are polled for `notifications/tools/list_changed`. nil: never.
        public var pollInterval: Duration? = .seconds(60)
        /// Reported as `serverInfo.version` and to the nodes.
        public var version: String = "dev"

        public init() {}

        /// Applies `VAULTHALLA_MCP_TIMEOUT`, the call deadline in seconds (`0`: none), as the daemon's own variable
        /// spells it. Returns false for a value that isn't a number of seconds (the default stays).
        @discardableResult
        public mutating func apply(environment: [String: String]) -> Bool {
            guard let text = environment["VAULTHALLA_MCP_TIMEOUT"]?.trimmingCharacters(in: .whitespaces) else {
                return true
            }
            guard let seconds = Double(text), seconds >= 0, seconds.isFinite, seconds < 1e9 else { return false }
            callDeadline = seconds == 0 ? nil : .milliseconds(Int64(seconds * 1000))
            return true
        }
    }

    static let serverName = "vaulthalla-desktop"

    private let registry: NodeStore
    private let connector: any NodeMCPConnector
    private let settings: Settings
    private let output: @Sendable (Data) async -> Void
    private let log: BridgeLog

    private var remotes: [NodeID: RemoteNode] = [:]
    /// The registry as last read, in the operator's order.
    private var registryNodes: [Node] = []
    private var catalog = ToolCatalog()
    /// The catalog the client last saw (in a `tools/list` answer or announced by a notification).
    private var announced: ToolCatalog?
    private var clientInitialized = false
    private var protocolVersion = RemoteNode.protocolVersions[0]

    /// Requests being worked on, by JSON-RPC id; the token tells a request from a later one reusing its id.
    private var inFlight: [JSONValue: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Requests whose answer must not be sent (the client cancelled them).
    private var cancelled: Set<UUID> = []
    private var pollTask: Task<Void, Never>?

    public init(registry: NodeStore, connector: any NodeMCPConnector, settings: Settings = Settings(),
                log: BridgeLog = .silent, output: @escaping @Sendable (Data) async -> Void) {
        self.registry = registry
        self.connector = connector
        self.settings = settings
        self.log = log
        self.output = output
    }

    /// Serves newline-delimited messages from `lines` until it ends (the client closed stdin), gives what is still
    /// running `grace` to answer, then cancels the rest.
    public func run<Lines: AsyncSequence & Sendable>(lines: Lines, grace: Duration = .seconds(5)) async
        where Lines.Element == Data
    {
        do {
            for try await line in lines {
                await receive(line)
            }
        } catch {
            log(.error, "reading stdin failed: \(error)")
        }
        let deadline = ContinuousClock.now + grace
        while !inFlight.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await shutdown()
    }

    /// Stops polling, cancels calls in flight (their answers are dropped) and closes the node connections.
    public func shutdown() async {
        pollTask?.cancel()
        pollTask = nil
        let running = inFlight.values
        for request in running {
            cancelled.insert(request.token)
            request.task.cancel()
        }
        for request in running { await request.task.value }
        inFlight.removeAll()
        for remote in remotes.values { await remote.close() }
    }

    /// Waits for the calls in flight (tests).
    func drain() async {
        while let request = inFlight.values.first { await request.task.value }
    }

    // MARK: - Dispatch

    /// Handles one line: a request (answered, possibly later), a notification, or a stray response (ignored).
    public func receive(_ line: Data) async {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) else { return }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            await send(RPC.error(id: .null, code: RPC.parseError, message: "Parse error"))
            return
        }
        guard case .object(let object) = message, object["jsonrpc"] == "2.0" else {
            await send(RPC.error(id: .null, code: RPC.invalidRequest,
                                 message: "Invalid Request: expected one JSON-RPC 2.0 object (batches aren't supported)"))
            return
        }
        guard let methodValue = object["method"] else { return }  // a response to something never sent
        guard let method = methodValue.stringValue else {
            await send(RPC.error(id: object["id"] ?? .null, code: RPC.invalidRequest, message: "Invalid Request"))
            return
        }
        let params = object["params"] ?? [:]
        guard let id = object["id"] else {
            await notification(method, params: params)
            return
        }
        guard id.stringValue != nil || id.integerValue != nil else {
            await send(RPC.error(id: .null, code: RPC.invalidRequest,
                                 message: "Invalid Request: id must be a string or an integer"))
            return
        }
        log(.debug, "request \(method)")

        switch method {
        case "initialize":
            await send(RPC.response(id: id, result: initializeResult(params)))
        case "ping":
            await send(RPC.response(id: id, result: [:]))
        case "tools/list":
            start(id) { bridge in await bridge.listTools() }
        case "tools/call":
            start(id) { bridge in await bridge.callTool(params) }
        default:
            await send(RPC.error(id: id, code: RPC.methodNotFound, message: "Method not found: \(method)"))
        }
    }

    private func notification(_ method: String, params: JSONValue) async {
        switch method {
        case "notifications/initialized":
            clientInitialized = true
            startPolling()
        case "notifications/cancelled":
            guard let id = params["requestId"], let request = inFlight[id] else { return }
            log(.info, "request cancelled by the client")
            cancelled.insert(request.token)
            request.task.cancel()
        default:
            break
        }
    }

    /// Runs a request on its own task; its answer is sent unless the client cancelled it.
    private func start(_ id: JSONValue, _ work: @escaping @Sendable (MCPBridge) async -> Result<JSONValue, RPCFailure>) {
        if let previous = inFlight[id] {
            // A client reusing an id in flight: the newer request wins; the older one's answer is dropped.
            cancelled.insert(previous.token)
            previous.task.cancel()
        }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            let outcome = await work(self)
            await self.finish(id, token: token, outcome)
        }
        inFlight[id] = (token, task)
    }

    private func finish(_ id: JSONValue, token: UUID, _ outcome: Result<JSONValue, RPCFailure>) async {
        if inFlight[id]?.token == token { inFlight[id] = nil }
        guard cancelled.remove(token) == nil else { return }
        switch outcome {
        case .success(let result):
            await send(RPC.response(id: id, result: result))
        case .failure(.verbatim(let error)):
            await send(RPC.error(id: id, verbatim: error))
        case .failure(.code(let code, let message)):
            await send(RPC.error(id: id, code: code, message: message))
        }
    }

    private func send(_ message: JSONValue) async {
        await output(RPC.encodeLine(message))
    }

    enum RPCFailure: Error {
        case code(Int, String)
        /// A node's JSON-RPC error, passed on as it came.
        case verbatim(JSONValue)
    }

    // MARK: - initialize

    private func initializeResult(_ params: JSONValue) -> JSONValue {
        if let requested = params["protocolVersion"]?.stringValue, RemoteNode.protocolVersions.contains(requested) {
            protocolVersion = requested
        } else {
            protocolVersion = RemoteNode.protocolVersions[0]
        }
        return [
            "protocolVersion": .string(protocolVersion),
            "capabilities": ["tools": ["listChanged": true]],
            "serverInfo": [
                "name": .string(Self.serverName), "title": "Vaulthalla Desktop", "version": .string(settings.version),
            ],
            "instructions": .string(Self.instructions),
        ]
    }

    static let instructions = """
        Vaulthalla Desktop's bridge to the Vaulthalla nodes this Mac is paired with. Every tool except nodes_list runs \
        on one node, named by the required node argument (its id or name; nodes_list shows them and whether each is \
        reachable). On each node a tool acts as the Vaulthalla user this Mac was paired by, with that user's \
        permissions. Read before you write, and change only what was asked. When a result says needs_confirmation, \
        nothing happened: show the message to the human and set confirm only after they explicitly approve that exact \
        action. Destructive commands are refused until confirm carries "destructive": true, which needs the human's \
        approval first. Keys and secrets are never handled by agents: no tool exports or imports them.
        """

    // MARK: - tools/list

    private func listTools() async -> Result<JSONValue, RPCFailure> {
        await refresh(force: false)
        announced = catalog
        let tools: [JSONValue] = [Self.nodesListDefinition] + catalog.definitions
        log(.info, "tools/list: \(catalog.entries.count) node tools from \(reachableCount) node(s)")
        return .success(["tools": .array(tools)])
    }

    private var reachableCount: Int {
        Set(catalog.entries.flatMap(\.nodes)).count
    }

    /// Re-reads the registry and fetches the tool lists that are stale (all of them with `force`), concurrently.
    private func refresh(force: Bool) async {
        await syncRegistry()
        let paired = registryNodes.compactMap { remotes[$0.id] }
        let maxAge = settings.catalogMaxAge
        let timeout = settings.listTimeout
        await withTaskGroup(of: Void.self) { group in
            for remote in paired {
                group.addTask {
                    guard await remote.isPaired else { return }
                    if !force, await remote.isFresh(maxAge: maxAge) { return }
                    await remote.refreshTools(timeout: timeout)
                }
            }
        }
        await rebuildCatalog()
    }

    private func syncRegistry() async {
        let nodes: [Node]
        do {
            nodes = try registry.reload()
        } catch {
            log(.error, "the node registry can't be read: \(error)")
            return
        }
        registryNodes = nodes
        let ids = Set(nodes.map(\.id))
        for (id, remote) in remotes where !ids.contains(id) {
            remotes[id] = nil
            await remote.close()
        }
        for node in nodes {
            if let remote = remotes[node.id] {
                await remote.update(node)
            } else {
                remotes[node.id] = RemoteNode(node: node, connector: connector,
                                              idleTimeout: Self.idleTimeout(for: settings.callDeadline),
                                              clientVersion: settings.version)
            }
        }
    }

    /// URLSession's per-request idle timeout: longer than any deadline, which the bridge enforces itself.
    static func idleTimeout(for deadline: Duration?) -> Duration {
        guard let deadline else { return .seconds(7 * 24 * 3600) }
        return deadline + .seconds(30)
    }

    private func rebuildCatalog() async {
        var available: [(node: Node, tools: [JSONValue])] = []
        for node in registryNodes {
            guard let remote = remotes[node.id] else { continue }
            await remote.update(node)
            let tools = await remote.tools
            if !tools.isEmpty { available.append((node, tools)) }
        }
        catalog = ToolCatalog(nodes: available)
    }

    /// Tells the client the list changed, if it has seen a different one and asked to be told (initialized).
    private func announceIfChanged() async {
        guard clientInitialized, let announced, announced != catalog else { return }
        self.announced = catalog
        log(.info, "the tool list changed")
        await send(RPC.notification("notifications/tools/list_changed"))
    }

    private func startPolling() {
        guard pollTask == nil, let interval = settings.pollInterval else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                await self.poll()
            }
        }
    }

    private func poll() async {
        await refresh(force: true)
        await announceIfChanged()
    }

    // MARK: - tools/call

    private func callTool(_ params: JSONValue) async -> Result<JSONValue, RPCFailure> {
        guard let name = params["name"]?.stringValue else {
            return .failure(.code(RPC.invalidParams, "tools/call needs params.name"))
        }
        let arguments = params["arguments"] ?? [:]
        guard case .object(var forwarded) = arguments else {
            return .failure(.code(RPC.invalidParams, "tools/call arguments must be an object"))
        }
        if name == ToolCatalog.nodesListName {
            log(.info, "tools/call nodes_list")
            return .success(await nodesList())
        }
        if catalog[name] == nil { await refresh(force: false) }
        guard let entry = catalog[name] else {
            return .failure(.code(RPC.invalidParams, "Unknown tool: \(name). The node offering it may be offline "
                + "(see nodes_list)."))
        }

        guard let target = forwarded.removeValue(forKey: ToolCatalog.nodeArgument)?.stringValue,
              !target.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return .success(RPC.toolResult(
                text: "Name the node to run \(name) on in the node argument (its id or name). It is offered by: "
                    + describe(entry.nodes) + ".", isError: true))
        }
        let node: Node
        switch resolve(target) {
        case .found(let found): node = found
        case .problem(let text): return .success(RPC.toolResult(text: text, isError: true))
        }
        if let command = forwarded["command"]?.stringValue, ToolCatalog.isKeyMaterial(commandLine: command) {
            log(.warning, "refused a key or secret export/import command for \(node.id)")
            return .success(RPC.toolResult(
                text: "Key and secret material is never handled through MCP. To back up a vault key, use Recovery "
                    + "Keys in Vaulthalla, or run `vh vault keys export <vault>` in a terminal on the node.",
                isError: true))
        }

        guard let remote = remotes[node.id] else {
            return .success(RPC.toolResult(text: "\(node.displayName) isn't a node this Mac knows.", isError: true))
        }
        guard entry.nodes.contains(node.id) else {
            return .success(RPC.toolResult(text: await notOffered(entry, on: node, remote: remote), isError: true))
        }

        log(.info, "tools/call \(entry.remoteName) on \(node.id)")
        let answer: JSONValue
        do {
            answer = try await remote.call(name: entry.remoteName, arguments: .object(forwarded),
                                           deadline: settings.callDeadline)
        } catch {
            log(.warning, "tools/call \(entry.remoteName) on \(node.id) failed: \(error.message)")
            await rebuildCatalog()
            await announceIfChanged()
            return .success(RPC.toolResult(text: Self.failureText(error, node: node), isError: true))
        }
        if let result = answer["result"] { return .success(result) }
        return .failure(.verbatim(answer["error"] ?? ["code": .integer(Int64(RPC.internalError)),
                                                       "message": "The node's answer had no result"]))
    }

    static func failureText(_ failure: NodeRequestFailure, node: Node) -> String {
        switch failure {
        case .deadline(let limit):
            "\(node.displayName) didn't finish within \(limit.seconds) s, so the call was abandoned. The command may "
                + "still complete on the node: check its effect before retrying."
        case .http(.transport), .http(.timeout):
            "The connection to \(node.displayName) failed (\(failure.message)) The command may or may not have run "
                + "on the node: check before retrying."
        case .http(.forbidden):
            "\(node.displayName) refused this Mac: it isn't paired with the node any more. Pair it again in Vaulthalla."
        default:
            "Can't reach \(node.displayName): \(failure.message)"
        }
    }

    private func notOffered(_ entry: ToolCatalog.Entry, on node: Node, remote: RemoteNode) async -> String {
        if case .paired = node.pairing {} else {
            return "\(node.displayName) isn't paired with this Mac (\(Self.pairingName(node.pairing)))."
        }
        if await remote.reachable != true {
            await remote.refreshTools(timeout: settings.listTimeout)
            await rebuildCatalog()
            await announceIfChanged()
        }
        if await remote.reachable != true {
            let problem = await remote.problem ?? "it isn't answering"
            return "\(node.displayName) is offline: \(problem)"
        }
        if let variant = catalog.variants(of: entry.remoteName).first(where: { $0.nodes.contains(node.id) }) {
            return "\(node.displayName) defines \(entry.remoteName) differently (another Vaulthalla version): call "
                + "\(variant.name) for it."
        }
        return "\(node.displayName) doesn't offer \(entry.remoteName)."
    }

    // MARK: - Nodes

    private enum Resolution {
        case found(Node)
        case problem(String)
    }

    /// A node by id (the local id or the daemon's), else by name, ignoring case.
    private func resolve(_ text: String) -> Resolution {
        let wanted = text.trimmingCharacters(in: .whitespaces)
        if let node = registryNodes.first(where: { $0.id.rawValue == wanted || $0.serverNodeID == wanted }) {
            return .found(node)
        }
        let named = registryNodes.filter { $0.displayName.compare(wanted, options: .caseInsensitive) == .orderedSame }
        if named.count == 1 { return .found(named[0]) }
        if named.count > 1 {
            return .problem("Several nodes are named \(wanted): use the id (\(describe(named.map(\.id)))).")
        }
        let known = registryNodes.isEmpty ? "none" : describe(registryNodes.map(\.id))
        return .problem("No node \(wanted). Known nodes: \(known).")
    }

    private func describe(_ ids: [NodeID]) -> String {
        ids.map { id in
            let name = registryNodes.first(where: { $0.id == id })?.displayName ?? id.rawValue
            return "\(name) (\(id.rawValue))"
        }.joined(separator: ", ")
    }

    private func nodesList() async -> JSONValue {
        await refresh(force: true)
        await announceIfChanged()
        var rows: [JSONValue] = []
        for node in registryNodes {
            var row: JSONObject = [
                "id": .string(node.id.rawValue),
                "name": .string(node.displayName),
                "host": .string(node.endpoint.host),
                "port": .integer(Int64(node.endpoint.port)),
                "pairing": .string(Self.pairingName(node.pairing)),
            ]
            if let server = node.serverNodeID { row["server_node_id"] = .string(server) }
            if let remote = remotes[node.id], await remote.isPaired {
                let reachable = await remote.reachable
                row["reachable"] = reachable.map { .bool($0) } ?? .null
                if reachable != true, let problem = await remote.problem { row["problem"] = .string(problem) }
            } else {
                row["reachable"] = .null
            }
            rows.append(.object(row))
        }
        let structured: JSONValue = ["nodes": .array(rows)]
        return RPC.toolResult(text: RPC.prettyText(structured), structured: structured, isError: false)
    }

    static func pairingName(_ state: PairingState) -> String {
        switch state {
        case .unpaired: "unpaired"
        case .pending: "pending"
        case .paired: "paired"
        case .revoked: "revoked"
        }
    }

    static let nodesListDefinition: JSONValue = [
        "name": .string(ToolCatalog.nodesListName),
        "title": "List Vaulthalla nodes",
        "description": """
            The Vaulthalla nodes this Mac knows: id, name, address, pairing state, and whether each paired node is \
            reachable now. Every other tool takes one of these as its node argument (the id or the name).
            """,
        "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
        "outputSchema": [
            "type": "object",
            "properties": [
                "nodes": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string"],
                            "name": ["type": "string"],
                            "host": ["type": "string"],
                            "port": ["type": "integer"],
                            "pairing": ["type": "string", "enum": ["unpaired", "pending", "paired", "revoked"]],
                            "server_node_id": ["type": "string"],
                            "reachable": ["type": ["boolean", "null"]],
                            "problem": ["type": "string"],
                        ],
                        "required": ["id", "name", "host", "port", "pairing", "reachable"],
                    ],
                ],
            ],
            "required": ["nodes"],
        ],
        "annotations": [
            "title": "List Vaulthalla nodes", "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true,
            "openWorldHint": false,
        ],
    ]
}
