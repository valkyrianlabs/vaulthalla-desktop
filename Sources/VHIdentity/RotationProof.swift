public import Foundation
public import Security

/// The old device key's endorsement of a new one, sent with `device.identity.rotate` (docs/pairing.md §4).
///
/// ```
/// message   = "vh-device-rotate-v1" ‖ new_spki_sha256 ‖ server_spki_sha256 ‖ UInt64BE(timestamp)
/// signature = ECDSA-P256-SHA256(old_key, message), DER (X9.62 Ecdsa-Sig-Value)
/// ```
///
/// Binding the server SPKI keeps a proof minted for one node from being replayed to another; the timestamp bounds
/// replay against the same node. The new certificate is self-signed by the new key, which proves possession of it.
public struct RotationProof: Sendable, Hashable {
    /// Domain separator for the signed message.
    public static let domain = Data("vh-device-rotate-v1".utf8)

    /// DER of the new device certificate.
    public let newCertificateDER: Data
    /// SHA-256 of the new certificate's SPKI (the new device id), included so callers needn't recompute it.
    public let newSPKISHA256: Data
    /// Seconds since the Unix epoch when the proof was made; the daemon accepts ±300 s.
    public let timestamp: UInt64
    /// DER-encoded ECDSA signature by the old key over ``message(newSPKISHA256:serverSPKISHA256:timestamp:)``.
    public let signature: Data

    public init(newCertificateDER: Data, newSPKISHA256: Data, timestamp: UInt64, signature: Data) {
        self.newCertificateDER = newCertificateDER
        self.newSPKISHA256 = newSPKISHA256
        self.timestamp = timestamp
        self.signature = signature
    }

    /// The exact bytes the old key signs (91 bytes).
    public static func message(newSPKISHA256: Data, serverSPKISHA256: Data, timestamp: UInt64) throws -> Data {
        try PairingCode.check(newSPKISHA256, "new_spki_sha256", SPKI.hashLength)
        try PairingCode.check(serverSPKISHA256, "server_spki_sha256", SPKI.hashLength)
        var message = domain
        message.append(newSPKISHA256)
        message.append(serverSPKISHA256)
        withUnsafeBytes(of: timestamp.bigEndian) { message.append(contentsOf: $0) }
        return message
    }

    /// Signs a rotation from `oldKey` (the private key currently paired with the node) to the certificate
    /// `newCertificateDER`.
    public static func sign(
        oldKey: SecKey,
        newCertificateDER: Data,
        serverSPKISHA256: Data,
        at date: Date = .now
    ) throws -> RotationProof {
        let newSPKI = try spkiSHA256(DeviceCertificate.secCertificate(der: newCertificateDER))
        let timestamp = UInt64(max(0, date.timeIntervalSince1970.rounded(.down)))
        let message = try message(newSPKISHA256: newSPKI, serverSPKISHA256: serverSPKISHA256, timestamp: timestamp)

        var error: Unmanaged<CFError>?
        guard
            let signature = SecKeyCreateSignature(
                oldKey, .ecdsaSignatureMessageX962SHA256, message as CFData, &error) as Data?
        else { throw IdentityError.signing(describe(error)) }
        return RotationProof(
            newCertificateDER: newCertificateDER, newSPKISHA256: newSPKI, timestamp: timestamp, signature: signature)
    }

    /// Checks the signature against the old public key, as the daemon does. Desktop uses it to self-check before
    /// sending; tests use it to pin the byte layout.
    public func isValid(oldPublicKey: SecKey, serverSPKISHA256: Data) -> Bool {
        guard
            let certificate = try? DeviceCertificate.secCertificate(der: newCertificateDER),
            (try? spkiSHA256(certificate)) == newSPKISHA256,
            let message = try? Self.message(
                newSPKISHA256: newSPKISHA256, serverSPKISHA256: serverSPKISHA256, timestamp: timestamp),
            let publicKey = try? SPKI.publicHalf(of: oldPublicKey)
        else { return false }
        return SecKeyVerifySignature(
            publicKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature as CFData, nil)
    }
}
