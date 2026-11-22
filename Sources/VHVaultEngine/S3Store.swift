public import Foundation
import CryptoKit
import OSLog

/// A bucket key lent for one request: never kept, never printed.
public struct S3Credentials {
    public let accessKeyID: String
    public let secret: UnsafeRawBufferPointer
    public let bucket: String
    /// `https://s3.us-west-004.backblazeb2.com`; plain `http` only to a loopback address.
    public let endpoint: String
    public let region: String

    public init(accessKeyID: String, secret: UnsafeRawBufferPointer, bucket: String, endpoint: String, region: String) {
        self.accessKeyID = accessKeyID
        self.secret = secret
        self.bucket = bucket
        self.endpoint = endpoint
        self.region = region
    }
}

/// Where the store takes its key from for each request: ``DeviceAccess`` in the app (the cloud's short-lived key,
/// renewed by itself), a fixed key in tests.
public protocol S3CredentialSource: Sendable {
    /// Calls `body` with the key in force; nil when there is none (nothing is sent).
    func withS3Credentials<R: Sendable>(_ body: @Sendable (S3Credentials) throws -> R) async rethrows -> R?
    /// The provider answered 401 or 403: the key is no longer good.
    func providerRefused() async
}

/// A fixed key, for tests and the live test (its secret in a zeroing ``SecretBytes``).
public final class StaticS3Credentials: S3CredentialSource, @unchecked Sendable {
    let accessKeyID: String
    let secret: SecretBytesBox
    let bucket: String
    let endpoint: String
    let region: String
    private let lock = NSLock()
    private var refusals = 0

    public init(accessKeyID: String, secret: Data, bucket: String, endpoint: String, region: String) {
        self.accessKeyID = accessKeyID
        self.secret = SecretBytesBox(secret)
        self.bucket = bucket
        self.endpoint = endpoint
        self.region = region
    }

    public var refusalCount: Int { lock.withLock { refusals } }

    public func withS3Credentials<R: Sendable>(_ body: @Sendable (S3Credentials) throws -> R) async rethrows -> R? {
        try secret.withBytes { s in
            try body(S3Credentials(accessKeyID: accessKeyID, secret: s, bucket: bucket, endpoint: endpoint, region: region))
        }
    }

    public func providerRefused() async { lock.withLock { refusals += 1 } }
}

/// A zeroing copy of a secret (VHCore's ``SecretBytes`` without importing it into public signatures here).
final class SecretBytesBox: @unchecked Sendable {
    private var bytes: [UInt8]
    private let lock = NSLock()
    init(_ data: Data) { bytes = [UInt8](data) }
    deinit { for i in bytes.indices { bytes[i] = 0 } }
    func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try lock.withLock { try bytes.withUnsafeBytes(body) }
    }
}

/// A Desktop-only vault's bucket over S3 (path-style, Signature Version 4 in Swift, ``SigV4``), with the key taken per
/// request from an ``S3CredentialSource``. Whole objects and ranged reads in memory, content objects streamed through a
/// file of sealed bytes (never plaintext) hashed as they arrive and sent in one PUT, or above ``Multipart/threshold`` as
/// a multipart upload (`S3Multipart.swift`), version listings and deletes by version id, and the conditional PUT
/// headers. A 401 or 403 tells the credential source (``DeviceAccess/providerRefusedKey()``); a write
/// whose answer was lost, or that the provider failed with 5xx, is "outcome unknown". Nothing here logs a key, a
/// signature or a body.
public final class S3Store: VaultStore, @unchecked Sendable {
    public let versionLog = true
    let credentials: any S3CredentialSource
    let session: URLSession
    let scratch: URL
    /// The largest single PUT S3, R2 and Backblaze B2 take; a content object above ``Multipart/threshold`` (always
    /// below this) goes up in parts.
    public static let maxSinglePut: UInt64 = 5 << 30
    /// The largest object S3 and R2 take (B2 takes 10 TB): larger content objects are refused before any byte is sent.
    public static let maxObject: UInt64 = 5 << 40
    private static let log = Logger(subsystem: "sh.vaulthalla.app", category: "vault.s3")

