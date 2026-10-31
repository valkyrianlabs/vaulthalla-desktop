import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
import VHFinder
import VHIdentity
import VHTransport
@testable import VHNodes

/// The File Provider replica (vaulthalla/desktop#4) end to end against the mock daemon (ws, Device sessions) and the
/// lanes test server, both answering for one ``FakeVault``: the same ``VaultReplica`` and ``NodeLink`` the extension
/// runs, presenting this Mac's key as a credential consumer.
extension KeychainSuite {
@Suite struct FinderReplicaTests {
    struct Fixture: Sendable {
        let daemon: MockDaemon
        let vault: FakeVault
        let replica: VaultReplica
        let link: NodeLink
        let device: DeviceIdentity
        let scratch: URL

        func names(_ items: [FinderItem]) -> [String] { items.map(\.name).sorted() }

        /// The root's children, listed through the replica.
        @discardableResult
        func listRoot() async throws -> [FinderItem] {
            try await replica.list(.root, page: .first, pageSize: 500).items
        }

        func item(_ path: String) async throws -> FinderItem {
            let id = try #require(vault.id(path))
            return try await replica.item(.entry(id))
        }
    }

    static let moment = Date(timeIntervalSince1970: 1_792_850_400)
    static let pattern = Data((0..<65536).map { UInt8((7 * $0 + 3) % 256) })

    /// `capabilities`: what the node's `meta.hello` announces (nil: a legacy node, which answers no hello).
    private func withReplica(onlineTimeout: Duration = .seconds(5), capabilities: [String]? = nil,
                             _ body: (Fixture) async throws -> Void) async throws
    {
        let shared = try KeychainFixture.require()
        let daemon = try await MockDaemon.start(identity: shared.server)
        defer { daemon.stop() }
        daemon.register(shared.device.spkiSHA256)
        if let capabilities {
            let hello = NodeSessionTests.hello(capabilities: capabilities, commands: [
                "device.server.identity", "meta.hello", "fs.dir.list", "fs.entry.get", "fs.dir.create", "fs.entry.rename",
                "fs.entry.move", "fs.entry.delete",
            ])
            daemon.answer("meta.hello") { _ in .ok(hello) }
        }
        let vault = FakeVault()
        vault.serve(on: daemon)
        let lanes = try await HTTPTestServer.start(tls: FakeVault.tls(server: shared.server),
                                                   router: { vault.route($0) }) { vault.handle($0) }
        defer { lanes.stop() }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "vh-replica-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let node = Node(
            id: NodeID(rawValue: "node-a"), displayName: "vh-test",
            endpoint: NodeEndpoint(host: "127.0.0.1", port: daemon.port),
            pairing: .paired(serverSPKISHA256: shared.server.spkiSHA256, deviceID: shared.device.deviceID, since: .now))
        try await TestRegistry.with { registry in
            try registry.owner.add(node)
            var configuration = NodeLink.Configuration()
            configuration.session = Fast.session()
            configuration.onlineTimeout = onlineTimeout
            configuration.offlineTimeout = .seconds(1)
            configuration.laneTimeout = .seconds(5)
            configuration.laneEndpoint = NodeEndpoint(host: "127.0.0.1", port: lanes.port)
            let link = NodeLink(nodeID: node.id, reader: CredentialReader(
                registry: registry.consumer, keys: TestRegistry.consumerKeys(shared.store)), configuration: configuration)
            let replica = try VaultReplica(vaultID: FakeVault.vaultID, link: link, storeURL: nil, macName: "Test Mac",
                                           now: { Self.moment })
            let fixture = Fixture(daemon: daemon, vault: vault, replica: replica, link: link, device: shared.device,
                                  scratch: scratch)
            do {
                try await body(fixture)
                await replica.close()
            } catch {
                await replica.close()
                throw error
            }
        }
    }

