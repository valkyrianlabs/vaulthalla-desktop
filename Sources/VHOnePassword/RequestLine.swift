import VHCore

/// Writes one request line, `{"id":N,"op":"...","params":{...}}\n`, straight into a `SecureByteBuffer`. Key
/// material goes from `SecretBytes` to base64 in the buffer without passing through a `String` or `Data`; the caller
/// wipes the buffer once it is written to the pipe.
struct RequestLineWriter: ~Copyable {
    private(set) var buffer: SecureByteBuffer
    private var needsComma: [Bool] = []
    private var afterKey = false

    init(id: Int, op: String, capacity: Int = 1024) {
        buffer = SecureByteBuffer(capacity: capacity)
        buffer.append("{\"id\":")
        buffer.append(utf8: String(id))
        buffer.append(",\"op\":")
        appendString(op)
        buffer.append(",\"params\":")
        needsComma = []
        afterKey = true
        beginObject()
    }

    /// Closes `params` and the envelope and returns the finished line.
    consuming func finish() -> SecureByteBuffer {
        endObject()
        buffer.append("}\n")
        return buffer
    }

    private mutating func beginValue() {
        if afterKey {
            afterKey = false
            return
        }
        if let last = needsComma.last {
            if last { buffer.append(UInt8(ascii: ",")) }
            needsComma[needsComma.count - 1] = true
        }
    }

    mutating func key(_ name: String) {
        if needsComma.last == true { buffer.append(UInt8(ascii: ",")) }
        if !needsComma.isEmpty { needsComma[needsComma.count - 1] = true }
        appendString(name)
        buffer.append(UInt8(ascii: ":"))
        afterKey = true
    }

    mutating func beginObject() {
        beginValue()
        buffer.append(UInt8(ascii: "{"))
        needsComma.append(false)
    }

    mutating func endObject() {
        needsComma.removeLast()
        buffer.append(UInt8(ascii: "}"))
    }

    mutating func beginArray() {
        beginValue()
        buffer.append(UInt8(ascii: "["))
        needsComma.append(false)
    }

    mutating func endArray() {
        needsComma.removeLast()
        buffer.append(UInt8(ascii: "]"))
    }

    mutating func string(_ value: String) {
        beginValue()
        appendString(value)
    }

    mutating func int(_ value: Int) {
        beginValue()
        buffer.append(utf8: String(value))
    }

    mutating func bool(_ value: Bool) {
        beginValue()
        buffer.append(value ? "true" : "false")
    }

    /// A JSON string holding `secret` in standard base64.
    mutating func base64(_ secret: SecretBytes) {
        beginValue()
        buffer.append(UInt8(ascii: "\""))
        buffer.appendBase64(secret)
        buffer.append(UInt8(ascii: "\""))
    }

    mutating func field(_ name: String, _ value: String) {
        key(name)
        string(value)
    }

    mutating func field(_ name: String, _ value: Int) {
        key(name)
        int(value)
    }

    private mutating func appendString(_ value: String) {
        buffer.append(UInt8(ascii: "\""))
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "\""): buffer.append("\\\"")
            case UInt8(ascii: "\\"): buffer.append("\\\\")
            case UInt8(ascii: "\n"): buffer.append("\\n")
            case UInt8(ascii: "\r"): buffer.append("\\r")
            case UInt8(ascii: "\t"): buffer.append("\\t")
            case 0..<0x20:
                buffer.append("\\u00")
                buffer.append(Self.hex[Int(byte >> 4)])
                buffer.append(Self.hex[Int(byte & 0xF)])
            default:
                buffer.append(byte)
            }
        }
        buffer.append(UInt8(ascii: "\""))
    }

    private static let hex: [UInt8] = Array("0123456789abcdef".utf8)
}
