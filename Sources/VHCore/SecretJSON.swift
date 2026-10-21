public import Foundation

/// JSON that carries key material (vault keys going to or coming from a daemon), handled so the keys never become
/// a Swift `String`, a `Codable` value or an unzeroed buffer:
///
/// - ``SecretJSONWriter`` builds a document straight into a buffer that zeroes what it leaves behind, encoding keys
///   to base64 from their `SecretBytes`; ``SecretJSONWriter/finish()`` hands it over as `SecretBytes`.
/// - ``SecretJSON/lift(_:members:)`` takes a received document apart: every string value of the named members
///   (`"key"`) is decoded from base64 into `SecretBytes` and replaced by the placeholder `"secret:<n>"` in a redacted
///   copy that is safe for `JSONDecoder`; `n` indexes ``SecretJSON/Lifted/secrets``.
///
/// Best effort, like ``SecretBytes``: it keeps keys out of Swift strings and the heap's abandoned copies, not out of
/// the kernel's socket buffers.
public enum SecretJSON {
    public enum Failure: Error, Equatable, Sendable {
        /// The document isn't JSON this reader can walk (unterminated string, a stray escape in a key value).
        case malformed
        /// A secret member's value isn't canonical base64.
        case malformedSecret
    }

    public struct Lifted: Sendable {
        /// The document with every secret value replaced by `"secret:<n>"`.
        public let redacted: Data
        public let secrets: [SecretBytes]

        /// The secret a placeholder names, nil for any other text.
        public func secret(for placeholder: String) -> SecretBytes? {
            guard placeholder.hasPrefix(SecretJSON.placeholderPrefix),
                  let index = Int(placeholder.dropFirst(SecretJSON.placeholderPrefix.count)),
                  secrets.indices.contains(index) else { return nil }
            return secrets[index]
        }
    }

    public static let placeholderPrefix = "secret:"

    /// Lifts the string values of `members` (at any depth) out of `document`. `document` isn't modified; the caller
    /// owns (and zeroes) it.
    public static func lift(_ document: UnsafeRawBufferPointer, members: Set<String>) throws(Failure) -> Lifted {
        let names = members.map { Array($0.utf8) }
        var out: [UInt8] = []
        out.reserveCapacity(document.count)
        var secrets: [SecretBytes] = []
        var i = 0
        let n = document.count

        func skipSpace(_ j: inout Int) {
            while j < n, [0x20, 0x09, 0x0A, 0x0D].contains(document[j]) { j += 1 }
        }
        // The index after a string's closing quote; `start` is its opening quote.
        func stringEnd(from start: Int) throws(Failure) -> Int {
            var j = start + 1
            while j < n {
                switch document[j] {
                case UInt8(ascii: "\\"): j += 2
                case UInt8(ascii: "\""): return j + 1
                default: j += 1
                }
            }
            throw .malformed
        }

        while i < n {
            let byte = document[i]
            guard byte == UInt8(ascii: "\"") else {
                out.append(byte)
                i += 1
                continue
            }
            let end = try stringEnd(from: i)
            out.append(contentsOf: UnsafeRawBufferPointer(rebasing: document[i..<end]))
            // A member name: a string followed by a colon.
            var j = end
            skipSpace(&j)
            guard j < n, document[j] == UInt8(ascii: ":") else {
                i = end
                continue
            }
            let name = UnsafeRawBufferPointer(rebasing: document[(i + 1)..<(end - 1)])
            let isSecret = names.contains { $0.elementsEqual(name) }
            j += 1
            skipSpace(&j)
            guard isSecret, j < n, document[j] == UInt8(ascii: "\"") else {
                // Copy the colon and spacing; the value is handled by the main loop.
                out.append(contentsOf: UnsafeRawBufferPointer(rebasing: document[end..<j]))
                i = j
                continue
            }
            let valueEnd = try stringEnd(from: j)
            let raw = UnsafeRawBufferPointer(rebasing: document[(j + 1)..<(valueEnd - 1)])
            guard let secret = decodeBase64(raw) else { throw .malformedSecret }
            out.append(contentsOf: UnsafeRawBufferPointer(rebasing: document[end..<j]))
            out.append(contentsOf: Array("\"\(placeholderPrefix)\(secrets.count)\"".utf8))
            secrets.append(secret)
            i = valueEnd
        }
        return Lifted(redacted: Data(out), secrets: secrets)
    }

