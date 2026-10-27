import Foundation
import Testing
@testable import VHFinder

/// The per-domain replica database: listings applied as revisions, tombstones, moves, change batches, anchors, and
/// rebuilding when it can't be used (it is a cache).
@Suite struct ReplicaStoreTests {
    static func folder(_ id: Int64, _ path: String, parent: Int64?, meta: String = "m") -> FinderItem {
        FinderItem(entryID: id, parentEntryID: parent, name: path == "/" ? "Vault" : (path as NSString).lastPathComponent,
                   path: path, kind: .directory, size: 0, createdAt: "", updatedAt: "", contentVersion: nil,
                   metadataVersion: "\(meta)\(id)")
    }

    static func file(_ id: Int64, _ path: String, parent: Int64, generation: Int = 1) -> FinderItem {
        FinderItem(entryID: id, parentEntryID: parent, name: (path as NSString).lastPathComponent, path: path,
                   kind: .file, size: Int64(generation * 10), createdAt: "", updatedAt: "",
                   contentVersion: "\"g\(id)-\(generation)\"", metadataVersion: "m\(id)-\(generation)")
    }

    static let root = folder(1, "/", parent: nil)

    @Test func listingsTakeRevisionsOnlyWhenSomethingChanged() throws {
        let store = try ReplicaStore(url: nil)
        #expect(store.revision == 0)
        let a = Self.file(10, "/a.txt", parent: 1)
        let docs = Self.folder(11, "/docs", parent: 1)
        #expect(try store.applyListing(of: Self.root, children: [a, docs]) == 3)
        #expect(store.rootEntryID == 1)
        #expect(try store.isListed(1) && !(try store.isListed(11)))
        #expect(try store.children(of: 1).map(\.name) == ["a.txt", "docs"])
        let afterFirst = store.revision

        // The same listing again changes nothing.
        #expect(try store.applyListing(of: Self.root, children: [a, docs]) == 0)
        #expect(store.revision == afterFirst)

        // An edit, an addition, a removal.
        let edited = Self.file(10, "/a.txt", parent: 1, generation: 2)
        let b = Self.file(12, "/b.txt", parent: 1)
        #expect(try store.applyListing(of: Self.root, children: [edited, b]) == 3)
        let batch = try store.changes(after: afterFirst, limit: 100)
        #expect(batch.updated.map(\.entryID).sorted() == [10, 12])
        #expect(batch.deleted == [11])
        #expect(!batch.more && batch.last == store.revision)
        #expect(try store.item(11) == nil)
    }

    @Test func aRemovedFolderTakesItsSubtreeAndAReturningIDIsAnUpdateOnly() throws {
        let store = try ReplicaStore(url: nil)
        let docs = Self.folder(11, "/docs", parent: 1)
        let deep = Self.folder(13, "/docs/deep", parent: 11)
        try store.applyListing(of: Self.root, children: [docs])
        try store.applyListing(of: docs, children: [Self.file(20, "/docs/x", parent: 11), deep])
        try store.applyListing(of: deep, children: [Self.file(21, "/docs/deep/y", parent: 13)])
        let before = store.revision
        try store.applyListing(of: Self.root, children: [])
        let gone = try store.changes(after: before, limit: 100)
        #expect(Set(gone.deleted) == [11, 13, 20, 21])
        #expect(try store.listedFolders().map(\.entryID) == [1])

        // The folder comes back (it had moved away and back): reported as updated, not deleted.
        let back = store.revision
        try store.applyListing(of: Self.root, children: [docs])
        let returned = try store.changes(after: before, limit: 100)
        #expect(returned.updated.map(\.entryID) == [11])
        #expect(Set(returned.deleted) == [13, 20, 21])
        #expect(try store.changes(after: back, limit: 100).deleted.isEmpty)
    }

    /// A move between two enumerated folders: whichever is listed first, the entry ends up once, under its new parent.
    @Test func movesBetweenListedFolders() throws {
        let store = try ReplicaStore(url: nil)
        let left = Self.folder(11, "/left", parent: 1)
        let right = Self.folder(12, "/right", parent: 1)
        let file = Self.file(20, "/left/f", parent: 11)
        try store.applyListing(of: Self.root, children: [left, right])
        try store.applyListing(of: left, children: [file])
        try store.applyListing(of: right, children: [])
        let before = store.revision
        var moved = file
        moved.parentEntryID = 12
        moved.path = "/right/f"
        moved.metadataVersion = "m20-moved"
        try store.applyListing(of: right, children: [moved])
        try store.applyListing(of: left, children: [])
        #expect(try store.item(20)?.parentEntryID == 12)
        let batch = try store.changes(after: before, limit: 100)
        #expect(batch.updated.map(\.entryID).contains(20))
        #expect(!batch.deleted.contains(20))
    }

