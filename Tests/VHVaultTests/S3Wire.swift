import CryptoKit
import Foundation
@testable import VHVaultEngine

/// The S3 REST API in front of a ``MemoryBucket``, as a local `URLProtocol`: path-style requests to
/// `https://s3.wire.test/<bucket>/<key>`, the access key id checked against the endpoint's keys (403 otherwise), the
/// signed payload hash checked against the body (400 XAmzContentSHA256Mismatch), and faults injected per request.
/// Endpoints are registered under a bucket name of their own, so suites may run in parallel.
final class S3Wire: URLProtocol, @unchecked Sendable {
    struct Logged: Sendable {
        var method: String
        var key: String?
        var query: [String: String]
        var headers: [String: String]
        var body: Data
        var keyID: String
        var partNumber: Int? { query["partNumber"].flatMap(Int.init) }
        var isComplete: Bool { method == "POST" && query["uploadId"] != nil }
    }

    enum Fault {
        case status(Int, code: String)
        /// The connection drops before the request is carried out.
        case dropBefore
        /// The request is carried out, and its answer lost.
        case dropAfter
        /// Carried out; the answer's ETag header replaced.
        case etag(String)
    }

    final class Endpoint: @unchecked Sendable {
        let name: String
        let bucket: MemoryBucket
        private let lock = NSLock()
        private var allowed: Set<String>
        private var logged: [Logged] = []
        private var inFlight = 0
        private var peak = 0
        var hook: (@Sendable (Logged) -> Fault?)?
        /// How long a part takes to answer (to see concurrency).
        var partDelay: TimeInterval = 0

        init(name: String, bucket: MemoryBucket, keys: Set<String>) {
            self.name = name
            self.bucket = bucket
            allowed = keys
        }

        var keys: Set<String> {
            get { lock.withLock { allowed } }
            set { lock.withLock { allowed = newValue } }
        }

        var log: [Logged] { lock.withLock { logged } }
        var peakParts: Int { lock.withLock { peak } }
        func record(_ l: Logged) { lock.withLock { logged.append(l) } }
        func partStarted() { lock.withLock { inFlight += 1; peak = max(peak, inFlight) } }
        func partEnded() { lock.withLock { inFlight -= 1 } }
    }

    nonisolated(unsafe) private static var endpoints: [String: Endpoint] = [:]
    private static let lock = NSLock()

    static let endpointURL = "https://s3.wire.test"

    static func register(bucket: MemoryBucket, keys: Set<String>) -> Endpoint {
        let e = Endpoint(name: "wire-\(UUID().uuidString.lowercased().prefix(12))", bucket: bucket, keys: keys)
        lock.withLock { endpoints[e.name] = e }
        return e
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let request = request
        DispatchQueue.global().async { [self] in handle(request) }
    }

