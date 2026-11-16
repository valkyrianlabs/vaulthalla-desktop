public import Foundation
import CryptoKit

/// AWS Signature Version 4 (header form), written with CryptoKit: what every S3 request to a Desktop-only vault's bucket
/// carries. Tested against AWS's published SigV4 test suite (`Tests/VHVaultTests/SigV4Tests.swift`) and against an
/// S3-compatible endpoint that checks every signature (the opt-in live test).
///
/// The secret is lent for one signature (``sign(_:secret:)``) and only HMAC keys derived from it exist afterwards,
/// inside CryptoKit; the signing key is never kept.
public struct SigV4: Sendable {
    public var accessKeyID: String
    public var region: String
    public var service: String

    public init(accessKeyID: String, region: String, service: String = "s3") {
        self.accessKeyID = accessKeyID
        self.region = region
        self.service = service
    }

    /// A request to sign: what goes into the canonical request.
    public struct Request: Sendable, Equatable {
        public var method: String
        /// The path exactly as it goes on the wire, already URI-encoded (`/bucket/o/abc`).
        public var encodedPath: String
        /// Query parameters, not encoded (encoded here, as on the wire).
        public var query: [(String, String)]
        /// Headers to sign (names in any case). `host` is required.
        public var headers: [(String, String)]
        /// Hex SHA-256 of the body, or `UNSIGNED-PAYLOAD`.
        public var payloadHash: String
        public var date: Date

        public init(method: String, encodedPath: String, query: [(String, String)] = [], headers: [(String, String)],
                    payloadHash: String, date: Date) {
            self.method = method
            self.encodedPath = encodedPath
            self.query = query
            self.headers = headers
            self.payloadHash = payloadHash
            self.date = date
        }

        public static func == (a: Request, b: Request) -> Bool {
            a.method == b.method && a.encodedPath == b.encodedPath && a.query.elementsEqual(b.query, by: ==)
                && a.headers.elementsEqual(b.headers, by: ==) && a.payloadHash == b.payloadHash && a.date == b.date
        }
    }

    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public static func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    public static func sha256Hex(_ data: some DataProtocol) -> String { hex(SHA256.hash(data: data)) }

    /// `20150830T123600Z`.
    public static func amzDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// RFC 3986 unreserved characters stay; everything else is %XX (upper case). `/` stays only when `keepSlash`.
    public static func uriEncode(_ text: String, keepSlash: Bool) -> String {
        var out = ""
        for b in text.utf8 {
            switch b {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
                 UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(b)))
            case UInt8(ascii: "/") where keepSlash: out.append("/")
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// The query as it goes on the wire and into the canonical request: encoded, sorted by name then value.
    public static func canonicalQuery(_ query: [(String, String)]) -> String {
        let encoded: [(name: String, value: String)] = query.map { pair in
            (uriEncode(pair.0, keepSlash: false), uriEncode(pair.1, keepSlash: false))
        }
        let sorted = encoded.sorted { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        return sorted.map { p in p.name + "=" + p.value }.joined(separator: "&")
    }

    /// Lower-case names, values trimmed with inner runs of spaces folded, sorted; the signed header list.
    static func canonicalHeaders(_ headers: [(String, String)]) -> (text: String, signed: String) {
        var merged: [String: [String]] = [:]
        for (name, value) in headers {
            let folded = value.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ")
            merged[name.lowercased(), default: []].append(folded)
        }
        let names = merged.keys.sorted()
        return (names.map { "\($0):\(merged[$0]!.joined(separator: ","))\n" }.joined(), names.joined(separator: ";"))
    }

    public func canonicalRequest(_ r: Request) -> String {
        let (headers, signed) = Self.canonicalHeaders(r.headers)
        return [r.method, r.encodedPath.isEmpty ? "/" : r.encodedPath, Self.canonicalQuery(r.query), headers, signed,
                r.payloadHash].joined(separator: "\n")
    }

    public func scope(_ date: Date) -> String { "\(Self.amzDate(date).prefix(8))/\(region)/\(service)/aws4_request" }

    public func stringToSign(_ r: Request) -> String {
        ["AWS4-HMAC-SHA256", Self.amzDate(r.date), scope(r.date), Self.sha256Hex(Data(canonicalRequest(r).utf8))]
            .joined(separator: "\n")
    }

    /// The signature's hex, with `secret` (the secret access key's bytes) lent for the call.
    public func signature(_ r: Request, secret: UnsafeRawBufferPointer) -> String {
        var k = Data("AWS4".utf8)
        k.append(contentsOf: secret)
        defer { k.resetBytes(in: 0 ..< k.count) }
        func mac(_ key: SymmetricKey, _ text: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)))
        }
        let dateKey = mac(SymmetricKey(data: k), String(Self.amzDate(r.date).prefix(8)))
        let signing = mac(mac(mac(dateKey, region), service), "aws4_request")
        return Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign(r).utf8), using: signing))
    }

    /// The `Authorization` header's value.
    public func authorization(_ r: Request, secret: UnsafeRawBufferPointer) -> String {
        "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope(r.date)), SignedHeaders=\(Self.canonicalHeaders(r.headers).signed), "
            + "Signature=\(signature(r, secret: secret))"
    }
}