    @Test func changesComeInBatches() throws {
        let store = try ReplicaStore(url: nil)
        let files = (0..<25).map { Self.file(100 + Int64($0), "/f\($0)", parent: 1) }
        try store.applyListing(of: Self.root, children: files)
        var anchor: Int64 = 0
        var seen: [Int64] = []
        var rounds = 0
        while true {
            let batch = try store.changes(after: anchor, limit: 10)
            seen += batch.updated.map(\.entryID)
            anchor = batch.last
            rounds += 1
            if !batch.more { break }
        }
        #expect(rounds == 3)
        #expect(Set(seen) == Set(files.map(\.entryID) + [1]))
        #expect(anchor == store.revision)
    }

    @Test func anchorsBelongToTheirStore() throws {
        let store = try ReplicaStore(url: nil)
        try store.applyListing(of: Self.root, children: [Self.file(10, "/a", parent: 1)])
        #expect(store.accepts(store.currentAnchor))
        #expect(store.accepts(SyncAnchor(storeID: store.storeID, revision: 0)))
        #expect(!store.accepts(SyncAnchor(storeID: "another", revision: 1)))
        #expect(!store.accepts(SyncAnchor(storeID: store.storeID, revision: store.revision + 1)))
    }

    @Test func droppedTombstonesExpireOlderAnchors() throws {
        let store = try ReplicaStore(url: nil)
        let files = (0..<10).map { Self.file(100 + Int64($0), "/f\($0)", parent: 1) }
        try store.applyListing(of: Self.root, children: files)
        let early = store.currentAnchor
        try store.applyListing(of: Self.root, children: [])
        try store.pruneTombstones(keeping: 4)
        #expect(!store.accepts(early))
        #expect(store.accepts(store.currentAnchor))
        #expect(try store.changes(after: store.floor, limit: 100).deleted.count == 4)
    }

    @Test func rewritesPathsBelowAMovedFolder() throws {
        let store = try ReplicaStore(url: nil)
        let docs = Self.folder(11, "/docs", parent: 1)
        let deep = Self.folder(13, "/docs/deep", parent: 11)
        try store.applyListing(of: Self.root, children: [docs])
        try store.applyListing(of: docs, children: [deep, Self.file(20, "/docs/x", parent: 11)])
        try store.applyListing(of: deep, children: [Self.file(21, "/docs/deep/y", parent: 13)])
        let before = store.revision
        try store.rewritePaths(under: 11, from: "/docs", to: "/archive/docs")
        #expect(try store.item(20)?.path == "/archive/docs/x")
        #expect(try store.item(21)?.path == "/archive/docs/deep/y")
        #expect(try store.item(13)?.path == "/archive/docs/deep")
        #expect(store.revision == before)
    }

    @Test func persistsAndRebuildsWhatItCantUse() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vh-replica-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = ReplicaLocation.storeURL(domain: "local-abc.7", in: directory)
        #expect(url.lastPathComponent == "local-abc.7.sqlite" && url.deletingLastPathComponent().lastPathComponent == "FileProvider")

        let id: String
        let revision: Int64
        do {
            let store = try ReplicaStore(url: url)
            try store.applyListing(of: Self.root, children: [Self.file(10, "/a", parent: 1)])
            id = store.storeID
            revision = store.revision
        }
        do {
            let reopened = try ReplicaStore(url: url)
            #expect(reopened.storeID == id && reopened.revision == revision && reopened.rootEntryID == 1)
            #expect(try reopened.item(10)?.name == "a")
        }
        // A file that isn't a database: deleted and started over, with a new store id (every anchor expires).
        ReplicaStore.deleteFiles(at: url)
        try Data("not a database at all, just bytes".utf8).write(to: url)
        let rebuilt = try ReplicaStore(url: url)
        #expect(rebuilt.storeID != id && rebuilt.revision == 0 && rebuilt.rootEntryID == nil)
        #expect(!rebuilt.accepts(SyncAnchor(storeID: id, revision: revision)))
        ReplicaStore.deleteFiles(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
