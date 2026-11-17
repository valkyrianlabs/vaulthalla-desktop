import CryptoKit
public import Foundation
import OSLog
import VLVaultfmt

// Multipart uploads of content objects (docs/desktop-vaults.md, "Multipart uploads"). The engine hands a content object
// over as a stream of sealed bytes and takes back its ETag and version id (vl_vaultfmt_engine.h `content_*`; always a
// plain PUT: no condition, the manifest names the version the upload produced). `S3Store.Upload` gathers the bytes in
// a scratch file as before; at `finish`, an object above `Multipart.threshold` goes up as one multipart upload:
//
//   1. CreateMultipartUpload; its upload id recorded on this Mac (`MultipartJournal`) before any part is sent;
//   2. the parts, `vl_vaultfmt_part_size` each (the format's own rule, as servers use it), each read from the scratch
//      file through a buffer of `Multipart.chunk` bytes into a part file, signed with its SHA-256 as the SigV4 payload
//      hash (which the provider checks), `Multipart.concurrency` at a time, each retried up to `Multipart.attempts`;
//   3. CompleteMultipartUpload naming every part's ETag as the provider answered it (a wrong one is refused);
//   4. a HEAD of the version the completion named: its size and ETag must be what was sent and answered;
//   5. the record removed.
//
// A failure before the completion is sent aborts the upload (nothing can have landed: `failed`). A completion whose
// answer is lost (a transport failure, a bound, a 5xx, or S3's 200 carrying an error) is "outcome unknown", never a
// guess: the store aborts the upload in case it didn't take (an abort can't remove a completed object) and the engine
// records nothing, exactly as after a lost single PUT reply. An upload the abort couldn't reach stays recorded, and the
// next open aborts it once it is `Multipart.staleAge` old (`cleanUpAbandonedUploads`).

extension S3Store {
    /// How content objects above the threshold go up. The defaults are the app's; tests lower the sizes.
    public struct Multipart: Sendable, Equatable {
        /// Sealed objects larger than this go up in parts; at or below it, in one PUT exactly as before.
        public var threshold: UInt64 = 64 << 20
        /// A fixed part size (tests); nil: `vl_vaultfmt_part_size` of the object's size (5 MiB up to 48.8 GiB, then
        /// whatever keeps the count at 10,000), the same rule vaulthalla-server uploads by.
        public var partSize: UInt64?
        /// Parts in flight at once.
        public var concurrency = 4
        /// Tries of each request that may be repeated (a part, the creation, the abort, the HEAD).
        public var attempts = 4
        /// The wait before the second try, doubled before each later one.
        public var retryDelay: TimeInterval = 2
        /// The largest buffer a part is read through.
        public var chunk = 1 << 20
        /// How old a recorded upload must be before an open aborts it.
        public var staleAge: TimeInterval = 24 * 3600

        public init() {}
    }

    /// S3's limits (Backblaze B2's S3 API and R2 have the same): parts of 5 MiB to 5 GiB but the last, 10,000 of them.
    static let maxPartSize: UInt64 = 5 << 30
    static let maxParts: UInt64 = 10_000

    func partSize(for size: UInt64) -> UInt64 { multipart.partSize ?? vl_vaultfmt_part_size(size) }

    // MARK: one upload

    func multipartUpload(key: String, file: URL, size: UInt64) throws(StoreError) -> StoredObject {
        let part = partSize(for: size)
        let count = (size + part - 1) / part
        guard part > 0, part <= Self.maxPartSize, count <= Self.maxParts else {
            throw .failed("a file of this size can't be sent in parts")
        }
        let uploadID = try createUpload(key: key)
        let journal = MultipartJournal(directory: scratch)
        let record = MultipartJournal.Record(key: key, uploadID: uploadID, started: now().timeIntervalSince1970)
        guard journal.add(record) else {
            abortUpload(key: key, uploadID: uploadID, journal: journal)
            throw .failed("the upload's record can't be written on this Mac")
        }
        let etags: [String]
        do throws(StoreError) {
            etags = try uploadParts(key: key, uploadID: uploadID, file: file, size: size, part: part, count: Int(count))
        } catch {
            // No completion was sent, so no object can exist: the upload failed, whatever a part met.
            abortUpload(key: key, uploadID: uploadID, journal: journal)
            throw .failed(Self.message(error))
        }
        let completed: StoredObject
        do throws(StoreError) {
            completed = try complete(key: key, uploadID: uploadID, etags: etags)
        } catch {
            // A refusal of the completion means it wasn't done; an unknown outcome may have landed or not. Either way
            // the upload is aborted: if it completed, the abort finds no upload and changes nothing.
            abortUpload(key: key, uploadID: uploadID, journal: journal)
            throw error
        }
        journal.remove(record)
        return try verify(key: key, completed: completed, size: size)
    }

