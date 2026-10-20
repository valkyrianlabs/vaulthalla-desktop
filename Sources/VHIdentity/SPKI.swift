public import Foundation
public import Security
import CryptoKit
import X509

/// SubjectPublicKeyInfo helpers. A pin, a device id and every protocol hash in docs/pairing.md use
/// `SHA-256(DER(SubjectPublicKeyInfo))`, the same bytes OpenSSL hashes with `i2d_X509_PUBKEY`, so the daemon and
/// Desktop agree without exchanging anything but certificates.
public enum SPKI {
    /// Length of an SPKI SHA-256 hash.
    public static let hashLength = 32

    /// DER of `SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING (0 unused bits) ... }` up to the
    /// 65-byte uncompressed point. Every P-256 SPKI is this prefix followed by `04 ‖ X ‖ Y`, 91 bytes in total.
    static let p256Prefix: [UInt8] = [
        0x30, 0x59,  // SEQUENCE, 89 bytes
        0x30, 0x13,  // SEQUENCE (AlgorithmIdentifier), 19 bytes
        0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,  // OID 1.2.840.10045.2.1 id-ecPublicKey
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,  // OID 1.2.840.10045.3.1.7 prime256v1
        0x03, 0x42, 0x00,  // BIT STRING, 66 bytes, 0 unused bits
    ]

    /// The DER SubjectPublicKeyInfo of an EC P-256 key. Accepts a public key or a private key (whose public half
    /// is used); a Secure Enclave private key works because only its public half is read.
    public static func p256DER(of key: SecKey) throws -> Data {
        let publicKey = try publicHalf(of: key)
        guard let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
            (attributes[kSecAttrKeyType] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String),
            (attributes[kSecAttrKeySizeInBits] as? Int) == 256
        else { throw IdentityError.unsupportedKey("expected an EC P-256 key") }

        var error: Unmanaged<CFError>?
        guard let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw IdentityError.unsupportedKey("public key export failed: \(describe(error))")
        }
        // SecKey's external representation of an EC public key is the ANSI X9.63 uncompressed point.
        guard point.count == 65, point.first == 0x04 else {
            throw IdentityError.unsupportedKey("expected a 65-byte uncompressed P-256 point")
        }
        return Data(p256Prefix) + point
    }

    /// The DER SubjectPublicKeyInfo exactly as it appears in `certificate`. Any key type the certificate parser
    /// understands is accepted here; protocol code checks the algorithm separately.
    public static func der(of certificate: SecCertificate) throws -> Data {
        let parsed: Certificate
        do {
            parsed = try Certificate(certificate)
        } catch {
            throw IdentityError.certificate("unparseable certificate: \(error)")
        }
        return try der(of: parsed.publicKey)
    }

    static func der(of publicKey: Certificate.PublicKey) throws -> Data {
        do {
            return Data(try publicKey.serializeAsPEM().derBytes)
        } catch {
            throw IdentityError.certificate("SPKI serialization failed: \(error)")
        }
    }

    static func publicHalf(of key: SecKey) throws -> SecKey {
        let attributes = SecKeyCopyAttributes(key) as? [CFString: Any]
        if (attributes?[kSecAttrKeyClass] as? String) == (kSecAttrKeyClassPublic as String) { return key }
        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw IdentityError.unsupportedKey("the key has no public half")
        }
        return publicKey
    }
}

/// SHA-256 over the DER SubjectPublicKeyInfo of `certificate`: the value both sides pin.
public func spkiSHA256(_ certificate: SecCertificate) throws -> Data {
    Data(SHA256.hash(data: try SPKI.der(of: certificate)))
}

/// SHA-256 over the DER SubjectPublicKeyInfo of an EC P-256 key (public, or private whose public half is used).
public func spkiSHA256(publicKey: SecKey) throws -> Data {
    Data(SHA256.hash(data: try SPKI.p256DER(of: publicKey)))
}

/// Desktop's device id for a node: lowercase hex of the device certificate's SPKI SHA-256 (64 characters).
public func deviceID(spkiSHA256: Data) -> String {
    spkiSHA256.lowercaseHex
}

extension Data {
    /// Lowercase hex, two characters per byte. Only ever applied to public values (hashes, nonces, codes).
    var lowercaseHex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Renders a `CFError` from Security.framework. Those messages describe the failing operation, never key bytes.
func describe(_ error: Unmanaged<CFError>?) -> String {
    guard let error = error?.takeRetainedValue() else { return "unknown error" }
    return CFErrorCopyDescription(error) as String? ?? "unknown error"
}
