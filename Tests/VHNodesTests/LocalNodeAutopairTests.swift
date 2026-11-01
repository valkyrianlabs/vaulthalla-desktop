import Foundation
import Testing
import VHCore
import VHIdentity
@testable import VHNodes

/// Setting up this Mac's own server without a code: when it tries, and that a failed attempt leaves nothing behind.
/// The approval itself is the pairing ``LocalPairingTests`` covers; end to end it runs in `LiveLocalAutopairTests`.
@Suite struct LocalNodeAutopairTests {
    private typealias FakeVH = LocalPairingTests.FakeVH

    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "LocalNodeAutopairTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var registryURL: URL { directory.appending(path: "nodes.json") }

    /// The credential owner's registry and keys (no key is ever created in these cases).
    private func owner(_ nodes: [Node] = []) throws -> (NodeStore, DeviceKeys) {
        let lease = CredentialLease(forRegistry: registryURL, holder: "app")
        try lease.acquire()
        let store = NodeStore(fileURL: registryURL, lease: lease)
        for node in nodes { try store.add(node) }
        let keys = DeviceKeys(primary: DeviceIdentityStore(configuration: .init(
            namespace: "sh.vaulthalla.app.test.autopair.\(UUID().uuidString.lowercased())", keychain: .fileBased)),
            development: nil, preferredBackend: .software, lease: lease)
        return (store, keys)
    }

    private static func autopair(_ vh: FakeVH, timeout: Duration = .seconds(30)) -> LocalNodeAutopair {
        LocalNodeAutopair(local: vh.pairing, deviceName: "Studio", appVersion: "0.5.0",
                          isThisMac: { ["127.0.0.1", "localhost", "studio.local"].contains($0) }, timeout: timeout)
    }

    private static func node(_ host: String, port: UInt16 = 36972, serverNodeID: String? = nil,
                             pairing: PairingState = .unpaired) -> Node {
        Node(id: .local(), displayName: host, endpoint: NodeEndpoint(host: host, port: port), pairing: pairing,
             serverNodeID: serverNodeID)
    }

    @Test func decidesFromTheRegistryAlone() {
        let isThisMac: (String) -> Bool = { $0 == "studio.local" }
        #expect(LocalNodeAutopair.decide(nodes: [], declined: false, isThisMac: isThisMac) == .pair)
        #expect(LocalNodeAutopair.decide(nodes: [Self.node("vh-storage")], declined: false, isThisMac: isThisMac) == .pair)
        // A node at an address of this Mac is the person's, paired or not (a dev instance on another port too).
        let mine = Self.node("studio.local", port: 37072, pairing: .revoked(at: .now))
        #expect(LocalNodeAutopair.decide(nodes: [Self.node("vh-storage"), mine], declined: true, isThisMac: isThisMac)
            == .known(mine.id))
        #expect(LocalNodeAutopair.decide(nodes: [], declined: true, isThisMac: isThisMac) == .skip(.declined))
    }

    @Test func runsNothingWhenThisMacsServerIsSaved() async throws {
        let vh = FakeVH(["device pair --json": LocalPairingTests.opened()])
        let local = Self.node("localhost")
        let (store, keys) = try owner([local])
        #expect(await Self.autopair(vh).run(store: store, keys: keys, declined: false) == .alreadyKnown(local.id))
        #expect(vh.calls.isEmpty)
    }

    @Test func runsNothingOnceThePersonRemovedIt() async throws {
        let vh = FakeVH(["device pair --json": LocalPairingTests.opened()])
        let (store, keys) = try owner()
        #expect(await Self.autopair(vh).run(store: store, keys: keys, declined: true) == .skipped(.declined))
        #expect(vh.calls.isEmpty)
    }

    @Test func aConsumerNeverPairs() async throws {
        let vh = FakeVH(["device pair --json": LocalPairingTests.opened()])
        let consumer = NodeStore(fileURL: registryURL)
        let keys = DeviceKeys(primary: DeviceIdentityStore(configuration: .init(
            namespace: "sh.vaulthalla.app.test.autopair.consumer", keychain: .fileBased)), development: nil)
        #expect(await Self.autopair(vh).run(store: consumer, keys: keys, declined: false) == .skipped(.notOwner))
        #expect(vh.calls.isEmpty)
    }

    @Test func whatVHRefusesFailsAndChangesNothing() async throws {
        let message = "permission denied: this user is not in the 'vaulthalla' group"
        let vh = FakeVH(["device pair --json": .init(status: 77, stdout: "", stderr: message)])
        let (store, keys) = try owner()
        let outcome = await Self.autopair(vh).run(store: store, keys: keys, declined: false)
        #expect(outcome == .failed(message))
        #expect(try store.reload().isEmpty)
    }

    @Test func theServersInstallIDFindsItUnderAnotherAddress() async throws {
        let vh = FakeVH(["device pair --json": LocalPairingTests.opened(nodeID: "node-1")])
        let saved = Self.node("studio.example.com", serverNodeID: "node-1")
        let (store, keys) = try owner([saved])
        #expect(await Self.autopair(vh).run(store: store, keys: keys, declined: false) == .alreadyKnown(saved.id))
        #expect(try store.reload() == [saved])
        #expect(vh.calls == [["device", "pair", "--json"], ["device", "pair", "--close"]], "the window was closed")
    }

    @Test func aListenerThatIsntListeningLeavesNoNode() async throws {
        let vh = FakeVH(["device pair --json": LocalPairingTests.opened(listening: false)])
        let (store, keys) = try owner()
        let outcome = await Self.autopair(vh).run(store: store, keys: keys, declined: false)
        #expect(outcome.isFailure)
        #expect(try store.reload().isEmpty)
        #expect(vh.calls.last == ["device", "pair", "--close"])
    }

    @Test func anUnreachableListenerLeavesNoNodeAndNoKey() async throws {
        // Nothing listens on port 9 of loopback: the client gives up, the node and its key are removed again.
        let vh = FakeVH(["device pair --json": LocalPairingTests.opened(port: 9)])
        let (store, keys) = try owner()
        let id = NodeID(rawValue: "local-unreachable")
        var autopair = Self.autopair(vh)
        autopair.newNodeID = { id }
        let outcome = await autopair.run(store: store, keys: keys, declined: false)
        #expect(outcome.isFailure, "\(outcome)")
        #expect(try store.reload().isEmpty)
        #expect(try await keys.primary.identity(for: id.rawValue) == nil, "the key made for the attempt was deleted")
        #expect(vh.calls.last == ["device", "pair", "--close"])
    }

    @Test func aHungVHTimesOut() async throws {
        let vh = LocalPairing { _ in
            try await Task.sleep(for: .seconds(60))
            return .init(status: 0, stdout: "")
        }
        let (store, keys) = try owner()
        let autopair = LocalNodeAutopair(local: vh, deviceName: "Studio", appVersion: "0.5.0",
                                         isThisMac: { _ in false }, timeout: .milliseconds(200))
        let started = ContinuousClock.now
        #expect(await autopair.run(store: store, keys: keys, declined: false).isFailure)
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(try store.reload().isEmpty)
    }
}
