public import Foundation

/// An in-memory versioned bucket that answers as Backblaze B2 does for a Desktop-only vault (version_log: every PUT a
/// new version, conditional PUTs refused with "not implemented", a DELETE by name a delete marker), the same double as
/// vl-vaultfmt's `tests/c_engine_lifecycle.c` bucket. For tests and previews; shared by every vault handle given it, so
/// two handles read what the other wrote.
public final class MemoryBucket: VaultStore, @unchecked Sendable {
    struct Version {
        var key: String
        var id: String
        var body: Data
        var marker: Bool
        var gone = false
        var at: Int64
    }

    private let lock = NSLock()
    private var all: [Version] = []
    private var seq = 0
    public let versionLog: Bool
    /// Counts every request, for "a refresh costs one HEAD".
    public private(set) var requests = 0
    /// The next request fails with this (then the bucket answers again).
    public var failNext: StoreError? {
        get { lock.withLock { pendingFailure } }
        set { lock.withLock { pendingFailure = newValue } }
    }
    private var pendingFailure: StoreError?

    public init(versionLog: Bool = true) { self.versionLog = versionLog }

    public var requestCount: Int { lock.withLock { requests } }
    public func resetRequestCount() { lock.withLock { requests = 0 } }
    /// Every current object's key (no delete marker on top).
    public var currentKeys: [String] {
        lock.withLock { Set(all.filter { !$0.gone }.map(\.key)).filter { find($0, nil) != nil }.sorted() }
    }

    private func begin() throws(StoreError) {
        requests += 1
        if let f = pendingFailure {
            pendingFailure = nil
            throw f
        }
    }

    private func add(_ key: String, _ body: Data, marker: Bool) -> Version {
        seq += 1
        let v = Version(key: key, id: String(format: "v%06d", seq), body: body, marker: marker, at: 1_800_000_000 + Int64(seq))
        all.append(v)
        return v
    }

    private func find(_ key: String, _ versionID: String?) -> Version? {
        for v in all.reversed() where !v.gone && v.key == key {
            if let versionID {
                if v.id == versionID { return v.marker ? nil : v }
                continue
            }
            return v.marker ? nil : v
        }
        return nil
    }

    private static func object(_ v: Version) -> StoredObject { StoredObject(etag: "\"e\(v.id)\"", versionID: v.id) }

    public func get(_ key: String, versionID: String?) throws(StoreError) -> ObjectBody {
        lock.lock()
        defer { lock.unlock() }
        try begin()
        guard let v = find(key, versionID) else { throw .notFound }
        return ObjectBody(bytes: v.body, object: Self.object(v))
    }

    public func getRange(_ key: String, versionID: String?, offset: UInt64, length: UInt64) throws(StoreError)
        -> (bytes: Data, total: UInt64)
    {
        lock.lock()
        defer { lock.unlock() }
        try begin()
        guard let v = find(key, versionID) else { throw .notFound }
        let total = UInt64(v.body.count)
        guard offset < total else { return (Data(), total) }
        let end = min(total, offset &+ length < offset ? total : offset + length)
        return (v.body.subdata(in: Int(offset) ..< Int(end)), total)
    }

    public func head(_ key: String) throws(StoreError) -> StoredObject {
        lock.lock()
        defer { lock.unlock() }
        try begin()
        guard let v = find(key, nil) else { throw .notFound }
        return Self.object(v)
    }

    public func put(_ key: String, _ bytes: UnsafeRawBufferPointer, condition: PutCondition) throws(StoreError) -> StoredObject {
        lock.lock()
        defer { lock.unlock() }
        try begin()
        switch condition {
        case .none: break
        case .ifAbsent:
            if versionLog { throw .conditionsUnsupported }
            if find(key, nil) != nil { throw .preconditionFailed }
        case .ifMatch(let etag):
            if versionLog { throw .conditionsUnsupported }
            guard let v = find(key, nil), Self.object(v).etag == etag else { throw .preconditionFailed }
        }
        return Self.object(add(key, Data(bytes), marker: false))
    }

    public func list(prefix: String) throws(StoreError) -> [ListedObject] {
        lock.lock()
        defer { lock.unlock() }
        try begin()
        let keys = Set(all.filter { !$0.gone && $0.key.hasPrefix(prefix) }.map(\.key)).sorted()
        return keys.compactMap { k in
            find(k, nil).map { ListedObject(key: k, size: UInt64($0.body.count), lastModified: $0.at, etag: Self.object($0).etag!) }
        }
    }

    public func versions(_ key: String, stopAt: String?, underPrefix: Bool) throws(StoreError) -> [ListedVersion] {
        lock.lock()
        defer { lock.unlock() }
        try begin()
        guard versionLog else { return [] }
        let keys = Set(all.filter { !$0.gone && (underPrefix ? $0.key.hasPrefix(key) : $0.key == key) }.map(\.key)).sorted()
        var out: [ListedVersion] = []
        for k in keys {
            var latest = true
            for v in all.reversed() where !v.gone && v.key == k {
                out.append(ListedVersion(key: k, versionID: v.id, size: v.marker ? 0 : UInt64(v.body.count), lastModified: v.at,
                                         deleteMarker: v.marker, etag: v.marker ? "" : Self.object(v).etag!, isLatest: latest))
                latest = false
            }
        }
        return out
    }

    public func remove(_ key: String, versionID: String?) throws(StoreError) {
        lock.lock()
        defer { lock.unlock() }
        try begin()
        guard let versionID else {
            _ = add(key, Data(), marker: true)
            return
        }
        for i in all.indices where all[i].key == key && all[i].id == versionID { all[i].gone = true }
    }

    public func beginContent(_ key: String, size: UInt64?) throws(StoreError) -> any ContentUpload {
        Upload(bucket: self, key: key)
    }

    final class Upload: ContentUpload, @unchecked Sendable {
        let bucket: MemoryBucket
        let key: String
        var bytes = Data()

        init(bucket: MemoryBucket, key: String) {
            self.bucket = bucket
            self.key = key
        }

        func write(_ chunk: UnsafeRawBufferPointer) throws(StoreError) { bytes.append(contentsOf: chunk) }

        func finish() throws(StoreError) -> StoredObject {
            bucket.lock.lock()
            defer { bucket.lock.unlock() }
            try bucket.begin()
            return MemoryBucket.object(bucket.add(key, bytes, marker: false))
        }

        func abort() { bytes = Data() }
    }
}
