import Foundation
import Testing
import VHContract
import VHCore
import VHIdentity
import VHNodes
import VHTransport

/// Desktop's real client code against a real daemon (docs/interop-testing.md): pairing with number matching,
/// the Device session, the HTTP lanes, remote MCP, key rotation and revocation. Skipped unless `VH_LIVE_NODE` is set.
@Suite(.enabled(if: LiveNode.isConfigured, "set VH_LIVE_NODE=<host:port> to run against a live daemon"),
       .serialized, .timeLimit(.minutes(5)))
struct LiveInteropTests {
    static let deviceName = "Interop Mac"

    // MARK: - Pairing

    /// The owner picks a code the Mac isn't showing: the daemon denies the request and the client says so.
    @Test func aDecoyCodeDeniesThePairing() async throws {
        let endpoint = try LiveNode.requireEndpoint()
        try await LiveKeychain.withKeys { keys in
            let identity = try await keys.identityForPairing(nodeTag: "live-denied", deviceName: Self.deviceName,
                                                             replacingExisting: true)
            let final = try await Self.pair(identity, endpoint: endpoint) { code, choices in
                try #require(choices.first { $0 != code.digits })
            }
            #expect(final == .denied)
            // The request is gone, and the key was never made a device.
            let devices = try await LiveNode.vhJSON(["device", "list"])
            #expect(devices.arrayValue?.contains { $0["device_id"]?.stringValue == identity.deviceID } == false)

            // A key that isn't a device gets a pairing-only connection: the HTTP lanes refuse it.
            let instance = try await LiveNode.instance()
            let http = try DeviceHTTPClient(configuration: .init(
                endpoint: endpoint, identity: identity.secIdentity,
                serverSPKIPin: Data(hexString: instance.serverSPKISHA256)))
            defer { http.invalidate() }
            await #expect(throws: DeviceHTTPError.forbidden) {
                _ = try await http.download(vaultID: instance.vaultID, path: "/hello.txt")
            }
        }
    }

    /// Pairing, then everything a paired Mac does, then rotation and revocation, on one key.
    @Test func pairsTalksRotatesAndIsRevoked() async throws {
        let endpoint = try LiveNode.requireEndpoint()
        let instance = try await LiveNode.instance()
        try #require(instance.alive, "the instance isn't running")
        try await LiveKeychain.withKeys { keys in
            let tag = "live-node"
            let identity = try await keys.identityForPairing(nodeTag: tag, deviceName: Self.deviceName,
                                                             replacingExisting: true)

            // 1. Pairing: the code the client computed is one of the three the daemon offers; approve with it.
            let final = try await Self.pair(identity, endpoint: endpoint) { code, choices in code.digits }
            guard case .approved(let serverNodeID, let nodeName, let deviceID, let serverSPKI) = final else {
                Issue.record("pairing ended \(final)")
                return
            }
            #expect(deviceID == identity.deviceID)
            #expect(serverSPKI.hex == instance.serverSPKISHA256, "the pin is the daemon's device listener key")
            #expect(!serverNodeID.isEmpty)
            print("[live] paired as \(deviceID.prefix(16)) with \(nodeName) (\(serverNodeID))")

            // 2. The Device session, pinned to the key pairing recorded.
            let node = Node(id: NodeID(rawValue: tag), displayName: nodeName, endpoint: endpoint,
                            pairing: .paired(serverSPKISHA256: serverSPKI, deviceID: deviceID, since: .now),
                            serverNodeID: serverNodeID)
            var settings = NodeSession.Configuration()
            settings.reconnect = ReconnectPolicy(base: .milliseconds(200), cap: .seconds(2))
            let session = NodeSession(node: node, keys: keys, configuration: settings)
            let events = Recorder(session.events)
            await session.start()
            defer { Task { await session.stop() } }
            try #require(await events.first(within: .seconds(20)) { $0.status == .online } != nil,
                         "the session never came online: \(events.all)")
            let ws = try #require(await session.client)
            try await Self.deviceSession(ws, instance: instance)

            // 3. HTTP lanes, 4. remote MCP, as the device.
            let http = try DeviceHTTPClient(configuration: .init(
                endpoint: endpoint, identity: identity.secIdentity, serverSPKIPin: serverSPKI))
            try await Self.httpLanes(http, vault: instance.vaultID)
            try await Self.remoteMCP(http, vault: instance.vaultID)
            http.invalidate()

            // 5. Rotation on demand: the session reconnects with the new key and the daemon lists it.
            try await session.rotateDeviceKey()
            let rotated = try #require(await Self.rotatedDeviceID(events, from: deviceID),
                                       "no rotation reported: \(events.all)")
            let index = events.all.firstIndex { $0.identityID == rotated } ?? 0
            try #require(await events.first(after: index, within: .seconds(20)) { $0.status == .online } != nil)
            let current = try #require(try await keys.identity(for: tag))
            #expect(current.deviceID == rotated)
            #expect(try await keys.pendingRotation(for: tag) == nil)
            #expect(await events.first(within: .seconds(5)) { $0.pairedDeviceID == rotated } != nil,
                    "the node record carries the new device id")
            let devices = try await LiveNode.vhJSON(["device", "list"])
            let row = try #require(devices.arrayValue?.first { $0["device_id"]?.stringValue == rotated },
                                   "device list: \(devices)")
            #expect(row["revoked"] == false)
            #expect(row["previous_device_id"] == .null, "the first handshake with the new key ends the old one's grace")
            #expect(devices.arrayValue?.contains { $0["device_id"]?.stringValue == deviceID } == false)
            print("[live] rotated \(deviceID.prefix(16)) -> \(rotated.prefix(16))")

            // The rotated key works on the lanes too; the old one is no device any more.
            let rotatedHTTP = try DeviceHTTPClient(configuration: .init(
                endpoint: endpoint, identity: current.secIdentity, serverSPKIPin: serverSPKI))
            defer { rotatedHTTP.invalidate() }
            let (hello, helloResponse) = try await rotatedHTTP.download(vaultID: instance.vaultID, path: "/hello.txt")
            #expect(helloResponse.statusCode == 200)
            #expect(hello == seededHello)

            // 6. Revocation from the CLI: the live session reports it and stays down.
            let mark = events.all.count
            try await LiveNode.vh(["device", "revoke", String(rotated.prefix(16))])
            try #require(await events.first(after: mark, within: .seconds(20)) { $0.status == .revoked } != nil,
                         "no revocation reported: \(events.all.dropFirst(mark))")
            #expect(await events.first(after: mark, within: .seconds(2)) {
                if case .revoked = $0.pairing { true } else { false }
            } != nil)
            try await Task.sleep(for: .seconds(3))
            let afterRevocation = events.all.dropFirst(mark).compactMap(\.status)
            #expect(afterRevocation.last == .revoked, "statuses after the revocation: \(afterRevocation)")
            #expect(!afterRevocation.contains(.online))
            #expect(await session.client == nil, "a revoked session keeps no connection")

            // The lanes refuse the revoked key (a fresh TLS connection is pairing-only).
            await #expect(throws: DeviceHTTPError.forbidden) {
                _ = try await rotatedHTTP.download(vaultID: instance.vaultID, path: "/hello.txt")
            }
            rotatedHTTP.invalidate()
            let listed = try await LiveNode.vhJSON(["device", "list"])
            #expect(listed.arrayValue?.first { $0["device_id"]?.stringValue == rotated }?["revoked"] == true)
            try await Task.sleep(for: .seconds(1))
            let listener = try await LiveNode.vhJSON(["device", "remote", "status"], admin: true)
            #expect(listener["connections"] == 0, "nothing reconnected: \(listener)")
            print("[live] revoked; the session stopped and nothing reconnected")
        }
    }

    // MARK: - Steps

    /// One pairing attempt: opens the owner's window, waits for the code, lets `choose` pick the code to approve
    /// with from the three the daemon offers, approves through the CLI, and returns the client's final state.
    private static func pair(_ identity: DeviceIdentity, endpoint: NodeEndpoint,
                             choose: (PairingCode, [String]) throws -> String) async throws -> PairingClient.State {
        try await LiveNode.vh(["device", "pair"])
        let client = PairingClient(identity: identity, configuration: .init(
            endpoint: endpoint, deviceName: deviceName, appVersion: "0.0.0-interop"))
        let states = Recorder(client.start())
        defer { client.cancel() }
        let waiting = await states.first(within: .seconds(30)) { if case .awaitingApproval = $0 { true } else { false } }
        guard case .awaitingApproval(let code) = waiting else {
            throw LiveFailure("no code shown: \(states.all)")
        }

        let pending = try await LiveNode.vhJSON(["device", "pending"])
        let request = try #require(pending["requests"]?.arrayValue?.first {
            $0["device_id"]?.stringValue == identity.deviceID
        }, "the daemon lists no request for this key: \(pending)")
        let choices = request["code_choices"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(choices.count == 3)
        #expect(choices.contains(code.digits), "the code this Mac shows is one of the daemon's three")
        #expect(request["name"]?.stringValue == deviceName)
        #expect(request["platform"]?.stringValue == "macOS")

        let requestID = try #require(request["request_id"]?.stringValue)
        let picked = try choose(code, choices)
        do {
            try await LiveNode.vh(["device", "approve", requestID, "--code", picked])
        } catch {
            // A wrong code denies the request and the command reports the refusal.
            guard picked != code.digits else { throw error }
        }
        let final = await states.first(within: .seconds(30)) { $0.isFinal }
        return try #require(final, "no decision reached the client: \(states.all)")
    }

    private static func deviceSession(_ ws: WsClient, instance: LiveNode.Instance) async throws {
        let identity = try await ws.send(command: "device.server.identity", payload: [:])
        #expect(identity["spki_sha256"]?.stringValue == instance.serverSPKISHA256)

        let contract = try await ws.send(Ws.Meta.Contract.Get.self)
        #expect(contract.wsHash == instance.wsHash, "meta.contract.get reports the daemon's own ws_hash")
        if contract.wsHash != WsContract.wsHash {
            print("[live] note: the vendored contract (\(WsContract.wsHash.prefix(12))) is older than the daemon's "
                  + "(\(contract.wsHash.prefix(12)))")
        }

        // Typed human commands, as the device's user: the vaults it may see (the same as `vh vault list` as that
        // user), and the seeded vault's files.
        let vaults = try await ws.send(Ws.Storage.Vault.List.self)
        let cli = try await LiveNode.vhJSON(["vault", "list"])
        let cliIDs = Set((cli.arrayValue ?? []).compactMap { $0["id"]?.integerValue })
        #expect(Set(vaults.vaults.map(\.id)) == cliIDs, "ws vs CLI vault list")
        print("[live] storage.vault.list as the device's user: \(vaults.vaults.map(\.name))")

        let top = try await ws.send(Ws.Fs.List.self, payload: .init(vaultID: instance.vaultID, path: "/"))
        let names = Set(top.files.map(\.name))
        #expect(names.isSuperset(of: ["hello.txt", "docs"]), "fs.list /: \(names)")
        let docs = try await ws.send(Ws.Fs.List.self, payload: .init(vaultID: instance.vaultID, path: "/docs"))
        #expect(docs.files.map(\.name) == ["blob.bin"])
    }

    private static func httpLanes(_ http: DeviceHTTPClient, vault: Int64) async throws {
        let (whole, response) = try await http.download(vaultID: vault, path: "/hello.txt")
        #expect(response.statusCode == 200)
        #expect(whole == seededHello)

        let (part, partial) = try await http.download(vaultID: vault, path: "/docs/blob.bin", range: 1000...5095)
        #expect(partial.statusCode == 206)
        #expect(partial.value(forHTTPHeaderField: "Content-Range") == "bytes 1000-5095/65536")
        #expect(part == seededBlob[1000...5095])

        let (_, missing) = try await http.download(vaultID: vault, path: "/nope.txt")
        #expect(missing.statusCode == 404 || missing.statusCode == 403)
    }

    private static func remoteMCP(_ http: DeviceHTTPClient, vault: Int64) async throws {
        let version = "2025-11-25"
        let initialize = try await http.mcp([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": .string(version), "capabilities": [:],
                       "clientInfo": ["name": "vaulthalla-desktop-interop", "version": "0"]],
        ])
        #expect(initialize.status == 200)
        #expect(initialize.body?["result"]?["protocolVersion"]?.stringValue == version)
        let initialized = try await http.mcp(["jsonrpc": "2.0", "method": "notifications/initialized"],
                                             protocolVersion: version)
        #expect(initialized.status == 202)

        let list = try await http.mcp(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], protocolVersion: version)
        let tools = (list.body?["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(tools.contains("vh_read") && tools.contains("vh_run"), "tools: \(tools)")
        for tool in tools {
            #expect(!tool.contains("export") && !tool.contains("approve") && !tool.contains("pair")
                    && !tool.contains("secret"), "\(tool) should not be offered to agents")
        }

        // Out of reach through the generic tool too.
        for command in ["vault keys export \(vault)", "device approve 0123456789abcdef --code 123456",
                        "device remote enable"] {
            let call = try await Self.call(http, tool: "vh_run", ["command": .string(command)], id: 3)
            #expect(call?["isError"] == true, "\(command): \(String(describing: call))")
            #expect(Self.text(call).contains("not available to agents"), "\(command): \(Self.text(call))")
        }

        // A read runs as the device's user.
        let read = try await Self.call(http, tool: "vh_read", ["command": .string("fs ls \(vault) /")], id: 4)
        #expect(read?["isError"] != true, "vh_read fs ls: \(String(describing: read))")
        #expect(Self.text(read).contains("hello.txt"))

        // A destructive command without the acknowledgement is refused, and nothing happens.
        let delete = try await Self.call(http, tool: "vh_run", ["command": .string("vault delete \(vault)")], id: 5)
        #expect(delete?["isError"] == true)
        #expect(delete?["structuredContent"]?["needs_confirmation"]?.stringValue == "destructive",
                "vault delete without confirm: \(String(describing: delete))")
        let (_, still) = try await http.download(vaultID: vault, path: "/hello.txt")
        #expect(still.statusCode == 200, "the vault is still there")
    }

    private static func call(_ http: DeviceHTTPClient, tool: String, _ arguments: JSONObject, id: Int)
        async throws -> JSONValue?
    {
        let answer = try await http.mcp([
            "jsonrpc": "2.0", "id": .integer(Int64(id)), "method": "tools/call",
            "params": ["name": .string(tool), "arguments": .object(arguments)],
        ], protocolVersion: "2025-11-25")
        #expect(answer.status == 200)
        return answer.body?["result"]
    }

    private static func text(_ result: JSONValue?) -> String {
        (result?["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    private static func rotatedDeviceID(_ events: Recorder<NodeSession.Event>, from original: String) async -> String? {
        await events.first(within: .seconds(20)) { $0.identityID.map { $0 != original } ?? false }?.identityID
    }
}

extension NodeSession.Event {
    var status: NodeSession.Status? {
        if case .status(let status) = self { return status }
        return nil
    }

    var pairing: PairingState? {
        if case .recordChanged(let pairing, _) = self { return pairing }
        return nil
    }

    var identityID: String? {
        if case .identity(let id, _) = self { return id }
        return nil
    }

    var pairedDeviceID: String? {
        if case .paired(_, let id, _) = pairing { return id }
        return nil
    }
}
