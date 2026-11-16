import Foundation
import Testing
import VHCore
import VHFinder
@testable import VHVault

/// A host holding an open vault, counting what the replica tells it.
final class TestHost: EngineHost, @unchecked Sendable {
    let vault: Vault
    private let lock = NSLock()
    private var changes = 0
    private var conflicts = 0
    init(_ vault: Vault) { self.vault = vault }
    func openedVault() async -> Vault? { vault }
    func noteChange() async { lock.withLock { changes += 1 } }
    func noteWriteConflict() async { lock.withLock { conflicts += 1 } }
    var changeCount: Int { lock.withLock { changes } }
    var conflictCount: Int { lock.withLock { conflicts } }
}

/// The engine-backed File Provider replica (EngineReplica, behind VHFinder's FinderReplica) over the in-memory bucket:
/// everything the extension asks, without the extension.
@Suite struct EngineReplicaTests {
    func setUp() throws -> (Fixture, TestHost, EngineReplica, URL) {
        let f = Fixture()
        let vault = try f.created()
        let host = TestHost(vault)
        let replica = EngineReplica(host: host, numbersURL: f.directory.appending(path: "ids.json"))
        let downloads = f.directory.appending(path: "downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        return (f, host, replica, downloads)
    }

    func file(_ dir: URL, _ data: Data) throws -> URL {
        let url = dir.appending(path: "src-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test func enumeratesCreatesReadsAndEdits() async throws {
        let (f, host, replica, downloads) = try setUp()
        defer { f.cleanUp() }
        #expect(try await replica.list(.root, page: .first, pageSize: 10).items.isEmpty)
        let docs = try await replica.create(.init(name: "Docs", parent: .root, kind: .directory), contents: nil, mayAlreadyExist: false)
        #expect(docs.kind == .directory)
        // Finder asking again for a folder that is there gets it.
        let again = try await replica.create(.init(name: "Docs", parent: .root, kind: .directory), contents: nil, mayAlreadyExist: true)
        #expect(again.entryID == docs.entryID)
        await #expect(throws: FinderError.filenameCollision) {
            _ = try await replica.create(.init(name: "Docs", parent: .root, kind: .directory), contents: nil, mayAlreadyExist: false)
        }
        await #expect(throws: FinderError.excludedFromSync) {
            _ = try await replica.create(.init(name: ".DS_Store", parent: .root, kind: .file), contents: nil, mayAlreadyExist: false)
        }
        let bytes = content(200_000)
        let report = try await replica.create(.init(name: "report.pdf", parent: .entry(docs.entryID), kind: .file),
                                              contents: try file(downloads, bytes), mayAlreadyExist: false)
        #expect(report.size == 200_000 && report.parentEntryID == docs.entryID && report.contentVersion != nil)
        #expect(host.changeCount == 3)

        let root = try await replica.list(.root, page: .first, pageSize: 10).items
        #expect(root.map(\.name) == ["Docs"])
        #expect(try await replica.list(.entry(docs.entryID), page: .first, pageSize: 10).items.map(\.name) == ["report.pdf"])
        #expect(try await replica.workingSet(page: .first, pageSize: 10).items.count == 2)

        // Whole and ranged fetches, at the same offsets.
        let whole = try await replica.fetch(.entry(report.entryID), into: downloads)
        #expect(try Data(contentsOf: whole.url) == bytes)
        let part = try await replica.fetchRange(.entry(report.entryID), version: report.version, minimal: 70_000 ..< 70_010,
                                                alignment: 4096, strict: true, into: downloads)
        #expect(part.range == 69_632 ..< 73_728)
        let sparse = try Data(contentsOf: part.url)
        #expect(sparse[69_632 ..< 73_728] == bytes[69_632 ..< 73_728])

        // Rename, then move into the root under a new name.
        var moved = try await replica.modify(.entry(report.entryID), base: report.version,
                                             changes: .init(name: "final.pdf"), failOnConflict: false).item
        #expect(moved.name == "final.pdf" && moved.metadataVersion != report.metadataVersion)
        moved = try await replica.modify(.entry(report.entryID), base: moved.version,
                                         changes: .init(name: "top.pdf", parent: .root), failOnConflict: false).item
        let rootID = await replica.rootEntryID
        #expect(moved.name == "top.pdf" && moved.parentEntryID == rootID)

        // An edit on the current version: a new generation.
        let edited = try await replica.modify(.entry(report.entryID), base: moved.version,
                                              changes: .init(contents: try file(downloads, Data("v2".utf8))),
                                              failOnConflict: false).item
        #expect(edited.contentVersion != moved.contentVersion && edited.size == 2)
        // An edit based on the old version: both kept, this one current, the conflict noted.
        await #expect(throws: FinderError.localVersionConflictingWithServer) {
            _ = try await replica.modify(.entry(report.entryID), base: moved.version,
                                         changes: .init(contents: try file(downloads, Data("v3".utf8))), failOnConflict: true)
        }
        _ = try await replica.modify(.entry(report.entryID), base: moved.version,
                                     changes: .init(contents: try file(downloads, Data("v3".utf8))), failOnConflict: false)
        #expect(host.conflictCount == 1)
        let entry = try #require(try host.vault.stat(try host.vault.rootUID()).map { _ in
            try host.vault.list(try host.vault.rootUID()).first { $0.name == "top.pdf" }
        } ?? nil)
        #expect(entry.versions.count >= 3)
        #expect(try Data(contentsOf: try await replica.fetch(.entry(report.entryID), into: downloads).url) == Data("v3".utf8))
    }

    @Test func deletesGoToTheTrashAndAnEditBeatsADelete() async throws {
        let (f, _, replica, downloads) = try setUp()
        defer { f.cleanUp() }
        let dir = try await replica.create(.init(name: "D", parent: .root, kind: .directory), contents: nil, mayAlreadyExist: false)
        let a = try await replica.create(.init(name: "a", parent: .entry(dir.entryID), kind: .file),
                                         contents: try file(downloads, Data("a".utf8)), mayAlreadyExist: false)
        await #expect(throws: FinderError.directoryNotEmpty) {
            try await replica.delete(.entry(dir.entryID), base: dir.version, recursive: false)
        }
        let newer = try await replica.modify(.entry(a.entryID), base: a.version,
                                             changes: .init(contents: try file(downloads, Data("b".utf8))), failOnConflict: false).item
        await #expect(throws: FinderError.self) { try await replica.delete(.entry(a.entryID), base: a.version, recursive: false) }
        try await replica.delete(.entry(a.entryID), base: newer.version, recursive: false)
        await #expect(throws: FinderError.noSuchItem) { _ = try await replica.item(.entry(a.entryID)) }
        try await replica.delete(.entry(dir.entryID), base: dir.version, recursive: false)
        await #expect(throws: FinderError.deletionRejected("The vault's root can't be deleted.")) {
            try await replica.delete(.root, base: dir.version, recursive: true)
        }
    }

    @Test func changesSinceAnAnchorAndAnExpiredOne() async throws {
        let (f, host, replica, downloads) = try setUp()
        defer { f.cleanUp() }
        let start = await replica.currentAnchor
        let x = try await replica.create(.init(name: "x", parent: .root, kind: .file), contents: try file(downloads, Data("x".utf8)),
                                         mayAlreadyExist: false)
        var c = try await replica.changes(since: start, limit: 100)
        #expect(c.updated.map(\.name) == ["x"] && c.deleted.isEmpty)
        let after = c.anchor
        try await replica.delete(.entry(x.entryID), base: x.version, recursive: false)
        c = try await replica.changes(since: after, limit: 100)
        #expect(c.deleted == [.entry(x.entryID)])
        #expect(try await replica.changes(since: c.anchor, limit: 100).updated.isEmpty)
        // An anchor of another generation (a re-anchored change log): enumerate everything again.
        await #expect(throws: FinderError.syncAnchorExpired) {
            _ = try await replica.changes(since: SyncAnchor(storeID: "g1", revision: 0), limit: 100)
        }

        // Another writer's change, taken in by a refresh, arrives as a change too.
        _ = try host.vault.publish()
        let other = try f.open(state: f.directory.appending(path: "other"), node: "mac-b").vault
        try other.join()
        _ = try other.mkdir(parent: try other.rootUID(), name: "FromB")
        _ = try other.publish()
        let before = await replica.currentAnchor
        let refreshed = try host.vault.refresh()
        #expect(refreshed.applied)
        c = try await replica.changes(since: before, limit: 100)
        #expect(c.updated.map(\.name) == ["FromB"])
    }

    @Test func itemNumbersSurviveAReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ids-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "ids.json")
        let a = EntryNumbers(url: url)
        let one = a.number("aaaaaaaaaaaaaaaaaaaaaaaaaa")
        let two = a.number("bbbbbbbbbbbbbbbbbbbbbbbbbb")
        #expect(one != two && a.number("aaaaaaaaaaaaaaaaaaaaaaaaaa") == one)
        let b = EntryNumbers(url: url)
        #expect(b.uid(two) == "bbbbbbbbbbbbbbbbbbbbbbbbbb" && b.number("cccccccccccccccccccccccccc") > two)
    }

    @Test func theDomainIdentifierIsNeverANodes() {
        let id = DesktopVaultDomainID(vaultUid: "0123456789abcdefghjkmnpqrs")!
        #expect(id.identifier == "desktop-0123456789abcdefghjkmnpqrs")
        #expect(VaultDomainID(identifier: id.identifier) == nil)
        #expect(DesktopVaultDomainID(identifier: id.identifier) == id)
        #expect(DesktopVaultDomainID(identifier: "node-1.42") == nil)
        #expect(DesktopVaultDomainID(vaultUid: "UPPERCASE0123456789ABCDEFG") == nil)
    }
}
