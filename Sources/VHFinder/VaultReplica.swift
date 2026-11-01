public import Foundation
import VHContract
import VHNodes
import VHTransport
import os

/// One vault's File Provider replica (vaulthalla/desktop#4): everything the extension does, without the FileProvider
/// framework, so `swift test` covers it against the mock daemon and the lanes test server.
///
/// It maps and caches; the server decides. Listings come from `fs.dir.list` (filtered by the server to what the
/// account may Lookup, vaulthalla/server#255), bytes from `/download/content`, writes go to `PUT /upload/content`
/// (create with `If-None-Match: *`, replace with `If-Match`, vaulthalla/server#258) or, on a node with
/// `http.upload.resumable`, for files over 8 MiB, a single-file resumable session carrying the same precondition
/// (``VaultLanes/putContent(vaultID:path:from:precondition:mimeType:progress:)``), and the `fs.*` commands, which the
/// server authorizes (move and rename into another folder included, vaulthalla/server#256). Nothing here decides
/// whether an account may do something: refusals are mapped (``FinderError``).
///
/// **Changes without a journal.** The server has no change feed yet (vaulthalla/server#259). Every folder the system
/// enumerated is listed again when the system asks for changes, and the listings are diffed against the
/// ``ReplicaStore``, whose revisions make the sync anchor.
///
/// **Conflicts.** A content write is conditional on the version the system based the edit on. When the server's file
/// changed since (412, or the version check before the upload), the local edit is uploaded as a conflict copy next to
/// it (``ConflictName``, created with `If-None-Match: *`) and the server's version stays the item; with the system's
/// fail-on-conflict option the system is told instead. A competing edit is never overwritten.
public actor VaultReplica {
    public let vaultID: Int64
    private let link: any ReplicaLink
    private let store: ReplicaStore
    private var pins: PinStore
    private let macName: String
    private let now: @Sendable () -> Date
    private var lastRefresh: ContinuousClock.Instant?
    private let log = Logger(subsystem: "sh.vaulthalla.app", category: "fileprovider-replica")

    /// How long a refresh of the listed folders counts as current for the next request for changes.
    public static let refreshInterval: Duration = .seconds(1)

    /// `storeURL`: the replica database (nil: in memory). `macName` names conflict copies.
    public init(vaultID: Int64, link: any ReplicaLink, storeURL: URL?, macName: String,
                now: @escaping @Sendable () -> Date = { Date() }) throws(FinderError) {
        self.vaultID = vaultID
        self.link = link
        self.macName = macName
        self.now = now
        do {
            store = try ReplicaStore(url: storeURL)
        } catch {
            throw .transient(error.description)
        }
        pins = PinStore(url: storeURL.map(PinStore.url(forStore:)))
    }

    public func close() async {
        await link.close()
    }

    // MARK: - Items

    public var rootEntryID: Int64? { store.rootEntryID }

    /// Entries kept downloaded (``PinStore``).
    public var pinnedEntries: Set<Int64> { pins.entries }

    /// Keeps `ids` downloaded, or lets the system remove their downloads again (Finder's Keep Downloaded, desktop#35).
    /// The changed items take a revision, so the system reads their new content policy with the next changes.
    public func keepDownloaded(_ ids: [FinderItemID], _ keep: Bool) throws(FinderError) {
        let entries = ids.compactMap { id -> Int64? in
            switch id {
            case .entry(let entryID): entryID
            case .root: store.rootEntryID
            case .workingSet, .trash: nil
            }
        }
        let changed: [Int64]
        do {
            changed = try pins.set(entries, pinned: keep)
        } catch {
            throw .transient("Couldn't save what to keep downloaded (\(error.localizedDescription)).")
        }
        do {
            try store.touch(changed)
        } catch {
            throw .transient(error.description)
        }
    }

    /// The item `id` names, from the replica (the root is listed first when the replica has none yet).
    public func item(_ id: FinderItemID) async throws(FinderError) -> FinderItem {
        switch id {
        case .root: return try await root()
        case .entry(let entryID):
            if let item = try stored(entryID) { return item }
            throw .noSuchItem
        case .workingSet, .trash: throw .noSuchItem
        }
    }

    private func root() async throws(FinderError) -> FinderItem {
        if let root = try storeCall({ () throws(ReplicaStore.Failure) in try store.rootItem() }) { return root }
        return try await refresh(path: "/", folderID: nil).folder
    }

    private func stored(_ entryID: Int64) throws(FinderError) -> FinderItem? {
        try storeCall { () throws(ReplicaStore.Failure) in try store.item(entryID) }
    }

    /// The folder `id` names (the root, or a directory entry).
    private func folder(_ id: FinderItemID) async throws(FinderError) -> FinderItem {
        let item = try await item(id)
        guard item.kind == .directory else { throw .cannotSynchronize("\(item.name) isn't a folder.") }
        return item
    }

    // MARK: - Enumeration

    /// One page of a folder's children by name. The first page lists the folder on the server, records it as
    /// enumerated (part of the working set from now on), and answers from that listing; later pages come from the
    /// replica. `next` is nil after the last page.
    public func list(_ container: FinderItemID, page: EnumerationPage, pageSize: Int) async throws(FinderError)
        -> (items: [FinderItem], next: EnumerationPage?)
    {
        let children: [FinderItem]
        if page.isFirst, container == .root {
            children = try await refresh(path: "/", folderID: nil).children
        } else {
            let folder = try await folder(container)
            if page.isFirst {
                children = try await refresh(path: folder.path, folderID: folder.entryID).children
            } else {
                children = try storeCall { () throws(ReplicaStore.Failure) in try store.children(of: folder.entryID) }
            }
        }
        let size = max(1, pageSize)
        let slice = Array(children.dropFirst(page.offset).prefix(size))
        let next = page.offset + slice.count < children.count ? EnumerationPage(offset: page.offset + slice.count) : nil
        return (slice, next)
    }

    /// One page of the working set: everything the replica knows, by entry id.
    public func workingSet(page: EnumerationPage, pageSize: Int) throws(FinderError)
        -> (items: [FinderItem], next: EnumerationPage?)
    {
        let size = max(1, pageSize)
        let items = try storeCall { () throws(ReplicaStore.Failure) in
            try store.workingSet(offset: page.offset, limit: size + 1)
        }
        let slice = Array(items.prefix(size))
        return (slice, items.count > size ? EnumerationPage(offset: page.offset + slice.count) : nil)
    }

    public var currentAnchor: SyncAnchor { store.currentAnchor }

    /// What changed after `anchor`: the enumerated folders are listed again (at most once per
    /// ``refreshInterval``) and diffed against the replica. A folder that is gone, or no longer listable by this
    /// account, goes with what it held: lost visibility arrives as deletions.
    public struct Changes: Hashable, Sendable {
        public var updated: [FinderItem]
        public var deleted: [FinderItemID]
        public var anchor: SyncAnchor
        public var moreComing: Bool
    }

    public func changes(since anchor: SyncAnchor, limit: Int = 200) async throws(FinderError) -> Changes {
        guard store.accepts(anchor) else { throw .syncAnchorExpired }
        if lastRefresh.map({ ContinuousClock.now - $0 >= Self.refreshInterval }) ?? true {
            try await refreshListedFolders()
        }
        let batch = try storeCall { () throws(ReplicaStore.Failure) in
            try store.changes(after: anchor.revision, limit: max(1, limit))
        }
        let root = store.rootEntryID
        return Changes(
            updated: batch.updated,
            deleted: batch.deleted.filter { $0 != root }.map(FinderItemID.entry),
            anchor: SyncAnchor(storeID: store.storeID, revision: batch.last), moreComing: batch.more)
    }

    /// Lists every enumerated folder again, the root first and parents before children, each by its path as the
    /// replica has it at that moment (a parent's listing may just have moved it).
    public func refreshListedFolders() async throws(FinderError) {
        let folders = try storeCall { () throws(ReplicaStore.Failure) in try store.listedFolders() }
        for listed in folders {
            guard let current = try stored(listed.entryID) else { continue }  // gone with a parent
            do throws(FinderError) {
                _ = try await refresh(path: current.path, folderID: current.entryID)
            } catch .noSuchItem, .readNotPermitted {
                try storeCall { () throws(ReplicaStore.Failure) in _ = try store.remove(current.entryID) }
            }
        }
        try storeCall { () throws(ReplicaStore.Failure) in try store.pruneTombstones() }
        lastRefresh = .now
    }

    /// Lists `path` on the server and records it. `folderID` is the folder the caller means (nil for the root): when
    /// the path now names another entry (the folder was moved away and something else took its name), the folder is
    /// treated as gone.
    @discardableResult
    private func refresh(path: String, folderID: Int64?) async throws(FinderError)
        -> (folder: FinderItem, children: [FinderItem])
    {
        let listing = try await link.send(Ws.Fs.Dir.List.self, payload: .init(vaultID: vaultID, path: path),
                                          during: .read)
        var folder = FinderItem(base: listing.entry, known: .directory)
        if path == "/" { folder.parentEntryID = nil }
        if let folderID, folder.entryID != folderID { throw .noSuchItem }
        let children = listing.files.map { FinderItem(entry: $0, parent: folder.entryID) }
        try storeCall { () throws(ReplicaStore.Failure) in _ = try store.applyListing(of: folder, children: children) }
        return (folder, try storeCall { () throws(ReplicaStore.Failure) in try store.children(of: folder.entryID) })
    }

    /// One entry as the server has it now (`fs.metadata`), recorded.
    @discardableResult
    private func lookUp(_ path: String, known kind: FinderItemKind?) async throws(FinderError) -> FinderItem {
        let answer = try await link.send(Ws.Fs.Metadata.self, payload: .init(vaultID: vaultID, path: path),
                                         during: .read)
        var item = FinderItem(base: answer.entry, known: kind)
        if let existing = try stored(item.entryID) {
            if item.symlinkTarget == nil { item.symlinkTarget = existing.symlinkTarget }
            if kind == nil { item.kind = existing.kind }
        }
        try record(item)
        return item
    }

    private func record(_ item: FinderItem) throws(FinderError) {
        try storeCall { () throws(ReplicaStore.Failure) in _ = try store.upsert(item) }
    }

    // MARK: - Contents

    /// Downloads the whole file into a new file in `directory` (on the replica's volume, so the system can clone it).
    /// Returns it and the item at the version of those bytes.
    public func fetch(_ id: FinderItemID, into directory: URL) async throws(FinderError) -> (url: URL, item: FinderItem) {
        var item = try await item(id)
        guard item.kind == .file else { throw .cannotSynchronize("\(item.name) has no contents to download.") }
        let destination = directory.appending(path: "vh-\(UUID().uuidString).download", directoryHint: .notDirectory)
        let (vaultID, path) = (vaultID, item.path)
        let done = try await link.withLanes(during: .read) { (lanes: VaultLanes) async throws(TransferError) in
            try await lanes.downloadContent(vaultID: vaultID, path: path, to: destination)
        }
        if let etag = done.etag, etag != item.contentVersion {
            // The file changed since it was listed: report the version these bytes are.
            item = (try? await lookUp(path, known: .file)) ?? item
            if item.contentVersion != etag {
                item.contentVersion = etag
                item.size = done.length
            }
        }
        return (destination, item)
    }

    /// The outcome of a ranged fetch.
    public struct PartialFetch: Sendable {
        public var url: URL
        public var item: FinderItem
        /// The bytes written to `url`, at these offsets.
        public var range: Range<Int64>
    }

    /// Downloads at least `minimal` of the file, aligned to `alignment`, into a new sparse file in `directory` at the
    /// same offsets, only while the file is `version` (`If-Range` with its content version). A changed file is
    /// `.versionNoLongerAvailable` when `strict`; otherwise the whole new version is fetched.
    public func fetchRange(_ id: FinderItemID, version: FinderItemVersion, minimal: Range<Int64>, alignment: Int64,
                           strict: Bool, into directory: URL) async throws(FinderError) -> PartialFetch {
        var item = try await item(id)
        guard item.kind == .file else { throw .cannotSynchronize("\(item.name) has no contents to download.") }
        let destination = directory.appending(path: "vh-\(UUID().uuidString).partial", directoryHint: .notDirectory)
        let base = version.contentETag ?? item.contentVersion
        if item.size == 0 || minimal.lowerBound >= item.size {
            guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil,
                                                 attributes: [.posixPermissions: 0o600])
            else { throw .transient("The download file couldn't be created.") }
            if strict, let base, base != item.contentVersion { throw .versionNoLongerAvailable }
            return PartialFetch(url: destination, item: item, range: 0..<0)
        }
        let bounds = Self.aligned(minimal, to: alignment, size: item.size)
        let (vaultID, path) = (vaultID, item.path)
        let answer = try await link.withLanes(during: .read) { (lanes: VaultLanes) async throws(TransferError) in
            try await lanes.downloadRange(vaultID: vaultID, path: path, range: bounds.lowerBound...(bounds.upperBound - 1),
                                          contentVersion: base, into: destination, acceptWhole: !strict)
        }
        switch answer {
        case .partial(let offset, let length, _, _):
            if let base, base != item.contentVersion { item.contentVersion = base }
            return PartialFetch(url: destination, item: item, range: offset..<(offset + length))
        case .whole(let length, let etag):
            item = (try? await lookUp(path, known: .file)) ?? item
            if let etag, item.contentVersion != etag { item.contentVersion = etag }
            item.size = length
            return PartialFetch(url: destination, item: item, range: 0..<length)
        case .changed, .unsatisfiable:
            try? FileManager.default.removeItem(at: destination)
            _ = try? await lookUp(path, known: .file)
            throw .versionNoLongerAvailable
        }
    }

    /// `range` widened to multiples of `alignment` (a power of two the system picks), the end capped at `size`.
    public static func aligned(_ range: Range<Int64>, to alignment: Int64, size: Int64) -> Range<Int64> {
        let step = max(1, alignment)
        let start = (range.lowerBound / step) * step
        let wanted = max(range.upperBound, range.lowerBound + 1)
        let end = min(size, ((wanted + step - 1) / step) * step)
        return start..<max(end, min(size, start + 1))
    }

    // MARK: - Creating

    /// What the system asks to create.
    public struct Template: Sendable {
        public var name: String
        public var parent: FinderItemID
        public var kind: FinderItemKind

        public init(name: String, parent: FinderItemID, kind: FinderItemKind) {
            self.name = name
            self.parent = parent
            self.kind = kind
        }
    }

    /// Names the replica never sends to the server: Finder's per-folder view settings.
    public static func isExcluded(name: String) -> Bool {
        name == ".DS_Store"
    }

    /// Creates `template` on the server: a folder with `fs.dir.create`, a file with `PUT /upload/content` and
    /// `If-None-Match: *` (`contents`, or empty). Symlinks aren't created through Finder (the lanes take files and
    /// folders): they stay local, excluded from sync. With `mayAlreadyExist`, an existing folder of that name is the
    /// answer; anything else already there is a collision, which the system resolves by renaming the local item.
    public func create(_ template: Template, contents: URL?, mayAlreadyExist: Bool = false) async throws(FinderError)
        -> FinderItem
    {
        if let problem = VaultPath.problem(withName: template.name) { throw .cannotSynchronize(problem) }
        if Self.isExcluded(name: template.name) || template.kind == .symlink { throw .excludedFromSync }
        let parent = try await folder(template.parent)
        let path = FinderItem.join(parent.path, template.name)
        switch template.kind {
        case .directory:
            do throws(FinderError) {
                _ = try await link.send(Ws.Fs.Dir.Create.self, payload: .init(vaultID: vaultID, path: path),
                                        during: .write)
            } catch .filenameCollision where mayAlreadyExist {
                // Fall through: the folder that is there is the one asked for, if it is a folder.
            }
            let made = try await lookUp(path, known: nil)
            guard made.kind == .directory else { throw .filenameCollision }
            return made
        case .file, .symlink:
            let (source, cleanup) = try Self.source(contents)
            defer { cleanup() }
            let written = try await put(source, at: path, precondition: .create)
            guard case .committed(let entry) = written else { throw .filenameCollision }
            return try await committed(entry, path: path)
        }
    }

    /// The file to send: `contents`, or an empty one made for the occasion.
    private static func source(_ contents: URL?) throws(FinderError) -> (URL, () -> Void) {
        if let contents { return (contents, {}) }
        let empty = FileManager.default.temporaryDirectory.appending(path: "vh-empty-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: empty.path(percentEncoded: false), contents: Data()) else {
            throw .transient("An empty file couldn't be made to upload.")
        }
        return (empty, { try? FileManager.default.removeItem(at: empty) })
    }

    private enum Written {
        case committed(WsModel.FsEntryBase?)
        case conflict
    }

    private func put(_ source: URL, at path: String, precondition: VaultLanes.ContentPrecondition)
        async throws(FinderError) -> Written
    {
        let vaultID = vaultID
        let answer = try await link.withLanes(during: .write) { (lanes: VaultLanes) async throws(TransferError) in
            try await lanes.putContent(vaultID: vaultID, path: path, from: source, precondition: precondition)
        }
        switch answer {
        case .committed(_, let entry, _): return .committed(entry)
        case .conflict: return .conflict
        }
    }

    /// The item a committed write produced: the answer's entry, else the server's lookup.
    private func committed(_ entry: WsModel.FsEntryBase?, path: String) async throws(FinderError) -> FinderItem {
        if let entry {
            let item = FinderItem(base: entry, known: .file)
            try record(item)
            return item
        }
        return try await lookUp(path, known: .file)
    }

    // MARK: - Modifying

    /// What changed locally.
    public struct Changeset: Sendable {
        public var name: String?
        public var parent: FinderItemID?
        /// The complete new contents.
        public var contents: URL?

        public init(name: String? = nil, parent: FinderItemID? = nil, contents: URL? = nil) {
            self.name = name
            self.parent = parent
            self.contents = contents
        }
    }

    public struct Modified: Sendable {
        /// The item as the server has it now.
        public var item: FinderItem
        /// The system should download the item's contents again: the server's version won over a conflicting edit.
        public var fetchContents: Bool
        /// Where the conflicting local edit went.
        public var conflictCopy: FinderItem?
    }

    /// Applies `changes` to the item: the name and folder first (`fs.entry.rename`, or `fs.entry.move` into another
    /// folder), then the contents, conditional on `base` (the version the system based the edit on). See the type's
    /// notes on conflicts. `failOnConflict`: the system's fail-on-conflict flow (it merges and asks again).
    public func modify(_ id: FinderItemID, base: FinderItemVersion, changes: Changeset, failOnConflict: Bool = false)
        async throws(FinderError) -> Modified
    {
        guard case .entry = id else {
            // The root's own metadata isn't the server's to change.
            return Modified(item: try await item(id), fetchContents: false, conflictCopy: nil)
        }
        var item = try await item(id)
        var newParent: FinderItem?
        if let parent = changes.parent { newParent = try await folder(parent) }
        let newName = changes.name ?? item.name
        if newName != item.name || (newParent.map { $0.entryID != item.parentEntryID } ?? false) {
            item = try await relocate(item, name: newName, into: newParent)
        }
        guard let contents = changes.contents, item.kind == .file else {
            return Modified(item: item, fetchContents: false, conflictCopy: nil)
        }
        let baseVersion = base.contentETag ?? item.contentVersion ?? ""
        // The server's version first: an edit based on an older one never uploads over it.
        let current = try await lookUp(item.path, known: .file)
        guard current.contentVersion == baseVersion else {
            return try await conflict(contents, with: current, failOnConflict: failOnConflict)
        }
        let written: Written
        do throws(FinderError) {
            written = try await put(contents, at: item.path, precondition: .replace(contentVersion: baseVersion))
        } catch .serverUnreachable(let why) {
            // The answer may be lost after the node took the bytes, or the node refused before reading the body and
            // closed the connection. If the version moved, something was written: keep the edit as a copy.
            guard let after = try? await lookUp(item.path, known: .file), after.contentVersion != baseVersion else {
                throw .serverUnreachable(why)
            }
            return try await conflict(contents, with: after, failOnConflict: failOnConflict)
        }
        switch written {
        case .committed(let entry):
            return Modified(item: try await committed(entry, path: item.path), fetchContents: false, conflictCopy: nil)
        case .conflict:
            let server = try await lookUp(item.path, known: .file)
            return try await conflict(contents, with: server, failOnConflict: failOnConflict)
        }
    }

    /// The server's version of `server` stays; the local edit becomes a conflict copy beside it.
    private func conflict(_ contents: URL, with server: FinderItem, failOnConflict: Bool) async throws(FinderError)
        -> Modified
    {
        if failOnConflict { throw .localVersionConflictingWithServer }
        let folder = VaultPath(normalizing: server.path).parent.rawValue
        let stamp = now()
        for attempt in 1...20 {
            let name = ConflictName.make(for: server.name, macName: macName, date: stamp, attempt: attempt)
            let path = FinderItem.join(folder, name)
            let written: Written
            do throws(FinderError) {
                written = try await put(contents, at: path, precondition: .create)
            } catch .filenameCollision {
                continue  // a folder of that name
            }
            guard case .committed(let entry) = written else { continue }
            let copy = try await committed(entry, path: path)
            log.notice("conflict: kept the local edit of entry \(server.entryID, privacy: .public) as a copy")
            return Modified(item: server, fetchContents: true, conflictCopy: copy)
        }
        throw .cannotSynchronize("No free name for the conflict copy of \(server.name).")
    }

    /// Renames or moves `item` on the server and records where it went (paths below a moved folder included).
    private func relocate(_ item: FinderItem, name: String, into newParent: FinderItem?) async throws(FinderError)
        -> FinderItem
    {
        if let problem = VaultPath.problem(withName: name) { throw .cannotSynchronize(problem) }
        let parentPath = newParent?.path ?? VaultPath(normalizing: item.path).parent.rawValue
        let destination = FinderItem.join(parentPath, name)
        let moving = newParent.map { $0.entryID != item.parentEntryID } ?? false
        if moving {
            _ = try await link.send(Ws.Fs.Entry.Move.self,
                                    payload: .init(vaultID: vaultID, from: item.path, to: destination), during: .write)
        } else {
            _ = try await link.send(Ws.Fs.Entry.Rename.self,
                                    payload: .init(vaultID: vaultID, from: item.path, to: destination), during: .write)
        }
        let moved = try await lookUp(destination, known: item.kind)
        if item.kind == .directory {
            try storeCall { () throws(ReplicaStore.Failure) in
                try store.rewritePaths(under: moved.entryID, from: item.path, to: moved.path)
            }
        }
        return moved
    }

    // MARK: - Deleting

    /// Deletes the item on the server (`fs.entry.delete`: into the server's trash, recoverable through `recovery.*`).
    /// A file whose content changed on the server since `base` isn't deleted (the system brings the new version back);
    /// a folder with children only when `recursive`. An item already gone is a success.
    public func delete(_ id: FinderItemID, base: FinderItemVersion, recursive: Bool) async throws(FinderError) {
        guard case .entry(let entryID) = id else { throw .deletionRejected("The vault's root can't be deleted.") }
        guard let item = try stored(entryID) else { return }
        do throws(FinderError) {
            let current = try await lookUp(item.path, known: item.kind)
            guard current.entryID == item.entryID else {
                try storeCall { () throws(ReplicaStore.Failure) in _ = try store.remove(entryID) }
                return  // the path holds something else now: the item itself is gone
            }
            if item.kind == .file, let baseVersion = base.contentETag, current.contentVersion != baseVersion {
                throw .deletionRejected("\(item.name) changed on the server.")
            }
            if item.kind == .directory, !recursive {
                let listing = try await link.send(Ws.Fs.Dir.List.self, payload: .init(vaultID: vaultID, path: item.path),
                                                  during: .read)
                if !listing.files.isEmpty { throw .directoryNotEmpty }
            }
            _ = try await link.send(Ws.Fs.Entry.Delete.self, payload: .init(vaultID: vaultID, path: item.path),
                                    during: .delete)
        } catch .noSuchItem {
            // Already gone.
        }
        try storeCall { () throws(ReplicaStore.Failure) in _ = try store.remove(entryID) }
    }

    // MARK: - Thumbnails

    /// Thumbnails of the files among `ids` that the server has one for, `size` px on the long side: one call of
    /// `each` per id, with nil data when there is none (a folder, an unsupported type, one still rendering).
    public func thumbnails(for ids: [FinderItemID], size: Int,
                           each: @Sendable (FinderItemID, Data?, FinderError?) -> Void) async {
        var files: [(id: FinderItemID, item: FinderItem)] = []
        for id in ids {
            if case .entry(let entryID) = id, let item = try? stored(entryID), item.kind == .file {
                files.append((id, item))
            } else {
                each(id, nil, nil)
            }
        }
        let vaultID = vaultID
        for batch in stride(from: 0, to: files.count, by: 200).map({ Array(files[$0..<min($0 + 200, files.count)]) }) {
            let keys = batch.map { VaultLanes.ThumbnailItem(key: $0.id.rawValue, path: $0.item.path) }
            let statuses: [String: VaultLanes.ThumbnailStatus]
            do throws(FinderError) {
                statuses = try await link.withLanes(during: .read) { (lanes: VaultLanes) async throws(TransferError) in
                    try await lanes.thumbnailStatus(vaultID: vaultID, items: keys, size: size)
                }
            } catch {
                for file in batch { each(file.id, nil, error) }
                continue
            }
            for file in batch {
                guard statuses[file.id.rawValue] == .ready else {
                    each(file.id, nil, nil)
                    continue
                }
                let path = file.item.path
                do throws(FinderError) {
                    let data = try await link.withLanes(during: .read) { (lanes: VaultLanes) async throws(TransferError) in
                        try await lanes.thumbnail(vaultID: vaultID, path: path, size: size)
                    }
                    each(file.id, data, nil)
                } catch {
                    each(file.id, nil, error)
                }
            }
        }
    }

    // MARK: - Plumbing

    private func storeCall<T>(_ body: () throws(ReplicaStore.Failure) -> T) throws(FinderError) -> T {
        do {
            return try body()
        } catch {
            log.error("\(error.description, privacy: .public)")
            throw .transient(error.description)
        }
    }
}
