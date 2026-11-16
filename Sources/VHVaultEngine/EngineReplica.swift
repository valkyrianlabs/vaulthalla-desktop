public import Foundation
public import VHFinder
import CryptoKit
import OSLog

/// What the engine-backed replica needs from whoever holds the vault open: the handle, and to hear of local changes
/// (``DesktopVaultSession`` publishes them shortly after) and of writes that met another edit.
public protocol EngineHost: Sendable {
    func openedVault() async -> Vault?
    func noteChange() async
    func noteWriteConflict() async
    /// Why there is no vault to serve, in words (nil: not known, or not yet).
    func unavailableReason() async -> String?
    /// The replica is closing (the extension was invalidated).
    func replicaClosing() async
}

extension EngineHost {
    public func unavailableReason() async -> String? { nil }
    public func replicaClosing() async {}
}


/// The File Provider identifiers of a vault's entries: the system's item ids are `e<Int64>`, the engine's are 128-bit
/// uids, so each uid gets the next number the first time it is seen, kept in `desktop-<uid>.ids` beside the state
/// (a uid keeps its number across rename, move and a re-anchor). Not a hash: no two uids can share a number.
final class EntryNumbers: @unchecked Sendable {
    private struct File: Codable {
        var next: Int64
        var numbers: [String: Int64]
    }

    private let url: URL?
    private let lock = NSLock()
    private var file: File
    private var uids: [Int64: String]

    init(url: URL?) {
        self.url = url
        let loaded = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(File.self, from: $0) }
        file = loaded ?? File(next: 2, numbers: [:])
        uids = Dictionary(file.numbers.map { ($1, $0) }) { a, _ in a }
    }

    func number(_ uid: String) -> Int64 {
        lock.withLock {
            if let n = file.numbers[uid] { return n }
            let n = file.next
            file.next += 1
            file.numbers[uid] = n
            uids[n] = uid
            if let url, let data = try? JSONEncoder().encode(file) { try? data.write(to: url, options: [.atomic]) }
            return n
        }
    }

    func existing(_ uid: String) -> Int64? { lock.withLock { file.numbers[uid] } }
    func uid(_ number: Int64) -> String? { lock.withLock { uids[number] } }
}

