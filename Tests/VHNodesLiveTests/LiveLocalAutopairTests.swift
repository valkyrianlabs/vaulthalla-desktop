import Foundation
import Testing
import VHContract
import VHCore
import VHIdentity
@testable import VHNodes
import VHTransport

/// Setting up "this Mac's" server without a code (``LocalNodeAutopair``) against a live daemon (docs/interop-testing.md):
/// the instance's `vh` over ssh stands in for the one on this Mac, and the node is saved at the instance's address
/// instead of loopback. Needs a server with `vh device pair --json` (1.21+). Skipped unless `VH_LIVE_NODE` is set.
@Suite(.enabled(if: LiveNode.isConfigured, "set VH_LIVE_NODE=<host:port> to run against a live daemon"),
       .serialized, .timeLimit(.minutes(5)))
struct LiveLocalAutopairTests {
    private static let vh = LocalPairing { arguments in
        do {
            return .init(status: 0, stdout: try await LiveNode.vh(arguments))
        } catch {
            return .init(status: 1, stdout: "", stderr: String(describing: error))
        }
    }

    @Test func setsUpTheServerWithoutACodeAndOnlyOnce() async throws {
        let endpoint = try LiveNode.requireEndpoint()
        let instance = try await LiveNode.instance()
        try #require(instance.alive, "the instance isn't running")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "vh-live-autopair-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registryURL = directory.appending(path: "nodes.json")
        let lease = CredentialLease(forRegistry: registryURL, holder: "live-test")
        try lease.acquire()
        defer { lease.release() }
        let store = NodeStore(fileURL: registryURL, lease: lease)

        try await LiveKeychain.withKeys { keys in
            var autopair = LocalNodeAutopair(local: Self.vh, deviceName: LiveInteropTests.deviceName,
                                             appVersion: "0.0.0-interop", host: endpoint.host,
                                             isThisMac: { _ in false })
            autopair.newNodeID = { NodeID(rawValue: "live-node") } // LiveKeychain deletes its key afterwards

            // 1. Nothing saved: one call pairs, approved through vh with this Mac's code, pinned to the server key
            //    `vh device pair --json` named, at the port it named.
            let outcome = await autopair.run(store: store, keys: keys, declined: false)
            guard case .paired(let id, _) = outcome else {
                Issue.record("not paired: \(outcome)")
                return
            }
            let node = try #require(try store.reload().first)
            #expect(node.id == id)
            #expect(node.endpoint == NodeEndpoint(host: endpoint.host, port: UInt16(instance.devicePort)))
            guard case .paired(let pin, let deviceID, _) = node.pairing else {
                Issue.record("the record isn't paired: \(node.pairing)")
                return
            }
            #expect(pin.hex == instance.serverSPKISHA256, "pinned to the listener's key")
            #expect(node.serverNodeID?.isEmpty == false)
            let pending = try await LiveNode.vhJSON(["device", "pending"])
            #expect(pending["window"] == .null, "the window was closed")
            let devices = try await LiveNode.vhJSON(["device", "list"])
            #expect(devices.arrayValue?.contains { $0["device_id"]?.stringValue == deviceID } == true)
            print("[live] set up without a code as \(deviceID.prefix(16)), node \(node.serverNodeID ?? "?")")

            // 2. Again: the server's install id finds the saved node (here not at an address of "this Mac"), nothing
            //    is added and the window is closed again.
            #expect(await autopair.run(store: store, keys: keys, declined: false) == .alreadyKnown(id))
            #expect(try store.reload().count == 1)
            #expect(try await LiveNode.vhJSON(["device", "pending"])["window"] == .null)

            // 3. A session from the record comes online with no pairing.
            var settings = NodeSession.Configuration()
            settings.reconnect = ReconnectPolicy(base: .milliseconds(200), cap: .seconds(2))
            let session = NodeSession(node: node, keys: keys, configuration: settings)
            let events = Recorder(session.events)
            await session.start()
            #expect(await events.first(within: .seconds(20)) { $0.status == .online } != nil,
                    "never came online: \(events.all)")
            await session.stop()

            _ = try await LiveNode.vh(["device", "revoke", deviceID])
        }
    }
}
