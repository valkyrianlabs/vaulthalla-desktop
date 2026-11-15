public import Foundation
import VLKeykit

/// vl-keykit's C API (`vl_keykit.h`) in Swift: the account recovery key's formats as Vaulthalla Cloud, the server and
/// Desktop share them. Every format and construction is the library's; this module only marshals. Secrets stay in
/// the library's handles (``AccountKey``, ``VaultKey``) and leave one only as the recovery code, in ``SecretBytes``.
public enum Keykit {
    /// The linked library's version ("0.4.0").
    public static var version: String { String(cString: vl_keykit_version()) }

    /// SHA-256 of a public key: the recipient id KEV1 and KAK1 envelopes carry.
    public static func recipientID(of publicKey: Data) throws(KeykitError) -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        try check(publicKey.withBytes { p, n in vl_keykit_recipient_id(p, n, &out) })
        return Data(out)
    }

    /// The 16 bytes of an account public id (canonical UUID text only).
    public static func publicIDBytes(_ publicID: String) throws(KeykitError) -> Data {
        var out = [UInt8](repeating: 0, count: 16)
        try check(publicID.withText { p, n in vl_keykit_public_id_bytes(p, n, &out) })
        return Data(out)
    }
}

/// A vl-keykit status other than OK. ``name`` is the library's stable spelling ("kak1_wrap_auth_failed"), the one the
/// golden vectors use.
public struct KeykitError: Error, Hashable, Sendable, CustomStringConvertible {
    public let status: Int32
    /// For a chain check: the chain position that failed, when one applies.
    public var index: Int?

    public init(status: Int32, index: Int? = nil) {
        self.status = status
        self.index = index
    }

    public var name: String { String(cString: vl_keykit_status_name(status)) }
    public var description: String { index.map { "vl-keykit: \(name) at \($0)" } ?? "vl-keykit: \(name)" }

    public static let seedMismatch = KeykitError(status: Int32(VL_KEYKIT_ERR_SEED_MISMATCH))
    public static let agreementFailed = KeykitError(status: Int32(VL_KEYKIT_ERR_AGREEMENT_FAILED))
    public static let badFormat = KeykitError(status: Int32(VL_KEYKIT_ERR_BAD_FORMAT))
    public static let invalidArgument = KeykitError(status: Int32(VL_KEYKIT_ERR_INVALID_ARGUMENT))
    public static let rollback = KeykitError(status: Int32(VL_KEYKIT_ERR_ACCOUNT_ROLLBACK))
    public static let pinMismatch = KeykitError(status: Int32(VL_KEYKIT_ERR_ACCOUNT_PIN_MISMATCH))
}

/// The two suites of KAK1 and KEV1 (holder keys, transfer keys, restore keys).
public enum KeySuite: UInt16, Sendable, Hashable, Codable {
    /// X25519 + HKDF-SHA-256 + AES-256-GCM: 32-byte public keys.
    case x25519 = 1
    /// P-256 ECDH + HKDF-SHA-256 + AES-256-GCM: the 65-byte uncompressed point (a Secure Enclave key's).
    case p256 = 2
}

/// Why a generation of the account key was published (signed into its statement).
public enum KeyReason: Int32, Sendable, Hashable, Codable {
    case initial = 0
    case routine = 1
    case compromise = 2

    public var name: String {
        switch self {
        case .initial: "initial"
        case .routine: "routine"
        case .compromise: "compromise"
        }
    }

    public init?(name: String) {
        switch name {
        case "initial": self = .initial
        case "routine": self = .routine
        case "compromise": self = .compromise
        default: return nil
        }
    }
}

/// What the chain check found between a generation and the one before it.
public enum KeyLink: Int32, Sendable, Hashable, Codable {
    case initial = 0
    /// Signed by the previous generation: a server that pinned that one follows it.
    case rotation = 1
    /// Not signed by the previous generation: a person must confirm the new fingerprint.
    case replacement = 2
}

// MARK: - plumbing shared by the module

@inline(__always)
func check(_ status: vl_keykit_status) throws(KeykitError) {
    guard status == Int32(VL_KEYKIT_OK) else { throw KeykitError(status: status) }
}

/// A variable-length output: `capacity` is the header's bound for it.
func output(_ capacity: Int, _ fill: (UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<Int>) -> vl_keykit_status)
    throws(KeykitError) -> Data {
    var buffer = [UInt8](repeating: 0, count: capacity)
    var length = capacity
    let status = buffer.withUnsafeMutableBufferPointer { fill($0.baseAddress!, &length) }
    try check(status)
    return Data(buffer[0 ..< length])
}

func textOutput(_ capacity: Int, _ fill: (UnsafeMutablePointer<CChar>, UnsafeMutablePointer<Int>) -> vl_keykit_status)
    throws(KeykitError) -> String {
    var buffer = [CChar](repeating: 0, count: capacity)
    var length = capacity
    let status = buffer.withUnsafeMutableBufferPointer { fill($0.baseAddress!, &length) }
    try check(status)
    return String(decoding: buffer[0 ..< length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func bytes<T>(of tuple: T) -> Data {
    var copy = tuple
    return withUnsafeBytes(of: &copy) { Data($0) }
}

extension Data {
    /// The bytes as a pointer and length for the C API; an empty value is (NULL, 0), the empty buffer.
    func withBytes<R>(_ body: (UnsafePointer<UInt8>?, Int) -> R) -> R {
        withUnsafeBytes { raw in body(raw.bindMemory(to: UInt8.self).baseAddress, raw.count) }
    }

    /// A buffer of exactly `count` bytes for a fixed-size parameter (`uint8_t x[16]`), or invalidArgument.
    func withFixed<R>(_ count: Int, _ body: (UnsafePointer<UInt8>) throws(KeykitError) -> R) throws(KeykitError) -> R {
        guard self.count == count else { throw KeykitError.invalidArgument }
        let result: Result<R, KeykitError> = withUnsafeBytes { raw in
            Result { () throws(KeykitError) -> R in try body(raw.bindMemory(to: UInt8.self).baseAddress!) }
        }
        return try result.get()
    }
}

extension String {
    /// The UTF-8 bytes as pointer and length, no terminating NUL read.
    func withText<R>(_ body: (UnsafePointer<CChar>?, Int) -> R) -> R {
        var copy = self
        return copy.withUTF8 { utf8 in
            utf8.withMemoryRebound(to: CChar.self) { body($0.baseAddress, $0.count) }
        }
    }
}