/// A Desktop-only vault's File Provider replica over vl-vaultfmt's engine (behind ``FinderReplica``, as ``VaultReplica``
/// is for server vaults): enumeration from the working content, sync anchors from the engine's change log
/// (`vault_changes`: an anchor of another generation, or too old, is "expired" and the system enumerates again),
/// contents by authenticated ranged reads, creates and edits as streamed writes with `expected_generation` (an edit
/// based on a generation that is no longer current keeps both: this Mac's current, the other a version), rename, move
/// and delete (into the vault's trash, recoverable). Every change is journalled before it returns; the host publishes
/// it shortly after. The engine decides; this maps.
public actor EngineReplica: FinderReplica {
    let host: any EngineHost
    let numbers: EntryNumbers
    let stateURL: URL?
    private let log = Logger(subsystem: "sh.vaulthalla.app", category: "fileprovider-engine")

    /// `numbersURL`: where the item numbers live (nil: memory, for tests).
    public init(host: any EngineHost, numbersURL: URL?) {
        self.host = host
        numbers = EntryNumbers(url: numbersURL)
        stateURL = numbersURL
    }

    public func close() async { await host.replicaClosing() }

    // MARK: plumbing

    func vault() async throws(FinderError) -> Vault {
        guard let v = await host.openedVault() else {
            if let why = await host.unavailableReason() { throw .notAuthenticated(why) }
            throw .serverUnreachable("The vault's storage can't be reached yet, and this Mac has no copy of it to show.")
        }
        return v
    }

    func run<T: Sendable>(_ body: @escaping @Sendable (Vault) throws(VaultError) -> T) async throws(FinderError) -> T {
        let v = try await vault()
        do {
            return try await v.perform(body)
        } catch {
            // The bucket couldn't be reached: say why when the host knows (no key, an expired or refused one).
            if [VaultStatus.storeFailed, VaultStatus.storeOutcomeUnknown].contains(error.status),
               let why = await host.unavailableReason() {
                throw .serverUnreachable(why)
            }
            throw Self.finderError(error)
        }
    }

    static func finderError(_ e: VaultError) -> FinderError {
        if e.name == "conflict" { return .localVersionConflictingWithServer }
        return switch e.status {
        case VaultStatus.notFound: .noSuchItem
        case VaultStatus.nameExists: .filenameCollision
        case VaultStatus.invalidName, VaultStatus.invalidMove, VaultStatus.notADirectory: .cannotSynchronize(e.sentence)
        case VaultStatus.storeFailed, VaultStatus.storeOutcomeUnknown: .serverUnreachable(e.sentence)
        case VaultStatus.busy, VaultStatus.stateFailed: .transient(e.sentence)
        default: .cannotSynchronize(e.sentence)
        }
    }

    /// The uid an identifier names (the root's own uid for `.root`).
    func uid(_ id: FinderItemID, root: String) throws(FinderError) -> String {
        switch id {
        case .root: return root
        case .entry(let n):
            guard let u = numbers.uid(n) else { throw .noSuchItem }
            return u
        case .workingSet, .trash: throw .noSuchItem
        }
    }

    func item(_ e: VaultEntry) -> FinderItem {
        let kind: FinderItemKind = switch e.kind {
        case .directory: .directory
        case .symlink: .symlink
        default: .file
        }
        // A file's content version is its generation (as a quoted validator, the form FinderItemVersion reads back);
        // the metadata version changes with its name, place, trash state and time.
        var meta = SHA256()
        meta.update(data: Data("\(e.name)\u{0}\(e.parent ?? "")\u{0}\(e.trashed)\u{0}\(e.mtime ?? "")\u{0}\(e.generation ?? "")".utf8))
        let metadata = SigV4.hex(meta.finalize().prefix(12))
        return FinderItem(entryID: numbers.number(e.uid), parentEntryID: e.parent.map(numbers.number), name: e.name,
                          path: e.name, kind: kind, size: kind == .file ? Int64(clamping: e.size ?? 0) : 0,
                          createdAt: e.mtime ?? "", updatedAt: e.mtime ?? "",
                          contentVersion: kind == .file ? "\"\(e.generation ?? "")\"" : nil, metadataVersion: metadata,
                          symlinkTarget: e.target, isHidden: e.name.hasPrefix("."))
    }

    static func generation(of version: FinderItemVersion) -> String? {
        version.contentETag.map { String($0.dropFirst().dropLast()) }
    }

    // MARK: items

    public var rootEntryID: Int64? {
        get async { (try? await run { v throws(VaultError) in try v.rootUID() }).map(numbers.number) }
    }

    public var pinnedEntries: Set<Int64> { [] }

    /// Keep Downloaded isn't offered for these vaults yet (no pin store here): the system's own policy applies.
    public func keepDownloaded(_ ids: [FinderItemID], _ keep: Bool) async throws(FinderError) {}

    public func item(_ id: FinderItemID) async throws(FinderError) -> FinderItem {
        let numbers = numbers
        let entry: VaultEntry? = try await run { v throws(VaultError) in
            let root = try v.rootUID()
            let u: String
            switch id {
            case .root: u = root
            case .entry(let n):
                guard let found = numbers.uid(n) else { return nil }
                u = found
            default: return nil
            }
            return try v.stat(u)
        }
        guard let entry, !entry.trashed else { throw .noSuchItem }
        return item(entry)
    }

    public func list(_ container: FinderItemID, page: EnumerationPage, pageSize: Int) async throws(FinderError)
        -> (items: [FinderItem], next: EnumerationPage?)
    {
        let numbers = numbers
        let children: [VaultEntry]? = try await run { v throws(VaultError) in
            let root = try v.rootUID()
            let u: String
            switch container {
            case .root: u = root
            case .entry(let n):
                guard let found = numbers.uid(n) else { return nil }
                u = found
            default: return nil
            }
            guard let dir = try v.stat(u), dir.kind == .directory, !dir.trashed else { return nil }
            return try v.list(u)
        }
        guard let children else { throw .noSuchItem }
        let all = children.filter { !$0.trashed }.sorted { $0.name < $1.name }.map(item)
        return Self.page(all, page, pageSize)
    }

    static func page(_ all: [FinderItem], _ page: EnumerationPage, _ size: Int) -> (items: [FinderItem], next: EnumerationPage?) {
        let n = max(1, size)
        let slice = Array(all.dropFirst(page.offset).prefix(n))
        let next = page.offset + slice.count < all.count ? EnumerationPage(offset: page.offset + slice.count) : nil
        return (slice, next)
    }

    /// Every live entry, by item number.
    public func workingSet(page: EnumerationPage, pageSize: Int) async throws(FinderError) -> (items: [FinderItem], next: EnumerationPage?) {
        let entries: [VaultEntry] = try await run { v throws(VaultError) in
            var out: [VaultEntry] = []
            var queue = [try v.rootUID()]
            while let dir = queue.popLast() {
                for e in try v.list(dir) where !e.trashed {
                    out.append(e)
                    if e.kind == .directory { queue.append(e.uid) }
                }
            }
            return out
        }
        let all = entries.map(item).sorted { $0.entryID < $1.entryID }
        return Self.page(all, page, pageSize)
    }

    // MARK: changes

    /// `g<generation>`: an anchor of another generation (a re-anchored or rebuilt change log) is expired.
    static func storeID(_ generation: UInt64) -> String { "g\(generation)" }

    public var currentAnchor: SyncAnchor {
        get async {
            guard let s = try? await run({ v throws(VaultError) in try v.status() }) else {
                return SyncAnchor(storeID: "g0", revision: 0)
            }
            return SyncAnchor(storeID: Self.storeID(s.generation), revision: Int64(clamping: s.revision))
        }
    }

    public func changes(since anchor: SyncAnchor, limit: Int) async throws(FinderError) -> VaultReplica.Changes {
        guard anchor.storeID.hasPrefix("g"), let generation = UInt64(anchor.storeID.dropFirst()), anchor.revision >= 0 else {
            throw .syncAnchorExpired
        }
        let (changes, root) = try await run { v throws(VaultError) in
            (try v.changes(generation: generation, after: UInt64(anchor.revision)), try v.rootUID())
        }
        if changes.expired { throw .syncAnchorExpired }
        var updated: [FinderItem] = []
        var deleted: [FinderItemID] = []
        for e in changes.changed where e.uid != root {
            if e.trashed {
                if let n = numbers.existing(e.uid) { deleted.append(.entry(n)) }
            } else {
                updated.append(item(e))
            }
        }
        for u in changes.removed where u != root {
            if let n = numbers.existing(u) { deleted.append(.entry(n)) }
        }
        return .make(updated: updated, deleted: deleted,
                     anchor: SyncAnchor(storeID: Self.storeID(changes.generation), revision: Int64(clamping: changes.revision)),
                     moreComing: false)
    }

    // MARK: contents

    public func fetch(_ id: FinderItemID, into directory: URL) async throws(FinderError) -> (url: URL, item: FinderItem) {
        let current = try await item(id)
        guard current.kind == .file, let u = numbers.uid(current.entryID) else {
            throw .cannotSynchronize("\(current.name) has no contents to download.")
        }
        let destination = directory.appending(path: "vh-\(UUID().uuidString).download", directoryHint: .notDirectory)
        try await readInto(destination, uid: u, offset: 0, length: .max)
        return (destination, current)
    }

    public func fetchRange(_ id: FinderItemID, version: FinderItemVersion, minimal: Range<Int64>, alignment: Int64,
                           strict: Bool, into directory: URL) async throws(FinderError) -> VaultReplica.PartialFetch {
        let current = try await item(id)
        guard current.kind == .file, let u = numbers.uid(current.entryID) else {
            throw .cannotSynchronize("\(current.name) has no contents to download.")
        }
        let destination = directory.appending(path: "vh-\(UUID().uuidString).partial", directoryHint: .notDirectory)
        let changed = Self.generation(of: version).map { "\"\($0)\"" != current.contentVersion } ?? false
        if changed && strict { throw .versionNoLongerAvailable }
        if changed || current.size == 0 || minimal.lowerBound >= current.size {
            // The whole current version (or nothing to read).
            try await readInto(destination, uid: u, offset: 0, length: .max)
            return .make(url: destination, item: current, range: 0 ..< current.size)
        }
        let bounds = VaultReplica.aligned(minimal, to: alignment, size: current.size)
        try await readInto(destination, uid: u, offset: UInt64(bounds.lowerBound), length: UInt64(bounds.count))
        return .make(url: destination, item: current, range: bounds)
    }

    /// Authenticated plaintext of `uid` into `url` at the same offsets (a sparse file for a range), mode 0600.
    func readInto(_ url: URL, uid: String, offset: UInt64, length: UInt64) async throws(FinderError) {
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw .transient("The download file couldn't be created.")
        }
        do {
            try await run { v throws(VaultError) in
                defer { try? handle.close() }
                _ = try? handle.seek(toOffset: offset)
                var failed = false
                try v.read(uid, offset: offset, length: length) { chunk in
                    do { try handle.write(contentsOf: Data(chunk)) } catch { failed = true }
                    return !failed
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: writes

    public func create(_ template: VaultReplica.Template, contents: URL?, mayAlreadyExist: Bool) async throws(FinderError)
        -> FinderItem
    {
        if VaultReplica.isExcluded(name: template.name) || template.kind == .symlink { throw .excludedFromSync }
        let numbers = numbers
        let parent = template.parent
        let name = template.name
        let entry: VaultEntry = try await run { v throws(VaultError) in
            let root = try v.rootUID()
            let p: String
            switch parent {
            case .root: p = root
            case .entry(let n):
                guard let u = numbers.uid(n) else { throw VaultError(status: VaultStatus.notFound) }
                p = u
            default: throw VaultError(status: VaultStatus.notFound)
            }
            switch template.kind {
            case .directory:
                do throws(VaultError) {
                    return try v.mkdir(parent: p, name: name)
                } catch where error.status == VaultStatus.nameExists && mayAlreadyExist {
                    if let existing = try v.list(p).first(where: { $0.name == name && !$0.trashed }), existing.kind == .directory {
                        return existing
                    }
                    throw error
                }
            case .file, .symlink:
                if let contents { return try v.write(contentsOf: contents, parent: p, name: name).entry }
                return try v.write(Data(), parent: p, name: name).entry
            }
        }
        await host.noteChange()
        return item(entry)
    }

    public func modify(_ id: FinderItemID, base: FinderItemVersion, changes: VaultReplica.Changeset, failOnConflict: Bool)
        async throws(FinderError) -> VaultReplica.Modified
    {
        guard case .entry = id else { return .make(item: try await item(id), fetchContents: false, conflictCopy: nil) }
        let numbers = numbers
        let expected = Self.generation(of: base)
        let (entry, conflict): (VaultEntry, Bool) = try await run { v throws(VaultError) in
            let root = try v.rootUID()
            guard case .entry(let n) = id, let u = numbers.uid(n), var current = try v.stat(u), !current.trashed else {
                throw VaultError(status: VaultStatus.notFound)
            }
            if let parentID = changes.parent {
                let p: String
                switch parentID {
                case .root: p = root
                case .entry(let pn):
                    guard let pu = numbers.uid(pn) else { throw VaultError(status: VaultStatus.notFound) }
                    p = pu
                default: throw VaultError(status: VaultStatus.notFound)
                }
                if p != current.parent { try v.move(u, into: p, name: changes.name) }
                else if let name = changes.name, name != current.name { try v.rename(u, to: name) }
            } else if let name = changes.name, name != current.name {
                try v.rename(u, to: name)
            }
            current = try v.stat(u) ?? current
            guard let contents = changes.contents, current.kind == .file else { return (current, false) }
            if failOnConflict, let expected, expected != current.generation {
                throw VaultError(local: "conflict", "changed elsewhere")
            }
            let written = try v.write(contentsOf: contents, uid: u, expectedGeneration: expected)
            return (written.entry, written.conflict)
        }
        await host.noteChange()
        if conflict {
            // Both kept by the engine: this edit current, the other a readable version of the same file.
            log.notice("engine: an edit based on an older generation was kept beside the other")
            await host.noteWriteConflict()
        }
        return .make(item: item(entry), fetchContents: false, conflictCopy: nil)
    }

    /// Into the vault's trash (recoverable, as a server vault's delete is). A file whose content changed since `base`
    /// isn't deleted (an edit beats a delete); a folder with children only when `recursive`.
    public func delete(_ id: FinderItemID, base: FinderItemVersion, recursive: Bool) async throws(FinderError) {
        guard case .entry(let n) = id else { throw .deletionRejected("The vault's root can't be deleted.") }
        guard let u = numbers.uid(n) else { return }
        let expected = Self.generation(of: base)
        let outcome: Int = try await run { v throws(VaultError) in
            guard let current = try v.stat(u), !current.trashed else { return 0 }
            if current.kind == .file, let expected, expected != current.generation { return 1 }
            if current.kind == .directory, !recursive, try !v.list(u).filter({ !$0.trashed }).isEmpty { return 2 }
            try v.trashEntry(u)
            return 3
        }
        switch outcome {
        case 1: throw .deletionRejected("It changed since; the new version is kept.")
        case 2: throw .directoryNotEmpty
        case 3: await host.noteChange()
        default: break
        }
    }

    public func thumbnails(for ids: [FinderItemID], size: Int, each: @Sendable (FinderItemID, Data?, FinderError?) -> Void) async {
        for id in ids { each(id, nil, nil) }  // the system makes its own from downloaded contents
    }
}
