import Foundation
import Testing
import VHContract
import VHCore
import VHIdentity
import VHNodes
import VHTransport

/// An AI app's own pairing against a real daemon (docs/architecture.md §3, "AI apps' own pairings";
/// docs/interop-testing.md): this Mac, paired with an approval key, opens a window on its Device session, the app's
/// new key pairs over the real `PairingClient` pinned to the listener's key, this Mac matches the code and approves
/// with its approval key (a software key here: no Touch ID in a test). The app is then its own device of the same
/// account, works on its own, and is revoked alone. Skipped unless `VH_LIVE_NODE` is set.
@Suite(.enabled(if: LiveNode.isConfigured, "set VH_LIVE_NODE=<host:port> to run against a live daemon"),
       .serialized, .timeLimit(.minutes(5)))
struct LiveAgentPairingTests {
    static let macName = "Interop Mac"

    /// Pairs `tag` as this Mac (approved with `vh device approve`, which needs no step-up), optionally registering
    /// `approvalKey` with the request; returns the record and an online Device session.
    private static func pairMac(_ tag: String, keys: DeviceKeys, endpoint: NodeEndpoint,
                                approvalKey: (any ApprovalSigner)?) async throws -> (Node, NodeSession) {
        let identity = try await keys.identityForPairing(nodeTag: tag, deviceName: macName, replacingExisting: true)
        try await LiveNode.vh(["device", "pair"])
        var configuration = PairingClient.Configuration(endpoint: endpoint, deviceName: macName,
                                                        appVersion: "0.0.0-interop")
        configuration.approvalKeySPKI = approvalKey?.publicKeySPKI
        let client = PairingClient(identity: identity, configuration: configuration)
        let states = Recorder(client.start())
        defer { client.cancel() }
        guard case .awaitingApproval(let code) = await states.first(within: .seconds(30), where: {
            if case .awaitingApproval = $0 { true } else { false }
        }) else { throw LiveFailure("no code shown: \(states.all)") }
        let pending = try await LiveNode.vhJSON(["device", "pending"])
        let request = try #require(pending["requests"]?.arrayValue?.first { $0["device_id"]?.stringValue == identity.deviceID })
        // `vh device pending --json` may leave approval_key_present out; when it says, it must agree.
        if let present = request["approval_key_present"], present != .null { #expect(present == .bool(approvalKey != nil)) }
        try await LiveNode.vh(["device", "approve", try #require(request["request_id"]?.stringValue), "--code", code.digits])
        guard case .approved(let serverNodeID, let nodeName, let deviceID, let pin) = await states.first(
            within: .seconds(30), where: { $0.isFinal }) else { throw LiveFailure("not approved: \(states.all)") }
        try await LiveNode.vh(["device", "pair", "--close"])  // vh's window; the app opens its own
        let node = Node(id: NodeID(rawValue: tag), displayName: nodeName, endpoint: endpoint,
                        pairing: .paired(serverSPKISHA256: pin, deviceID: deviceID, since: .now), serverNodeID: serverNodeID)
        var settings = NodeSession.Configuration()
        settings.reconnect = ReconnectPolicy(base: .milliseconds(200), cap: .seconds(2))
        let session = NodeSession(node: node, keys: keys, configuration: settings)
        let events = Recorder(session.events)
        await session.start()
        try #require(await events.first(within: .seconds(20)) { $0.status == .online } != nil,
                     "this Mac's session never came online: \(events.all)")
        return (node, session)
    }

    private static func device(_ id: String) async throws -> JSONValue? {
        try await LiveNode.vhJSON(["device", "list"]).arrayValue?.first { $0["device_id"]?.stringValue == id }
    }

    @Test func anAIAppGetsItsOwnDeviceWorksAloneAndIsRevokedAlone() async throws {
        let endpoint = try LiveNode.requireEndpoint()
        let instance = try await LiveNode.instance()
        try #require(instance.alive, "the instance isn't running")
        try await LiveKeychain.withKeys { keys in
            let approvalKey = SoftwareApprovalKey()
            let (node, session) = try await Self.pairMac("live-agent-mac", keys: keys, endpoint: endpoint,
                                                         approvalKey: approvalKey)
            defer { Task { await session.stop() } }
            guard case .paired(_, let macDeviceID, _) = node.pairing else { return }

            // The exchange: window, the new key over the real pairing client, code matched here, approved with the
            // approval key on this Mac's session.
            let pairing = AgentPairing(keys: keys, session: session, signer: approvalKey)
            let own = try await pairing.pair(node, client: .claudeCode, macName: Self.macName, appVersion: "0.0.0-interop").get()
            #expect(own.deviceName == "Claude Code on Interop Mac")
            #expect(own.serverSPKISHA256.hex == instance.serverSPKISHA256)
            let row = try #require(try await Self.device(own.deviceID), "the node lists the app's device")
            #expect(row["name"]?.stringValue == "Claude Code on Interop Mac" && row["revoked"] == false)
            #expect(row["user_name"] == (try await Self.device(macDeviceID))?["user_name"], "the same account")
            let pendingAfter = try await LiveNode.vhJSON(["device", "pending"])
            #expect(pendingAfter["requests"]?.arrayValue?.isEmpty != false, "no request is left pending")
            print("[live] Claude Code paired as \(own.deviceID.prefix(16)) beside this Mac's \(macDeviceID.prefix(16))")

            // It works on its own key, as the same account: the bridge's reader presents it, the node accepts it,
            // and the HTTP lanes serve the seeded file to it.
            var record = node
            record.agentIdentities["claude-code"] = own
            let reader = CredentialReader(registry: nil, keys: keys, client: .claudeCode, access: { AgentAccess() })
            let credentials = try await reader.load(record)
            #expect(credentials.identity.deviceID == own.deviceID)
            #expect(await reader.check(credentials) == .accepted)
            let http = try DeviceHTTPClient(configuration: credentials.laneConfiguration())
            let (hello, response) = try await http.download(vaultID: instance.vaultID, path: "/hello.txt")
            http.invalidate()
            #expect(response.statusCode == 200 && hello.count == 44)

            // Revoked alone, on this Mac's session: the app's key is refused, this Mac's still works.
            #expect(await AgentRevocation.revoke(deviceID: own.deviceID, macSession: session) == .revoked)
            #expect(try await Self.device(own.deviceID)?["revoked"] == true)
            #expect(await reader.check(credentials) == .refused)
            #expect(try await Self.device(macDeviceID)?["revoked"] == false)
            #expect(await CredentialReader(registry: nil, keys: keys).check(try await CredentialReader(registry: nil, keys: keys)
                .load(node)) == .accepted)
            // Revoking it again settles too (the node answers it as done, or as not found).
            let again = await AgentRevocation.revoke(deviceID: own.deviceID, macSession: session)
            print("[live] revoking again: \(again)")
            #expect(again == .revoked || again == .alreadyGone)

            try await LiveNode.vh(["device", "revoke", macDeviceID])
        }
    }