    /// How long a request may take (vl-vaultfmt 0.4.0: the store bounds every request and reports a write past a
    /// bound as "outcome unknown"; the values are vaulthalla-server's). A bound cancels the task, which closes the
    /// connection (or resets the HTTP/2 stream), so a stalled PUT can't complete minutes later from this Mac.
    public struct Bounds: Sendable, Equatable {
        /// No byte sent or received for this long fails the request (`timeoutIntervalForRequest`): below 1 byte/s for
        /// 60 s. Every request, content uploads included (they have no total bound: a large file takes what it takes).
        public var noProgress: TimeInterval = 60
        /// A request with a body whose first byte isn't sent within this long (the connection never came up).
        public var connect: TimeInterval = 30
        /// The manifest root PUT, in all: a root whose reply is lost may still land later, below newer roots
        /// (Backblaze orders versions by upload start), so its attempt is cut short and the engine told it is unknown.
        public var rootTotal: TimeInterval = 60
        /// Every other whole-object request (small: manifest segments, envelopes, listings, reads of headers).
        public var smallTotal: TimeInterval? = nil

        public init() {}
    }

    let bounds: Bounds
    let multipart: Multipart
    /// The clock the record of open multipart uploads is kept by (tests move it).
    let now: @Sendable () -> Date
    /// What the multipart path did, for tests (the largest buffer it held, parts sent).
    let stats = MultipartStats()

    /// `scratch`: where streamed uploads gather their sealed bytes (beside the vault's state), and where the record of
    /// this installation's open multipart uploads is kept.
    public convenience init(credentials: any S3CredentialSource, scratch: URL, bounds: Bounds = Bounds(),
                            multipart: Multipart = Multipart()) {
        self.init(credentials: credentials, scratch: scratch, bounds: bounds, multipart: multipart, protocolClasses: nil)
    }

