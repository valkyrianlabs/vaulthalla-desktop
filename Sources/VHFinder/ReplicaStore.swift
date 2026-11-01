public import Foundation
import SQLite3

/// A domain's replica database: what the extension last learned from the server about the vault's entries, so the
/// File Provider can be answered without asking the server for everything again (vaulthalla/desktop#4).
///
/// **A cache, never a source of truth.** It maps item identifiers to entries (id, parent, path), keeps their versions,
/// and records which folders the system enumerated (the working set's scope). It holds no file contents and nothing
/// secret. Losing it costs a re-enumeration and nothing else: a store that can't be opened, or has another schema, is
/// deleted and started over with a new ``storeID``, which expires every anchor the system holds
/// (``SyncAnchor``).
///
/// **Changes.** Every row that becomes new, different or gone takes the next ``revision``; gone rows leave a tombstone
/// with theirs. "What changed after revision N" is then one query (``changes(after:limit:)``). Without a server change
/// journal (vaulthalla/server#259) the extension finds changes by listing folders again and applying the listings
/// here (``applyListing(of:children:)``).
///
/// Not thread-safe: one owner (``VaultReplica``, an actor) uses it.
public final class ReplicaStore {
    public static let schemaVersion = 1
    /// Tombstones kept before the oldest are dropped; an anchor older than the dropped ones expires.
    public static let tombstoneLimit = 20_000

    public let url: URL?
    public private(set) var storeID: String = ""
    public private(set) var revision: Int64 = 0
    /// Anchors at or below this revision may have missed a dropped tombstone.
    public private(set) var floor: Int64 = 0
    public private(set) var rootEntryID: Int64?
    private var db: OpaquePointer?

    public enum Failure: Error, CustomStringConvertible {
        case sqlite(String)
        public var description: String {
            switch self { case .sqlite(let message): "replica database: \(message)" }
        }
    }

    /// Opens (or creates) the store at `url`; nil keeps it in memory. A store that can't be used is deleted and made
    /// again, empty.
    public init(url: URL?) throws(Failure) {
        self.url = url
        do {
            try open()
        } catch {
            close()
            guard let url else { throw error }
            Self.deleteFiles(at: url)
            try open()
        }
    }

    deinit { close() }

