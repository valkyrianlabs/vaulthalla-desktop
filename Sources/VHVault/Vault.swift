public import Foundation
public import VHCore
public import VHRecovery
import Darwin
import VLVaultfmt

// MARK: - what the engine answers

public enum EntryKind: Int32, Sendable, Hashable {
    case directory = 0
    case file = 1
    case symlink = 2
    case tombstone = 3
}

/// One provider version of a file, newest first.
public struct FileVersion: Sendable, Hashable {
    public var versionID: String
    public var generation: String?
    public var keyVersion: UInt32
    /// Sealed bytes; 0 when unknown.
    public var size: UInt64
    public var lastModified: String?
    /// nil: the current version.
    public var noncurrentAt: String?
    public var deleteMarker: Bool
}

/// An entry of the vault's working content (`vl_vaultfmt_entry`): what the last publish produced plus every local
/// change since.
public struct VaultEntry: Sendable, Hashable {
    /// 26 lower-case base32 characters: stays the same across rename and move.
    public var uid: String
    public var kind: EntryKind
    /// nil for the vault root.
    public var parent: String?
    public var name: String
    public var trashed: Bool
    /// Plaintext bytes (files).
    public var size: UInt64?
    public var mode: UInt32
    public var keyVersion: UInt32
    /// ISO 8601 UTC.
    public var mtime: String?
    /// Hex salt of the current object: a file's content version.
    public var generation: String?
    public var target: String?
    public var objectSize: UInt64?
    public var versionID: String?
    public var versions: [FileVersion]
}

/// What a change listing answers: the anchor to keep, and whether the one given was too old (enumerate again).
public struct VaultChanges: Sendable {
    public var generation: UInt64
    public var revision: UInt64
    public var expired: Bool
    public var changed: [VaultEntry]
    public var removed: [String]
}

public struct OpenInfo: Sendable, Equatable {
    public enum Anchor: Int32, Sendable { case state = 0, reanchored = 1, created = 2 }
    public enum State: Int32, Sendable { case fresh = 0, loaded = 1, damaged = 2 }
    public var anchor: Anchor
    public var state: State
    /// The last journal record was cut short (a crash during an append) and dropped.
    public var tornTail: Bool
    /// A damaged journal record and what followed it were dropped.
    public var journalTruncated: Bool
    /// false after a re-anchor: nothing bounds a replayed old root ("freshness unverified").
    public var freshnessVerified: Bool
    /// Objects placed under /Recovered by a re-anchor.
    public var recovered: UInt64
    public var epoch: UInt64?
    public var rootSHA256: String?
}

public struct RefreshInfo: Sendable, Equatable {
    public var moved, applied, adopted, rootMissing, unionBase: Bool
    public var epoch: UInt64
    public var rootSHA256: String
    public var changed: UInt64
    public var conflicts: UInt64
    /// Two-sided content changes: both generations kept (ours current, theirs a version).
    public var contentConflicts: UInt64
}

public struct PublishInfo: Sendable, Equatable {
    public var published: Bool
    public var epoch: UInt64
    public var rootSHA256: String
    public var rounds: UInt32
    public var segmentsWritten: UInt32
    public var segmentsReused: UInt32
    public var purged: UInt64
}

public struct GCInfo: Sendable, Equatable {
    public var ran: Bool
    public var deleted, retained, young: UInt64
}

/// `vl_vaultfmt_vault_status`: what the UI says about the vault.
public struct EngineStatus: Sendable, Equatable {
    public var epoch: UInt64?
    public var rootSHA256: String?
    /// A root was refused (rollback, fork, order_violation, superseded, publish_mode_mismatch): nothing is published
    /// until the chain moves on.
    public var refusedReason: String?
    /// A newer writer's root was seen (the writer floor): Vaulthalla needs an update.
    public var updateNeeded: Bool
    /// Local changes not in the bucket yet.
    public var unpublished: Bool
    public var generation: UInt64
    public var revision: UInt64
    public var pendingPurges: UInt64
}

// MARK: - the vault