    /// `protocolClasses`: tests answer through a local `URLProtocol`.
    init(credentials: any S3CredentialSource, scratch: URL, bounds: Bounds, multipart: Multipart = Multipart(),
         protocolClasses: [AnyClass]?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.scratch = scratch
        self.bounds = bounds
        self.multipart = multipart
        self.now = now
        let c = URLSessionConfiguration.ephemeral
        if let protocolClasses { c.protocolClasses = protocolClasses }
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = bounds.noProgress
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: requests

    struct Call: Sendable {
        var method: String
        var key: String?
        var query: [(String, String)] = []
        var headers: [(String, String)] = []
        var payloadHash = SigV4.emptyPayloadHash
        var write = false
        /// A streamed content upload: no total bound.
        var content = false
    }

    enum Body: Sendable {
        case none
        case data(Data)
        case file(URL)
    }

    /// Signs `call` with the key in force and sends it within its bounds. Throws only for "no key", transport failures
    /// and bounds; statuses are the caller's to read. Any failure of a write is "outcome unknown": the request may have
    /// reached the provider (a timeout after the body was sent above all), and only the engine can tell.
    func send(_ call: Call, body: Body = .none) throws(StoreError) -> (Data, HTTPURLResponse) {
        let (data, response, _) = try exchange(call, body: body)
        return (data, response)
    }

    /// ``send(_:body:)`` that also says which key signed the request (its access key id), so a multipart upload can
    /// tell a renewed key from the one the provider refused.
    func exchange(_ call: Call, body: Body = .none) throws(StoreError) -> (Data, HTTPURLResponse, String) {
        let date = Date()
        let credentials = credentials
        let signed: Result<Signed?, StoreError> = blocking {
            do {
                return .success(try await credentials.withS3Credentials { c in
                    Signed(request: try Self.request(call, credentials: c, date: date), keyID: c.accessKeyID)
                })
            } catch {
                return .failure(error as? StoreError ?? .failed("the request couldn't be made"))
            }
        }
        guard let signedRequest = try signed.get() else { throw .failed("no storage key is in force on this Mac") }
        var request = signedRequest.request
        let total = call.key == Self.rootKey && call.method == "PUT" ? bounds.rootTotal : (call.content ? nil : bounds.smallTotal)
        let done = DispatchSemaphore(value: 0)
        let watch = Watch()
        let completion: @Sendable (Data?, URLResponse?, (any Error)?) -> Void = { data, response, error in
            watch.finish(data, response, error)
            done.signal()
        }
        let task: URLSessionTask
        switch body {
        case .none: task = session.dataTask(with: request, completionHandler: completion)
        case .data(let d):
            request.httpBody = nil
            task = session.uploadTask(with: request, from: d, completionHandler: completion)
        case .file(let url): task = session.uploadTask(with: request, fromFile: url, completionHandler: completion)
        }
        task.delegate = watch
        if case .none = body {} else {
            Self.boundTimers.asyncAfter(deadline: .now() + bounds.connect) {
                if !watch.sentAny { watch.cut("connect", task) }
            }
        }
        if let total { Self.boundTimers.asyncAfter(deadline: .now() + total) { watch.cut("total", task) } }
        task.resume()
        done.wait()
        let (data, response, error, bound) = watch.result()
        if let http = response as? HTTPURLResponse, error == nil {
            if http.statusCode == 401 || http.statusCode == 403 { blocking { await credentials.providerRefused() } }
            return (data ?? Data(), http, signedRequest.keyID)
        }
        let why: String = if let bound {
            "the storage request passed its \(bound) bound"
        } else {
            (error as? URLError).map { $0.code == .timedOut ? "the storage request made no progress for \(Int(bounds.noProgress)) s"
                : "the storage request failed (\($0.code.rawValue))" } ?? "the storage request failed"
        }
        throw call.write ? .outcomeUnknown(why) : .failed(why)
    }

    static let rootKey = ".vaulthalla/root"

    /// Where the bounds fire: a serial queue of the store's own, so a bound is never late for want of a thread of GCD's
    /// shared (constrained) pool, which the store's callers may hold blocked (see ``BlockingExecutor``).
    static let boundTimers = DispatchQueue(label: "sh.vaulthalla.vault.s3.bounds", qos: .utility)

    struct Signed: Sendable {
        var request: URLRequest
        var keyID: String
    }

    /// The access key id of the key in force (nil: none), never its secret.
    func currentKeyID() -> String? {
        let credentials = credentials
        return blocking { await credentials.withS3Credentials { $0.accessKeyID } }
    }

    /// One task's progress and outcome: whether any body byte went out, and which bound cut it (if one did).
    final class Watch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var sent = false
        private var bound: String?
        private var finished = false
        private var outcome: (Data?, URLResponse?, (any Error)?) = (nil, nil, nil)

        var sentAny: Bool { lock.withLock { sent } }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                        totalBytesExpectedToSend: Int64) {
            lock.withLock { sent = true }
        }

        /// Cancels the task for `name` unless it already finished (the first bound wins).
        func cut(_ name: String, _ task: URLSessionTask) {
            let cutting: Bool = lock.withLock {
                guard !finished, bound == nil else { return false }
                bound = name
                return true
            }
            if cutting { task.cancel() }
        }

        func finish(_ data: Data?, _ response: URLResponse?, _ error: (any Error)?) {
            lock.withLock {
                finished = true
                outcome = (data, response, error)
            }
        }

