import CryptoKit
public import Foundation

/// An in-memory versioned bucket that answers as Backblaze B2 does for a Desktop-only vault (version_log: every PUT a
/// new version, conditional PUTs refused with "not implemented", a DELETE by name a delete marker, and a key's versions
/// ordered by when their upload *started*: ``loseNextPut(keyPrefix:)`` and ``landLost()`` make a PUT whose reply was lost
/// complete later, below versions written since, as measured on Backblaze on 2026-11-16), the same double as
/// vl-vaultfmt's `tests/c_engine_lifecycle.c` bucket. For tests and previews; shared by every vault handle given it, so
/// two handles read what the other wrote. Multipart uploads follow S3's documented behaviour (below), for the tests that
/// put ``S3Store`` in front of this bucket.
public final class MemoryBucket: VaultStore, @unchecked Sendable {
    struct Version {
        var key: String
        var id: String
        var body: Data
        var marker: Bool
        var gone = false
        var at: Int64
        /// A completed multipart upload's ETag (S3's digest of the parts' digests); nil: the bucket's own form.
        var etag: String?
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
    private var losing: String?
    private var lost: [Version] = []

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

    private static func object(_ v: Version) -> StoredObject { StoredObject(etag: v.etag ?? "\"e\(v.id)\"", versionID: v.id) }

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
        if let prefix = losing, key.hasPrefix(prefix) {
            // The upload starts now (its place in the order), its reply never arrives, it completes later.
            losing = nil
            seq += 1
            lost.append(Version(key: key, id: String(format: "v%06d", seq), body: Data(bytes), marker: false,
                                at: 1_800_000_000 + Int64(seq)))
            throw .outcomeUnknown("the reply was lost")
        }
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

    /// The next PUT of a key under `keyPrefix` loses its reply (``StoreError/outcomeUnknown(_:)``) and stays in flight.
    public func loseNextPut(keyPrefix: String) { lock.withLock { losing = keyPrefix } }