/// One Desktop-only vault open through vl-vaultfmt's engine (vl_vaultfmt_engine.h): the bucket (``VaultStore``), this
/// Mac's keys (``VaultKeySource``) and the state file (the library's reference `FileStateBlob`, in the App Group
/// container). Every call blocks while the engine works, which may include network requests: call it through
/// ``perform(_:)``, which runs it on a queue of its own, never on Swift's cooperative pool (the store's callbacks wait
/// on the network there). The handle is safe to use from several threads; the engine serializes inside.
///
/// One process at a time: the state file is locked (`flock`) while a handle is open, so the app and the File Provider
/// extension never run two engines over one state.
public final class Vault: @unchecked Sendable {
    public let uid: Uid
    let handle: OpaquePointer
    private let fileState: OpaquePointer
    private let storeBox: StoreBox
    private let keysBox: KeysBox
    private let clockBox: ClockBox?
    private let lockFD: Int32
    public let stateURL: URL

    static let queue = DispatchQueue(label: "sh.vaulthalla.vault.engine", qos: .utility, attributes: .concurrent)

    /// Opens the vault `uid` (or creates it with `createName` when state and bucket are both empty).
    /// `nodeID`: this installation's id (the root's producer and writer).
    public static func open(uid: Uid, store: any VaultStore, keys: any VaultKeySource, stateURL: URL, nodeID: String,
                            createName: String? = nil, software: String = "Vaulthalla Desktop",
                            skipRecovery: Bool = false,
                            now: (@Sendable () -> Int64)? = nil) throws(VaultError) -> (vault: Vault, info: OpenInfo) {
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw VaultError(local: "state_directory", "The vault's state folder can't be made on this Mac.")
        }
        let lockPath = stateURL.path(percentEncoded: false) + ".lock"
        let fd = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VaultError(local: "state_lock", "The vault's state can't be locked on this Mac.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw VaultError(local: "state_busy", "Another part of Vaulthalla has this vault open on this Mac.")
        }
        var fileState: OpaquePointer?
        let path = stateURL.path(percentEncoded: false)
        var status = path.withText { p, n in vl_vaultfmt_file_state_new(p, n, &fileState) }
        guard status == VaultStatus.ok, let fileState else {
            close(fd)
            throw VaultError(status: status, message: "the state file")
        }
        var stateTable = vl_vaultfmt_state_table()
        status = vl_vaultfmt_file_state_table(fileState, &stateTable)
        guard status == VaultStatus.ok else {
            vl_vaultfmt_file_state_free(fileState)
            close(fd)
            throw VaultError(status: status, message: "the state file")
        }
        let storeBox = StoreBox(store)
        let keysBox = KeysBox(keys)
        let clockBox = now.map(ClockBox.init)
        var storeTable = storeBox.table()
        var keysTable = keysBox.table()
        var info = vl_vaultfmt_open_info()
        var out: OpaquePointer?
        status = nodeID.withText { node, nodeLength in
            software.withText { sw, swLength in
                (createName ?? "").withText { name, nameLength in
                    var options = vl_vaultfmt_vault_options()
                    options.node_id = node
                    options.node_id_len = nodeLength
                    options.software = sw
                    options.software_len = swLength
                    options.create_name = createName == nil ? nil : name
                    options.create_name_len = createName == nil ? 0 : nameLength
                    options.skip_recovery = skipRecovery ? 1 : 0
                    if let clockBox {
                        options.now = { ctx in Unmanaged<ClockBox>.fromOpaque(ctx!).takeUnretainedValue().now() }
                        options.now_ctx = Unmanaged.passUnretained(clockBox).toOpaque()
                    }
                    return uid.bytes.withUnsafeBufferPointer { u in
                        vl_vaultfmt_vault_open(u.baseAddress, &storeTable, &keysTable, &stateTable, &options, &info, &out)
                    }
                }
            }
        }
        guard status == VaultStatus.ok, let out else {
            vl_vaultfmt_file_state_free(fileState)
            close(fd)
            let detail = storeBox.takeLastFailure()
            throw VaultError(status: status, message: detail ?? fixedText(&info.message))
        }
        let vault = Vault(uid: uid, handle: out, fileState: fileState, storeBox: storeBox, keysBox: keysBox,
                          clockBox: clockBox, lockFD: fd, stateURL: stateURL)
        return (vault, OpenInfo(info))
    }

    private init(uid: Uid, handle: OpaquePointer, fileState: OpaquePointer, storeBox: StoreBox, keysBox: KeysBox,
                 clockBox: ClockBox?, lockFD: Int32, stateURL: URL) {
        self.uid = uid
        self.handle = handle
        self.fileState = fileState
        self.storeBox = storeBox
        self.keysBox = keysBox
        self.clockBox = clockBox
        self.lockFD = lockFD
        self.stateURL = stateURL
    }

    deinit {
        vl_vaultfmt_vault_free(handle)
        vl_vaultfmt_file_state_free(fileState)
        flock(lockFD, LOCK_UN)
        close(lockFD)
    }

    /// Runs `body` on the engine's queue (off the cooperative pool) and returns its result.
    public func perform<T: Sendable>(_ body: @escaping @Sendable (Vault) throws(VaultError) -> T) async throws(VaultError) -> T {
        let result: Result<T, VaultError> = await withCheckedContinuation { continuation in
            Self.queue.async {
                do throws(VaultError) {
                    continuation.resume(returning: .success(try body(self)))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }

    /// Opens on the engine's queue.
    public static func open(uid: Uid, store: any VaultStore, keys: any VaultKeySource, stateURL: URL, nodeID: String,
                            createName: String? = nil, skipRecovery: Bool = false) async throws(VaultError)
        -> (vault: Vault, info: OpenInfo)
    {
        let result: Result<(vault: Vault, info: OpenInfo), VaultError> = await withCheckedContinuation { c in
            queue.async {
                do throws(VaultError) {
                    c.resume(returning: .success(try open(uid: uid, store: store, keys: keys, stateURL: stateURL,
                                                          nodeID: nodeID, createName: createName,
                                                          skipRecovery: skipRecovery)))
                } catch {
                    c.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }

    // MARK: errors

    /// The vault's last failure message (no secrets), for an error of `status`.
    func fail(_ status: Int32) -> VaultError {
        var length = 0
        _ = vl_vaultfmt_vault_last_error(handle, nil, &length)
        guard length > 0 else { return VaultError(status: status) }
        var buffer = [CChar](repeating: 0, count: length + 1)
        guard vl_vaultfmt_vault_last_error(handle, &buffer, &length) == VaultStatus.ok else { return VaultError(status: status) }
        let message = String(decoding: buffer[0 ..< length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return VaultError(status: status, message: message)
    }

    func check(_ status: Int32) throws(VaultError) {
        guard status == VaultStatus.ok else {
            // A store callback's own failure says more than the engine's summary of it.
            if let detail = storeBox.takeLastFailure() {
                throw VaultError(status: status, message: detail)
            }
            throw fail(status)
        }
    }

    // MARK: reading

    public func rootUID() throws(VaultError) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = buffer.count
        try check(vl_vaultfmt_vault_root(handle, &buffer, &length))
        return String(decoding: buffer[0 ..< length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func list(_ directory: String) throws(VaultError) -> [VaultEntry] {
        var listing: OpaquePointer?
        try check(directory.withText { p, n in vl_vaultfmt_vault_list(handle, p, n, &listing) })
        defer { vl_vaultfmt_listing_free(listing) }
        return try Self.entries(listing)
    }

    /// One entry, live or trashed; nil when there is none.
    public func stat(_ uid: String) throws(VaultError) -> VaultEntry? {
        var listing: OpaquePointer?
        let status = uid.withText { p, n in vl_vaultfmt_vault_stat(handle, p, n, &listing) }
        if status == VaultStatus.notFound { return nil }
        try check(status)
        defer { vl_vaultfmt_listing_free(listing) }
        return try Self.entries(listing).first
    }

    public func trash() throws(VaultError) -> [VaultEntry] {
        var listing: OpaquePointer?
        try check(vl_vaultfmt_vault_trash(handle, &listing))
        defer { vl_vaultfmt_listing_free(listing) }
        return try Self.entries(listing)
    }

    /// What changed after the anchor `(generation, revision)`.
    public func changes(generation: UInt64, after revision: UInt64) throws(VaultError) -> VaultChanges {
        var info = vl_vaultfmt_changes_info()
        var listing: OpaquePointer?
        try check(vl_vaultfmt_vault_changes(handle, generation, revision, &info, &listing))
        defer { vl_vaultfmt_listing_free(listing) }
        var removed: [String] = []
        for i in 0 ..< vl_vaultfmt_listing_removed_count(listing) {
            var uid: UnsafePointer<CChar>?
            if vl_vaultfmt_listing_removed(listing, i, &uid) == VaultStatus.ok, let uid { removed.append(String(cString: uid)) }
        }
        return VaultChanges(generation: info.generation, revision: info.revision, expired: info.expired != 0,
                            changed: try Self.entries(listing), removed: removed)
    }

    /// Plaintext `[offset, offset + length)` of a file (its current object, or `versionID`), clipped to its size. `sink`
    /// receives only authenticated chunks, in order; returning false stops the read.
    public func read(_ uid: String, versionID: String? = nil, offset: UInt64 = 0, length: UInt64 = .max,
                     sink: (UnsafeRawBufferPointer) -> Bool) throws(VaultError) {
        try withoutActuallyEscaping(sink) { sink throws(VaultError) in
            let box = SinkBox(sink)
            let ctx = Unmanaged.passUnretained(box).toOpaque()
            let status = uid.withText { u, un in
                (versionID ?? "").withText { v, vn in
                    vl_vaultfmt_vault_read(handle, u, un, versionID == nil ? nil : v, versionID == nil ? 0 : vn, offset, length,
                                           { ctx, bytes, len in
                                               let box = Unmanaged<SinkBox>.fromOpaque(ctx!).takeUnretainedValue()
                                               return box.sink(UnsafeRawBufferPointer(start: bytes, count: len)) ? 0 : 1
                                           }, ctx)
                }
            }
            try check(status)
        }
    }

    /// The whole file (or a range of it) as bytes. For tests and small files; Finder reads stream to a file.
    public func readData(_ uid: String, versionID: String? = nil, offset: UInt64 = 0, length: UInt64 = .max)
        throws(VaultError) -> Data
    {
        var out = Data()
        try read(uid, versionID: versionID, offset: offset, length: length) { out.append(contentsOf: $0); return true }
        return out
    }

    // MARK: writing

    /// Starts a new file `name` in `parent` (`uid` nil), or new content for the file `uid`. `expectedGeneration`: the
    /// generation the local edit started from. `size`: the plaintext size when known.
    public func beginWrite(parent: String? = nil, name: String? = nil, uid: String? = nil, expectedGeneration: String? = nil,
                           size: UInt64? = nil) throws(VaultError) -> VaultWrite {
        var write: OpaquePointer?
        let status = (parent ?? "").withText { p, pn in
            (name ?? "").withText { nm, nn in
                (uid ?? "").withText { u, un in
                    (expectedGeneration ?? "").withText { g, gn in
                        vl_vaultfmt_write_begin(handle, parent == nil ? nil : p, parent == nil ? 0 : pn,
                                                name == nil ? nil : nm, name == nil ? 0 : nn,
                                                uid == nil ? nil : u, uid == nil ? 0 : un,
                                                expectedGeneration == nil ? nil : g, expectedGeneration == nil ? 0 : gn,
                                                size ?? .max, &write)
                    }
                }
            }
        }
        try check(status)
        return VaultWrite(vault: self, handle: write!)
    }

    /// Writes a whole file from `data`. Returns the entry and whether the write met a conflict (both kept).
    @discardableResult
    public func write(_ data: Data, parent: String? = nil, name: String? = nil, uid: String? = nil,
                      expectedGeneration: String? = nil) throws(VaultError) -> (entry: VaultEntry, conflict: Bool) {
        let w = try beginWrite(parent: parent, name: name, uid: uid, expectedGeneration: expectedGeneration,
                               size: UInt64(data.count))
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 1 << 20)
            try w.write(data[offset ..< end])
            offset = end
        }
        return try w.finish()
    }

    /// Streams the file at `url` in pieces of 1 MiB (the plaintext never lands anywhere but the sealer).
    @discardableResult
    public func write(contentsOf url: URL, parent: String? = nil, name: String? = nil, uid: String? = nil,
                      expectedGeneration: String? = nil) throws(VaultError) -> (entry: VaultEntry, conflict: Bool) {
        guard let file = try? FileHandle(forReadingFrom: url) else {
            throw VaultError(local: "read_failed", "The file to send couldn't be read.")
        }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()).map { UInt64($0) }
        _ = try? file.seek(toOffset: 0)
        let w = try beginWrite(parent: parent, name: name, uid: uid, expectedGeneration: expectedGeneration, size: size)
        while true {
            guard let chunk = try? file.read(upToCount: 1 << 20) else {
                throw VaultError(local: "read_failed", "The file to send couldn't be read.")
            }
            if chunk.isEmpty { break }
            try w.write(chunk)
        }
        return try w.finish()
    }

    // MARK: tree changes

    @discardableResult
    public func mkdir(parent: String, name: String) throws(VaultError) -> VaultEntry {
        var listing: OpaquePointer?
        try check(parent.withText { p, pn in name.withText { n, nn in vl_vaultfmt_vault_mkdir(handle, p, pn, n, nn, &listing) } })
        defer { vl_vaultfmt_listing_free(listing) }
        guard let e = try Self.entries(listing).first else { throw VaultError(local: "malformed", "mkdir returned no entry") }
        return e
    }

    public func rename(_ uid: String, to name: String) throws(VaultError) {
        try check(uid.withText { u, un in name.withText { n, nn in vl_vaultfmt_vault_rename(handle, u, un, n, nn) } })
    }

    /// Moves `uid` into `parent`, keeping its name unless `name` is given.
    public func move(_ uid: String, into parent: String, name: String? = nil) throws(VaultError) {
        try check(uid.withText { u, un in
            parent.withText { p, pn in
                (name ?? "").withText { n, nn in
                    vl_vaultfmt_vault_move(handle, u, un, p, pn, name == nil ? nil : n, name == nil ? 0 : nn)
                }
            }
        })
    }

    public func trashEntry(_ uid: String) throws(VaultError) {
        try check(uid.withText { u, un in vl_vaultfmt_vault_trash_entry(handle, u, un) })
    }

    /// Back where it was (else the vault root) under its own name, or into `parent` as `name`.
    public func restore(_ uid: String, into parent: String? = nil, name: String? = nil) throws(VaultError) {
        try check(uid.withText { u, un in
            (parent ?? "").withText { p, pn in
                (name ?? "").withText { n, nn in
                    vl_vaultfmt_vault_restore(handle, u, un, parent == nil ? nil : p, parent == nil ? 0 : pn,
                                              name == nil ? nil : n, name == nil ? 0 : nn)
                }
            }
        })
    }

    public func purge(_ uid: String) throws(VaultError) {
        try check(uid.withText { u, un in vl_vaultfmt_vault_purge(handle, u, un) })
    }

    // MARK: keys

    /// Adds key `version` with its KEV1 envelopes (PUT before the version is recorded). `key` must be what the keys
    /// source holds for that version.
    public func addKey(version: UInt32, key: SecretBytes, envelopes: [Data], keyCheck: String? = nil) throws(VaultError) {
        // A copy for the call: the keys source may lend the same SecretBytes while the engine checks it.
        let copy = UnsafeMutableRawBufferPointer.allocate(byteCount: key.count, alignment: 1)
        defer {
            copy.initializeMemory(as: UInt8.self, repeating: 0)
            copy.deallocate()
        }
        key.withUnsafeBytes { copy.copyMemory(from: $0) }
        let k = UnsafeRawBufferPointer(copy)
        let status: Int32 = withEnvelopes(envelopes) { list in
            (keyCheck ?? "").withText { c, cn in
                vl_vaultfmt_vault_key_add(handle, version, k.baseAddress?.assumingMemoryBound(to: UInt8.self), k.count,
                                          list.baseAddress, list.count, keyCheck == nil ? nil : c, keyCheck == nil ? 0 : cn)
            }
        }
        try check(status)
    }

    // MARK: the bucket

    @discardableResult
    public func refresh() throws(VaultError) -> RefreshInfo {
        var info = vl_vaultfmt_refresh_info()
        try check(vl_vaultfmt_vault_refresh(handle, &info))
        return RefreshInfo(moved: info.moved != 0, applied: info.applied != 0, adopted: info.adopted != 0,
                           rootMissing: info.root_missing != 0, unionBase: info.union_base != 0, epoch: info.epoch,
                           rootSHA256: fixedText(&info.root_sha256), changed: info.changed, conflicts: info.conflicts,
                           contentConflicts: info.content_conflicts)
    }

    @discardableResult
    public func publish() throws(VaultError) -> PublishInfo {
        var info = vl_vaultfmt_publish_info()
        try check(vl_vaultfmt_vault_publish(handle, &info))
        return PublishInfo(published: info.published != 0, epoch: info.epoch, rootSHA256: fixedText(&info.root_sha256),
                           rounds: info.rounds, segmentsWritten: info.segments_written,
                           segmentsReused: info.segments_reused, purged: info.purged)
    }

    @discardableResult
    public func collectGarbageIfDue(now: Int64 = Int64(Date().timeIntervalSince1970)) throws(VaultError) -> GCInfo {
        var info = vl_vaultfmt_gc_info()
        try check(vl_vaultfmt_vault_gc_if_due(handle, now, &info))
        return GCInfo(ran: info.ran != 0, deleted: info.deleted, retained: info.retained, young: info.young)
    }

    /// This installation joins the root's writers at the next publish (it opened another Mac's vault from the bucket).
    public func join() throws(VaultError) { try check(vl_vaultfmt_vault_join(handle)) }

    public func status() throws(VaultError) -> EngineStatus {
        var s = vl_vaultfmt_vault_status()
        try check(vl_vaultfmt_vault_status_get(handle, &s))
        let reason = fixedText(&s.refused_reason)
        return EngineStatus(epoch: s.has_known != 0 ? s.epoch : nil, rootSHA256: s.has_known != 0 ? fixedText(&s.root_sha256) : nil,
                            refusedReason: s.refused != 0 ? (reason.isEmpty ? "refused" : reason) : nil,
                            updateNeeded: s.update_needed != 0, unpublished: s.unpublished != 0,
                            generation: s.generation, revision: s.revision, pendingPurges: s.pending_purges)
    }

    // MARK: listings

    static func entries(_ listing: OpaquePointer?) throws(VaultError) -> [VaultEntry] {
        guard let listing else { return [] }
        var out: [VaultEntry] = []
        let count = vl_vaultfmt_listing_count(listing)
        out.reserveCapacity(count)
        for i in 0 ..< count {
            var e = vl_vaultfmt_entry()
            let status = vl_vaultfmt_listing_entry(listing, i, &e)
            guard status == VaultStatus.ok else { throw VaultError(status: status, message: "a listing entry") }
            var versions: [FileVersion] = []
            for j in 0 ..< vl_vaultfmt_listing_version_count(listing, i) {
                var v = vl_vaultfmt_file_version()
                guard vl_vaultfmt_listing_version(listing, i, j, &v) == VaultStatus.ok else { continue }
                versions.append(FileVersion(versionID: text(v.version_id) ?? "", generation: text(v.generation),
                                            keyVersion: v.key_version, size: v.size, lastModified: text(v.last_modified),
                                            noncurrentAt: text(v.noncurrent_at), deleteMarker: v.delete_marker != 0))
            }
            let name = e.name.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: e.name_len), as: UTF8.self) } ?? ""
            out.append(VaultEntry(uid: text(e.uid) ?? "", kind: EntryKind(rawValue: e.kind) ?? .file, parent: text(e.parent),
                                  name: name, trashed: e.trashed != 0, size: e.has_size != 0 ? e.size : nil, mode: e.mode,
                                  keyVersion: e.key_version, mtime: text(e.mtime), generation: text(e.generation),
                                  target: text(e.target), objectSize: e.has_object != 0 ? e.object_size : nil,
                                  versionID: text(e.version_id), versions: versions))
        }
        return out
    }
}

/// A streamed write: one thread at a time; free (or let go of) it before its vault.
public final class VaultWrite: @unchecked Sendable {
    private let vault: Vault
    private var handle: OpaquePointer?

    init(vault: Vault, handle: OpaquePointer) {
        self.vault = vault
        self.handle = handle
    }

    deinit { vl_vaultfmt_write_free(handle) }

    public func write(_ plaintext: some DataProtocol) throws(VaultError) {
        guard let handle else { throw VaultError(local: "write_finished", "the write is finished") }
        let data = Data(plaintext)
        let status = data.withUnsafeBytes { b in
            vl_vaultfmt_write_chunk(handle, b.baseAddress?.assumingMemoryBound(to: UInt8.self), b.count)
        }
        try vault.check(status)
    }

    /// Uploads the rest and records the version. `conflict`: the file's generation was no longer the expected one
    /// (both are kept: this one current, the other a version).
    public func finish() throws(VaultError) -> (entry: VaultEntry, conflict: Bool) {
        guard let handle else { throw VaultError(local: "write_finished", "the write is finished") }
        var conflict: Int32 = 0
        var listing: OpaquePointer?
        let status = vl_vaultfmt_write_finish(handle, &conflict, &listing)
        vl_vaultfmt_write_free(handle)
        self.handle = nil
        defer { vl_vaultfmt_listing_free(listing) }
        try vault.check(status)
        guard let entry = try Vault.entries(listing).first else { throw VaultError(local: "malformed", "a write returned no entry") }
        return (entry, conflict != 0)
    }
}

// MARK: - helpers

extension OpenInfo {
    init(_ i: vl_vaultfmt_open_info) {
        var copy = i
        anchor = Anchor(rawValue: i.anchor) ?? .state
        state = State(rawValue: i.state) ?? .loaded
        tornTail = i.torn_tail != 0
        journalTruncated = i.journal_truncated != 0
        freshnessVerified = i.freshness_verified != 0
        recovered = i.recovered
        epoch = i.has_known != 0 ? i.epoch : nil
        rootSHA256 = i.has_known != 0 ? fixedText(&copy.root_sha256) : nil
    }
}

/// A NUL-terminated C array member as text.
func fixedText<T>(_ tuple: inout T) -> String {
    withUnsafeBytes(of: &tuple) { raw in
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

func text(_ p: UnsafePointer<CChar>?) -> String? { p.map { String(cString: $0) } }

extension String {
    /// The UTF-8 bytes as pointer and length for the C API (no NUL is read).
    func withText<R>(_ body: (UnsafePointer<CChar>?, Int) throws -> R) rethrows -> R {
        var copy = self
        return try copy.withUTF8 { u in try u.withMemoryRebound(to: CChar.self) { try body($0.baseAddress, $0.count) } }
    }
}

private func withEnvelopes<R>(_ envelopes: [Data], _ body: (UnsafeBufferPointer<vl_vaultfmt_bytes>) -> R) -> R {
    let buffers = envelopes.map { d -> UnsafeMutableRawBufferPointer in
        let b = UnsafeMutableRawBufferPointer.allocate(byteCount: max(d.count, 1), alignment: 1)
        _ = d.copyBytes(to: b.bindMemory(to: UInt8.self))
        return b
    }
    defer { buffers.forEach { $0.deallocate() } }
    let list = zip(buffers, envelopes).map { b, d in
        vl_vaultfmt_bytes(bytes: UnsafePointer(b.baseAddress!.assumingMemoryBound(to: UInt8.self)), len: d.count)
    }
    return list.withUnsafeBufferPointer(body)
}