    private func createUpload(key: String) throws(StoreError) -> String {
        // Not a write of the object: an upload whose creation answer was lost holds no part and bills nothing.
        let (data, r) = try attempt(Call(method: "POST", key: key, query: [("uploads", "")]))
        guard (200 ..< 300).contains(r.statusCode) else { throw .failed(Self.failure(data, r)) }
        guard let id = XMLRecords.parse(data, records: []).top["UploadId"], !id.isEmpty else {
            throw .failed("the storage provider started an upload without naming it")
        }
        return id
    }

    private func uploadParts(key: String, uploadID: String, file: URL, size: UInt64, part: UInt64, count: Int)
        throws(StoreError) -> [String]
    {
        let state = PartQueue(count: count)
        let group = DispatchGroup()
        for _ in 0 ..< max(1, min(multipart.concurrency, count)) {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                while let n = state.next() {
                    let offset = UInt64(n) * part
                    do throws(StoreError) {
                        let etag = try self.uploadPart(key: key, uploadID: uploadID, file: file, number: n + 1, offset: offset,
                                                       length: min(part, size - offset))
                        state.done(n, etag)
                    } catch {
                        state.fail(error)
                    }
                }
            }
        }
        group.wait()
        return try state.result()
    }

    private func uploadPart(key: String, uploadID: String, file: URL, number: Int, offset: UInt64, length: UInt64)
        throws(StoreError) -> String
    {
        let partURL = scratch.appending(path: "part-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: partURL) }
        let digest = try copyPart(from: file, offset: offset, length: length, to: partURL)
        let (data, r) = try attempt(Call(method: "PUT", key: key, query: [("partNumber", "\(number)"), ("uploadId", uploadID)],
                                         payloadHash: digest, write: true, content: true), body: .file(partURL))
        guard (200 ..< 300).contains(r.statusCode) else { throw .failed(Self.failure(data, r)) }
        guard let etag = r.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
            throw .failed("the storage provider took a part without naming it")
        }
        stats.partSent()
        return etag
    }

    /// The part's bytes into their own file through one buffer of at most `chunk` bytes, and their SHA-256.
    private func copyPart(from file: URL, offset: UInt64, length: UInt64, to partURL: URL) throws(StoreError) -> String {
        guard FileManager.default.createFile(atPath: partURL.path(percentEncoded: false), contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let out = try? FileHandle(forWritingTo: partURL), let input = try? FileHandle(forReadingFrom: file) else {
            throw .failed("the upload's scratch file can't be read")
        }
        defer {
            try? out.close()
            try? input.close()
        }
        var hash = SHA256()
        var left = length
        do {
            try input.seek(toOffset: offset)
            while left > 0 {
                guard let chunk = try input.read(upToCount: Int(min(UInt64(multipart.chunk), left))), !chunk.isEmpty else {
                    throw StoreError.failed("the upload's scratch file ended early")
                }
                stats.held(chunk.count)
                hash.update(data: chunk)
                try out.write(contentsOf: chunk)
                left -= UInt64(chunk.count)
            }
        } catch {
            throw error as? StoreError ?? .failed("the upload's scratch file can't be read")
        }
        return SigV4.hex(hash.finalize())
    }

    private func complete(key: String, uploadID: String, etags: [String]) throws(StoreError) -> StoredObject {
        var xml = "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        for (i, etag) in etags.enumerated() {
            xml += "<Part><PartNumber>\(i + 1)</PartNumber><ETag>\(Self.escaped(etag))</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        let body = Data(xml.utf8)
        let call = Call(method: "POST", key: key, query: [("uploadId", uploadID)], headers: [("content-type", "application/xml")],
                        payloadHash: SigV4.sha256Hex(body), write: true, content: true)
        // Sent again only after a refusal, and only with another key: a refused request was never carried out. Any
        // failure in transit is "outcome unknown" (send) and isn't repeated.
        var (data, r, used) = try exchange(call, body: .data(body))
        if r.statusCode == 401 || r.statusCode == 403, waitForAnotherKey(than: used) {
            (data, r, used) = try exchange(call, body: .data(body))
        }
        switch r.statusCode {
        case 200 ..< 300:
            let answer = XMLRecords.parse(data, records: [])
            // S3 may answer 200 and then report a failure in the body: whether the object exists isn't known.
            guard answer.top["Code"] == nil, let etag = answer.top["ETag"], !etag.isEmpty else {
                throw .outcomeUnknown("the storage provider's answer to the upload's completion carried no object")
            }
            return StoredObject(etag: Self.quoted(etag), versionID: r.value(forHTTPHeaderField: "x-amz-version-id"))
        case 500...: throw .outcomeUnknown(Self.failure(data, r))
        default: throw .failed(Self.failure(data, r))  // refused (InvalidPart, EntityTooSmall, NoSuchUpload...): not done
        }
    }

    /// The completed object is what was sent: its size, and the ETag and version the completion answered. A completion
    /// that named no version takes the HEAD's when the ETag (the digest of this upload's parts) is the completion's.
    private func verify(key: String, completed: StoredObject, size: UInt64) throws(StoreError) -> StoredObject {
        let query = completed.versionID.map { [("versionId", $0)] } ?? []
        let (data, r): (Data, HTTPURLResponse)
        do throws(StoreError) {
            (data, r) = try attempt(Call(method: "HEAD", key: key, query: query))
        } catch {
            throw .outcomeUnknown("the uploaded file couldn't be checked: \(Self.message(error))")
        }
        guard (200 ..< 300).contains(r.statusCode) else {
            throw .outcomeUnknown("the uploaded file couldn't be checked: \(Self.failure(data, r))")
        }
        let length = r.value(forHTTPHeaderField: "Content-Length").flatMap { UInt64($0) }
        let etag = r.value(forHTTPHeaderField: "ETag")
        let version = r.value(forHTTPHeaderField: "x-amz-version-id")
        let sameETag = etag.map { Self.unquoted($0) == Self.unquoted(completed.etag ?? "") }
        guard length == size, sameETag != false,
              completed.versionID == nil || version == nil || version == completed.versionID else {
            Self.multipartLog.error("a completed upload isn't what was sent (size \(length.map(String.init) ?? "-", privacy: .public))")
            throw .failed("the uploaded file isn't what this Mac sent")
        }
        return StoredObject(etag: completed.etag, versionID: completed.versionID ?? (sameETag == true ? version : nil))
    }

    static func quoted(_ etag: String) -> String { etag.hasPrefix("\"") ? etag : "\"\(etag)\"" }
    static func unquoted(_ etag: String) -> String { etag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }

    /// Aborts `uploadID` (best effort) and forgets its record once the provider has no such upload any more.
    func abortUpload(key: String, uploadID: String, journal: MultipartJournal) {
        do throws(StoreError) {
            let (data, r) = try attempt(Call(method: "DELETE", key: key, query: [("uploadId", uploadID)], write: true))
            if (200 ..< 300).contains(r.statusCode) || r.statusCode == 404 {
                journal.remove(uploadID: uploadID)
            } else {
                Self.multipartLog.error("an upload couldn't be aborted: \(Self.failure(data, r), privacy: .public)")
            }
        } catch {
            Self.multipartLog.error("an upload couldn't be aborted: \(Self.message(error), privacy: .public)")
        }
    }

    // MARK: retries

    /// `call`, tried up to `Multipart.attempts` times while the failure says nothing that matters landed or the provider
    /// asks for another try: a transport failure or a bound, a 5xx, S3's RequestTimeout, BadDigest,
    /// XAmzContentSHA256Mismatch, SlowDown, or a 401/403 once another key is in force (a renewal; the refused key is
    /// never sent again). The last answer is returned for the caller to read, or the last failure thrown. Only for
    /// requests that may be repeated: a part (the same number again replaces it), the creation, the abort, a HEAD.
    func attempt(_ call: Call, body: Body = .none) throws(StoreError) -> (Data, HTTPURLResponse) {
        var last: Result<(Data, HTTPURLResponse), StoreError> = .failure(.failed("the storage request wasn't sent"))
        var refused: String?
        for i in 0 ..< max(1, multipart.attempts) {
            if i > 0 { Thread.sleep(forTimeInterval: multipart.retryDelay * Double(1 << (i - 1))) }
            if let refused, (currentKeyID() ?? refused) == refused { continue }  // no other key yet
            let data: Data, r: HTTPURLResponse, used: String
            do {
                (data, r, used) = try exchange(call, body: body)
            } catch {
                last = .failure(error)
                continue
            }
            last = .success((data, r))
            switch r.statusCode {
            case 200 ..< 300: return (data, r)
            case 401, 403: refused = used
            case 500...: continue
            case 400 where Self.retryable.contains(XMLRecords.parse(data, records: []).top["Code"] ?? ""): continue
            default: return (data, r)
            }
        }
        return try last.get()
    }

    static let retryable: Set<String> = ["RequestTimeout", "BadDigest", "XAmzContentSHA256Mismatch", "SlowDown", "InternalError"]

    /// Waits as `attempt` does for a key other than `used` to be in force.
    private func waitForAnotherKey(than used: String) -> Bool {
        for i in 0 ..< max(1, multipart.attempts - 1) {
            Thread.sleep(forTimeInterval: multipart.retryDelay * Double(1 << i))
            if let key = currentKeyID(), key != used { return true }
        }
        return false
    }

    static func message(_ e: StoreError) -> String {
        switch e {
        case .failed(let m), .outcomeUnknown(let m): m
        case .notFound: "not found"
        case .preconditionFailed: "a precondition failed"
        case .conditionsUnsupported: "conditions unsupported"
        }
    }

    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let multipartLog = Logger(subsystem: "sh.vaulthalla.app", category: "vault.s3.multipart")

    // MARK: uploads left behind

    /// Aborts the uploads this installation recorded for this vault's bucket that are still open at the provider and
    /// at least `Multipart.staleAge` old by both this Mac's record and the provider's `Initiated`. An upload this Mac
    /// didn't record (another writer's, or anything else in the bucket) is never touched; a completed object never is
    /// (only open uploads are listed, and an abort can't remove an object). Records of uploads the provider no longer
    /// lists are forgotten.
    public func cleanUpAbandonedUploads() {
        let journal = MultipartJournal(directory: scratch)
        let records = journal.records()
        guard !records.isEmpty else { return }
        let t = now().timeIntervalSince1970
        let stale = records.filter { t - $0.started >= multipart.staleAge }
        guard !stale.isEmpty else { return }
        let open: [OpenUpload]
        do throws(StoreError) { open = try listUploads(prefix: "o/") } catch {
            Self.multipartLog.info("open uploads couldn't be listed: \(Self.message(error), privacy: .public)")
            return
        }
        for record in stale {
            guard let listed = open.first(where: { $0.uploadID == record.uploadID }) else {
                journal.remove(record)  // completed or aborted: nothing to do
                continue
            }
            guard listed.key == record.key, listed.initiated.map({ t - $0 >= multipart.staleAge }) ?? true else { continue }
            abortUpload(key: record.key, uploadID: record.uploadID, journal: journal)
        }
    }

    struct OpenUpload: Sendable, Equatable {
        var key: String
        var uploadID: String
        /// Unix seconds (nil when the provider's time didn't parse).
        var initiated: Double?
    }

    /// ListMultipartUploads under `prefix`, every page.
    func listUploads(prefix: String) throws(StoreError) -> [OpenUpload] {
        var out: [OpenUpload] = []
        var marker: (key: String, upload: String?)?
        repeat {
            var query = [("uploads", ""), ("prefix", prefix)]
            if let marker {
                query.append(("key-marker", marker.key))
                if let u = marker.upload { query.append(("upload-id-marker", u)) }
            }
            let (data, r) = try send(Call(method: "GET", query: query))
            try expect(data, r, write: false)
            let page = XMLRecords.parse(data, records: ["Upload"])
            for u in page.records {
                guard let key = u.fields["Key"], let id = u.fields["UploadId"] else { continue }
                let initiated = u.fields["Initiated"].flatMap { t in
                    (try? Date(t, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                        ?? (try? Date(t, strategy: .iso8601))
                }
                out.append(OpenUpload(key: key, uploadID: id, initiated: initiated?.timeIntervalSince1970))
            }
            if page.top["IsTruncated"] == "true", let next = page.top["NextKeyMarker"] {
                marker = (next, page.top["NextUploadIdMarker"])
            } else {
                marker = nil
            }
        } while marker != nil
        return out
    }
}

/// The parts of one upload: which to send next, their ETags, and the first failure (after which no new part starts).
final class PartQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIndex = 0
    private var etags: [String?]
    private var failure: StoreError?

    init(count: Int) { etags = Array(repeating: nil, count: count) }

    func next() -> Int? {
        lock.withLock {
            guard failure == nil, nextIndex < etags.count else { return nil }
            defer { nextIndex += 1 }
            return nextIndex
        }
    }

    func done(_ n: Int, _ etag: String) { lock.withLock { etags[n] = etag } }
    func fail(_ e: StoreError) { lock.withLock { if failure == nil { failure = e } } }

    func result() throws(StoreError) -> [String] {
        let (failure, etags) = lock.withLock { (self.failure, self.etags) }
        if let failure { throw failure }
        let all = etags.compactMap { $0 }
        guard all.count == etags.count else { throw .failed("a part of the upload wasn't sent") }
        return all
    }
}

/// What the multipart path did, for tests.
final class MultipartStats: @unchecked Sendable {
    private let lock = NSLock()
    private var largest = 0
    private var parts = 0
    var largestBuffer: Int { lock.withLock { largest } }
    var partsSent: Int { lock.withLock { parts } }
    func held(_ n: Int) { lock.withLock { largest = max(largest, n) } }
    func partSent() { lock.withLock { parts += 1 } }
}

/// This installation's open multipart uploads for one vault: a file per upload in the vault's scratch folder
/// (`multipart/`, beside the sealed bytes), written before any part is sent and removed once the provider has no
/// such upload. Only what is recorded here is ever aborted by ``S3Store/cleanUpAbandonedUploads()``.
struct MultipartJournal {
    struct Record: Codable, Equatable {
        var key: String
        var uploadID: String
        /// Unix seconds, by this Mac's clock.
        var started: Double
    }

    let directory: URL

    init(directory scratch: URL) { directory = scratch.appending(path: "multipart", directoryHint: .isDirectory) }

    private func url(_ uploadID: String) -> URL {
        let name = SHA256.hash(data: Data(uploadID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).json")
    }

    /// Durable before it returns true.
    func add(_ r: Record) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(r)
            let target = url(r.uploadID)
            let tmp = directory.appending(path: ".\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: tmp.path(percentEncoded: false), contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else { return false }
            let h = try FileHandle(forWritingTo: tmp)
            try h.write(contentsOf: data)
            try h.synchronize()
            try h.close()
            guard rename(tmp.path(percentEncoded: false), target.path(percentEncoded: false)) == 0 else {
                try? FileManager.default.removeItem(at: tmp)
                return false
            }
            return true
        } catch {
            return false
        }
    }

    func remove(_ r: Record) { remove(uploadID: r.uploadID) }
    func remove(uploadID: String) { try? FileManager.default.removeItem(at: url(uploadID)) }

    func records() -> [Record] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { u in
            (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        }
    }
}
