public import Foundation
import VLKeykit

/// An account key generation's fingerprint: 16 bytes, shown as eight groups of four hex digits. A server pins it; a
/// person compares it only where a design says so.
public struct Fingerprint: Hashable, Sendable, CustomStringConvertible, Codable {
    public let bytes: Data

    public init(bytes: Data) throws(KeykitError) {
        guard bytes.count == Int(VL_KEYKIT_FINGERPRINT_SIZE) else { throw KeykitError.badFormat }
        self.bytes = bytes
    }

    /// Canonical text only, or with `lenient` also what a person types (upper case; '-', ' ' or nothing between).
    public init(text: String, lenient: Bool = false) throws(KeykitError) {
        var out = [UInt8](repeating: 0, count: 16)
        try check(text.withText { p, n in vl_keykit_fingerprint_parse(p, n, lenient ? 1 : 0, &out) })
        bytes = Data(out)
    }

    /// xxxx-xxxx-xxxx-xxxx-xxxx-xxxx-xxxx-xxxx
    public var text: String {
        // 16 bytes always format; the library refuses nothing here.
        let fp = [UInt8](bytes)
        return (try? textOutput(Int(VL_KEYKIT_FINGERPRINT_TEXT_SIZE)) { out, n in vl_keykit_fingerprint_text(fp, out, n) }) ?? ""
    }

    public var description: String { text }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do { try self.init(text: text) } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a fingerprint"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

/// A key statement (`vhc-account-key-v1`): one generation of the account key as its canonical text, parsed strictly
/// when made.
public struct KeyStatement: Hashable, Sendable, Codable {
    public let text: String
    public let publicID: Data
    public let generation: UInt32
    public let reason: KeyReason
    public let x25519PublicKey: Data
    public let ed25519PublicKey: Data
    public let previousFingerprint: Fingerprint?
    public let fingerprint: Fingerprint

    public init(_ text: String) throws(KeykitError) {
        var info = vl_keykit_statement_info()
        try check(text.withText { p, n in vl_keykit_statement_parse(p, n, &info) })
        self.text = text
        publicID = bytes(of: info.public_id)
        generation = info.generation
        reason = KeyReason(rawValue: info.reason) ?? .initial
        x25519PublicKey = bytes(of: info.x25519_public)
        ed25519PublicKey = bytes(of: info.ed25519_public)
        previousFingerprint = info.has_previous != 0 ? try Fingerprint(bytes: bytes(of: info.previous_fingerprint)) : nil
        fingerprint = try Fingerprint(bytes: bytes(of: info.fingerprint))
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do { try self.init(text) } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(error)"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

/// A statement as the cloud serves it in a chain: its text and signatures.
public struct SignedStatement: Hashable, Sendable {
    public var statement: String
    public var signature: Data
    public var previousSignature: Data?

    public init(statement: String, signature: Data, previousSignature: Data? = nil) {
        self.statement = statement
        self.signature = signature
        self.previousSignature = previousSignature
    }
}

/// One generation the chain check verified.
public struct VerifiedGeneration: Hashable, Sendable {
    public let generation: UInt32
    public let reason: KeyReason
    public let link: KeyLink
    public let fingerprint: Fingerprint
    public let x25519PublicKey: Data
    public let ed25519PublicKey: Data
}

/// The account key's chain of statements: verified whole, and followed from a pin.
public enum KeyChain {
    /// Verifies every signature of `chain` (generation 1 first) for the account `publicID`. A failure carries the
    /// position that failed in ``KeykitError/index`` when one applies.
    public static func verify(_ chain: [SignedStatement], publicID: String) throws(KeykitError) -> [VerifiedGeneration] {
        var out = [vl_keykit_generation](repeating: vl_keykit_generation(), count: chain.count)
        var failed = Int.max
        let status = withSigned(chain) { list in
            publicID.withText { id, idn in
                out.withUnsafeMutableBufferPointer { o in
                    vl_keykit_chain_verify(list, chain.count, id, idn, o.baseAddress, &failed)
                }
            }
        }
        guard status == Int32(VL_KEYKIT_OK) else {
            throw KeykitError(status: status, index: failed == Int.max ? nil : failed)
        }
        return try out.map { g throws(KeykitError) in
            VerifiedGeneration(generation: g.generation, reason: KeyReason(rawValue: g.reason) ?? .initial,
                               link: KeyLink(rawValue: g.link) ?? .replacement,
                               fingerprint: try Fingerprint(bytes: bytes(of: g.fingerprint)),
                               x25519PublicKey: bytes(of: g.x25519_public), ed25519PublicKey: bytes(of: g.ed25519_public))
        }
    }

    /// Follows the verified chain from a pin (the generation and fingerprint a person confirmed): `accepted` is the
    /// highest generation reached through signed rotations only, `newest` the chain's last; accepted < newest means a
    /// replacement waits for a person to confirm the newest fingerprint.
    public static func follow(_ chain: [SignedStatement], publicID: String, pinGeneration: UInt32,
                              pinFingerprint: Fingerprint) throws(KeykitError) -> (accepted: UInt32, newest: UInt32) {
        var accepted: UInt32 = 0
        var newest: UInt32 = 0
        let status = withSigned(chain) { list in
            publicID.withText { id, idn in
                pinFingerprint.bytes.withBytes { fp, _ in
                    vl_keykit_chain_follow(list, chain.count, id, idn, pinGeneration, fp, &accepted, &newest)
                }
            }
        }
        try check(status)
        return (accepted, newest)
    }

    /// Lays `chain` out as C structs whose pointers stay valid for `body`.
    private static func withSigned(_ chain: [SignedStatement],
                                   _ body: (UnsafePointer<vl_keykit_signed_statement>?) -> vl_keykit_status) -> vl_keykit_status {
        // Every field's bytes in one allocation, so the pointers stay put during the call.
        var blobs: [Data] = []
        for s in chain {
            blobs.append(Data(s.statement.utf8))
            blobs.append(s.signature)
            blobs.append(s.previousSignature ?? Data())
        }
        let total = blobs.reduce(0) { $0 + $1.count }
        let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: max(total, 1), alignment: 1)
        defer { storage.deallocate() }
        var offsets: [Int] = []
        var at = 0
        for b in blobs {
            offsets.append(at)
            b.withUnsafeBytes { src in
                if let base = src.baseAddress { storage.baseAddress!.advanced(by: at).copyMemory(from: base, byteCount: src.count) }
            }
            at += b.count
        }
        let base = storage.baseAddress!
        var structs: [vl_keykit_signed_statement] = []
        for (i, s) in chain.enumerated() {
            let st = base.advanced(by: offsets[3 * i]).assumingMemoryBound(to: CChar.self)
            let sig = base.advanced(by: offsets[3 * i + 1]).assumingMemoryBound(to: UInt8.self)
            let prev = base.advanced(by: offsets[3 * i + 2]).assumingMemoryBound(to: UInt8.self)
            // A signature of the wrong length is passed as it is: the library reads 64 bytes, so refuse it here.
            guard s.signature.count == 64, s.previousSignature.map({ $0.count == 64 }) ?? true else {
                return vl_keykit_status(VL_KEYKIT_ERR_INVALID_ARGUMENT)
            }
            structs.append(vl_keykit_signed_statement(statement: st, statement_len: blobs[3 * i].count, signature: sig,
                                                      previous_signature: s.previousSignature == nil ? nil : UnsafePointer(prev)))
        }
        return structs.withUnsafeBufferPointer { body($0.baseAddress) }
    }
}
