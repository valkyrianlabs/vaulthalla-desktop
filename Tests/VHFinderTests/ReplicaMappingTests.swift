import FileProvider
import Foundation
import Testing
import VHContract
import VHCore
@testable import VHFinder
import VHNodes
import VHTransport

/// The replica's pure parts (vaulthalla/desktop#4): identifiers, items from the server's entries, versions,
/// capabilities, error mapping, conflict-copy names, anchors and pages.
@Suite struct ReplicaMappingTests {
    static func entry(_ id: Int64, _ path: String, type: String = "file", parent: Int64? = 1, size: Int64 = 12,
                      content: String? = "\"g9-0123456789abcdef\"", meta: String = "m9-fedcba9876543210",
                      target: String? = nil, updated: String = "2026-10-24T12:30:00Z") -> WsModel.FsEntry {
        WsModel.FsEntry(
            id: id, name: (path as NSString).lastPathComponent, path: path, absPath: "/mnt/v\(path)", sizeBytes: size,
            isHidden: path.hasPrefix("/."), isSystem: false, createdAt: "2026-10-01T08:00:00Z", updatedAt: updated,
            parentID: parent, vaultID: 3, metadataVersion: meta, contentVersion: type == "file" ? content : nil,
            type: type, fileCount: type == "directory" ? 2 : nil, target: target)
    }

    // MARK: Identifiers

    /// The raw values are the File Provider's own: the extension passes them through without translating.
    @Test func identifiersAreTheFileProvidersOwn() {
        #expect(FinderItemID.root.rawValue == NSFileProviderItemIdentifier.rootContainer.rawValue)
        #expect(FinderItemID.workingSet.rawValue == NSFileProviderItemIdentifier.workingSet.rawValue)
        #expect(FinderItemID.trash.rawValue == NSFileProviderItemIdentifier.trashContainer.rawValue)
        for id in [FinderItemID.root, .workingSet, .trash, .entry(0), .entry(42), .entry(Int64.max)] {
            #expect(FinderItemID(rawValue: id.rawValue) == id)
        }
        #expect(FinderItemID.entry(42).rawValue == "e42")
    }

    @Test(arguments: ["", "e", "42", "e-1", "e+1", "e042", "e4x", "x42", "e99999999999999999999", "E42"])
    func refusesIdentifiersItNeverHandsOut(_ raw: String) {
        #expect(FinderItemID(rawValue: raw) == nil)
    }

    @Test func capabilityBitsAreTheFileProvidersOwn() {
        #expect(FinderCapabilities.reading.rawValue == NSFileProviderItemCapabilities.allowsReading.rawValue)
        #expect(FinderCapabilities.writing.rawValue == NSFileProviderItemCapabilities.allowsWriting.rawValue)
        #expect(FinderCapabilities.reparenting.rawValue == NSFileProviderItemCapabilities.allowsReparenting.rawValue)
        #expect(FinderCapabilities.renaming.rawValue == NSFileProviderItemCapabilities.allowsRenaming.rawValue)
        #expect(FinderCapabilities.trashing.rawValue == NSFileProviderItemCapabilities.allowsTrashing.rawValue)
        #expect(FinderCapabilities.deleting.rawValue == NSFileProviderItemCapabilities.allowsDeleting.rawValue)
    }

    // MARK: Items

    @Test func filesCarryTheServersVersionsAndFields() throws {
        let item = FinderItem(entry: Self.entry(9, "/docs/a report.pdf", parent: 5), parent: 5)
        #expect(item.entryID == 9 && item.parentEntryID == 5 && item.name == "a report.pdf")
        #expect(item.path == "/docs/a report.pdf" && item.kind == .file && item.size == 12)
        #expect(item.identifier(root: 1) == .entry(9) && item.parentIdentifier(root: 1) == .entry(5))
        // content = the strong ETag exactly (quotes included), so it is usable as If-Match and If-Range.
        #expect(item.version.content == Data("\"g9-0123456789abcdef\"".utf8))
        #expect(item.version.metadata == Data("m9-fedcba9876543210".utf8))
        #expect(item.version.contentETag == "\"g9-0123456789abcdef\"")
        #expect(item.capabilities == [.reading, .writing, .renaming, .reparenting, .deleting])
        #expect(!item.capabilities.contains(.trashing))
        #expect(item.modified == (try Date("2026-10-24T12:30:00Z", strategy: .iso8601)))
        #expect(item.created == (try Date("2026-10-01T08:00:00Z", strategy: .iso8601)))
    }

    @Test func foldersAndSymlinksUseTheMetadataVersionForBoth() {
        let folder = FinderItem(entry: Self.entry(5, "/docs", type: "directory", size: 4096), parent: 1)
        #expect(folder.kind == .directory && folder.size == 0 && folder.contentVersion == nil)
        #expect(folder.version.content == folder.version.metadata)
        #expect(folder.version.contentETag == nil)
        #expect(folder.parentIdentifier(root: 1) == .root)
        let link = FinderItem(entry: Self.entry(6, "/latest", type: "symlink", target: "docs/a.pdf"), parent: 1)
        #expect(link.kind == .symlink && link.symlinkTarget == "docs/a.pdf" && link.contentVersion == nil)
        #expect(!link.capabilities.contains(.writing))
        // A type a newer daemon adds is a file unless it carries folder counts.
        #expect(FinderItem(entry: Self.entry(7, "/x", type: "socket"), parent: 1).kind == .file)
    }

