import Foundation
import Testing
import VHContract
import VHCore
@testable import VHMCP

/// The bridge's MCP surface against in-memory daemons (`FakeTransport`): aggregation, routing, pass-through,
/// cancellation, deadlines and offline nodes. `LoopbackTLSTests` runs the same paths over real mutual TLS.
@Suite(.timeLimit(.minutes(1))) struct BridgeTests {
    let registry = TempRegistry()
    let alpha = FakeDaemon(name: "alpha", tools: Catalog.standard)
    let beta = FakeDaemon(name: "beta", tools: Catalog.standard)

    private func client(settings: MCPBridge.Settings = Client.settings()) throws -> Client {
        try registry.store.add(TempRegistry.paired("node-a", name: "Alpha"))
        try registry.store.add(TempRegistry.paired("node-b", name: "Beta"))
        return Client(registry: registry.store,
                      connector: FakeConnector(daemons: [NodeID(rawValue: "node-a"): alpha,
                                                         NodeID(rawValue: "node-b"): beta]),
                      settings: settings)
    }

    @Test func initializeNegotiatesAndAdvertisesListChanged() async throws {
        defer { registry.remove() }
        let client = try client()
        let reply = try await client.request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:]])
        #expect(reply["result"]?["protocolVersion"] == "2025-06-18")
        #expect(reply["result"]?["capabilities"]?["tools"]?["listChanged"] == true)
        #expect(reply["result"]?["serverInfo"]?["name"] == "vaulthalla-desktop")
        #expect(reply["result"]?["instructions"]?.stringValue?.contains("node argument") == true)

        let unknown = try await client.request("initialize", ["protocolVersion": "1999-01-01"])
        #expect(unknown["result"]?["protocolVersion"] == "2025-11-25")
        #expect(try await client.request("ping")["result"] == [:])
        #expect(try await client.request("resources/list")["error"]?["code"] == -32601)
    }

    @Test func malformedInputGetsJSONRPCErrors() async throws {
        defer { registry.remove() }
        let client = try client()
        await client.sendRaw("{not json")
        await client.sendRaw(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        await client.sendRaw(#"{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}"#)
        await client.sendRaw("   ")
        let errors = client.messages.compactMap { $0["error"]?["code"]?.integerValue }
        #expect(errors == [-32700, -32600, -32600])
        // Nothing reached a node.
        #expect(alpha.methods.isEmpty && beta.methods.isEmpty)
    }

    @Test func toolsListAggregatesNodesWithANodeArgument() async throws {
        defer { registry.remove() }
        alpha.set { $0.tools = Catalog.standard + [Catalog.keyExport, Catalog.declaresNode, Catalog.nodesList] }
        let client = try client()
        try await client.initialize()
        let tools = try await client.tools()

        #expect(JSONValue.array(tools).toolNames == ["nodes_list", "vh_read", "vh_run", "vaults_delete"])
        for tool in tools.dropFirst() {
            let original = try #require(Catalog.standard.first { $0["name"] == tool["name"] })
            // Annotations pass through unchanged; the node argument is required and comes first.
            #expect(tool["annotations"] == original["annotations"])
            #expect(tool["inputSchema"]?["required"]?.arrayValue?.first == "node")
            #expect(tool["inputSchema"]?["properties"]?["node"]?["type"] == "string")
            let nodeHelp = tool["inputSchema"]?["properties"]?["node"]?["description"]?.stringValue ?? ""
            #expect(nodeHelp.contains("Alpha (node-a)") && nodeHelp.contains("Beta (node-b)"))
            // Everything else in the schema is the node's.
            for (key, value) in original["inputSchema"]?["properties"]?.objectValue ?? [:] {
                #expect(tool["inputSchema"]?["properties"]?[key] == value)
            }
            #expect(tool["description"] == original["description"])
        }
        let vaultsDelete = try #require(tools.first { $0["name"] == "vaults_delete" })
        #expect(vaultsDelete["inputSchema"]?["required"] == ["node", "name"])
        #expect(vaultsDelete["inputSchema"]?["additionalProperties"] == false)
    }

    @Test func differingDefinitionsBecomeVariants() async throws {
        defer { registry.remove() }
        var older = Catalog.vhRun
        if case .object(var object) = older {
            object["description"] = "Runs a vh command (older catalog)."
            object["annotations"] = Catalog.annotations("write", title: "Run a vh command")
            older = .object(object)
        }
        let olderRun = older
        beta.set { $0.tools = [Catalog.vhRead, olderRun] }
        let client = try client()
        let tools = try await client.tools()
        #expect(JSONValue.array(tools).toolNames == ["nodes_list", "vh_read", "vh_run", "vh_run_v2", "vaults_delete"])

        let primary = try #require(tools.first { $0["name"] == "vh_run" })
        let variant = try #require(tools.first { $0["name"] == "vh_run_v2" })
        // Each variant keeps its own node's annotations: nothing is merged.
        #expect(primary["annotations"] == Catalog.vhRun["annotations"])
        #expect(variant["annotations"] == olderRun["annotations"])
        #expect(primary["description"]?.stringValue?.contains("use vh_run_v2") == true)
        #expect(variant["description"]?.stringValue?.contains("Beta") == true)

        // A variant only reaches the nodes that define it that way.
        let wrong = try await client.call("vh_run", ["node": "Beta", "command": "status"])
        #expect(wrong["result"]?["isError"] == true)
        #expect(wrong["result"]?.text.contains("call vh_run_v2") == true)
        let right = try await client.call("vh_run_v2", ["node": "Beta", "command": "status"])
        #expect(right["result"]?.text == "beta ran vh_run")
        #expect(beta.calls.map(\.name) == ["vh_run"])
        #expect(alpha.calls.isEmpty)
    }

    @Test func callsRouteToTheNamedNodeWithoutTheNodeArgument() async throws {
        defer { registry.remove() }
        let client = try client()
        _ = try await client.tools()

        let byName = try await client.call("vh_read", ["node": "beta", "command": "vault list"])
        #expect(byName["result"] == ["content": [["type": "text", "text": "beta ran vh_read"]], "isError": false])
        let byID = try await client.call("vh_read", ["node": "node-a", "command": "status"])
        #expect(byID["result"]?.text == "alpha ran vh_read")

        #expect(beta.calls.count == 1)
        #expect(beta.calls.first?.arguments == ["command": "vault list"])
        #expect(alpha.calls.first?.arguments == ["command": "status"])
        // Every request after initialize carried the negotiated version.
        let headers = beta.headers
        #expect(beta.methods.first == "initialize" && headers.first == .some(nil))
        #expect(headers.dropFirst().allSatisfy { $0 == "2025-11-25" })
        #expect(beta.methods.filter { $0 == "initialize" }.count == 1)
    }

    @Test func needsConfirmationAndConfirmPassThrough() async throws {
        defer { registry.remove() }
        let client = try client()
        _ = try await client.tools()

        let refused = try await client.call("vaults_delete", ["node": "Alpha", "name": "projects"])
        #expect(refused["result"] == FakeDaemon.needsConfirmation(tool: "vaults_delete"))
        #expect(refused["result"]?["structuredContent"]?["needs_confirmation"] == "destructive")

        let confirmed = try await client.call("vaults_delete", [
            "node": "Alpha", "name": "projects", "confirm": ["destructive": true],
        ])
        #expect(confirmed["result"]?["isError"] == false)
        #expect(alpha.calls.last?.arguments == ["name": "projects", "confirm": ["destructive": true]])
    }

    @Test func nodeProtocolErrorsPassThroughVerbatim() async throws {
        defer { registry.remove() }
        let client = try client()
        _ = try await client.tools()
        // The node dropped the tool since the list was fetched: its JSON-RPC error comes back as it was.
        alpha.set { $0.tools = [Catalog.vhRead] }
        let reply = try await client.call("vh_run", ["node": "Alpha", "command": "status"])
        #expect(reply["error"] == ["code": -32602, "message": "Unknown tool: vh_run"])
    }

    @Test func badNodeArgumentsAndUnknownTools() async throws {
        defer { registry.remove() }
        try registry.store.add(TempRegistry.paired("node-c", name: "alpha"))
        let client = try client()
        _ = try await client.tools()

        let missing = try await client.call("vh_read", ["command": "status"])
        #expect(missing["result"]?["isError"] == true)
        #expect(missing["result"]?.text.contains("node argument") == true)
        let unknown = try await client.call("vh_read", ["node": "gamma", "command": "status"])
        #expect(unknown["result"]?.text.contains("No node gamma") == true)
        let ambiguous = try await client.call("vh_read", ["node": "ALPHA", "command": "status"])
        #expect(ambiguous["result"]?.text.contains("Several nodes") == true)
        let tool = try await client.call("vh_teleport", ["node": "Alpha"])
        #expect(tool["error"]?["code"] == -32602)
        let notObject = try await client.request("tools/call", ["name": "vh_read", "arguments": "x"])
        #expect(notObject["error"]?["code"] == -32602)
        #expect(alpha.calls.isEmpty && beta.calls.isEmpty)
    }

    @Test func keyCommandsNeverLeaveTheBridge() async throws {
        defer { registry.remove() }
        let client = try client()
        _ = try await client.tools()
        for command in ["vault keys export projects", "vault key import projects --file k.json",
                        "secrets export", "VAULT KEYS EXPORT 3"] {
            let reply = try await client.call("vh_run", ["node": "Alpha", "command": .string(command)])
            #expect(reply["result"]?["isError"] == true)
            #expect(reply["result"]?.text.contains("never handled through MCP") == true)
        }
        let status = try await client.call("vh_read", ["node": "Alpha", "command": "vault keys status"])
        #expect(status["result"]?["isError"] == false)
        #expect(alpha.calls.map(\.name) == ["vh_read"])

        #expect(ToolCatalog.isKeyMaterial(toolName: "vault_keys_export"))
        #expect(ToolCatalog.isKeyMaterial(toolName: "secrets_update"))
        #expect(!ToolCatalog.isKeyMaterial(toolName: "vault_keys_status"))
        #expect(!ToolCatalog.isKeyMaterial(toolName: "users_create"))
    }

    @Test func cancellationStopsTheRequestAndSuppressesTheAnswer() async throws {
        defer { registry.remove() }
        let client = try client()
        _ = try await client.tools()
        alpha.set { $0.callDelay = .seconds(30) }

        await client.send(["jsonrpc": "2.0", "id": "slow", "method": "tools/call",
                           "params": ["name": "vh_read", "arguments": ["node": "Alpha", "command": "status"]]])
        let deadline = ContinuousClock.now + .seconds(5)
        while alpha.callsStarted == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Other requests are answered while the call runs.
        #expect(try await client.request("ping")["result"] == [:])

        await client.send(["jsonrpc": "2.0", "method": "notifications/cancelled",
                           "params": ["requestId": "slow", "reason": "user"]])
        await client.bridge.drain()
        #expect(alpha.cancelledCalls == 1)
        #expect(await client.answer(to: "slow", within: .milliseconds(200)) == nil)
        #expect(alpha.calls.isEmpty)
    }

    @Test func aCallPastItsDeadlineIsAbandoned() async throws {
        defer { registry.remove() }
        let client = try client(settings: Client.settings(deadline: .milliseconds(200)))
        _ = try await client.tools()
        alpha.set { $0.callDelay = .seconds(30) }
        let reply = try await client.call("vh_read", ["node": "Alpha", "command": "status"])
        #expect(reply["result"]?["isError"] == true)
        #expect(reply["result"]?.text.contains("didn't finish within") == true)
        #expect(alpha.cancelledCalls == 1)
        // A slow command doesn't make the node offline.
        #expect(JSONValue.array(try await client.tools()).toolNames.contains("vh_read"))
    }

    @Test func aProtocolRefusalReinitializes() async throws {
        defer { registry.remove() }
        let client = try client()
        _ = try await client.tools()
        // The node was upgraded or downgraded meanwhile and refuses the negotiated version.
        alpha.set { $0.versions = ["2025-06-18"] }
        let reply = try await client.call("vh_read", ["node": "Alpha", "command": "status"])
        #expect(reply["result"]?.text == "alpha ran vh_read")
        #expect(alpha.methods.suffix(4) == ["tools/call", "initialize", "notifications/initialized", "tools/call"])
        #expect(alpha.headers.last == "2025-06-18")
    }

    @Test func offlineNodesLoseTheirToolsAndTheClientIsTold() async throws {
        defer { registry.remove() }
        beta.set { $0.online = false }
        let client = try client(settings: Client.settings(poll: .milliseconds(100)))
        try await client.initialize()

        var tools = try await client.tools()
        let nodeHelp = tools.first { $0["name"] == "vh_read" }?["inputSchema"]?["properties"]?["node"]?["description"]
        #expect(nodeHelp?.stringValue?.contains("Beta") == false)

        let offline = try await client.call("vh_read", ["node": "Beta", "command": "status"])
        #expect(offline["result"]?["isError"] == true)
        #expect(offline["result"]?.text.contains("Beta is offline") == true)

        let listed = try await client.call("nodes_list", [:])
        let rows = try #require(listed["result"]?["structuredContent"]?["nodes"]?.arrayValue)
        #expect(rows.map { $0["reachable"] } == [true, false])
        #expect(rows.map { $0["pairing"] } == ["paired", "paired"])
        #expect(rows[1]["problem"]?.stringValue?.isEmpty == false)

        // Everything goes offline: the list changes, and the client hears about it.
        alpha.set { $0.online = false }
        #expect(await client.first(where: { $0["method"] == "notifications/tools/list_changed" }) != nil)
        tools = try await client.tools()
        #expect(JSONValue.array(tools).toolNames == ["nodes_list"])

        // A node coming back, and a node paired meanwhile, bring their tools back.
        let before = client.listChangedCount
        beta.set { $0.online = true }
        let deadline = ContinuousClock.now + .seconds(5)
        while client.listChangedCount == before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(client.listChangedCount == before + 1)
        tools = try await client.tools()
        #expect(JSONValue.array(tools).toolNames == ["nodes_list", "vh_read", "vh_run", "vaults_delete"])
        await client.bridge.shutdown()
    }

    @Test func unpairedNodesAreListedButOfferNothing() async throws {
        defer { registry.remove() }
        try registry.store.add(Node(id: NodeID(rawValue: "node-p"), displayName: "Pending",
                                    endpoint: NodeEndpoint(host: "10.0.0.9"), pairing: .pending(code: "123456")))
        let client = try client()
        let listed = try await client.call("nodes_list", [:])
        let rows = try #require(listed["result"]?["structuredContent"]?["nodes"]?.arrayValue)
        #expect(rows.map { $0["name"] } == ["Pending", "Alpha", "Beta"])
        #expect(rows[0]["pairing"] == "pending" && rows[0]["reachable"] == .null)
        #expect(rows[0]["host"] == "10.0.0.9" && rows[0]["port"] == 36972)
        let call = try await client.call("vh_read", ["node": "Pending", "command": "status"])
        #expect(call["result"]?.text.contains("isn't paired") == true)
    }

    @Test func deadlineEnvironment() {
        var settings = MCPBridge.Settings()
        #expect(settings.callDeadline == .seconds(600))
        var applied = settings.apply(environment: ["VAULTHALLA_MCP_TIMEOUT": "90"])
        #expect(applied && settings.callDeadline == .seconds(90))
        applied = settings.apply(environment: ["VAULTHALLA_MCP_TIMEOUT": "0"])
        #expect(applied && settings.callDeadline == nil)
        applied = settings.apply(environment: ["VAULTHALLA_MCP_TIMEOUT": "soon"])
        #expect(!applied && settings.callDeadline == nil)
    }
}