    private func write(_ text: String, in fixture: Fixture) throws -> URL {
        let url = fixture.scratch.appending(path: "local-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: Browsing and reading

    @Test func listsWhatTheServerListsAndReadsItsBytes() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/hello.txt", data: Data("Hello from the vault, 44 bytes of text!!!!\n".utf8))
            fixture.vault.add("/docs")
            fixture.vault.add("/docs/blob.bin", data: Self.pattern)
            fixture.vault.add("/latest", type: "symlink", target: "docs/blob.bin")

            let root = try await fixture.listRoot()
            #expect(fixture.names(root) == fixture.vault.names(in: "/"))
            #expect(root.first { $0.name == "docs" }?.kind == .directory)
            #expect(root.first { $0.name == "latest" }?.symlinkTarget == "docs/blob.bin")
            #expect(try await fixture.replica.item(.root).isRoot)

            // Whole file: the bytes, at the version they are.
            let hello = try await fixture.item("/hello.txt")
            let (url, fetched) = try await fixture.replica.fetch(hello.identifier(root: 1), into: fixture.scratch)
            #expect(try Data(contentsOf: url) == fixture.vault.data("/hello.txt"))
            #expect(fetched.contentVersion == fixture.vault.contentVersion("/hello.txt"))

            // A folder: its children join the working set once listed.
            let docs = try await fixture.item("/docs")
            let inside = try await fixture.replica.list(.entry(docs.entryID), page: .first, pageSize: 10).items
            #expect(fixture.names(inside) == ["blob.bin"])
            let workingSet = try await fixture.replica.workingSet(page: .first, pageSize: 500).items
            #expect(Set(workingSet.map(\.name)) == ["hello.txt", "docs", "latest", "blob.bin"])

            // A range: aligned, written at its offset, guarded by the version.
            let blob = try await fixture.item("/docs/blob.bin")
            let part = try await fixture.replica.fetchRange(.entry(blob.entryID), version: blob.version,
                                                            minimal: 20_000..<20_100, alignment: 16384, strict: true,
                                                            into: fixture.scratch)
            #expect(part.range == 16384..<32768)
            let handle = try FileHandle(forReadingFrom: part.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 16384)
            #expect(try handle.read(upToCount: 16384) == Self.pattern[16384..<32768])
            #expect(part.item.version == blob.version)
        }
    }

    @Test func pagesAFolderByName() async throws {
        try await withReplica { fixture in
            for index in 0..<7 { fixture.vault.add("/f\(index).txt", data: Data([UInt8(index)])) }
            var page = EnumerationPage.first
            var names: [String] = []
            while true {
                let (items, next) = try await fixture.replica.list(.root, page: page, pageSize: 3)
                names += items.map(\.name)
                guard let next else { break }
                page = next
            }
            #expect(names == (0..<7).map { "f\($0).txt" })
            // Later pages come from the replica: one listing for the whole enumeration.
            #expect(fixture.daemon.count(of: "fs.dir.list") == 1)
        }
    }

    @Test func aRangeOfAnotherVersionIsRefusedOrReplacedWhole() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/blob.bin", data: Self.pattern)
            try await fixture.listRoot()
            let old = try await fixture.item("/blob.bin")
            let newer = Data(repeating: 0x5A, count: 40_000)
            fixture.vault.edit("/blob.bin", newer)

