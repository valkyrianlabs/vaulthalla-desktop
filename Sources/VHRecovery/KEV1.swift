import CryptoKit
public import Foundation
public import VHCore

/// KEV1 key envelopes (vaulthalla-server design/encryption/03-metadata-recovery.md §5.2; the C++ reference is
/// vl-keykit `kev1.hpp`): one vault key version wrapped to one recipient's public key. Byte for byte the format
/// Vaulthalla Server and Vaulthalla Cloud read and write; `KEV1VectorsTests` reproduces vectors.json `kev1`.
///
///     offset  len  field
///      0       8   magic 89 56 48 4B 0D 0A 1A 0A
///      8       2   version 1
///     10       2   suite: 1 = X25519 (recovery recipients), 2 = P-256 (device grants)
///     12       1   purpose: 1 = a whole vault key version
///     13       1   recipient_class: 0 = customer-controlled
///     14       2   reserved, 0
///     16       4   key_version (>= 1)
///     20      16   vault_uid
///     36      32   recipient_id = SHA-256(recipient public key)
///     68       2   epk_len (32 or 65)
///     70   epk_len epk
///     70+e    48   AES-256-GCM(K_wrap, nonce 0^12, vault key, AAD = bytes[0 ..< 70+e])
///
///     K_wrap = HKDF-SHA-256(salt = epk ‖ rpk, IKM = Z, info = "vh.kev1.wrap" ‖ bytes[0 ..< 70+e], 32 bytes)
public enum KEV1 {
    public static let magic: [UInt8] = [0x89, 0x56, 0x48, 0x4B, 0x0D, 0x0A, 0x1A, 0x0A]
    public static let version: UInt16 = 1
    public static let purposeVaultKey: UInt8 = 1
    public static let classCustomer: UInt8 = 0
    public static let vaultKeyCount = 32
    public static let fixedPrefixCount = 70
    public static let wrappedCount = 48
    public static let objectPrefix = ".vaulthalla/key/"

    public enum Suite: UInt16, Sendable {
        case x25519 = 1
        case p256 = 2

        var ephemeralCount: Int { self == .x25519 ? 32 : 65 }
    }

    /// The reader's checks, in the order it makes them; the vectors name the first that fails.
    public enum Failure: String, Error, Sendable {
        case badMagic = "bad_magic"
        case unsupportedVersion = "unsupported_version"
        case unsupportedSuite = "unsupported_suite"
        case badPurpose = "bad_purpose"
        case unsupportedRecipientClass = "unsupported_recipient_class"
        case reservedNonzero = "reserved_nonzero"
        case vaultMismatch = "vault_mismatch"
        case recipientMismatch = "recipient_mismatch"
        case badLength = "bad_length"
        case badEphemeral = "bad_ephemeral"
        case wrapAuthFailed = "wrap_auth_failed"
        case badKeyVersion = "bad_key_version"
    }

    public enum InvalidInput: Error, Sendable {
        case vaultKeyNot32Bytes, keyVersionZero, badRecipientKey, badEphemeralSecret
    }

    /// A secret key a recipient opens envelopes with: X25519 (32 bytes) or a P-256 scalar (32 bytes).
    public struct RecipientSecret: Sendable {
        let suite: Suite
        let secret: SecretBytes

        public init(suite: Suite, secret: SecretBytes) {
            self.suite = suite
            self.secret = secret
        }