    @Test func theRootIsTheContainer() {
        let base = WsModel.FsEntryBase(id: 1, name: "Vault", path: "/", absPath: "/mnt/v", sizeBytes: 0, isHidden: false,
                                       isSystem: false, createdAt: "", updatedAt: "", metadataVersion: "m1-0")
        let root = FinderItem(base: base, known: .directory)
        #expect(root.isRoot && root.identifier(root: 1) == .root && root.parentIdentifier(root: 1) == .root)
        #expect(root.capabilities == [.reading, .writing])
        // A base entry with a content version is a file.
        let file = WsModel.FsEntryBase(id: 2, name: "a", path: "/a", absPath: "/mnt/v/a", sizeBytes: 3, isHidden: false,
                                       isSystem: false, createdAt: "", updatedAt: "", parentID: 1,
                                       metadataVersion: "m2-0", contentVersion: "\"g2-0\"")
        #expect(FinderItem(base: file).kind == .file)
    }

    // MARK: Errors

    @Test func mapsWsRefusals() {
        #expect(FinderError(WsError.denied("no"), during: .read) == .readNotPermitted("no"))
        #expect(FinderError(WsError.denied("no"), during: .write) == .cannotSynchronize("no"))
        #expect(FinderError(WsError.denied("no"), during: .delete) == .deletionRejected("no"))
        #expect(FinderError(WsError.notFound("gone"), during: .read) == .noSuchItem)
        #expect(FinderError(WsError.conflict("exists"), during: .write) == .filenameCollision)
        #expect(FinderError(WsError.invalid("bad name"), during: .write) == .cannotSynchronize("bad name"))
        #expect(FinderError(WsError.unauthorized("no session"), during: .read) == .notAuthenticated("no session"))
        #expect(FinderError(WsError.needsConfirmation(code: "device_unknown", message: "Unknown device."),
                            during: .read) == .notAuthenticated("Unknown device."))
        #expect(FinderError(WsError.needsConfirmation(code: "destructive", message: "Sure?"), during: .delete)
            == .cannotSynchronize("Sure?"))
        #expect(FinderError(WsError.disconnected, during: .read) == .serverUnreachable(WsError.disconnected.message))
        #expect(FinderError(WsError.timeout, during: .write) == .serverUnreachable(WsError.timeout.message))
        #expect(FinderError(WsError.cancelled, during: .read) == .cancelled)
        #expect(FinderError(WsError.error("boom"), during: .read) == .transient("boom"))
    }

    @Test func mapsLaneFailures() {
        #expect(FinderError(TransferError.forbidden, during: .read) == .readNotPermitted(TransferError.forbidden.message))
        #expect(FinderError(TransferError.forbidden, during: .write) == .cannotSynchronize(TransferError.forbidden.message))
        #expect(FinderError(TransferError.notFound, during: .read) == .noSuchItem)
        #expect(FinderError(TransferError.alreadyExists, during: .write) == .filenameCollision)
        #expect(FinderError(TransferError.quotaExceeded, during: .write) == .insufficientQuota)
        #expect(FinderError(TransferError.busy, during: .read) == .serverUnreachable(TransferError.busy.message))
        #expect(FinderError(TransferError.connection("reset"), during: .write)
            == .serverUnreachable(TransferError.connection("reset").message))
        #expect(FinderError(TransferError.pinMismatch, during: .read) == .notAuthenticated(TransferError.pinMismatch.message))
        #expect(FinderError(TransferError.status(503, ""), during: .read) == .transient(TransferError.status(503, "").message))
        #expect(FinderError(TransferError.status(428, "precondition"), during: .write) == .cannotSynchronize("precondition"))
        #expect(FinderError(TransferError.status(416, ""), during: .read) == .versionNoLongerAvailable)
        #expect(FinderError(TransferError.cancelled, during: .read) == .cancelled)
    }

    @Test func credentialFailuresFailClosed() {
        for failure in [CredentialFailure.revoked, .notPaired, .missingKey, .unknownNode(NodeID(rawValue: "n")),
                        .keychain("x"), .registry("y")] {
            #expect(FinderError(failure) == .notAuthenticated(failure.description))
        }
        #expect(FinderError.from(CredentialFailure.revoked, during: .read) == .notAuthenticated(CredentialFailure.revoked.description))
        #expect(FinderError.from(CancellationError(), during: .read) == .cancelled)
    }

    @Test func posixCodes() {
        #expect(FinderError.noSuchItem.posixCode == ENOENT)
        #expect(FinderError.filenameCollision.posixCode == EEXIST)
        #expect(FinderError.readNotPermitted("").posixCode == EACCES)
        #expect(FinderError.insufficientQuota.posixCode == ENOSPC)
        #expect(FinderError.versionNoLongerAvailable.posixCode == ESTALE)
        #expect(FinderError.directoryNotEmpty.posixCode == ENOTEMPTY)
    }

    // MARK: Conflict copies

    private static let utc = TimeZone(identifier: "UTC")!
    private static let moment = Date(timeIntervalSince1970: 1_792_850_400)  // 2026-10-24 14:00 UTC

    @Test func namesConflictCopies() {
        #expect(ConflictName.stamp(Self.moment, timeZone: Self.utc) == "2026-10-24 1400")
        #expect(ConflictName.make(for: "hello.txt", macName: "Cooper's Mac Studio", date: Self.moment, timeZone: Self.utc)
            == "hello (conflict from Cooper's Mac Studio 2026-10-24 1400).txt")
        #expect(ConflictName.make(for: "archive.tar.gz", macName: "Mac", date: Self.moment, timeZone: Self.utc)
            == "archive.tar (conflict from Mac 2026-10-24 1400).gz")
        #expect(ConflictName.make(for: "Makefile", macName: "Mac", date: Self.moment, timeZone: Self.utc)
            == "Makefile (conflict from Mac 2026-10-24 1400)")
        #expect(ConflictName.make(for: ".env", macName: "Mac", date: Self.moment, timeZone: Self.utc)
            == ".env (conflict from Mac 2026-10-24 1400)")
        #expect(ConflictName.make(for: "notes.", macName: "Mac", date: Self.moment, timeZone: Self.utc)
            == "notes. (conflict from Mac 2026-10-24 1400)")
        #expect(ConflictName.make(for: "hello.txt", macName: "Mac", date: Self.moment, timeZone: Self.utc, attempt: 3)
            == "hello (conflict from Mac 2026-10-24 1400) 3.txt")
        // The Mac's name can't smuggle a path in.
        #expect(ConflictName.make(for: "a.txt", macName: "evil/../:name\n", date: Self.moment, timeZone: Self.utc)
            == "a (conflict from evil-..--name 2026-10-24 1400).txt")
        #expect(ConflictName.make(for: "a.txt", macName: "  ", date: Self.moment, timeZone: Self.utc)
            == "a (conflict from Mac 2026-10-24 1400).txt")
        #expect(ConflictName.isConflictCopy("a (conflict from Mac 2026-10-24 1400).txt"))
    }

    @Test func conflictNamesStayWithinTheServersLimit() {
        let long = String(repeating: "é", count: 200) + ".numbers"
        let name = ConflictName.make(for: long, macName: "Mac", date: Self.moment, timeZone: Self.utc)
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(" (conflict from Mac 2026-10-24 1400).numbers"))
        #expect(VaultPath.problem(withName: name) == nil)
    }

    // MARK: Anchors and pages

    @Test func anchorsRoundTripAndStaySmall() throws {
        let anchor = SyncAnchor(storeID: UUID().uuidString.lowercased(), revision: 123_456_789)
        #expect(SyncAnchor(data: anchor.data) == anchor)
        #expect(anchor.data.count <= 500)
        #expect(SyncAnchor(storeID: "s", revision: Int64.max).data.count <= 500)
        for garbage in ["", "vh1:a:", "vh1:a:store", "vh1:a:store:-1", "vh1:a::4", "vh1:p:4", "anchor", "vh1:a:a:b:4"] {
            #expect(SyncAnchor(data: Data(garbage.utf8)) == nil, "\(garbage)")
        }
        #expect(SyncAnchor(data: Data(repeating: 0x41, count: 600)) == nil)
    }

    @Test func pagesRoundTripAndTheSystemsInitialPagesAreTheStart() {
        let page = EnumerationPage(offset: 400)
        #expect(EnumerationPage(data: page.data) == page)
        #expect(page.data.count <= 500)
        #expect(EnumerationPage(data: NSFileProviderPage.initialPageSortedByName as Data).isFirst)
        #expect(EnumerationPage(data: NSFileProviderPage.initialPageSortedByDate as Data).isFirst)
        #expect(EnumerationPage(data: Data("vh1:p:-3".utf8)).isFirst)
    }

    @Test func alignsRanges() {
        #expect(VaultReplica.aligned(20_971_520..<22_020_096, to: 16384, size: 50_331_648) == 20_971_520..<22_020_096)
        #expect(VaultReplica.aligned(100..<200, to: 4096, size: 1_000_000) == 0..<4096)
        #expect(VaultReplica.aligned(5000..<9000, to: 4096, size: 1_000_000) == 4096..<12288)
        // The end of the file isn't a multiple of the alignment.
        #expect(VaultReplica.aligned(65000..<65537, to: 16384, size: 65537) == 49152..<65537)
        #expect(VaultReplica.aligned(0..<65537, to: 16384, size: 65536) == 0..<65536)
        // An empty minimal range still asks for one aligned block.
        #expect(VaultReplica.aligned(4096..<4096, to: 4096, size: 100_000) == 4096..<8192)
    }
}
