import Foundation
import Testing
import VHContract
import VHCore
@testable import VHMCP

/// `--client` and the per-node switches (`agent-access.json` beside the registry): a node switched off for the
/// bridge's client is absent from `nodes_list` and `tools/list`, never contacted, and a call naming it is refused with
/// a plain message. Without `--client` the bridge serves every paired node, whatever the file says.
@Suite(.timeLimit(.minutes(1))) struct ClientSwitchTests {
    let registry = TempRegistry()
    let alpha = FakeDaemon(name: "alpha", tools: Catalog.standard)
    let beta = FakeDaemon(name: "beta", tools: Catalog.standard)
    var accessURL: URL { AgentAccess.fileURL(besideRegistry: registry.store.fileURL) }

    private func client(_ agent: AgentClient?) throws -> Client {
        try registry.writer.add(TempRegistry.paired("node-a", name: "Alpha"))
        try registry.writer.add(TempRegistry.paired("node-b", name: "Beta"))
        var settings = Client.settings()
        settings.client = agent
        settings.accessURL = accessURL
        return Client(registry: registry.store,
                      connector: FakeConnector(daemons: [NodeID(rawValue: "node-a"): alpha,
                                                         NodeID(rawValue: "node-b"): beta]),
                      settings: settings)
    }

    private func exclude(_ id: String, from agent: AgentClient) throws {
        var access = try AgentAccess.load(from: accessURL)
        access.set(NodeID(rawValue: id), available: false, to: agent)
        try access.save(to: accessURL)
    }

    private func listedNodes(_ client: Client) async throws -> [String] {
        let listed = try await client.call("nodes_list", [:])
        return listed["result"]?["structuredContent"]?["nodes"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
    }

    @Test func aSwitchedOffNodeIsHiddenRefusedAndNeverContacted() async throws {
        defer { registry.remove() }
        try exclude("node-b", from: .codex)
        let client = try client(.codex)
        try await client.initialize()

        let tools = try await client.tools()
        #expect(JSONValue.array(tools).toolNames == ["nodes_list", "vh_read", "vh_run", "vaults_delete"])
        let help = tools[1]["inputSchema"]?["properties"]?["node"]?["description"]?.stringValue ?? ""
        #expect(help.contains("Alpha (node-a)") && !help.contains("Beta"))
        #expect(try await listedNodes(client) == ["node-a"])

        for target in ["node-b", "Beta", "beta"] {
            let refused = try await client.call("vh_read", ["node": .string(target), "command": "vault list"])
            #expect(refused["result"]?["isError"] == true)
            #expect(refused["result"]?.text.contains("Beta is turned off for Codex in Vaulthalla") == true)
        }
        // Even a tool no available node offers is refused for the switched-off node, not reported unknown.
        let unknown = try await client.call("only_on_beta", ["node": "node-b"])
        #expect(unknown["result"]?.text.contains("turned off for Codex") == true)
        #expect(beta.methods.isEmpty, "a switched-off node is never contacted")

        let allowed = try await client.call("vh_read", ["node": "Alpha", "command": "vault list"])
        #expect(allowed["result"]?.text == "alpha ran vh_read")
    }

    @Test func switchesAreReadLiveAndNodesPairedLaterAreAvailable() async throws {
        defer { registry.remove() }
        let client = try client(.claudeCode)
        try await client.initialize()
        #expect(try await listedNodes(client) == ["node-a", "node-b"])

        try exclude("node-a", from: .claudeCode)
        #expect(try await listedNodes(client) == ["node-b"])
        try registry.writer.add(TempRegistry.paired("node-c", name: "Gamma"))
        #expect(try await listedNodes(client) == ["node-b", "node-c"])

        var access = try AgentAccess.load(from: accessURL)
        access.set(NodeID(rawValue: "node-a"), available: true, to: .claudeCode)
        try access.save(to: accessURL)
        #expect(try await listedNodes(client) == ["node-a", "node-b", "node-c"])
    }

    @Test func switchesApplyOnlyToTheirClientAndNotWithoutOne() async throws {
        defer { registry.remove() }
        try exclude("node-b", from: .claudeCode)
        let codex = try client(.codex)
        #expect(try await listedNodes(codex) == ["node-a", "node-b"])
        let unnamed = Client(registry: registry.store,
                             connector: FakeConnector(daemons: [NodeID(rawValue: "node-a"): alpha,
                                                                NodeID(rawValue: "node-b"): beta]),
                             settings: {
                                 var settings = Client.settings()
                                 settings.accessURL = accessURL
                                 return settings
                             }())
        #expect(try await listedNodes(unnamed) == ["node-a", "node-b"])
        let call = try await unnamed.call("vh_read", ["node": "Beta", "command": "vault list"])
        #expect(call["result"]?.text == "beta ran vh_read")
    }

    @Test func unreadableSwitchesFailClosed() async throws {
        defer { registry.remove() }
        let client = try client(.claudeDesktop)
        try FileManager.default.createDirectory(at: accessURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: accessURL)
        let listed = try await client.call("nodes_list", [:])
        #expect(listed["result"]?["structuredContent"]?["nodes"] == [])
        #expect(listed["result"]?["structuredContent"]?["notice"]?.stringValue?.contains("No node is available to Claude") == true)
        let refused = try await client.call("vh_read", ["node": "Alpha", "command": "vault list"])
        #expect(refused["result"]?.text.contains("can't read which nodes are") == true)
        #expect(alpha.methods.isEmpty && beta.methods.isEmpty)

        try Data(#"{"version": 99, "excluded": {}}"#.utf8).write(to: accessURL)
        #expect(try await listedNodes(client) == [])
        try FileManager.default.removeItem(at: accessURL)
        #expect(try await listedNodes(client) == ["node-a", "node-b"])
    }

    /// Which identity each node gets for a client: its own (listed "own"), this Mac's by default or by choice
    /// ("mac"), or none: listed with the reason and refused, and never this Mac's because its own was refused.
    @Test func nodesWithoutAnIdentityForTheClientAreListedWithTheReason() async throws {
        defer { registry.remove() }
        var access = AgentAccess()
        access.setOwnPairing(true, for: .codex)
        try FileManager.default.createDirectory(at: accessURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try access.save(to: accessURL)
        let client = try client(.codex)
        // Alpha: Codex's own pairing. Beta: none, and own pairing chosen: unavailable.
        var alphaRecord = TempRegistry.paired("node-a", name: "Alpha")
        alphaRecord.agentIdentities["codex"] = AgentIdentity(deviceID: "cd", deviceName: "Codex on Mac", certificate: Data(),
                                                             serverSPKISHA256: Data(repeating: 7, count: 32), pairedAt: .now)
        _ = try registry.writer.update(alphaRecord)

        var rows = try await listed(client)
        #expect(rows.map { $0["identity"] } == ["own", nil])
        #expect(rows[1]["available"] == false)
        #expect(rows[1]["problem"]?.stringValue?.contains("Codex has no pairing of its own with Beta") == true)
        let refused = try await client.call("vh_read", ["node": "Beta", "command": "vault list"])
        #expect(refused["result"]?.text.contains("no pairing of its own") == true)
        #expect(beta.methods.isEmpty, "never contacted")

        // This Mac's pairing chosen for Beta.
        access.setMacPairing(true, on: NodeID(rawValue: "node-b"), for: .codex)
        try access.save(to: accessURL)
        rows = try await listed(client)
        #expect(rows.map { $0["identity"] } == ["own", "mac"])

        // The node revoked Codex's own pairing on Alpha: unavailable, though this Mac's pairing is fine there.
        alphaRecord.agentIdentities["codex"]?.refusedAt = .now
        access.setMacPairing(true, on: NodeID(rawValue: "node-a"), for: .codex)
        try access.save(to: accessURL)
        _ = try registry.writer.update(alphaRecord)
        rows = try await listed(client)
        #expect(rows[0]["available"] == false)
        #expect(rows[0]["problem"]?.stringValue?.contains("no longer accepts") == true)
        let blocked = try await client.call("vh_read", ["node": "Alpha", "command": "vault list"])
        #expect(blocked["result"]?.text.contains("no longer accepts") == true)
    }

    private func listed(_ client: Client) async throws -> [JSONValue] {
        try await client.call("nodes_list", [:])["result"]?["structuredContent"]?["nodes"]?.arrayValue ?? []
    }

    @Test func argumentsNameAKnownClientOrNothing() throws {
        #expect(try BridgeArguments.parse([]).get() == nil)
        #expect(try BridgeArguments.parse(["--client", "claude-code"]).get() == .claudeCode)
        #expect(try BridgeArguments.parse(["--client=codex"]).get() == .codex)
        #expect(try BridgeArguments.parse(["--client", "claude-desktop"]).get() == .claudeDesktop)
        for bad in [["--client"], ["--client", "chatgpt"], ["--client=", "x"], ["--verbose"],
                    ["--client", "codex", "--client", "codex"]] {
            guard case .failure(let refusal) = BridgeArguments.parse(bad) else { Issue.record("\(bad)"); continue }
            #expect(refusal.description.hasPrefix("vaulthalla-mcp: "))
            #expect(refusal.description.contains("claude-code|claude-desktop|codex"))
        }
    }
}
