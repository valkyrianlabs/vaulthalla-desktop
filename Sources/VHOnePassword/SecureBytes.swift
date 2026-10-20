import VHCore

/// A growable byte buffer for protocol lines that may hold key material. When it grows it zeroes the storage it
/// leaves behind, and `wipe()` zeroes what it holds, so a request or response line never survives as stray copies
/// in abandoned arrays. Best effort: it keeps bytes out of Swift `String`s and unzeroed heap, not out of the kernel's
/// pipe buffers.
struct SecureByteBuffer: ~Copyable {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int) {
        bytes.reserveCapacity(max(capacity, 64))
    }

    deinit {
        // Zero the storage in place; `self` is immutable here, and the array is uniquely owned.
        bytes.withUnsafeBufferPointer { UnsafeMutableBufferPointer(mutating: $0).update(repeating: 0) }
    }

    var count: Int { bytes.count }
    var isEmpty: Bool { bytes.isEmpty }

    private mutating func reserve(_ extra: Int) {
        let needed = bytes.count + extra
        guard needed > bytes.capacity else { return }
        var grown: [UInt8] = []
        grown.reserveCapacity(max(needed, bytes.capacity * 2))
        grown.append(contentsOf: bytes)
        bytes.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        bytes = grown
    }

    mutating func append(_ byte: UInt8) {
        reserve(1)
        bytes.append(byte)
    }

    mutating func append(contentsOf raw: UnsafeRawBufferPointer) {
        reserve(raw.count)
        bytes.append(contentsOf: raw)
    }

    mutating func append(_ text: StaticString) {
        text.withUTF8Buffer { append(contentsOf: UnsafeRawBufferPointer($0)) }
    }

    mutating func append(utf8 text: String) {
        var text = text
        text.withUTF8 { append(contentsOf: UnsafeRawBufferPointer($0)) }
    }

    /// Appends `secret` as standard base64 (with padding), encoding straight from its buffer.
    mutating func appendBase64(_ secret: SecretBytes) {
        reserve((secret.count + 2) / 3 * 4)
        secret.withUnsafeBytes { raw in
            var i = 0
            while i + 3 <= raw.count {
                let n = UInt32(raw[i]) << 16 | UInt32(raw[i + 1]) << 8 | UInt32(raw[i + 2])
                bytes.append(Base64.alphabet[Int(n >> 18 & 63)])
                bytes.append(Base64.alphabet[Int(n >> 12 & 63)])
                bytes.append(Base64.alphabet[Int(n >> 6 & 63)])
                bytes.append(Base64.alphabet[Int(n & 63)])
                i += 3
            }
            let rest = raw.count - i
            if rest > 0 {
                let n = UInt32(raw[i]) << 16 | (rest == 2 ? UInt32(raw[i + 1]) << 8 : 0)
                bytes.append(Base64.alphabet[Int(n >> 18 & 63)])
                bytes.append(Base64.alphabet[Int(n >> 12 & 63)])
                bytes.append(rest == 2 ? Base64.alphabet[Int(n >> 6 & 63)] : UInt8(ascii: "="))
                bytes.append(UInt8(ascii: "="))
            }
        }
    }

    /// Hands the bytes to `body` without copying them.
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }

    mutating func wipe() {
        bytes.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        bytes.removeAll(keepingCapacity: true)
    }
}

enum Base64 {
    static let alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    private static let decodeTable: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (i, c) in alphabet.enumerated() { table[Int(c)] = UInt8(i) }
        return table
    }()

    /// Decodes standard, padded base64 straight into a `SecretBytes`. The scratch buffer is zeroed before return.
    /// nil if the text isn't canonical base64 or decodes to nothing.
    static func decodeSecret(_ text: UnsafeRawBufferPointer) -> SecretBytes? {
        guard !text.isEmpty, text.count % 4 == 0 else { return nil }
        var padding = 0
        if text[text.count - 1] == UInt8(ascii: "=") { padding += 1 }
        if text[text.count - 2] == UInt8(ascii: "=") { padding += 1 }
        let length = text.count / 4 * 3 - padding
        guard length > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: length)
        defer { out.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        var o = 0
        var i = 0
        while i < text.count {
            var n: UInt32 = 0
            for j in 0..<4 {
                let c = text[i + j]
                let isPad = c == UInt8(ascii: "=") && i + 4 == text.count && j >= 4 - padding
                let v = isPad ? 0 : decodeTable[Int(c)]
                if v == 0xFF { return nil }
                n = n << 6 | UInt32(v)
            }
            for shift in [16, 8, 0] where o < length {
                out[o] = UInt8(truncatingIfNeeded: n >> UInt32(shift))
                o += 1
            }
            i += 4
        }
        return SecretBytes(out)
    }
}