        /// The public key: X25519 raw (32 bytes) or the uncompressed P-256 point (65 bytes).
        public func publicKey() throws(KEV1.InvalidInput) -> Data {
            switch suite {
            case .x25519:
                guard let k = secret.withUnsafeBytes({ try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) })
                else { throw .badRecipientKey }
                return k.publicKey.rawRepresentation
            case .p256:
                guard let k = secret.withUnsafeBytes({ try? P256.KeyAgreement.PrivateKey(rawRepresentation: $0) })
                else { throw .badRecipientKey }
                return k.publicKey.x963Representation
            }
        }
    }

    public struct Header: Sendable, Equatable {
        public let suite: UInt16
        public let purpose: UInt8
        public let recipientClass: UInt8
        public let keyVersion: UInt32
        public let vaultUid: Uid
        public let recipientID: Data
    }

    public struct Unwrapped: Sendable {
        public let keyVersion: UInt32
        public let key: SecretBytes  // 32 bytes
    }

    /// SHA-256 of a recipient public key: the envelope's recipient_id.
    public static func recipientID(_ publicKey: some DataProtocol) -> Data { Data(SHA256.hash(data: publicKey)) }

    /// kid = base32(SHA-256(envelope)[0 ..< 16]); the bucket object is `.vaulthalla/key/<kid>`.
    public static func kid(_ envelope: some DataProtocol) -> String {
        Uid(bytes: Data(SHA256.hash(data: envelope)).prefix(Uid.byteCount))!.base32
    }

    // MARK: writer

    /// Wraps `vaultKey` (version `keyVersion` of `vaultUid`) to `recipientPublicKey`. The ephemeral key is fresh;
    /// `ephemeralSecretForTesting` fixes it (the vectors).
    public static func wrap(vaultKey: SecretBytes, suite: Suite, keyVersion: UInt32, vaultUid: Uid,
                            recipientPublicKey: Data, ephemeralSecretForTesting: Data? = nil) throws -> Data {
        guard vaultKey.count == vaultKeyCount else { throw InvalidInput.vaultKeyNot32Bytes }
        guard keyVersion != 0 else { throw InvalidInput.keyVersionZero }
        var envelope = Data(magic)
        envelope.append(be16(version))
        envelope.append(be16(suite.rawValue))
        envelope.append(contentsOf: [purposeVaultKey, classCustomer, 0, 0])
        envelope.append(be32(keyVersion))
        envelope.append(contentsOf: vaultUid.bytes)
        envelope.append(recipientID(recipientPublicKey))

        let z: Data
        let epk: Data
        switch suite {
        case .x25519:
            guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey),
                  recipientPublicKey.count == 32 else { throw InvalidInput.badRecipientKey }
            let mine: Curve25519.KeyAgreement.PrivateKey
            if let fixed = ephemeralSecretForTesting {
                guard let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: fixed)
                else { throw InvalidInput.badEphemeralSecret }
                mine = k
            } else {
                mine = Curve25519.KeyAgreement.PrivateKey()
            }
            epk = mine.publicKey.rawRepresentation
            z = try agree { try mine.sharedSecretFromKeyAgreement(with: peer) }
        case .p256:
            guard recipientPublicKey.count == 65,
                  let peer = try? P256.KeyAgreement.PublicKey(x963Representation: recipientPublicKey)
            else { throw InvalidInput.badRecipientKey }
            let mine: P256.KeyAgreement.PrivateKey
            if let fixed = ephemeralSecretForTesting {
                guard let k = try? P256.KeyAgreement.PrivateKey(rawRepresentation: fixed)
                else { throw InvalidInput.badEphemeralSecret }
                mine = k
            } else {
                mine = P256.KeyAgreement.PrivateKey()
            }
            epk = mine.publicKey.x963Representation
            z = try agree { try mine.sharedSecretFromKeyAgreement(with: peer) }
        }
        envelope.append(be16(UInt16(epk.count)))
        envelope.append(epk)
        let kWrap = wrapKey(z: z, epk: epk, rpk: recipientPublicKey, prefix: envelope)
        let sealed = try vaultKey.withUnsafeBytes { key in
            try AES.GCM.seal(Data(key), using: kWrap, nonce: zeroNonce, authenticating: envelope)
        }
        envelope.append(sealed.ciphertext)
        envelope.append(sealed.tag)
        return envelope
    }

    // MARK: reader

    /// The authenticated prefix's fields, read without a key. Applies the structural checks through reserved_nonzero
    /// and the length check; authenticates nothing.
    public static func inspect(_ envelope: Data) throws(Failure) -> Header {
        let env = [UInt8](envelope)
        try checkPrefix(env)
        let suite = be16(env, 10)
        guard let known = Suite(rawValue: suite) else { throw .unsupportedSuite }
        guard env[12] == purposeVaultKey else { throw .badPurpose }
        guard env[13] == classCustomer else { throw .unsupportedRecipientClass }
        guard env[14] == 0, env[15] == 0 else { throw .reservedNonzero }
        let epkLen = Int(be16(env, 68))
        guard epkLen == known.ephemeralCount, env.count == fixedPrefixCount + epkLen + wrappedCount else { throw .badLength }
        return Header(suite: suite, purpose: env[12], recipientClass: env[13], keyVersion: be32(env, 16),
                      vaultUid: Uid(bytes: env[20 ..< 36])!, recipientID: Data(env[36 ..< 68]))
    }

    /// Opens an envelope with the recipient's secret. Throws the first check that fails.
    public static func unwrap(_ envelope: Data, recipient: RecipientSecret, vaultUid: Uid) throws(Failure) -> Unwrapped {
        let env = [UInt8](envelope)
        try checkPrefix(env)
        let suite = be16(env, 10)
        guard suite == recipient.suite.rawValue else { throw .unsupportedSuite }
        guard env[12] == purposeVaultKey else { throw .badPurpose }
        guard env[13] == classCustomer else { throw .unsupportedRecipientClass }
        guard env[14] == 0, env[15] == 0 else { throw .reservedNonzero }
        let keyVersion = be32(env, 16)
        guard constantTimeEqual(Array(env[20 ..< 36]), vaultUid.bytes) else { throw .vaultMismatch }
        guard let rpk = try? recipient.publicKey() else { throw .recipientMismatch }
        guard constantTimeEqual(Array(env[36 ..< 68]), [UInt8](recipientID(rpk))) else { throw .recipientMismatch }
        let epkLen = Int(be16(env, 68))
        guard epkLen == recipient.suite.ephemeralCount, env.count == fixedPrefixCount + epkLen + wrappedCount
        else { throw .badLength }
        let prefix = Data(env[0 ..< fixedPrefixCount + epkLen])
        let epk = Data(env[fixedPrefixCount ..< fixedPrefixCount + epkLen])
        let z: Data
        do {
            switch recipient.suite {
            case .x25519:
                guard let mine = recipient.secret.withUnsafeBytes({ try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }),
                      let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk)
                else { throw Failure.badEphemeral }
                z = try agree { try mine.sharedSecretFromKeyAgreement(with: peer) }
            case .p256:
                guard let mine = recipient.secret.withUnsafeBytes({ try? P256.KeyAgreement.PrivateKey(rawRepresentation: $0) }),
                      let peer = try? P256.KeyAgreement.PublicKey(x963Representation: epk)
                else { throw Failure.badEphemeral }
                z = try agree { try mine.sharedSecretFromKeyAgreement(with: peer) }
            }
        } catch {
            throw .badEphemeral
        }
        let kWrap = wrapKey(z: z, epk: epk, rpk: rpk, prefix: prefix)
        let wrapped = env[fixedPrefixCount + epkLen ..< env.count]
        guard let box = try? AES.GCM.SealedBox(nonce: zeroNonce, ciphertext: Data(wrapped.prefix(vaultKeyCount)),
                                               tag: Data(wrapped.suffix(16))),
              var plain = try? AES.GCM.open(box, using: kWrap, authenticating: prefix)
        else { throw .wrapAuthFailed }
        defer { plain.resetBytes(in: 0 ..< plain.count) }
        guard keyVersion != 0 else { throw .badKeyVersion }
        return Unwrapped(keyVersion: keyVersion, key: SecretBytes(plain))
    }

    // MARK: helpers

    private static let zeroNonce = try! AES.GCM.Nonce(data: Data(count: 12))
    private static let info = Data("vh.kev1.wrap".utf8)

    private static func checkPrefix(_ env: [UInt8]) throws(Failure) {
        guard env.count >= fixedPrefixCount, Array(env[0 ..< 8]) == magic else { throw .badMagic }
        guard be16(env, 8) == version else { throw .unsupportedVersion }
    }

    /// Z: the X25519 output or the P-256 x-coordinate. All zero (a low-order peer) is refused.
    private static func agree(_ body: () throws -> SharedSecret) throws(Failure) -> Data {
        guard let secret = try? body() else { throw .badEphemeral }
        let z = secret.withUnsafeBytes { Data($0) }
        guard z.contains(where: { $0 != 0 }) else { throw .badEphemeral }
        return z
    }

    private static func wrapKey(z: Data, epk: Data, rpk: Data, prefix: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: z), salt: epk + rpk, info: info + prefix,
                               outputByteCount: 32)
    }

    private static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
    private static func be16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) << 8 | UInt16(b[at + 1]) }
    private static func be32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var acc: UInt8 = 0
        for i in 0 ..< a.count { acc |= a[i] ^ b[i] }
        return acc == 0
    }
}