    private static let alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    private static let decodeTable: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (index, c) in alphabet.enumerated() { table[Int(c)] = UInt8(index) }
        return table
    }()

    /// Standard, padded base64 (JSON's `\/` escape allowed) straight into `SecretBytes`; scratch is zeroed. nil if
    /// it isn't base64 or decodes to nothing.
    static func decodeBase64(_ text: UnsafeRawBufferPointer) -> SecretBytes? {
        // Unescape `\/` (some encoders escape slashes) into zeroed scratch; any other escape isn't base64.
        var clean = [UInt8](repeating: 0, count: text.count)
        defer { clean.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        var length = 0
        var k = 0
        while k < text.count {
            if text[k] == UInt8(ascii: "\\") {
                guard k + 1 < text.count, text[k + 1] == UInt8(ascii: "/") else { return nil }
                k += 1
            }
            clean[length] = text[k]
            length += 1
            k += 1
        }
        guard length > 0, length % 4 == 0 else { return nil }
        var padding = 0
        if clean[length - 1] == UInt8(ascii: "=") { padding += 1 }
        if clean[length - 2] == UInt8(ascii: "=") { padding += 1 }
        let size = length / 4 * 3 - padding
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        defer { bytes.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        var o = 0
        var q = 0
        while q < length {
            var value: UInt32 = 0
            for p in 0..<4 {
                let c = clean[q + p]
                let isPad = c == UInt8(ascii: "=") && q + 4 == length && p >= 4 - padding
                let v = isPad ? 0 : decodeTable[Int(c)]
                if v == 0xFF { return nil }
                value = value << 6 | UInt32(v)
            }
            for shift in [16, 8, 0] where o < size {
                bytes[o] = UInt8(truncatingIfNeeded: value >> UInt32(shift))
                o += 1
            }
            q += 4
        }
        return SecretBytes(bytes)
    }

    static func appendBase64(_ secret: SecretBytes, to bytes: inout [UInt8]) {
        secret.withUnsafeBytes { raw in
            var i = 0
            while i + 3 <= raw.count {
                let n = UInt32(raw[i]) << 16 | UInt32(raw[i + 1]) << 8 | UInt32(raw[i + 2])
                bytes.append(alphabet[Int(n >> 18 & 63)])
                bytes.append(alphabet[Int(n >> 12 & 63)])
                bytes.append(alphabet[Int(n >> 6 & 63)])
                bytes.append(alphabet[Int(n & 63)])
                i += 3
            }
            let rest = raw.count - i
            if rest > 0 {
                let n = UInt32(raw[i]) << 16 | (rest == 2 ? UInt32(raw[i + 1]) << 8 : 0)
                bytes.append(alphabet[Int(n >> 18 & 63)])
                bytes.append(alphabet[Int(n >> 12 & 63)])
                bytes.append(rest == 2 ? alphabet[Int(n >> 6 & 63)] : UInt8(ascii: "="))
                bytes.append(UInt8(ascii: "="))
            }
        }
    }
}

/// Writes one JSON document into a buffer that zeroes the storage it outgrows and what it holds at the end; keys go
/// from `SecretBytes` to base64 without passing through a `String`.
///
///     let writer = SecretJSONWriter()
///     writer.beginObject()
///     writer.field("vault_id", 12)
///     writer.key("key"); writer.base64(secret)
///     writer.endObject()
///     let document = writer.finish()   // SecretBytes
public final class SecretJSONWriter {
    private var bytes: [UInt8] = []
    /// Per open container: whether a value was written (a comma comes before the next).
    private var hasValue: [Bool] = []
    private var afterKey = false

    public init(capacity: Int = 1024) {
        bytes.reserveCapacity(capacity)
    }

    deinit { wipe() }

    private func reserve(_ extra: Int) {
        let needed = bytes.count + extra
        guard needed > bytes.capacity else { return }
        var grown: [UInt8] = []
        grown.reserveCapacity(max(needed, bytes.capacity * 2))
        grown.append(contentsOf: bytes)
        bytes.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        bytes = grown
    }

    private func append(_ text: String) {
        let utf8 = Array(text.utf8)
        reserve(utf8.count)
        bytes.append(contentsOf: utf8)
    }

    private func beginValue() {
        if afterKey {
            afterKey = false
            return
        }
        if let last = hasValue.last {
            if last { append(",") }
            hasValue[hasValue.count - 1] = true
        }
    }

    public func key(_ name: String) {
        if let last = hasValue.last {
            if last { append(",") }
            hasValue[hasValue.count - 1] = true
        }
        appendString(name)
        append(":")
        afterKey = true
    }

    public func beginObject() {
        beginValue()
        append("{")
        hasValue.append(false)
    }

    public func endObject() {
        hasValue.removeLast()
        append("}")
    }

    public func beginArray() {
        beginValue()
        append("[")
        hasValue.append(false)
    }

    public func endArray() {
        hasValue.removeLast()
        append("]")
    }

    public func string(_ value: String) {
        beginValue()
        appendString(value)
    }

    public func int<I: BinaryInteger>(_ value: I) {
        beginValue()
        append(String(value))
    }

    public func bool(_ value: Bool) {
        beginValue()
        append(value ? "true" : "false")
    }

    public func null() {
        beginValue()
        append("null")
    }

    /// A JSON string holding `secret` in standard base64.
    public func base64(_ secret: SecretBytes) {
        beginValue()
        reserve((secret.count + 2) / 3 * 4 + 2)
        bytes.append(UInt8(ascii: "\""))
        SecretJSON.appendBase64(secret, to: &bytes)
        bytes.append(UInt8(ascii: "\""))
    }

    public func field(_ name: String, _ value: String) {
        key(name)
        string(value)
    }

    public func field<I: BinaryInteger>(_ name: String, _ value: I) {
        key(name)
        int(value)
    }

    public func field(_ name: String, _ value: Bool) {
        key(name)
        bool(value)
    }

    /// The document as `SecretBytes`; the writer's buffer is zeroed and emptied.
    public func finish() -> SecretBytes {
        let document = SecretBytes(bytes)
        wipe()
        return document
    }

    private func wipe() {
        bytes.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        bytes.removeAll(keepingCapacity: true)
    }

    private func appendString(_ value: String) {
        var out: [UInt8] = [UInt8(ascii: "\"")]
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "\""): out += Array("\\\"".utf8)
            case UInt8(ascii: "\\"): out += Array("\\\\".utf8)
            case UInt8(ascii: "\n"): out += Array("\\n".utf8)
            case UInt8(ascii: "\r"): out += Array("\\r".utf8)
            case UInt8(ascii: "\t"): out += Array("\\t".utf8)
            case 0..<0x20: out += Array(String(format: "\\u%04x", byte).utf8)
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
        reserve(out.count)
        bytes.append(contentsOf: out)
    }
}
