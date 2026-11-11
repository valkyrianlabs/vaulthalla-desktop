import CryptoKit
public import Foundation
public import VHCore

/// The recovery seed (vaulthalla-server spec 03 §5.3; vl-keykit `seed.hpp`; vectors.json `recovery_seed`): 16 random
/// bytes, written as 26 base32 symbols and a check symbol. A recovery kit holds it; it derives the vault's X25519
/// recovery recipient and an Ed25519 signing key:
///
///     PRK = HKDF-Extract(salt = "vh.recovery.v1", IKM = seed)
///     x25519 secret = HKDF-Expand(PRK, "x25519", 32);  ed25519 seed = HKDF-Expand(PRK, "ed25519", 32)
public struct RecoverySeed: Sendable {
    public static let byteCount = 16
    public static let textCount = 27

    public enum Failure: String, Error, Sendable {
        case badLength = "bad_length"
        case badSymbol = "bad_symbol"
        case badCheck = "bad_check"
    }

    let seed: SecretBytes

    public init(bytes: SecretBytes) throws(Failure) {
        guard bytes.count == Self.byteCount else { throw .badLength }
        seed = bytes
    }

    /// Parses the text form: spaces and dashes are ignored, upper case is accepted.
    public init(text: String) throws(Failure) {
        let clean = String(text.lowercased().filter { !$0.isWhitespace && $0 != "-" })
        guard clean.utf8.count == Self.textCount else { throw .badLength }
        guard let raw = Base32.decode(String(clean.prefix(Self.textCount - 1)), byteCount: Self.byteCount)
        else { throw .badSymbol }
        let bytes = SecretBytes(raw)
        guard clean.last.map({ UInt8(ascii: $0.unicodeScalars.first!) }) == Self.checkSymbol(bytes)
        else { throw .badCheck }
        seed = bytes
    }

    public static func generate() -> RecoverySeed {
        var raw = [UInt8](repeating: 0, count: byteCount)
        precondition(SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess)
        defer { raw.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return try! RecoverySeed(bytes: SecretBytes(raw))
    }

    /// The text form; only for the kit (1Password, print), never a log.
    public func text() -> String {
        seed.withUnsafeBytes { raw in Base32.encode(Array(raw)) } + String(UnicodeScalar(Self.checkSymbol(seed)))
    }

    public func x25519Secret() -> SecretBytes { expand("x25519") }
    public func x25519PublicKey() -> Data {
        let k = x25519Secret().withUnsafeBytes { try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
        return k.publicKey.rawRepresentation
    }
    /// The recipient this seed opens envelopes as (KEV1 suite 1).
    public func recipient() -> KEV1.RecipientSecret { KEV1.RecipientSecret(suite: .x25519, secret: x25519Secret()) }

    public func ed25519Seed() -> SecretBytes { expand("ed25519") }
    public func ed25519PublicKey() -> Data {
        let k = ed25519Seed().withUnsafeBytes { try! Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
        return k.publicKey.rawRepresentation
    }

    private func expand(_ label: String) -> SecretBytes {
        let key = seed.withUnsafeBytes { raw in
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw), salt: Data("vh.recovery.v1".utf8),
                                   info: Data(label.utf8), outputByteCount: 32)
        }
        return key.withUnsafeBytes { SecretBytes($0) }
    }

    /// The check symbol: alphabet[SHA-256(seed)[0] >> 3].
    static func checkSymbol(_ seed: SecretBytes) -> UInt8 {
        let digest = seed.withUnsafeBytes { Data(SHA256.hash(data: $0)) }
        return Uid.alphabet[Int(digest[0] >> 3)]
    }
}
