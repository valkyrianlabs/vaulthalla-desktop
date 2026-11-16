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
/// file of sealed bytes (never plaintext) hashed as they arrive, version listings and deletes by version id, and the
/// conditional PUT headers. A 401 or 403 tells the credential source (``DeviceAccess/providerRefusedKey()``); a write
/// whose answer was lost, or that the provider failed with 5xx, is "outcome unknown". Nothing here logs a key, a
/// signature or a body.
public final class S3Store: VaultStore, @unchecked Sendable {
    public let versionLog = true
    let credentials: any S3CredentialSource
    let session: URLSession
    let scratch: URL
    /// The largest single PUT S3 takes; larger content objects are refused before any byte is sent.
    public static let maxSinglePut: UInt64 = 5 << 30
    private static let log = Logger(subsystem: "sh.vaulthalla.app", category: "vault.s3")

    /// `scratch`: where streamed uploads gather their sealed bytes (beside the vault's state).
    public init(credentials: any S3CredentialSource, scratch: URL, timeout: TimeInterval = 120) {
        self.credentials = credentials
        self.scratch = scratch
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = timeout
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
    }

    enum Body: Sendable {
        case none
        case data(Data)
        case file(URL)
    }

    /// Signs `call` with the key in force and sends it. Throws only for "no key" and transport failures; statuses are
    /// the caller's to read.
    func send(_ call: Call, body: Body = .none) throws(StoreError) -> (Data, HTTPURLResponse) {
        let outcome: Result<(Data, HTTPURLResponse), StoreError> = blocking { [credentials, session] () async -> Result<(Data, HTTPURLResponse), StoreError> in
            let date = Date()
            let signed: URLRequest?
            do {
                signed = try await credentials.withS3Credentials { c in try Self.request(call, credentials: c, date: date) }
            } catch {
                return .failure(error as? StoreError ?? .failed("the request couldn't be made"))
            }
            guard var request = signed else { return .failure(.failed("no storage key is in force on this Mac")) }
            do {
                let (data, response): (Data, URLResponse)
                switch body {
                case .none: (data, response) = try await session.data(for: request)
                case .data(let d):
                    request.httpBody = nil
                    (data, response) = try await session.upload(for: request, from: d)
                case .file(let url): (data, response) = try await session.upload(for: request, fromFile: url)
                }
                guard let http = response as? HTTPURLResponse else { return .failure(.failed("not an HTTP answer")) }
                if http.statusCode == 401 || http.statusCode == 403 { await credentials.providerRefused() }
                return .success((data, http))
            } catch {
                let why = (error as? URLError).map { "the storage request failed (\($0.code.rawValue))" } ?? "the storage request failed"
                return .failure(call.write ? .outcomeUnknown(why) : .failed(why))
            }
        }
        return try outcome.get()
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
        if let size, size > Self.maxSinglePut { throw .failed("a file over 5 GiB can't be sent yet") }
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
            guard size <= S3Store.maxSinglePut else { throw .failed("a file over 5 GiB can't be sent yet") }
            hash.update(bufferPointer: bytes)
            do { try handle.write(contentsOf: Data(bytes)) } catch { throw .failed("the upload's scratch file can't be written") }
        }

        func finish() throws(StoreError) -> StoredObject {
            do { try handle.close() } catch { throw .failed("the upload's scratch file can't be written") }
            defer { try? FileManager.default.removeItem(at: url) }
            let digest = SigV4.hex(hash.finalize())
            let (data, r) = try store.send(Call(method: "PUT", key: key, payloadHash: digest, write: true), body: .file(url))
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

/// Runs `op` to completion on a task and waits for it. Only for threads outside Swift's cooperative pool (the engine's
/// queue): the store's callbacks are synchronous, the network isn't.
final class BlockingBox<T>: @unchecked Sendable { var value: T? }

func blocking<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> T {
    let box = BlockingBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
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