    @Test func withoutAnApprovalKeyNothingIsLeftBehind() async throws {
        let endpoint = try LiveNode.requireEndpoint()
        try await LiveKeychain.withKeys { keys in
            let (node, session) = try await Self.pairMac("live-agent-plain", keys: keys, endpoint: endpoint,
                                                         approvalKey: nil)
            defer { Task { await session.stop() } }
            guard case .paired(_, let macDeviceID, _) = node.pairing else { return }
            let before = try await LiveNode.vhJSON(["device", "list"]).arrayValue?.count ?? 0

            // A local approval key the node never registered: the node refuses it (approval_key_unavailable).
            let pairing = AgentPairing(keys: keys, session: session, signer: SoftwareApprovalKey())
            let outcome = await pairing.pair(node, client: .claudeCode, macName: Self.macName, appVersion: "0.0.0-interop")
            #expect(outcome == .failure(.noApprovalKey), "\(outcome)")
            let tag = AgentIdentity.keyTag(node: node.id, client: .claudeCode)
            #expect(try await keys.identity(for: tag) == nil, "the new key is deleted")
            let pending = try await LiveNode.vhJSON(["device", "pending"])
            #expect(pending["requests"]?.arrayValue?.isEmpty != false, "no request is left pending")
            #expect(pending["window"] == nil || pending["window"] == .null, "the window is closed")
            #expect((try await LiveNode.vhJSON(["device", "list"]).arrayValue?.count ?? 0) == before, "no new device")

            try await LiveNode.vh(["device", "revoke", macDeviceID])
        }
    }

