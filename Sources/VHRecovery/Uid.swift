import Foundation
import Security

/// A 16-byte vault or object uid and its strict Crockford base32 text (26 lower-case symbols, no padding), as
/// Vaulthalla writes them (vl-keykit `uid.hpp`; vectors.json `object_ids`). Decoding refuses upper case, padding, the
/// letters i, l, o and u, and non-zero trailing bits, so one uid has exactly one spelling.
public struct Uid: Sendable, Hashable, CustomStringConvertible {
    public static let byteCount = 16
    public static let textCount = 26
    public static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz".utf8)

    public let bytes: [UInt8]

    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Array(bytes)
    }

    public init?(base32 text: String) {
        guard let decoded = Base32.decode(text, byteCount: Self.byteCount) else { return nil }
        bytes = decoded
    }

    public static func random() -> Uid {
        var raw = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        precondition(status == errSecSuccess, "the system random generator failed")
        return Uid(bytes: raw)!
    }

    public var base32: String { Base32.encode(bytes) }
    public var description: String { base32 }
}

/// Crockford base32 with Vaulthalla's lower-case alphabet, most significant bits first.
enum Base32 {
    static func encode(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        var buffer: UInt32 = 0
        var bits = 0
        for b in bytes {
            buffer = (buffer << 8) | UInt32(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(Uid.alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
        }
        if bits > 0 { out.append(Uid.alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// Exactly `byteCount` bytes from exactly ceil(byteCount * 8 / 5) symbols, the unused trailing bits zero.
    static func decode(_ text: String, byteCount: Int) -> [UInt8]? {
        let symbols = Array(text.utf8)
        guard symbols.count == (byteCount * 8 + 4) / 5 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(byteCount)
        var buffer: UInt32 = 0
        var bits = 0
        for s in symbols {
            guard let value = Uid.alphabet.firstIndex(of: s) else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        guard out.count == byteCount, buffer & ((1 << UInt32(bits)) - 1) == 0 else { return nil }
        return out
    }
}