    private func respond(_ status: Int, _ headers: [String: String] = [:], _ body: Data = Data()) {
        let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func error(_ status: Int, _ code: String) {
        respond(status, ["Content-Type": "application/xml"], Data("<Error><Code>\(code)</Code><Message>m</Message></Error>".utf8))
    }

    private static func body(of r: URLRequest) -> Data {
        if let b = r.httpBody { return b }
        guard let s = r.httpBodyStream else { return Data() }
        s.open()
        defer { s.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = s.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            out.append(buffer, count: n)
        }
        return out
    }

    static func iso(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(.iso8601)
    }

    private func handle(_ r: URLRequest) {
        let url = r.url!
        let path = url.path(percentEncoded: false).dropFirst()
        let slash = path.firstIndex(of: "/")
        let name = String(slash.map { path[..<$0] } ?? path)
        let key = slash.map { String(path[path.index(after: $0)...]) }.flatMap { $0.isEmpty ? nil : $0 }
        guard let endpoint = Self.lock.withLock({ Self.endpoints[name] }) else { return error(404, "NoSuchBucket") }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var headers: [String: String] = [:]
        for (k, v) in r.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v }
        let body = Self.body(of: r)
        let auth = headers["authorization"] ?? ""
        let keyID = auth.range(of: "Credential=").map { String(auth[$0.upperBound...].prefix { $0 != "/" }) } ?? ""
        let logged = Logged(method: r.httpMethod ?? "GET", key: key, query: query, headers: headers, body: body, keyID: keyID)
        endpoint.record(logged)
        guard endpoint.keys.contains(keyID) else { return error(403, "InvalidAccessKeyId") }
        if headers["x-amz-content-sha256"] != SigV4.sha256Hex(body) { return error(400, "XAmzContentSHA256Mismatch") }
        let fault = endpoint.hook?(logged)
        switch fault {
        case .status(let status, let code)?: return error(status, code)
        case .dropBefore?: return client!.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        default: break
        }
        if logged.partNumber != nil {
            endpoint.partStarted()
            if endpoint.partDelay > 0 { Thread.sleep(forTimeInterval: endpoint.partDelay) }
            endpoint.partEnded()
        }
        let answer = route(endpoint.bucket, logged)
        if case .dropAfter? = fault { return client!.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        var headersOut = answer.headers
        if case .etag(let e)? = fault { headersOut["ETag"] = e }
        respond(answer.status, headersOut, answer.body)
    }

    struct Answer {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    static func xml(_ s: String) -> Answer {
        Answer(status: 200, headers: ["Content-Type": "application/xml"], body: Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\(s)".utf8))
    }

    static func failure(_ status: Int, _ code: String) -> Answer {
        Answer(status: status, headers: ["Content-Type": "application/xml"], body: Data("<Error><Code>\(code)</Code></Error>".utf8))
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func identity(_ o: StoredObject) -> [String: String] {
        var h: [String: String] = [:]
        if let e = o.etag { h["ETag"] = e }
        if let v = o.versionID { h["x-amz-version-id"] = v }
        return h
    }

    private func route(_ b: MemoryBucket, _ l: Logged) -> Answer {
        let q = l.query
        do {
            switch (l.method, l.key) {
            case ("POST", let key?) where q["uploads"] != nil:
                let id = b.createMultipartUpload(key)
                return Self.xml("<InitiateMultipartUploadResult><Bucket>b</Bucket><Key>\(Self.escape(key))</Key><UploadId>\(id)</UploadId></InitiateMultipartUploadResult>")
            case ("PUT", let key?) where q["uploadId"] != nil:
                do {
                    let etag = try b.uploadPart(key, uploadID: q["uploadId"]!, partNumber: Int(q["partNumber"] ?? "") ?? 0, l.body)
                    return Answer(status: 200, headers: ["ETag": etag])
                } catch { return Self.failure(error.status, error.code) }
            case ("POST", let key?) where q["uploadId"] != nil:
                let records = XMLRecords.parse(l.body, records: ["Part"]).records
                let parts = records.map { (number: Int($0.fields["PartNumber"] ?? "") ?? 0, etag: $0.fields["ETag"] ?? "") }
                do {
                    let o = try b.completeMultipartUpload(key, uploadID: q["uploadId"]!, parts: parts)
                    var a = Self.xml("<CompleteMultipartUploadResult><Location>l</Location><Bucket>b</Bucket><Key>\(Self.escape(key))</Key><ETag>\(Self.escape(o.etag!))</ETag></CompleteMultipartUploadResult>")
                    a.headers["x-amz-version-id"] = o.versionID
                    return a
                } catch { return Self.failure(error.status, error.code) }
            case ("DELETE", let key?) where q["uploadId"] != nil:
                do {
                    try b.abortMultipartUpload(key, uploadID: q["uploadId"]!)
                    return Answer(status: 204)
                } catch { return Self.failure(error.status, error.code) }
            case ("GET", nil) where q["uploads"] != nil:
                let uploads = b.multipartUploads(prefix: q["prefix"] ?? "").map {
                    "<Upload><Key>\(Self.escape($0.key))</Key><UploadId>\($0.uploadID)</UploadId><Initiated>\(Self.iso($0.initiated))</Initiated></Upload>"
                }.joined()
                return Self.xml("<ListMultipartUploadsResult><Bucket>b</Bucket><IsTruncated>false</IsTruncated>\(uploads)</ListMultipartUploadsResult>")
            case ("GET", nil) where q["versions"] != nil:
                let versions = try b.versions(q["prefix"] ?? "", stopAt: nil, underPrefix: true).map { v in
                    let tag = v.deleteMarker ? "DeleteMarker" : "Version"
                    return "<\(tag)><Key>\(Self.escape(v.key))</Key><VersionId>\(v.versionID)</VersionId><IsLatest>\(v.isLatest)</IsLatest><LastModified>\(Self.iso(v.lastModified))</LastModified>"
                        + (v.deleteMarker ? "" : "<ETag>\(Self.escape(v.etag))</ETag><Size>\(v.size)</Size>") + "</\(tag)>"
                }.joined()
                return Self.xml("<ListVersionsResult><IsTruncated>false</IsTruncated>\(versions)</ListVersionsResult>")
            case ("GET", nil):
                let objects = try b.list(prefix: q["prefix"] ?? "").map {
                    "<Contents><Key>\(Self.escape($0.key))</Key><Size>\($0.size)</Size><LastModified>\(Self.iso($0.lastModified))</LastModified><ETag>\(Self.escape($0.etag))</ETag></Contents>"
                }.joined()
                return Self.xml("<ListBucketResult><IsTruncated>false</IsTruncated>\(objects)</ListBucketResult>")
            case ("PUT", let key?):
                let condition: PutCondition = if l.headers["if-none-match"] == "*" { .ifAbsent }
                    else if let e = l.headers["if-match"] { .ifMatch(e) } else { .none }
                let o = try l.body.withUnsafeBytes { try b.put(key, $0, condition: condition) }
                return Answer(status: 200, headers: Self.identity(o))
            case ("HEAD", let key?):
                let (o, size) = try b.head(key, versionID: q["versionId"])
                var h = Self.identity(o)
                h["Content-Length"] = "\(size)"
                return Answer(status: 200, headers: h)
            case ("GET", let key?):
                if let range = l.headers["range"], range.hasPrefix("bytes=") {
                    let bounds = range.dropFirst(6).split(separator: "-").compactMap { UInt64($0) }
                    let (offset, last) = (bounds[0], bounds.count > 1 ? bounds[1] : .max - 1)
                    let r = try b.getRange(key, versionID: q["versionId"], offset: offset, length: last - offset + 1)
                    if offset >= r.total { return Answer(status: 416, headers: ["Content-Range": "bytes */\(r.total)"]) }
                    let o = try b.head(key, versionID: q["versionId"]).object
                    var h = Self.identity(o)
                    h["Content-Range"] = "bytes \(offset)-\(offset + UInt64(r.bytes.count) - 1)/\(r.total)"
                    return Answer(status: 206, headers: h, body: r.bytes)
                }
                let o = try b.get(key, versionID: q["versionId"])
                return Answer(status: 200, headers: Self.identity(o.object), body: o.bytes)
            case ("DELETE", let key?):
                try b.remove(key, versionID: q["versionId"])
                return Answer(status: 204)
            default:
                return Self.failure(400, "InvalidRequest")
            }
        } catch let e as StoreError {
            switch e {
            case .notFound: return Self.failure(404, "NoSuchKey")
            case .preconditionFailed: return Self.failure(412, "PreconditionFailed")
            case .conditionsUnsupported: return Self.failure(501, "NotImplemented")
            default: return Self.failure(500, "InternalError")
            }
        } catch {
            return Self.failure(500, "InternalError")
        }
    }
}

/// A key that is renewed the way ``DeviceAccess`` renews the cloud's: the one in force can change between requests, and
/// a refusal may bring another (`onRefusal`).
final class RenewingCredentials: S3CredentialSource, @unchecked Sendable {
    private let lock = NSLock()
    private var keyID: String
    private var secret: SecretBytesBox
    private var refusals = 0
    let bucket: String
    var onRefusal: (@Sendable (RenewingCredentials) -> Void)?

    init(keyID: String, bucket: String) {
        self.keyID = keyID
        secret = SecretBytesBox(Data("secret-\(keyID)".utf8))
        self.bucket = bucket
    }

    var refusalCount: Int { lock.withLock { refusals } }

    func renew(to id: String) {
        lock.withLock {
            keyID = id
            secret = SecretBytesBox(Data("secret-\(id)".utf8))
        }
    }

    func withS3Credentials<R: Sendable>(_ body: @Sendable (S3Credentials) throws -> R) async rethrows -> R? {
        let (id, secret) = lock.withLock { (keyID, self.secret) }
        return try secret.withBytes { s in
            try body(S3Credentials(accessKeyID: id, secret: s, bucket: bucket, endpoint: S3Wire.endpointURL, region: "us-west-004"))
        }
    }

    func providerRefused() async {
        lock.withLock { refusals += 1 }
        onRefusal?(self)
    }
}