        func result() -> (Data?, URLResponse?, (any Error)?, String?) {
            lock.withLock { (outcome.0, outcome.1, outcome.2, bound) }
        }
    }

    static func request(_ call: Call, credentials c: S3Credentials, date: Date) throws -> URLRequest {
        guard let base = URLComponents(string: c.endpoint), let scheme = base.scheme, let host = base.host,
              scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
            throw StoreError.failed("the storage endpoint isn't an https address")
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let authority = base.port.map { $0 == defaultPort ? host : "\(host):\($0)" } ?? host
        var path = "/" + SigV4.uriEncode(c.bucket, keepSlash: false)
        if let key = call.key { path += "/" + SigV4.uriEncode(key, keepSlash: true) }
        let query = SigV4.canonicalQuery(call.query)
        guard let url = URL(string: "\(scheme)://\(authority)\(path)\(query.isEmpty ? "" : "?" + query)") else {
            throw StoreError.failed("the storage address couldn't be made")
        }
        var headers = call.headers
        headers.append(("host", authority))
        headers.append(("x-amz-date", SigV4.amzDate(date)))
        headers.append(("x-amz-content-sha256", call.payloadHash))
        let signer = SigV4(accessKeyID: c.accessKeyID, region: c.region)
        let auth = signer.authorization(SigV4.Request(method: call.method, encodedPath: path, query: call.query, headers: headers,
                                                      payloadHash: call.payloadHash, date: date), secret: c.secret)
        var r = URLRequest(url: url)
        r.httpMethod = call.method
        for (name, value) in headers where name != "host" { r.setValue(value, forHTTPHeaderField: name) }
        r.setValue(auth, forHTTPHeaderField: "Authorization")
        return r
    }

    /// The provider's error, in words without anything it echoed (S3 errors repeat the key id and what was signed).
    static func failure(_ data: Data, _ r: HTTPURLResponse) -> String {
        let code = XMLRecords.parse(data, records: []).top["Code"] ?? ""
        return "the storage provider answered \(r.statusCode)\(code.isEmpty ? "" : " \(code)")"
    }

    func expect(_ data: Data, _ r: HTTPURLResponse, write: Bool) throws(StoreError) {
        switch r.statusCode {
        case 200 ..< 300: return
        case 404, 405: throw .notFound
        case 412: throw .preconditionFailed
        case 501: throw .conditionsUnsupported
        case 500...: throw write ? .outcomeUnknown(Self.failure(data, r)) : .failed(Self.failure(data, r))
        default: throw .failed(Self.failure(data, r))
        }
    }

    static func object(_ r: HTTPURLResponse) -> StoredObject {
        StoredObject(etag: r.value(forHTTPHeaderField: "ETag"), versionID: r.value(forHTTPHeaderField: "x-amz-version-id"))
    }

    // MARK: VaultStore

    public func get(_ key: String, versionID: String?) throws(StoreError) -> ObjectBody {
        let (data, r) = try send(Call(method: "GET", key: key, query: versionID.map { [("versionId", $0)] } ?? []))
        try expect(data, r, write: false)
        return ObjectBody(bytes: data, object: Self.object(r))
    }

    public func getRange(_ key: String, versionID: String?, offset: UInt64, length: UInt64) throws(StoreError)
        -> (bytes: Data, total: UInt64)
    {
        let last = length == 0 ? offset : offset + length - 1
        let (data, r) = try send(Call(method: "GET", key: key, query: versionID.map { [("versionId", $0)] } ?? [],
                                      headers: [("range", "bytes=\(offset)-\(last)")]))
        if r.statusCode == 416 {
            // Past the end: nothing, and the size from `bytes */total`.
            guard let total = Self.total(r) else { throw .failed("a range past the end without the object's size") }
            return (Data(), total)
        }
        try expect(data, r, write: false)
        if r.statusCode == 206 {
            guard let total = Self.total(r) else { throw .failed("a ranged answer without Content-Range") }
            return (length == 0 ? Data() : data, total)
        }
        // 200: the whole object.
        let total = UInt64(data.count)
        guard offset < total else { return (Data(), total) }
        return (data.subdata(in: Int(offset) ..< Int(min(total, offset + length))), total)
    }

    static func total(_ r: HTTPURLResponse) -> UInt64? {
        guard let range = r.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") else { return nil }
        return UInt64(range[range.index(after: slash)...])
    }

    public func head(_ key: String) throws(StoreError) -> StoredObject {
        let (data, r) = try send(Call(method: "HEAD", key: key))
        try expect(data, r, write: false)
        return Self.object(r)
    }

    public func put(_ key: String, _ bytes: UnsafeRawBufferPointer, condition: PutCondition) throws(StoreError) -> StoredObject {
        let data = Data(bytes)
        var headers: [(String, String)] = []
        switch condition {
        case .none: break
        case .ifAbsent: headers.append(("if-none-match", "*"))
        case .ifMatch(let etag): headers.append(("if-match", etag))
        }
        let (body, r) = try send(Call(method: "PUT", key: key, headers: headers, payloadHash: SigV4.sha256Hex(data), write: true),
                                 body: .data(data))
        try expect(body, r, write: true)
        return Self.object(r)
    }

    public func list(prefix: String) throws(StoreError) -> [ListedObject] {
        var out: [ListedObject] = []
        var token: String?
        repeat {
            var query = [("list-type", "2"), ("prefix", prefix)]
            if let token { query.append(("continuation-token", token)) }
            let (data, r) = try send(Call(method: "GET", query: query))
            try expect(data, r, write: false)
            let page = XMLRecords.parse(data, records: ["Contents"])
            for c in page.records {
                guard let key = c.fields["Key"] else { continue }
                out.append(ListedObject(key: key, size: UInt64(c.fields["Size"] ?? "") ?? 0,
                                        lastModified: Self.seconds(c.fields["LastModified"]), etag: c.fields["ETag"] ?? ""))
            }
            token = page.top["IsTruncated"] == "true" ? page.top["NextContinuationToken"] : nil
        } while token != nil
        return out
    }

    public func versions(_ key: String, stopAt: String?, underPrefix: Bool) throws(StoreError) -> [ListedVersion] {
        var out: [ListedVersion] = []
        var marker: (key: String, version: String?)?
        repeat {
            var query = [("versions", ""), ("prefix", key)]
            if let marker {
                query.append(("key-marker", marker.key))
                if let v = marker.version { query.append(("version-id-marker", v)) }
            }
            let (data, r) = try send(Call(method: "GET", query: query))
            try expect(data, r, write: false)
            let page = XMLRecords.parse(data, records: ["Version", "DeleteMarker"])
            for v in page.records {
                guard let k = v.fields["Key"], let id = v.fields["VersionId"], underPrefix || k == key else { continue }
                out.append(ListedVersion(key: k, versionID: id, size: UInt64(v.fields["Size"] ?? "") ?? 0,
                                         lastModified: Self.seconds(v.fields["LastModified"]),
                                         deleteMarker: v.element == "DeleteMarker", etag: v.fields["ETag"] ?? "",
                                         isLatest: v.fields["IsLatest"] == "true"))
            }
            if page.top["IsTruncated"] == "true", let next = page.top["NextKeyMarker"] {
                marker = (next, page.top["NextVersionIdMarker"])
            } else {
                marker = nil
            }
        } while marker != nil
        return out
    }

    public func remove(_ key: String, versionID: String?) throws(StoreError) {
        let (data, r) = try send(Call(method: "DELETE", key: key, query: versionID.map { [("versionId", $0)] } ?? [], write: true))
        if r.statusCode == 404 { return }
        try expect(data, r, write: true)
    }

    public func beginContent(_ key: String, size: UInt64?) throws(StoreError) -> any ContentUpload {
        if let size, size > Self.maxObject { throw .failed("a file over 5 TiB can't be sent") }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw .failed("the upload's scratch folder can't be made")
        }
        let url = scratch.appending(path: "upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw .failed("the upload's scratch file can't be made")
        }
        return Upload(store: self, key: key, url: url, handle: handle)
    }

    final class Upload: ContentUpload, @unchecked Sendable {
        let store: S3Store
        let key: String
        let url: URL
        let handle: FileHandle
        var hash = SHA256()
        var size: UInt64 = 0

        init(store: S3Store, key: String, url: URL, handle: FileHandle) {
            self.store = store
            self.key = key
            self.url = url
            self.handle = handle
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ bytes: UnsafeRawBufferPointer) throws(StoreError) {
            size += UInt64(bytes.count)
            guard size <= S3Store.maxObject else { throw .failed("a file over 5 TiB can't be sent") }
            hash.update(bufferPointer: bytes)
            do { try handle.write(contentsOf: Data(bytes)) } catch { throw .failed("the upload's scratch file can't be written") }
        }

        func finish() throws(StoreError) -> StoredObject {
            do { try handle.close() } catch { throw .failed("the upload's scratch file can't be written") }
            defer { try? FileManager.default.removeItem(at: url) }
            // Above the threshold, in parts; at or below it, the one PUT as before.
            if size > store.multipart.threshold { return try store.multipartUpload(key: key, file: url, size: size) }
            let digest = SigV4.hex(hash.finalize())
            let (data, r) = try store.send(Call(method: "PUT", key: key, payloadHash: digest, write: true, content: true),
                                           body: .file(url))
            try store.expect(data, r, write: true)
            return S3Store.object(r)
        }

        func abort() {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func seconds(_ text: String?) -> Int64 {
        guard let text else { return 0 }
        if let d = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return Int64(d.timeIntervalSince1970)
        }
        return (try? Date(text, strategy: .iso8601)).map { Int64($0.timeIntervalSince1970) } ?? 0
    }
}

