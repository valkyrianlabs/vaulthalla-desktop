import Foundation
import Testing
import VHCore
import VHRecovery
@testable import VHVault

/// A vault on the in-memory B2-like bucket: what every engine test opens.
struct Fixture {
    let uid = Uid.random()
    let bucket = MemoryBucket()
    let key = newVaultKey()
    let recipient = RecoverySeed.generate()
    let directory: URL
    let clock = TickingClock()

    init() {
        directory = FileManager.default.temporaryDirectory.appending(path: "vhvault-\(UUID().uuidString)")
    }

    var keys: MemoryVaultKeys { MemoryVaultKeys([1: key], current: 1) }
    var stateURL: URL { directory.appending(path: "state") }

    func envelope() throws -> Data {
        try KEV1.wrap(vaultKey: key, suite: .x25519, keyVersion: 1, vaultUid: uid,
                      recipientPublicKey: recipient.x25519PublicKey())
    }

    func open(create: String? = nil, state: URL? = nil, node: String = "mac-a") throws(VaultError) -> (vault: Vault, info: OpenInfo) {
        try Vault.open(uid: uid, store: bucket, keys: keys, stateURL: state ?? stateURL, nodeID: node, createName: create,
                       now: clock.tick)
    }

    /// A new vault with key 1 added (its envelope PUT first).
    func created() throws -> Vault {
        let (vault, info) = try open(create: "Finance")
        #expect(info.anchor == .created)
        try vault.addKey(version: 1, key: key, envelopes: [try envelope()])
        return vault
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

/// A clock that moves a second per reading, as the library's C lifecycle test's does: every change gets its own time.
final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Int64 = 1_800_000_000
    func tick() -> Int64 { lock.withLock { now += 1; return now } }
}

func content(_ n: Int, seed: Int = 13) -> Data { Data((0 ..< n).map { UInt8(truncatingIfNeeded: $0 * seed + ($0 >> 8)) }) }

@Suite struct EngineTests {
    @Test func nothingToOpenWithoutANameThenANewVault() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        #expect(throws: VaultError.self) { try f.open() }
        do {
            _ = try f.open()
        } catch {
            #expect(error.status == VaultStatus.noVault)
            #expect(!error.message.isEmpty)
        }
        let vault = try f.created()
        let root = try vault.rootUID()
        #expect(root.count == 26)
        #expect(try vault.list(root).isEmpty)
    }

    @Test func nothingIsSealedBeforeAKeyIsAddedWithItsEnvelope() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let (vault, _) = try f.open(create: "Finance")
        let root = try vault.rootUID()
        #expect { try vault.beginWrite(parent: root, name: "x") } throws: { ($0 as? VaultError)?.status == VaultStatus.keyNotAdded }
        #expect { try vault.addKey(version: 1, key: f.key, envelopes: []) } throws: {
            ($0 as? VaultError)?.status == VaultStatus.recipientRequired
        }
        try vault.addKey(version: 1, key: f.key, envelopes: [try f.envelope()])
        // The envelope is in the bucket before anything is sealed under the key.
        #expect(f.bucket.currentKeys.contains { $0.hasPrefix(".vaulthalla/key/") })
    }

    /// vl-vaultfmt's tests/c_engine_lifecycle.c, through VHVault.
    @Test func aWholeLifecycle() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        var vault: Vault? = try f.created()
        let root = try vault!.rootUID()
        let docs = try vault!.mkdir(parent: root, name: "Docs")
        #expect { try vault!.mkdir(parent: root, name: "Docs") } throws: { ($0 as? VaultError)?.status == VaultStatus.nameExists }
        let bytes = content(150_000)
        let written = try vault!.write(bytes, parent: docs.uid, name: "report.pdf")
        #expect(!written.conflict)
        #expect(written.entry.kind == .file && written.entry.size == 150_000 && written.entry.versionID != nil)
        #expect(written.entry.versions.count == 1)
        let file = written.entry.uid
        #expect(try vault!.readData(file) == bytes)
        #expect(try vault!.readData(file, offset: 70_000, length: 10) == bytes[70_000 ..< 70_010])

        try vault!.rename(file, to: "final.pdf")
        #expect(try vault!.status().unpublished)
        let p1 = try vault!.publish()
        #expect(p1.published && p1.epoch == 1)
        let s = try vault!.status()
        #expect(!s.unpublished && s.epoch == 1)
        f.bucket.resetRequestCount()
        let r = try vault!.refresh()
        #expect(!r.moved && f.bucket.requestCount == 1)

        var changes = try vault!.changes(generation: s.generation, after: s.revision)
        #expect(!changes.expired && changes.changed.isEmpty)
        try vault!.trashEntry(file)
        changes = try vault!.changes(generation: s.generation, after: s.revision)
        #expect(changes.changed.count == 1 && changes.changed[0].trashed)
        #expect(try vault!.trash().map(\.uid) == [file])
        try vault!.restore(file)
        #expect(try vault!.publish().epoch == 2)

        // Close and open again from the state.
        vault = nil
        let (again, info) = try f.open()
        #expect(info.anchor == .state && info.state == .loaded && info.epoch == 2)
        #expect(try again.list(docs.uid).map(\.name) == ["final.pdf"])

        // Another installation with no state re-anchors from the bucket and reads the file.
        let other = try f.open(state: f.directory.appending(path: "other"), node: "mac-b")
        #expect(other.info.anchor == .reanchored && !other.info.freshnessVerified && other.info.epoch == 2)
        #expect(try other.vault.readData(file) == bytes)

        // Purge: the objects go once a root without the file settled.
        try again.purge(file)
        #expect(try again.stat(file) == nil)
        #expect(try again.publish().purged == 1)
        #expect { try again.readData(file) } throws: { ($0 as? VaultError)?.isNotFound == true }
    }

    @Test func theStateIsLockedToOneHandle() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let vault = try f.created()
        #expect { try f.open() } throws: { ($0 as? VaultError)?.name == "state_busy" }
        _ = vault
    }

    @Test func aWriteFromAnOlderGenerationKeepsBoth() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let vault = try f.created()
        let root = try vault.rootUID()
        let first = try vault.write(Data("one".utf8), parent: root, name: "a.txt").entry
        let second = try vault.write(Data("two".utf8), uid: first.uid, expectedGeneration: first.generation).entry
        #expect(second.generation != first.generation)
        // An edit that started from the first generation: both kept, this one current.
        let late = try vault.write(Data("three".utf8), uid: first.uid, expectedGeneration: first.generation)
        #expect(late.conflict)
        #expect(try vault.readData(first.uid) == Data("three".utf8))
    }

    @Test func storeFailuresArriveWithTheirStatus() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let vault = try f.created()
        _ = try vault.mkdir(parent: try vault.rootUID(), name: "A")
        f.bucket.failNext = .failed("HTTP 503 from the provider")
        #expect { try vault.publish() } throws: { e in
            guard let e = e as? VaultError else { return false }
            return e.isTransient
        }
        #expect(try vault.status().unpublished)
        #expect(try vault.publish().published)
    }
}