            await #expect(throws: FinderError.versionNoLongerAvailable) {
                _ = try await fixture.replica.fetchRange(.entry(old.entryID), version: old.version, minimal: 0..<100,
                                                         alignment: 4096, strict: true, into: fixture.scratch)
            }
            // The replica learned the new version on the way.
            #expect(try await fixture.replica.item(.entry(old.entryID)).contentVersion
                == fixture.vault.contentVersion("/blob.bin"))

            let whole = try await fixture.replica.fetchRange(.entry(old.entryID), version: old.version,
                                                             minimal: 0..<100, alignment: 4096, strict: false,
                                                             into: fixture.scratch)
            #expect(whole.range == 0..<40_000)
            #expect(try Data(contentsOf: whole.url) == newer)
            #expect(whole.item.contentVersion == fixture.vault.contentVersion("/blob.bin"))
        }
    }

    // MARK: Creating

    @Test func createsFilesAndFoldersConditionally() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/docs")
            try await fixture.listRoot()

            let made = try await fixture.replica.create(.init(name: "new.txt", parent: .root, kind: .file),
                                                        contents: try write("brand new", in: fixture))
            #expect(fixture.vault.data("/new.txt") == Data("brand new".utf8))
            #expect(made.entryID == fixture.vault.id("/new.txt") && made.parentIdentifier(root: 1) == .root)
            #expect(made.contentVersion == fixture.vault.contentVersion("/new.txt"))
            let put = try #require(fixture.vault.state.withLock { $0.puts.last })
            #expect(put.ifNoneMatch == "*" && put.ifMatch == nil)

            // The name is taken now: a collision, and the server's file stays.
            await #expect(throws: FinderError.filenameCollision) {
                _ = try await fixture.replica.create(.init(name: "new.txt", parent: .root, kind: .file),
                                                     contents: try write("other", in: fixture))
            }
            #expect(fixture.vault.data("/new.txt") == Data("brand new".utf8))

            // An empty file, a folder, and a folder that is already there when the system says it may be.
            let empty = try await fixture.replica.create(.init(name: "empty", parent: .root, kind: .file), contents: nil)
            #expect(empty.size == 0 && fixture.vault.data("/empty") == Data())
            let folder = try await fixture.replica.create(.init(name: "made", parent: .root, kind: .directory),
                                                          contents: nil)
            #expect(folder.kind == .directory && fixture.vault.id("/made") == folder.entryID)
            let docs = try await fixture.replica.create(.init(name: "docs", parent: .root, kind: .directory),
                                                        contents: nil, mayAlreadyExist: true)
            #expect(docs.entryID == fixture.vault.id("/docs"))
            await #expect(throws: FinderError.filenameCollision) {
                _ = try await fixture.replica.create(.init(name: "docs", parent: .root, kind: .directory), contents: nil)
            }

            // Never sent: Finder's view settings and symlinks.
            await #expect(throws: FinderError.excludedFromSync) {
                _ = try await fixture.replica.create(.init(name: ".DS_Store", parent: .root, kind: .file),
                                                     contents: try write("x", in: fixture))
            }
            await #expect(throws: FinderError.excludedFromSync) {
                _ = try await fixture.replica.create(.init(name: "link", parent: .root, kind: .symlink), contents: nil)
            }
            await #expect(throws: FinderError.cannotSynchronize("A name can't contain “/”.")) {
                _ = try await fixture.replica.create(.init(name: "a/b", parent: .root, kind: .file), contents: nil)
            }
        }
    }

    /// The server's access rules decide: a refused upload (403 on the lanes, the key still accepted) is the
    /// account's, not a revocation, and nothing is retried as if it were.
    @Test func aRefusedWriteIsTheAccountsNotARevocation() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/locked")
            fixture.vault.state.withLock { $0.readOnly = ["/locked"] }
            try await fixture.listRoot()
            let locked = try await fixture.item("/locked")
            await #expect {
                _ = try await fixture.replica.create(.init(name: "a.txt", parent: .entry(locked.entryID), kind: .file),
                                                     contents: try write("x", in: fixture))
            } throws: { error in
                guard case FinderError.cannotSynchronize = error else { return false }
                return true
            }
            await #expect {
                _ = try await fixture.replica.create(.init(name: "d", parent: .entry(locked.entryID), kind: .directory),
                                                     contents: nil)
            } throws: { error in
                guard case FinderError.cannotSynchronize = error else { return false }
                return true
            }
            // The link didn't fail closed: reading still works.
            #expect(await fixture.link.closedReason == nil)
            #expect(try await fixture.listRoot().count == 1)
        }
    }

    // MARK: Editing and conflicts

    @Test func anEditReplacesTheVersionItWasBasedOn() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/hello.txt", data: Data("hello".utf8))
            try await fixture.listRoot()
            let hello = try await fixture.item("/hello.txt")
            let done = try await fixture.replica.modify(.entry(hello.entryID), base: hello.version,
                                                        changes: .init(contents: try write("hello, edited", in: fixture)))
            #expect(fixture.vault.data("/hello.txt") == Data("hello, edited".utf8))
            #expect(!done.fetchContents && done.conflictCopy == nil)
            #expect(done.item.entryID == hello.entryID && done.item.contentVersion != hello.contentVersion)
            #expect(done.item.contentVersion == fixture.vault.contentVersion("/hello.txt"))
            #expect(fixture.vault.state.withLock { $0.puts.last?.ifMatch } == hello.contentVersion)
        }
    }

    /// The server's file changed since the edit's base: the edit goes to a conflict copy, the server's version stays
    /// and comes back to the Mac. Neither edit is lost.
    @Test func aCompetingEditBecomesAConflictCopy() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/hello.txt", data: Data("hello".utf8))
            try await fixture.listRoot()
            let hello = try await fixture.item("/hello.txt")
            fixture.vault.edit("/hello.txt", Data("server edit".utf8))

            let done = try await fixture.replica.modify(.entry(hello.entryID), base: hello.version,
                                                        changes: .init(contents: try write("mac edit", in: fixture)))
            let copyName = ConflictName.make(for: "hello.txt", macName: "Test Mac", date: Self.moment)
            #expect(fixture.vault.data("/hello.txt") == Data("server edit".utf8))
            #expect(fixture.vault.data("/\(copyName)") == Data("mac edit".utf8))
            #expect(done.fetchContents)
            #expect(done.item.entryID == hello.entryID)
            #expect(done.item.contentVersion == fixture.vault.contentVersion("/hello.txt"))
            #expect(done.conflictCopy?.name == copyName)
            // The edit never went up as a replacement: the only upload created the copy.
            #expect(fixture.vault.state.withLock { $0.puts.map(\.path) } == ["/\(copyName)"])

            // Another conflict in the same minute takes the next free name.
            let current = try await fixture.item("/hello.txt")
            fixture.vault.edit("/hello.txt", Data("server edit 2".utf8))
            let again = try await fixture.replica.modify(.entry(current.entryID), base: current.version,
                                                         changes: .init(contents: try write("mac edit 2", in: fixture)))
            let second = ConflictName.make(for: "hello.txt", macName: "Test Mac", date: Self.moment, attempt: 2)
            #expect(again.conflictCopy?.name == second)
            #expect(fixture.vault.data("/\(second)") == Data("mac edit 2".utf8))
            #expect(fixture.vault.data("/hello.txt") == Data("server edit 2".utf8))
        }
    }

    /// The competing write lands between the version check and the upload: the server refuses the upload (412) and
    /// the edit becomes a conflict copy all the same.
    @Test func aRaceAtTheUploadBecomesAConflictCopy() async throws {
        try await withReplica { fixture in
            let id = fixture.vault.add("/hello.txt", data: Data("hello".utf8))
            try await fixture.listRoot()
            let hello = try await fixture.item("/hello.txt")
            fixture.vault.state.withLock { state in
                state.beforePut = { state in
                    state.entries[id]!.data = Data("raced".utf8)
                    state.entries[id]!.generation += 1
                    state.entries[id]!.revision += 1
                }
            }
            let done = try await fixture.replica.modify(.entry(hello.entryID), base: hello.version,
                                                        changes: .init(contents: try write("mac edit", in: fixture)))
            let copyName = ConflictName.make(for: "hello.txt", macName: "Test Mac", date: Self.moment)
            #expect(fixture.vault.data("/hello.txt") == Data("raced".utf8))
            #expect(fixture.vault.data("/\(copyName)") == Data("mac edit".utf8))
            #expect(done.fetchContents && done.item.contentVersion == fixture.vault.contentVersion("/hello.txt"))
            let puts = fixture.vault.state.withLock { $0.puts }
            #expect(puts.first?.ifMatch == hello.contentVersion && puts.first?.path == "/hello.txt")
        }
    }

    /// A node with `http.upload.resumable`: a write larger than 8 MiB goes as a single-file resumable session
    /// carrying the precondition (`if_none_match: "*"` to create, `if_match` to replace); a failed precondition at
    /// commit is still a conflict copy. Small writes stay one `PUT /upload/content`.
    @Test func largeWritesGoAsResumableSessions() async throws {
        let capabilities = ["device.lanes.download", "device.lanes.upload", "device.server.identity",
                            "http.upload.resumable"]
        try await withReplica(capabilities: capabilities) { fixture in
            try await fixture.listRoot()
            let big = Data((0..<(9 << 20 + 123)).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
            let bigURL = fixture.scratch.appending(path: "big")
            try big.write(to: bigURL)

            let made = try await fixture.replica.create(.init(name: "big.bin", parent: .root, kind: .file),
                                                        contents: bigURL)
            #expect(fixture.vault.data("/big.bin") == big)
            #expect(made.contentVersion == fixture.vault.contentVersion("/big.bin"))
            let first = try #require(fixture.vault.uploads.state.withLock { $0.sessions["up1"] })
            #expect(first.files.first?.ifNoneMatch == "*" && first.files.first?.duplicatePolicy == nil)
            #expect(fixture.vault.uploads.partRequests.count >= 1)

            // An edit replaces the version it was based on.
            let edited = big + Data("and a tail".utf8)
            let editedURL = fixture.scratch.appending(path: "edited")
            try edited.write(to: editedURL)
            let done = try await fixture.replica.modify(.entry(made.entryID), base: made.version,
                                                        changes: .init(contents: editedURL))
            #expect(fixture.vault.data("/big.bin") == edited)
            #expect(!done.fetchContents && done.item.contentVersion == fixture.vault.contentVersion("/big.bin"))
            #expect(fixture.vault.uploads.state.withLock { $0.sessions["up2"]?.files.first?.ifMatch } == made.contentVersion)

            // A competing write lands before the commit: the precondition fails there, and the edit becomes a copy.
            let id = try #require(fixture.vault.id("/big.bin"))
            fixture.vault.state.withLock { state in
                state.beforePut = { state in
                    state.entries[id]!.data = Data("raced".utf8)
                    state.entries[id]!.generation += 1
                    state.entries[id]!.revision += 1
                }
            }
            let current = try await fixture.item("/big.bin")
            let raced = try await fixture.replica.modify(.entry(current.entryID), base: current.version,
                                                         changes: .init(contents: bigURL))
            let copyName = ConflictName.make(for: "big.bin", macName: "Test Mac", date: Self.moment)
            #expect(fixture.vault.data("/big.bin") == Data("raced".utf8))
            #expect(fixture.vault.data("/\(copyName)") == big)
            #expect(raced.fetchContents && raced.conflictCopy?.name == copyName)

            // Small writes: one PUT /upload/content, as before.
            let sessions = fixture.vault.uploads.state.withLock { $0.sessions.count }
            _ = try await fixture.replica.create(.init(name: "small.txt", parent: .root, kind: .file),
                                                 contents: try write("small", in: fixture))
            #expect(fixture.vault.data("/small.txt") == Data("small".utf8))
            #expect(fixture.vault.uploads.state.withLock { $0.sessions.count } == sessions)
        }
    }

    /// Without the capability (a legacy node), even a large write is one `PUT /upload/content`.
    @Test func largeWritesStayOnePutWithoutTheCapability() async throws {
        try await withReplica { fixture in
            try await fixture.listRoot()
            let big = Data(repeating: 7, count: 9 << 20)
            let url = fixture.scratch.appending(path: "big")
            try big.write(to: url)
            _ = try await fixture.replica.create(.init(name: "big.bin", parent: .root, kind: .file), contents: url)
            #expect(fixture.vault.data("/big.bin") == big)
            #expect(fixture.vault.uploads.state.withLock { $0.sessions.isEmpty })
        }
    }

    @Test func failOnConflictLeavesTheMergeToTheSystem() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/hello.txt", data: Data("hello".utf8))
            try await fixture.listRoot()
            let hello = try await fixture.item("/hello.txt")
            fixture.vault.edit("/hello.txt", Data("server edit".utf8))
            await #expect(throws: FinderError.localVersionConflictingWithServer) {
                _ = try await fixture.replica.modify(.entry(hello.entryID), base: hello.version,
                                                     changes: .init(contents: try write("mac edit", in: fixture)),
                                                     failOnConflict: true)
            }
            #expect(fixture.vault.names(in: "/") == ["hello.txt"])
            #expect(fixture.vault.data("/hello.txt") == Data("server edit".utf8))
        }
    }

    // MARK: Rename, move, delete

    @Test func renamesAndMovesKeepTheItem() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/hello.txt", data: Data("hello".utf8))
            fixture.vault.add("/docs")
            fixture.vault.add("/archive")
            fixture.vault.add("/docs/inner.txt", data: Data("inner".utf8))
            try await fixture.listRoot()
            let docs = try await fixture.item("/docs")
            _ = try await fixture.replica.list(.entry(docs.entryID), page: .first, pageSize: 10)
            let hello = try await fixture.item("/hello.txt")

            let renamed = try await fixture.replica.modify(.entry(hello.entryID), base: hello.version,
                                                           changes: .init(name: "hi.txt"))
            #expect(renamed.item.entryID == hello.entryID && renamed.item.name == "hi.txt")
            #expect(renamed.item.metadataVersion != hello.metadataVersion)
            #expect(renamed.item.contentVersion == hello.contentVersion)
            #expect(fixture.vault.names(in: "/") == ["archive", "docs", "hi.txt"])
            #expect(fixture.daemon.count(of: "fs.entry.rename") == 1)

            let moved = try await fixture.replica.modify(.entry(hello.entryID), base: renamed.item.version,
                                                         changes: .init(parent: .entry(docs.entryID)))
            #expect(moved.item.parentIdentifier(root: 1) == .entry(docs.entryID) && moved.item.path == "/docs/hi.txt")
            #expect(fixture.vault.names(in: "/docs") == ["hi.txt", "inner.txt"])
            #expect(fixture.daemon.count(of: "fs.entry.move") == 1)

            // A folder moves with what it holds: the paths below follow, so the next read goes to the right place.
            let archive = try await fixture.item("/archive")
            _ = try await fixture.replica.modify(.entry(docs.entryID), base: docs.version,
                                                 changes: .init(parent: .entry(archive.entryID)))
            let inner = try await fixture.item("/archive/docs/inner.txt")
            #expect(inner.path == "/archive/docs/inner.txt")
            let (url, _) = try await fixture.replica.fetch(.entry(inner.entryID), into: fixture.scratch)
            #expect(try Data(contentsOf: url) == Data("inner".utf8))

            // The server refuses the destination: the system is told it can't sync this.
            fixture.vault.state.withLock { $0.readOnly = ["/"] }
            await #expect {
                _ = try await fixture.replica.modify(.entry(archive.entryID), base: archive.version,
                                                     changes: .init(name: "renamed"))
            } throws: { error in
                guard case FinderError.cannotSynchronize = error else { return false }
                return true
            }
        }
    }

    @Test func deletesIntoTheServersTrash() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/a.txt", data: Data("a".utf8))
            fixture.vault.add("/b.txt", data: Data("b".utf8))
            fixture.vault.add("/full")
            fixture.vault.add("/full/x", data: Data("x".utf8))
            try await fixture.listRoot()
            let a = try await fixture.item("/a.txt")
            try await fixture.replica.delete(.entry(a.entryID), base: a.version, recursive: false)
            #expect(fixture.vault.names(in: "/") == ["b.txt", "full"])
            #expect(fixture.vault.state.withLock { $0.trash.map(\.name) } == ["a.txt"])
            // Already gone: done.
            try await fixture.replica.delete(.entry(a.entryID), base: a.version, recursive: false)

            // Changed on the server since the base: not deleted.
            let b = try await fixture.item("/b.txt")
            fixture.vault.edit("/b.txt", Data("b, edited elsewhere".utf8))
            await #expect {
                try await fixture.replica.delete(.entry(b.entryID), base: b.version, recursive: false)
            } throws: { error in
                guard case FinderError.deletionRejected = error else { return false }
                return true
            }
            #expect(fixture.vault.data("/b.txt") == Data("b, edited elsewhere".utf8))

            // A folder with children only when recursive.
            let full = try await fixture.item("/full")
            await #expect(throws: FinderError.directoryNotEmpty) {
                try await fixture.replica.delete(.entry(full.entryID), base: full.version, recursive: false)
            }
            try await fixture.replica.delete(.entry(full.entryID), base: full.version, recursive: true)
            #expect(fixture.vault.names(in: "/") == ["b.txt"])
            await #expect(throws: FinderError.noSuchItem) { _ = try await fixture.replica.item(.entry(full.entryID)) }
        }
    }

    // MARK: Changes

    /// No change journal yet: the enumerated folders are listed again and diffed, and the anchor moves on.
    @Test func findsTheServersChangesByListingAgain() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/hello.txt", data: Data("hello".utf8))
            fixture.vault.add("/gone.txt", data: Data("bye".utf8))
            fixture.vault.add("/docs")
            fixture.vault.add("/docs/inner.txt", data: Data("inner".utf8))
            try await fixture.listRoot()
            let docs = try await fixture.item("/docs")
            _ = try await fixture.replica.list(.entry(docs.entryID), page: .first, pageSize: 10)
            let inner = try await fixture.item("/docs/inner.txt")
            let anchor = await fixture.replica.currentAnchor
            let gone = try #require(fixture.vault.id("/gone.txt"))

            fixture.vault.add("/fresh.txt", data: Data("new".utf8))
            fixture.vault.edit("/hello.txt", Data("hello, changed".utf8))
            fixture.vault.remove("/gone.txt")
            fixture.vault.state.withLock { state in
                state.entries[docs.entryID]!.name = "papers"
                state.entries[docs.entryID]!.revision += 1
            }

            let changes = try await fixture.replica.changes(since: anchor)
            #expect(Set(changes.updated.map(\.name)) == ["fresh.txt", "hello.txt", "papers", "inner.txt"])
            #expect(changes.deleted == [.entry(gone)])
            #expect(!changes.moreComing && changes.anchor.revision > anchor.revision)
            #expect(changes.updated.first { $0.name == "hello.txt" }?.contentVersion
                == fixture.vault.contentVersion("/hello.txt"))
            // The renamed folder kept its id, and its child's path followed it.
            #expect(changes.updated.first { $0.name == "papers" }?.entryID == docs.entryID)
            #expect(try await fixture.replica.item(.entry(inner.entryID)).path == "/papers/inner.txt")

            // Nothing new since: an empty batch at the same anchor.
            try await Task.sleep(for: VaultReplica.refreshInterval)
            let none = try await fixture.replica.changes(since: changes.anchor)
            #expect(none.updated.isEmpty && none.deleted.isEmpty && none.anchor == changes.anchor)
        }
    }

    /// A folder the account may no longer list goes, with what it held: lost visibility arrives as deletions.
    @Test func lostVisibilityArrivesAsDeletions() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/docs")
            fixture.vault.add("/docs/secret.txt", data: Data("s".utf8))
            try await fixture.listRoot()
            let docs = try await fixture.item("/docs")
            _ = try await fixture.replica.list(.entry(docs.entryID), page: .first, pageSize: 10)
            let secret = try await fixture.item("/docs/secret.txt")
            let anchor = await fixture.replica.currentAnchor
            fixture.vault.state.withLock { $0.unlistable = ["/docs"] }
            let changes = try await fixture.replica.changes(since: anchor)
            #expect(Set(changes.deleted) == [.entry(docs.entryID), .entry(secret.entryID)])

            await #expect(throws: FinderError.syncAnchorExpired) {
                _ = try await fixture.replica.changes(since: SyncAnchor(storeID: "another-store", revision: 0))
            }
        }
    }

    @Test func thumbnailsComeFromTheServersPreviews() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/photo.jpg", data: Data([1, 2, 3]))
            fixture.vault.add("/render.png", data: Data([4]))
            fixture.vault.add("/folder")
            try await fixture.listRoot()
            let ids = try await [fixture.item("/photo.jpg"), fixture.item("/render.png"), fixture.item("/folder")]
                .map { FinderItemID.entry($0.entryID) }
            let results = Mutex<[FinderItemID: Data?]>([:])
            await fixture.replica.thumbnails(for: ids + [.entry(99_999)], size: 256) { id, data, error in
                #expect(error == nil)
                results.withLock { $0[id] = data }
            }
            let got = results.withLock { $0 }
            #expect(got.count == 4)
            #expect(got[ids[0]] == .some(Data([0xFF, 0xD8, 0xFF, 0xE0])))
            #expect(got[ids[1]] == .some(nil) && got[ids[2]] == .some(nil))
        }
    }

    // MARK: Identity

    /// The node revokes this Mac: the session's refusal survives a reload, and the link fails closed.
    @Test func aRevokedKeyFailsClosed() async throws {
        try await withReplica { fixture in
            fixture.vault.add("/hello.txt", data: Data("hello".utf8))
            try await fixture.listRoot()
            fixture.daemon.revoke(fixture.device.spkiSHA256)
            await #expect {
                _ = try await fixture.listRoot()
            } throws: { error in
                guard case FinderError.notAuthenticated = error else { return false }
                return true
            }
            let reason = await fixture.link.closedReason
            #expect(reason.map { if case .notAuthenticated = $0 { true } else { false } } == true)
            // And stays closed, the lanes included.
            let hello = try await fixture.replica.item(.entry(try #require(fixture.vault.id("/hello.txt"))))
            await #expect {
                _ = try await fixture.replica.fetch(.entry(hello.entryID), into: fixture.scratch)
            } throws: { error in
                guard case FinderError.notAuthenticated = error else { return false }
                return true
            }
        }
    }

    @Test func anUnreachableNodeIsReportedSo() async throws {
        try await withReplica(onlineTimeout: .milliseconds(600)) { fixture in
            fixture.daemon.stop()
            await #expect {
                _ = try await fixture.listRoot()
            } throws: { error in
                guard case FinderError.serverUnreachable = error else { return false }
                return true
            }
            #expect(await fixture.link.closedReason == nil)
        }
    }
}
}
