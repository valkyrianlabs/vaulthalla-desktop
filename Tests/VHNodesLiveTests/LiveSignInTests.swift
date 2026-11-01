import Foundation
import Testing
import VHContract
import VHCore
import VHIdentity
import VHNodes
import VHTransport

/// desktop#7 against a live daemon (docs/interop-testing.md): pairing driven through `vh` (``LocalPairing``, here with
/// the instance's `vh` over ssh standing in for the one on this Mac), staying signed in across a relaunch, and
/// signing out. Skipped unless `VH_LIVE_NODE` is set.
@Suite(.enabled(if: LiveNode.isConfigured, "set VH_LIVE_NODE=<host:port> to run against a live daemon"),
       .serialized, .timeLimit(.minutes(5)))
struct LiveSignInTests {
    /// `vh` on the instance as the seeded user, as `LocalPairing` runs the local one.
    private static let vh = LocalPairing { arguments in
        do {
            return .init(status: 0, stdout: try await LiveNode.vh(arguments))
        } catch {
            return .init(status: 1, stdout: "", stderr: String(describing: error))
        }
    }

    @Test func pairsThroughVHStaysSignedInAndSignsOut() async throws {
        let endpoint = try LiveNode.requireEndpoint()
        let instance = try await LiveNode.instance()
        try #require(instance.alive, "the instance isn't running")
        try await LiveKeychain.withKeys(reopenable: { keys, reopen in
            let tag = "live-node"
            let identity = try await keys.identityForPairing(nodeTag: tag, deviceName: LiveInteropTests.deviceName,
                                                             replacingExisting: true)

            // 1. Pairing through vh: open the window, pair, approve once the daemon's own view shows this Mac's
            //    request with this Mac's code, close the window.
            try await Self.vh.openWindow()
            let client = PairingClient(identity: identity, configuration: .init(
                endpoint: endpoint, deviceName: LiveInteropTests.deviceName, appVersion: "0.0.0-interop"))
            let states = Recorder(client.start())
            defer { client.cancel() }
            let waiting = await states.first(within: .seconds(30)) { if case .awaitingApproval = $0 { true } else { false } }
            guard case .awaitingApproval(let code) = waiting else { throw LiveFailure("no code shown: \(states.all)") }
            try await Self.vh.approve(deviceID: identity.deviceID, code: code.digits)
            let final = await states.first(within: .seconds(30)) { $0.isFinal }
            await Self.vh.closeWindow()
            guard case .approved(let serverNodeID, let nodeName, let deviceID, let serverSPKI) = final else {
                Issue.record("pairing ended \(String(describing: final))")
                return
            }
            #expect(deviceID == identity.deviceID)
            let pending = try await LiveNode.vhJSON(["device", "pending"])
            #expect(pending["window"] == .null, "the window was closed")
            print("[live] paired through vh as \(deviceID.prefix(16))")

            // 2. A relaunch: the keychain opened again and a new session from the saved record come online with no
            //    pairing, which is all staying signed in needs (the record and key outlive the process).
            var node = Node(id: NodeID(rawValue: tag), displayName: nodeName, endpoint: endpoint,
                            pairing: .paired(serverSPKISHA256: serverSPKI, deviceID: deviceID, since: .now),
                            serverNodeID: serverNodeID)
            var settings = NodeSession.Configuration()
            settings.reconnect = ReconnectPolicy(base: .milliseconds(200), cap: .seconds(2))
            let relaunched = reopen()
            let session = NodeSession(node: node, keys: relaunched, configuration: settings)
            let events = Recorder(session.events)
            await session.start()
            try #require(await events.first(within: .seconds(20)) { $0.status == .online } != nil,
                         "the relaunched session never came online: \(events.all)")
            let ws = try #require(await session.client)

            // 3. Sign out: the node revokes the device, the key is deleted, the record returns to unpaired.
            let report = await SignOut.run([node]) { target in
                _ = try await ws.send(Ws.Device.Revoke.self, payload: .init(deviceID: target.deviceID))
            } removeDomains: {
            } forget: { id in
                await session.stop()
                try? await relaunched.deleteIdentity(for: id.rawValue)
                node.pairing = .unpaired
            }
            #expect(report.revoked == [node.id], "not revoked: \(report.notRevoked)")
            #expect(try await reopen().identity(for: tag) == nil, "the key is gone from the keychain")
            let listed = try await LiveNode.vhJSON(["device", "list"])
            #expect(listed.arrayValue?.first { $0["device_id"]?.stringValue == deviceID }?["revoked"] == true)

            // Nothing connects afterwards: the record is unpaired and a session can't find a key to present.
            let after = NodeSession(node: Node(id: node.id, displayName: nodeName, endpoint: endpoint,
                                               pairing: .paired(serverSPKISHA256: serverSPKI, deviceID: deviceID,
                                                                since: .now)),
                                    keys: reopen(), configuration: settings)
            let afterEvents = Recorder(after.events)
            await after.start()
            defer { Task { await after.stop() } }
            let gaveUp = await afterEvents.first(within: .seconds(20)) {
                if case .pairingRequired = $0 { true } else { false }
            }
            #expect(gaveUp != nil, "a session without the key asks for pairing: \(afterEvents.all)")
            #expect(!afterEvents.all.contains { $0.status == .online })
            print("[live] signed out: revoked on the node, key deleted, nothing connects")
        })
    }
}
