import Foundation
import Testing
import VHCore

@Suite struct NodeStoreTests {
    /// A fresh directory per test; the store's file doesn't exist until the first write.
    private let directory: URL
    private let fileURL: URL
    /// The test is the registry's owner: its stores write (CredentialLeaseTests covers the read-only side).
    private let lease: CredentialLease

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "NodeStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileURL = directory.appending(path: "nested/nodes.json")
        lease = CredentialLease(forRegistry: fileURL, holder: "test")
        try lease.acquire()
    }

    private func makeStore() -> NodeStore {
        NodeStore(fileURL: fileURL, lease: lease)
    }

    private func node(_ name: String, pairing: PairingState = .unpaired) -> Node {
        Node(id: NodeID(rawValue: "id-\(name)"), displayName: name, endpoint: NodeEndpoint(host: "\(name).local"), pairing: pairing)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func missingFileIsAnEmptyRegistry() throws {
        defer { cleanUp() }
        let store = makeStore()
        #expect(try store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func addPersistsAcrossInstances() throws {
        defer { cleanUp() }
        let paired = PairingState.paired(
            serverSPKISHA256: Data([1, 2, 3]),
            deviceID: "dev-1",
            since: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try makeStore().add(node("a"))
        try makeStore().add(node("b", pairing: paired))

        let loaded = try makeStore().load()
        #expect(loaded == [node("a"), node("b", pairing: paired)])
    }

    @Test func writesVersionedEnvelope() throws {
        defer { cleanUp() }
        try makeStore().add(node("a"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        #expect(object?["version"] as? Int == 1)
        #expect((object?["nodes"] as? [Any])?.count == 1)
    }

    @Test func rejectsDuplicateIDs() throws {
        defer { cleanUp() }
        let store = makeStore()
        try store.add(node("a"))
        #expect(throws: NodeStore.Failure.duplicate(NodeID(rawValue: "id-a"))) { try store.add(node("a")) }
    }

    @Test func updateKeepsPosition() throws {
        defer { cleanUp() }
        let store = makeStore()
        try store.add(node("a"))
        try store.add(node("b"))
        var renamed = node("a")
        renamed.displayName = "Home lab"
        let nodes = try store.update(renamed)
        #expect(nodes.map(\.displayName) == ["Home lab", "b"])
        #expect(try makeStore().load().map(\.displayName) == ["Home lab", "b"])
        #expect(throws: NodeStore.Failure.notFound(NodeID(rawValue: "id-z"))) { try store.update(node("z")) }
    }

    @Test func removes() throws {
        defer { cleanUp() }
        let store = makeStore()
        try store.add(node("a"))
        try store.add(node("b"))
        #expect(try store.remove(NodeID(rawValue: "id-a")).map(\.displayName) == ["b"])
        #expect(try makeStore().load().map(\.displayName) == ["b"])
        #expect(throws: NodeStore.Failure.notFound(NodeID(rawValue: "id-a"))) {
            try store.remove(NodeID(rawValue: "id-a"))
        }
    }

    @Test func reorderNeverDropsNodes() throws {
        defer { cleanUp() }
        let store = makeStore()
        for name in ["a", "b", "c", "d"] { try store.add(node(name)) }
        let ids = ["c", "ghost", "a"].map { NodeID(rawValue: "id-\($0)") }
        #expect(try store.reorder(ids).map(\.displayName) == ["c", "a", "b", "d"])
        #expect(try makeStore().load().map(\.displayName) == ["c", "a", "b", "d"])
    }

    @Test func movesAndClamps() throws {
        defer { cleanUp() }
        let store = makeStore()
        for name in ["a", "b", "c"] { try store.add(node(name)) }
        #expect(try store.move(NodeID(rawValue: "id-a"), to: 2).map(\.displayName) == ["b", "c", "a"])
        #expect(try store.move(NodeID(rawValue: "id-a"), to: -5).map(\.displayName) == ["a", "b", "c"])
        #expect(try store.move(NodeID(rawValue: "id-b"), to: 99).map(\.displayName) == ["a", "c", "b"])
    }

    @Test func corruptFileIsReportedAndNeverOverwritten() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: fileURL)

        let store = makeStore()
        #expect(throws: NodeStore.Failure.self) { try store.load() }
        #expect(throws: NodeStore.Failure.self) { try store.add(node("a")) }
        #expect(try Data(contentsOf: fileURL) == garbage)
    }

    @Test func newerVersionIsLeftAlone() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = Data(#"{"version": 2, "nodes": [{"shape": "unknown"}]}"#.utf8)
        try future.write(to: fileURL)

        let store = makeStore()
        #expect(throws: NodeStore.Failure.unsupportedVersion(2)) { try store.load() }
        #expect(throws: NodeStore.Failure.unsupportedVersion(2)) { try store.add(node("a")) }
        #expect(try Data(contentsOf: fileURL) == future)
    }

    @Test func sharedAcrossTasks() async throws {
        defer { cleanUp() }
        let store = makeStore()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { _ = try store.add(node("n\(index)")) }
            }
            try await group.waitForAll()
        }
        #expect(try makeStore().load().count == 20)
    }
}

@Suite struct NodeRecordCompatibilityTests {
    @Test func recordsWithoutTheNewerMembersStillLoad() throws {
        let json = """
            {"id": "local-1", "displayName": "vh-storage", "endpoint": {"host": "vh-storage.local", "port": 36972},
             "pairing": {"unpaired": {}}}
            """
        let node = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
        #expect(node.displayName == "vh-storage")
        #expect(!node.isNamedByUser)
        #expect(node.serverNodeID == nil)
        #expect(node.nextServerSPKISHA256 == nil)
    }

    @Test func newerMembersRoundTrip() throws {
        let node = Node(id: NodeID(rawValue: "local-1"), displayName: "Home lab", endpoint: NodeEndpoint(host: "10.0.0.33"),
                        isNamedByUser: true, serverNodeID: "node-7f3a", nextServerSPKISHA256: Data(repeating: 7, count: 32))
        let decoded = try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(node))
        #expect(decoded == node)
    }
}