    /// The PUTs in flight complete, each in the place its start gave it (below anything started after it).
    public func landLost() {
        lock.withLock {
            for v in lost {
                let i = all.firstIndex { Int($0.id.dropFirst())! > Int(v.id.dropFirst())! } ?? all.count
                all.insert(v, at: i)
            }
            lost = []
        }
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

    // MARK: multipart uploads (S3's CreateMultipartUpload, UploadPart, CompleteMultipartUpload, AbortMultipartUpload,
    // ListMultipartUploads as documented; Backblaze B2's S3 API has the same limits)

    /// What S3 answers a multipart request it refuses with: the HTTP status and the error code.
    public enum MultipartFailure: Error, Equatable, Sendable {
        case noSuchUpload, invalidPart, invalidPartOrder, entityTooSmall, entityTooLarge, invalidArgument, malformedXML

        public var code: String {
            switch self {
            case .noSuchUpload: "NoSuchUpload"
            case .invalidPart: "InvalidPart"
            case .invalidPartOrder: "InvalidPartOrder"
            case .entityTooSmall: "EntityTooSmall"
            case .entityTooLarge: "EntityTooLarge"
            case .invalidArgument: "InvalidArgument"
            case .malformedXML: "MalformedXML"
            }
        }

        public var status: Int { self == .noSuchUpload ? 404 : 400 }
    }

    public struct OpenUpload: Sendable, Equatable {
        public var key: String
        public var uploadID: String
        /// Unix seconds.
        public var initiated: Int64
    }

    struct Pending {
        var key: String
        var initiated: Int64
        /// The upload's place in the order of the key's versions: Backblaze orders a large file by when it started.
        var seq: Int
        var parts: [Int: (etag: String, body: Data)] = [:]
    }

    /// Every part but the last must be at least this large when the upload completes (S3: 5 MiB; tests lower it).
    public var minimumPartSize: UInt64 {
        get { lock.withLock { minimumPart } }
        set { lock.withLock { minimumPart = newValue } }
    }
    private var minimumPart: UInt64 = 5 << 20
    private var pending: [String: Pending] = [:]
    private var uploadSeq = 0

    static func md5(_ d: Data) -> Data { Data(Insecure.MD5.hash(data: d)) }
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// CreateMultipartUpload: a new upload id (`initiated`: Unix seconds, the bucket's clock by default).
    public func createMultipartUpload(_ key: String, initiated: Int64? = nil) -> String {
        lock.withLock {
            requests += 1
            uploadSeq += 1
            seq += 1
            let id = "upload-\(uploadSeq)-\(UUID().uuidString.prefix(8))"
            pending[id] = Pending(key: key, initiated: initiated ?? Int64(Date().timeIntervalSince1970), seq: seq)
            return id
        }
    }

    /// UploadPart: the part's ETag (the quoted MD5 of its bytes). The same number again replaces the part.
    public func uploadPart(_ key: String, uploadID: String, partNumber: Int, _ body: Data) throws(MultipartFailure) -> String {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        guard pending[uploadID]?.key == key else { throw .noSuchUpload }
        guard (1 ... 10_000).contains(partNumber) else { throw .invalidArgument }
        guard UInt64(body.count) <= 5 << 30 else { throw .entityTooLarge }
        let etag = "\"\(Self.hex(Self.md5(body)))\""
        pending[uploadID]!.parts[partNumber] = (etag, body)
        return etag
    }

    /// CompleteMultipartUpload with the parts named (ascending numbers, each with the ETag its upload answered): a new
    /// version of `key` whose ETag is the MD5 of the parts' MD5s, a dash and their count. Parts not named are dropped.
    public func completeMultipartUpload(_ key: String, uploadID: String, parts: [(number: Int, etag: String)])
        throws(MultipartFailure) -> StoredObject
    {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        guard let upload = pending[uploadID], upload.key == key else { throw .noSuchUpload }
        guard !parts.isEmpty else { throw .malformedXML }
        guard zip(parts, parts.dropFirst()).allSatisfy({ $0.number < $1.number }) else { throw .invalidPartOrder }
        var body = Data()
        var digests = Data()
        for (i, p) in parts.enumerated() {
            guard let stored = upload.parts[p.number], Self.unquote(stored.etag) == Self.unquote(p.etag) else { throw .invalidPart }
            if i < parts.count - 1, UInt64(stored.body.count) < minimumPart { throw .entityTooSmall }
            body.append(stored.body)
            digests.append(Self.md5(stored.body))
        }
        pending[uploadID] = nil
        let v = Version(key: key, id: String(format: "v%06d", upload.seq), body: body, marker: false,
                        at: 1_800_000_000 + Int64(upload.seq), etag: "\"\(Self.hex(Self.md5(digests)))-\(parts.count)\"")
        let i = all.firstIndex { Int($0.id.dropFirst())! > upload.seq } ?? all.count
        all.insert(v, at: i)
        return Self.object(v)
    }

    /// AbortMultipartUpload: the upload and its parts are gone; an upload that isn't open (completed, aborted) is
    /// NoSuchUpload, and nothing else changes.
    public func abortMultipartUpload(_ key: String, uploadID: String) throws(MultipartFailure) {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        guard pending[uploadID]?.key == key else { throw .noSuchUpload }
        pending[uploadID] = nil
    }

    /// ListMultipartUploads: the open uploads under `prefix`, by key then upload id.
    public func multipartUploads(prefix: String = "") -> [OpenUpload] {
        lock.withLock {
            pending.filter { $0.value.key.hasPrefix(prefix) }
                .map { OpenUpload(key: $0.value.key, uploadID: $0.key, initiated: $0.value.initiated) }
                .sorted { ($0.key, $0.uploadID) < ($1.key, $1.uploadID) }
        }
    }

    /// HEAD of a version (or the current object): its identity and size.
    public func head(_ key: String, versionID: String?) throws(StoreError) -> (object: StoredObject, size: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        try begin()
        guard let v = find(key, versionID) else { throw .notFound }
        return (Self.object(v), UInt64(v.body.count))
    }

    static func unquote(_ e: String) -> String { e.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
}