    /// Scopes (server 1.23, `device.scope`): the app's own pairing asks for read and is approved for it, the node
    /// reports it and holds the device to it (ws and /mcp), narrowing needs nothing, widening the approval key.
    /// Recorded as skipped against a node without scopes.
    @Test func anAIAppsOwnPairingIsHeldToItsScope() async throws {
        let endpoint = try LiveNode.requireEndpoint()
        let instance = try await LiveNode.instance()
        try await LiveKeychain.withKeys { keys in
            let approvalKey = SoftwareApprovalKey()
            let (node, session) = try await Self.pairMac("live-agent-mac", keys: keys, endpoint: endpoint,
                                                         approvalKey: approvalKey)
            defer { Task { await session.stop() } }
            guard case .paired(_, let macDeviceID, _) = node.pairing else { return }
            guard await session.capabilitySupport(.deviceScope) == .yes else {
                print("[live] this node has no device scopes: skipped")
                try await LiveNode.vh(["device", "revoke", macDeviceID])
                return
            }

            let pairing = AgentPairing(keys: keys, session: session, signer: approvalKey)
            let own = try await pairing.pair(node, client: .codex, macName: Self.macName, appVersion: "0.0.0-interop",
                                             scope: .read).get()
            #expect(own.scope == .read)
            #expect(await AgentScopes.report(deviceIDs: [own.deviceID], via: session)[own.deviceID] == .scoped(.read))
            #expect(try await Self.device(own.deviceID)?["scope"] == "read")
            #expect(try await Self.device(macDeviceID)?["scope"] != "read", "this Mac's own pairing isn't scoped")

            // Held to it: a write over its own ws session is device_scope; over /mcp the write is the node's plain
            // tool error naming the limit, while a read runs.
            var record = node
            record.agentIdentities["codex"] = own
            let credentials = try await CredentialReader(registry: nil, keys: keys, client: .codex,
                                                         access: { AgentAccess() }).load(record)
            do {
                _ = try await OneShotDeviceTransport(credentials: credentials)
                    .send(Ws.Device.Rename.self, payload: .init(deviceID: own.deviceID, name: "renamed"))
                Issue.record("a write ran under read")
            } catch {
                #expect((error as? WsError)?.code == "device_scope", "\(error)")
            }
            let http = try DeviceHTTPClient(configuration: credentials.laneConfiguration())
            defer { http.invalidate() }
            let version = "2025-11-25"
            _ = try await http.mcp(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                    "params": ["protocolVersion": .string(version), "capabilities": [:],
                                               "clientInfo": ["name": "interop", "version": "0"]]])
            let refused = try await http.mcp(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                              "params": ["name": "vh_run",
                                                         "arguments": ["command": "vault create live-scope-probe"]]],
                                             protocolVersion: version)
            let refusedResult = refused.body?["result"]
            #expect(refusedResult?["isError"] == true, "\(String(describing: refused.body))")
            let refusedText = refusedResult?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            #expect(refusedText.contains("read-only"), "\(refusedText)")
            let read = try await http.mcp(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                           "params": ["name": "vh_read",
                                                      "arguments": ["command": .string("fs ls \(instance.vaultID) /")]]],
                                          protocolVersion: version)
            #expect(read.body?["result"]?["isError"] != true, "\(String(describing: read.body))")

            // Widening asks for the approval key's step-up; narrowing doesn't.
            #expect(await AgentScopes.set(.write, deviceID: own.deviceID, current: .read, macSession: session,
                                          signer: nil, context: nil) == .needsApprovalKey)
            let context = try #require(Self.context(node))
            #expect(await AgentScopes.set(.write, deviceID: own.deviceID, current: .read, macSession: session,
                                          signer: approvalKey, context: context) == .changed(.write))
            #expect(try await Self.device(own.deviceID)?["scope"] == "write")
            #expect(await AgentScopes.set(.read, deviceID: own.deviceID, current: .write, macSession: session,
                                          signer: nil, context: nil) == .changed(.read))
            #expect(try await Self.device(own.deviceID)?["scope"] == "read")
            print("[live] Codex paired read-only as \(own.deviceID.prefix(16)); widened to write and narrowed back")

            #expect(await AgentRevocation.revoke(deviceID: own.deviceID, macSession: session) == .revoked)
            try await LiveNode.vh(["device", "revoke", macDeviceID])
        }
    }

    private static func context(_ node: Node) -> ApprovalContext? {
        guard case .paired(let pin, let deviceID, _) = node.pairing, let nodeID = node.serverNodeID else { return nil }
        return ApprovalContext(nodeID: nodeID, serverSPKISHA256: pin, deviceSPKISHA256: Data(hexString: deviceID))
    }
}