    /// Deletes a store's files (the database and its WAL), as when its domain is removed.
    public static func deleteFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(filePath: url.path(percentEncoded: false) + suffix))
        }
    }

    // MARK: - Opening

    private func open() throws(Failure) {
        let path: String
        if let url {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            path = url.path(percentEncoded: false)
        } else {
            path = ":memory:"
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw .sqlite(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS items (
                entry_id INTEGER PRIMARY KEY, parent_id INTEGER, name TEXT NOT NULL, path TEXT NOT NULL,
                kind INTEGER NOT NULL, size INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
                content_version TEXT, metadata_version TEXT NOT NULL, symlink_target TEXT, hidden INTEGER NOT NULL,
                listed INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS items_parent ON items(parent_id, name, entry_id);
            CREATE INDEX IF NOT EXISTS items_revision ON items(revision);
            CREATE TABLE IF NOT EXISTS tombstones (
                entry_id INTEGER PRIMARY KEY, parent_id INTEGER, revision INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS tombstones_revision ON tombstones(revision);
            """)
        let meta = try readMeta()
        if let schema = meta["schema"] {
            guard schema == String(Self.schemaVersion), let id = meta["store_id"], !id.isEmpty else {
                throw .sqlite("schema \(schema) isn't \(Self.schemaVersion)")
            }
            storeID = id
            revision = Int64(meta["revision"] ?? "") ?? 0
            floor = Int64(meta["floor"] ?? "") ?? 0
            rootEntryID = meta["root_entry_id"].flatMap { Int64($0) }
        } else {
            storeID = UUID().uuidString.lowercased()
            try writeMeta(["schema": String(Self.schemaVersion), "store_id": storeID, "revision": "0", "floor": "0"])
        }
    }

    private func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    // MARK: - Reading

    public var currentAnchor: SyncAnchor { SyncAnchor(storeID: storeID, revision: revision) }

    /// Whether `anchor` can be served: this store's, not ahead of it, and not older than a dropped tombstone.
    public func accepts(_ anchor: SyncAnchor) -> Bool {
        anchor.storeID == storeID && anchor.revision <= revision && anchor.revision >= floor
    }

    public func item(_ entryID: Int64) throws(Failure) -> FinderItem? {
        try query("SELECT \(Self.columns) FROM items WHERE entry_id = ?", [.int(entryID)]).first
    }

    /// The root folder's row, once a listing of "/" recorded it.
    public func rootItem() throws(Failure) -> FinderItem? {
        guard let rootEntryID else { return nil }
        return try item(rootEntryID)
    }

    /// A folder's children by name (then id): the order container pages are cut in.
    public func children(of parentEntryID: Int64) throws(Failure) -> [FinderItem] {
        try query("SELECT \(Self.columns) FROM items WHERE parent_id = ? ORDER BY name, entry_id", [.int(parentEntryID)])
    }

    /// The child of `parentEntryID` named `name`, if the replica knows one.
    public func child(of parentEntryID: Int64, named name: String) throws(Failure) -> FinderItem? {
        try query("SELECT \(Self.columns) FROM items WHERE parent_id = ? AND name = ?",
                  [.int(parentEntryID), .text(name)]).first
    }

    /// The working set: every entry the replica knows except the root, by entry id.
    public func workingSet(offset: Int, limit: Int) throws(Failure) -> [FinderItem] {
        var rows = try query("SELECT \(Self.columns) FROM items ORDER BY entry_id LIMIT ? OFFSET ?",
                             [.int(Int64(limit) + 1), .int(Int64(offset))])
        rows.removeAll { $0.entryID == rootEntryID || $0.isRoot }
        return Array(rows.prefix(limit))
    }

    /// The folders the system enumerated, the root first: the ones a refresh lists again.
    public func listedFolders() throws(Failure) -> [FinderItem] {
        let rows = try query("SELECT \(Self.columns) FROM items WHERE listed = 1 ORDER BY entry_id", [])
        return rows.sorted { ($0.isRoot ? 0 : 1, $0.path) < ($1.isRoot ? 0 : 1, $1.path) }
    }

    public func isListed(_ entryID: Int64) throws(Failure) -> Bool {
        try scalar("SELECT listed FROM items WHERE entry_id = ?", [.int(entryID)]) == 1
    }

    /// What changed after `revision`, in revision order, at most `limit` rows: entries new or different (`updated`)
    /// and entries gone (`deleted`; an id that came back since is reported as updated only). `last` is the revision
    /// to resume after; `more` whether rows remain past it.
    public struct ChangeBatch: Hashable, Sendable {
        public var updated: [FinderItem]
        public var deleted: [Int64]
        public var last: Int64
        public var more: Bool
    }

    public func changes(after revision: Int64, limit: Int) throws(Failure) -> ChangeBatch {
        let cap = Int64(limit) + 1
        var revisions: [Int64] = []
        let updated = try query("SELECT \(Self.columns), revision FROM items WHERE revision > ? ORDER BY revision LIMIT ?",
                                [.int(revision), .int(cap)]) { revisions.append($0) }
        var deleted: [(id: Int64, revision: Int64)] = []
        try each("""
            SELECT entry_id, revision FROM tombstones WHERE revision > ?
            AND entry_id NOT IN (SELECT entry_id FROM items) ORDER BY revision LIMIT ?
            """, [.int(revision), .int(cap)]) { row in
            deleted.append((sqlite3_column_int64(row, 0), sqlite3_column_int64(row, 1)))
        }
        // Merge by revision and cut at `limit`.
        var merged: [(revision: Int64, item: FinderItem?, deleted: Int64?)] =
            zip(revisions, updated).map { ($0, $1, nil) } + deleted.map { ($0.revision, nil, $0.id) }
        merged.sort { $0.revision < $1.revision }
        let taken = merged.prefix(limit)
        let more = merged.count > limit
        let last = more ? (taken.last?.revision ?? revision) : self.revision
        return ChangeBatch(updated: taken.compactMap(\.item), deleted: taken.compactMap(\.deleted), last: last,
                           more: more)
    }

    // MARK: - Writing

    /// Records `item` as the server has it now. Returns whether anything changed (and took a revision). The folder's
    /// `listed` flag is kept.
    @discardableResult
    public func upsert(_ item: FinderItem) throws(Failure) -> Bool {
        try transaction { () throws(Failure) -> Bool in try write(item) }
    }

    /// Records a listing of `folder`: the folder itself (now listed), its children as they are, and every child the
    /// replica had there that the listing no longer has as gone (with what it held). Returns how many rows changed.
    @discardableResult
    public func applyListing(of folder: FinderItem, children: [FinderItem]) throws(Failure) -> Int {
        try transaction { () throws(Failure) -> Int in
            if folder.isRoot { try setRoot(folder.entryID) }
            var changed = try write(folder) ? 1 : 0
            try run("UPDATE items SET listed = 1 WHERE entry_id = ?", [.int(folder.entryID)])
            var present = Set<Int64>()
            for child in children {
                present.insert(child.entryID)
                var child = child
                child.parentEntryID = folder.entryID
                if try write(child) { changed += 1 }
            }
            for stale in try self.children(of: folder.entryID) where !present.contains(stale.entryID) {
                changed += try tombstone(stale.entryID)
            }
            return changed
        }
    }

    /// Records that `entryID` (and everything under it) is gone. Returns how many rows went.
    @discardableResult
    public func remove(_ entryID: Int64) throws(Failure) -> Int {
        try transaction { () throws(Failure) -> Int in try tombstone(entryID) }
    }

    /// After a folder moved from `oldPath` to `newPath`: the paths of everything below it, which the server changed
    /// with it. Paths aren't shown to the system, so nothing takes a revision.
    public func rewritePaths(under entryID: Int64, from oldPath: String, to newPath: String) throws(Failure) {
        guard oldPath != newPath else { return }
        try transaction { () throws(Failure) in
            var queue = try children(of: entryID)
            while let next = queue.popLast() {
                if next.path.hasPrefix(oldPath + "/") {
                    let moved = newPath + next.path.dropFirst(oldPath.count)
                    try run("UPDATE items SET path = ? WHERE entry_id = ?", [.text(String(moved)), .int(next.entryID)])
                }
                queue += try children(of: next.entryID)
            }
        }
    }

    /// Gives each of `entryIDs` the replica has the next revision without changing it, so the next changes report it
    /// as updated: how the system learns that something it can't see in the row did change (Keep Downloaded). Returns
    /// how many rows took a revision.
    @discardableResult
    public func touch(_ entryIDs: [Int64]) throws(Failure) -> Int {
        try transaction { () throws(Failure) -> Int in
            var touched = 0
            for id in entryIDs where try item(id) != nil {
                try run("UPDATE items SET revision = ? WHERE entry_id = ?", [.int(nextRevision()), .int(id)])
                touched += 1
            }
            return touched
        }
    }

    /// Marks a folder as enumerated by the system, so refreshes list it again.
    public func markListed(_ entryID: Int64) throws(Failure) {
        try run("UPDATE items SET listed = 1 WHERE entry_id = ?", [.int(entryID)])
    }

    /// Drops the oldest tombstones beyond ``tombstoneLimit``; anchors from before them expire.
    public func pruneTombstones(keeping limit: Int = ReplicaStore.tombstoneLimit) throws(Failure) {
        let count = try scalar("SELECT COUNT(*) FROM tombstones", []) ?? 0
        guard count > Int64(limit) else { return }
        try transaction { () throws(Failure) in
            let cut = try scalar("SELECT revision FROM tombstones ORDER BY revision LIMIT 1 OFFSET ?",
                                 [.int(count - Int64(limit) - 1)]) ?? 0
            try run("DELETE FROM tombstones WHERE revision <= ?", [.int(cut)])
            floor = max(floor, cut)
            try writeMeta(["floor": String(floor)])
        }
    }

    private func setRoot(_ entryID: Int64) throws(Failure) {
        guard rootEntryID != entryID else { return }
        rootEntryID = entryID
        try writeMeta(["root_entry_id": String(entryID)])
    }

    private func nextRevision() -> Int64 {
        revision += 1
        return revision
    }

    /// Writes one row when it differs from what is stored; clears a tombstone the id may have.
    private func write(_ item: FinderItem) throws(Failure) -> Bool {
        if let current = try self.item(item.entryID), current == item { return false }
        let revision = nextRevision()
        try run("""
            INSERT INTO items (entry_id, parent_id, name, path, kind, size, created_at, updated_at, content_version,
                               metadata_version, symlink_target, hidden, listed, revision)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT(entry_id) DO UPDATE SET parent_id = excluded.parent_id, name = excluded.name,
                path = excluded.path, kind = excluded.kind, size = excluded.size, created_at = excluded.created_at,
                updated_at = excluded.updated_at, content_version = excluded.content_version,
                metadata_version = excluded.metadata_version, symlink_target = excluded.symlink_target,
                hidden = excluded.hidden, revision = excluded.revision
            """, [
                .int(item.entryID), item.parentEntryID.map(Value.int) ?? .null, .text(item.name), .text(item.path),
                .int(Int64(item.kind.rawValue)), .int(item.size), .text(item.createdAt), .text(item.updatedAt),
                item.contentVersion.map(Value.text) ?? .null, .text(item.metadataVersion),
                item.symlinkTarget.map(Value.text) ?? .null, .int(item.isHidden ? 1 : 0), .int(revision),
            ])
        try run("DELETE FROM tombstones WHERE entry_id = ?", [.int(item.entryID)])
        return true
    }

    /// Removes `entryID` and its descendants, leaving a tombstone for each.
    private func tombstone(_ entryID: Int64) throws(Failure) -> Int {
        var removed = 0
        var queue = [entryID]
        while let next = queue.popLast() {
            guard let row = try item(next) else { continue }
            queue += try children(of: next).map(\.entryID)
            try run("DELETE FROM items WHERE entry_id = ?", [.int(next)])
            try run("INSERT OR REPLACE INTO tombstones (entry_id, parent_id, revision) VALUES (?, ?, ?)",
                    [.int(next), row.parentEntryID.map(Value.int) ?? .null, .int(nextRevision())])
            removed += 1
        }
        return removed
    }

    // MARK: - SQLite

    private static let columns = """
        entry_id, parent_id, name, path, kind, size, created_at, updated_at, content_version, metadata_version, \
        symlink_target, hidden
        """

    private enum Value {
        case int(Int64)
        case text(String)
        case null
    }

    private var inTransaction = false

    private func transaction<T>(_ body: () throws(Failure) -> T) throws(Failure) -> T {
        if inTransaction { return try body() }
        let before = revision
        try exec("BEGIN IMMEDIATE")
        inTransaction = true
        defer { inTransaction = false }
        do {
            let result = try body()
            if revision != before { try writeMeta(["revision": String(revision)]) }
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            revision = before
            throw error
        }
    }

    private func readMeta() throws(Failure) -> [String: String] {
        var meta: [String: String] = [:]
        try each("SELECT key, value FROM meta", []) { row in
            meta[String(cString: sqlite3_column_text(row, 0))] = String(cString: sqlite3_column_text(row, 1))
        }
        return meta
    }

    private func writeMeta(_ values: [String: String]) throws(Failure) {
        for (key, value) in values {
            try run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [.text(key), .text(value)])
        }
    }

    private func exec(_ sql: String) throws(Failure) {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(message)
            throw .sqlite(text)
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws(Failure) -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw .sqlite(String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .int(let number): sqlite3_bind_int64(statement, position, number)
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Value]) throws(Failure) {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw .sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func each(_ sql: String, _ values: [Value], _ row: (OpaquePointer) -> Void) throws(Failure) {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw .sqlite(String(cString: sqlite3_errmsg(db))) }
            row(statement)
        }
    }

    private func scalar(_ sql: String, _ values: [Value]) throws(Failure) -> Int64? {
        var result: Int64?
        try each(sql, values) { row in
            if sqlite3_column_type(row, 0) != SQLITE_NULL { result = sqlite3_column_int64(row, 0) }
        }
        return result
    }

    /// Rows of ``columns``; `extra` gets column 12 (an additional integer selected after them) of each row.
    private func query(_ sql: String, _ values: [Value], extra: ((Int64) -> Void)? = nil) throws(Failure)
        -> [FinderItem]
    {
        var items: [FinderItem] = []
        try each(sql, values) { row in
            extra?(sqlite3_column_int64(row, 12))
            func text(_ column: Int32) -> String? {
                sqlite3_column_type(row, column) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(row, column))
            }
            func integer(_ column: Int32) -> Int64? {
                sqlite3_column_type(row, column) == SQLITE_NULL ? nil : sqlite3_column_int64(row, column)
            }
            items.append(FinderItem(
                entryID: sqlite3_column_int64(row, 0), parentEntryID: integer(1), name: text(2) ?? "",
                path: text(3) ?? "/", kind: FinderItemKind(rawValue: Int(sqlite3_column_int64(row, 4))) ?? .file,
                size: sqlite3_column_int64(row, 5), createdAt: text(6) ?? "", updatedAt: text(7) ?? "",
                contentVersion: text(8), metadataVersion: text(9) ?? "", symlinkTarget: text(10),
                isHidden: sqlite3_column_int64(row, 11) != 0))
        }
        return items
    }
}

/// Where a domain's replica database lives: `<container>/FileProvider/<domain identifier>.sqlite`. The container is
/// the App Group's, so the app can remove a domain's database with the domain; the identifier carries no `/`
/// (``VaultDomainID``).
public enum ReplicaLocation {
    public static let directoryName = "FileProvider"

    public static func storeURL(domain identifier: String, in container: URL) -> URL {
        let safe = String(identifier.map { $0 == "/" || $0 == ":" ? "_" : $0 })
        return container.appending(path: directoryName, directoryHint: .isDirectory)
            .appending(path: "\(safe).sqlite", directoryHint: .notDirectory)
    }
}
