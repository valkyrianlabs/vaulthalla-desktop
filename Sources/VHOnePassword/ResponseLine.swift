import Foundation
import VHCore

/// One response line with its key material lifted out: `redacted` is the line with every `key_b64` value
/// overwritten by `*`, safe to hand to `JSONDecoder`; `secrets` are those values, decoded in the order they
/// appeared. The raw line is zeroed as soon as this is built.
struct ResponseLine: Sendable {
    let redacted: Data
    let secrets: [SecretBytes]

    /// The JSON key whose string values carry key material (base64). The helper emits them as
    /// `"key_b64":"<base64>"` with no whitespace; base64 never contains `"` or `\`, so the value ends at the next
    /// quote. The marker can't match inside another string: a quote inside a JSON string is always escaped.
    static let secretKey = Array(#""key_b64":""#.utf8)

    enum Failure: Error, Equatable {
        case malformedSecret
    }

    /// Consumes `line`: extracts and decodes secrets, redacts them in place, copies out the redacted text, then
    /// zeroes `line`.
    static func take(_ line: inout [UInt8]) throws(Failure) -> ResponseLine {
        defer { line.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        var secrets: [SecretBytes] = []
        let marker = secretKey
        var i = 0
        while i + marker.count <= line.count {
            guard line[i] == marker[0], line[i..<(i + marker.count)].elementsEqual(marker) else {
                i += 1
                continue
            }
            let start = i + marker.count
            guard let end = line[start...].firstIndex(of: UInt8(ascii: "\"")) else { throw .malformedSecret }
            let secret = line.withUnsafeBytes { raw in
                Base64.decodeSecret(UnsafeRawBufferPointer(rebasing: raw[start..<end]))
            }
            guard let secret else { throw .malformedSecret }
            secrets.append(secret)
            for j in start..<end { line[j] = UInt8(ascii: "*") }
            i = end + 1
        }
        return ResponseLine(redacted: Data(line), secrets: secrets)
    }
}

/// The id of a response: the helper echoes the request's id, or sends null when it couldn't parse the request.
enum WireID: Decodable, Equatable, Sendable {
    case int(Int)
    case string(String)
    case null

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let n = try? c.decode(Int.self) {
            self = .int(n)
        } else {
            self = .string(try c.decode(String.self))
        }
    }
}

struct WireHeader: Decodable {
    let id: WireID
}

struct WireError: Decodable, Sendable {
    let code: String
    let message: String
    let hint: String?
    let detail: String?
}

struct WireEnvelope<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let error: WireError?
}