/// Refuses every redirect: a bucket answers where it was asked, or not at all.
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Runs `op` to completion on a task and waits for it: the store's callbacks are synchronous, the network and the
/// credentials aren't. The task runs on ``BlockingExecutor``'s own threads, never on Swift's cooperative pool, so the
/// wait can't starve the task it waits for whatever thread the caller is on (the engine's queue in the app; a test's
/// cooperative thread: with every pool thread waiting here, a task left to the pool would never run).
package final class BlockingBox<T>: @unchecked Sendable { package var value: T?; package init() {} }

/// Where ``blocking(_:)``'s tasks run: a few serial queues of its own, in turn. Serial queues, not a concurrent one:
/// GCD runs a concurrent queue (as it runs the global ones) on its constrained pool, capped per process at five
/// threads per CPU (`kern.wq_max_constrained_threads`: 15 on a 3-core CI Mac). The store's callers block in that pool
/// (the engine's queue; parts in flight), and with all of it waiting here a task left to it would never run. A serial
/// queue's work runs on a thread outside that cap. The jobs are short (a request signed, a key read).
final class BlockingExecutor: TaskExecutor, @unchecked Sendable {
    static let shared = BlockingExecutor()
    private let queues = (0 ..< 4).map { DispatchQueue(label: "sh.vaulthalla.vault.blocking.\($0)", qos: .utility) }
    private let lock = NSLock()
    private var turn = 0

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let queue = lock.withLock {
            turn = (turn + 1) % queues.count
            return queues[turn]
        }
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

package func blocking<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> T {
    let box = BlockingBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached(executorPreference: BlockingExecutor.shared) {
        box.value = await op()
        done.signal()
    }
    done.wait()
    return box.value!
}

/// S3's XML answers, flat: the records named (`Contents`, `Version`, `DeleteMarker`) with their direct children's
/// text, in document order, and the top level's own fields (`IsTruncated`, `NextContinuationToken`, `Code`...).
struct XMLRecords {
    struct Record {
        var element: String
        var fields: [String: String] = [:]
    }

    var records: [Record] = []
    var top: [String: String] = [:]

    static func parse(_ data: Data, records names: Set<String>) -> XMLRecords {
        let delegate = Delegate(names: names)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return delegate.result
    }

    final class Delegate: NSObject, XMLParserDelegate {
        let names: Set<String>
        var result = XMLRecords()
        var current: Record?
        var depth = 0
        var recordDepth = 0
        var text = ""

        init(names: Set<String>) { self.names = names }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            depth += 1
            text = ""
            if current == nil, names.contains(name) {
                current = Record(element: name)
                recordDepth = depth
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if var record = current {
                if depth == recordDepth {
                    result.records.append(record)
                    current = nil
                } else if depth == recordDepth + 1 {
                    record.fields[name] = text
                    current = record
                }
            } else if depth == 2 {
                result.top[name] = text
            }
            text = ""
            depth -= 1
        }
    }
}
