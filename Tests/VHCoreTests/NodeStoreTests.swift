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

/// The routing members (`endpoints`, `lastGood`, `lastAdvertisedAt`, the server's transfer protocol §2): optional on
/// disk, lenient, and never a reason to lose a record.
@Suite struct NodeRoutingRecordTests {
    private static let older = """
        {"id":"local-1","displayName":"vh","endpoint":{"host":"vh.local","port":36972},"pairing":{"unpaired":{}}}
        """

    private func decode(_ json: String) throws -> Node {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Node.self, from: Data(json.utf8))
    }

    @Test func recordsWithoutRoutesStillLoad() throws {
        let node = try decode(Self.older)
        #expect(node.endpoints.isEmpty && node.lastGood == nil && node.lastAdvertisedAt == nil)
    }

    @Test func roundTripsAndLeavesEmptyRoutesOut() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        var node = try decode(Self.older)
        let bare = String(decoding: try encoder.encode(node), as: UTF8.self)
        #expect(!bare.contains("endpoints") && !bare.contains("lastGood"))

        node.endpoints = [AdvertisedEndpoint(host: "10.0.0.11", port: 36972, kind: .lan, source: "interface",
                                             interface: "enp3s0")]
        node.lastGood = LastGoodEndpoint(endpoint: NodeEndpoint(host: "10.0.0.11"),
                                         at: Date(timeIntervalSince1970: 1_800_000_000), transportClass: .lan)
        node.lastAdvertisedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Node.self, from: encoder.encode(node)) == node)
    }

    @Test func malformedRoutesAreDroppedNotFatal() throws {
        let json = """
            {"id":"local-1","displayName":"vh","endpoint":{"host":"vh.local","port":36972},"pairing":{"unpaired":{}},
             "endpoints":[{"host":"10.0.0.11","port":36972,"kind":"lan"},{"host":"bad","port":99999},
                          {"port":1},{"host":"x.example","port":443,"kind":"quantum"}],
             "lastGood":{"endpoint":"nope"},"lastAdvertisedAt":"yesterday"}
            """
        let node = try decode(json)
        #expect(node.endpoints.map(\.host) == ["10.0.0.11", "x.example"])
        #expect(node.endpoints.last?.kind == nil)
        #expect(node.lastGood == nil && node.lastAdvertisedAt == nil)
    }

    @Test func classesOrderBestFirst() {
        #expect(EndpointClass.allCases.sorted() == [.loopback, .lan, .vpn, .wan, .passthrough])
        #expect(EndpointClass.wan.displayName == "Direct WAN")
    }
}

@Suite struct TransferStatsBoardTests {
    @Test func reportsLatestAndStreamsChanges() async {
        let board = TransferStatsBoard()
        let node = NodeID(rawValue: "n")
        #expect(board.stats(for: node) == nil)
        let updates = board.updates()
        board.report(TransferStats(throughputUp: 1e6, partBytes: 64 << 20, partsInFlight: 4, tuning: true), for: node)
        board.report(nil, for: node)
        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.0 == node && first?.1?.partsInFlight == 4 && first?.1?.throughputDown == nil)
        let second = await iterator.next()
        #expect(second?.0 == node && second?.1 == nil)
        #expect(board.stats(for: node) == nil)
    }
}
