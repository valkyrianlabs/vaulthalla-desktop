public import Foundation
public import Security

/// Where a device's private key lives.
public enum KeyBackend: String, Sendable, Hashable, Codable {
    /// A P-256 key generated inside the Secure Enclave. The private key never exists outside it. Needs a signed app
    /// with a keychain access group; creating one fails with ``IdentityError/missingEntitlement(operation:)``
    /// otherwise.
    case secureEnclave
    /// A P-256 key generated in software and stored, non-extractable, in the Keychain. Used by tests and as the
    /// fallback on Macs without a Secure Enclave (none ship with Apple silicon, so in practice: tests).
    case software
}

/// Desktop's identity toward one node: a P-256 private key, the self-signed certificate wrapping it, and the
/// Keychain `SecIdentity` that pairs them (what Network.framework presents as the TLS client certificate).
///
/// `@unchecked Sendable` because `SecKey`, `SecCertificate` and `SecIdentity` are immutable CoreFoundation objects
/// whose functions are thread-safe; the SDK just doesn't annotate them.
public struct DeviceIdentity: @unchecked Sendable, CustomStringConvertible {
    /// The node this identity belongs to (``DeviceIdentityStore`` key).
    public let nodeTag: String
    public let backend: KeyBackend
    /// The private key. For ``KeyBackend/secureEnclave`` a handle; the key material stays in the enclave.
    public let privateKey: SecKey
    public let certificate: SecCertificate
    /// Key and certificate as the Keychain pairs them. Hand this to `sec_identity_create` for TLS.
    public let secIdentity: SecIdentity
    /// SHA-256 of the certificate's DER SubjectPublicKeyInfo: what the daemon stores in `devices.spki_sha256`.
    public let spkiSHA256: Data
    /// The device name the certificate was issued for (its common name without the "Vaulthalla Desktop " prefix).
    public let deviceName: String
    public let notValidBefore: Date
    public let notValidAfter: Date

    /// The device id: lowercase hex of ``spkiSHA256``.
    public var deviceID: String { VHIdentity.deviceID(spkiSHA256: spkiSHA256) }

    /// The certificate's DER encoding (public; safe to send and log).
    public var certificateDER: Data { SecCertificateCopyData(certificate) as Data }

    /// Redacted: the node tag, backend and device id only.
    public var description: String {
        "DeviceIdentity(node: \(nodeTag), backend: \(backend.rawValue), device: \(deviceID))"
    }

    /// Assembles an identity from a Keychain `SecIdentity`, checking that its key and certificate match.
    init(nodeTag: String, secIdentity: SecIdentity) throws {
        var key: SecKey?
        var status = SecIdentityCopyPrivateKey(secIdentity, &key)
        guard status == errSecSuccess, let key else { throw IdentityError.keychain("copy identity key", status) }
        var certificate: SecCertificate?
        status = SecIdentityCopyCertificate(secIdentity, &certificate)
        guard status == errSecSuccess, let certificate else {
            throw IdentityError.keychain("copy identity certificate", status)
        }

        let spki = try VHIdentity.spkiSHA256(certificate)
        guard try VHIdentity.spkiSHA256(publicKey: key) == spki else {
            throw IdentityError.certificate("the Keychain paired a certificate with a different key")
        }

        let attributes = SecKeyCopyAttributes(key) as? [CFString: Any]
        let token = attributes?[kSecAttrTokenID] as? String
        let commonName = (SecCertificateCopySubjectSummary(certificate) as String?) ?? ""
        let prefix = DeviceCertificate.commonName(deviceName: "")
        let window = try DeviceCertificate.validityWindow(of: certificate)

        self.nodeTag = nodeTag
        self.backend = token == (kSecAttrTokenIDSecureEnclave as String) ? .secureEnclave : .software
        self.privateKey = key
        self.certificate = certificate
        self.secIdentity = secIdentity
        self.spkiSHA256 = spki
        self.deviceName = commonName.hasPrefix(prefix) ? String(commonName.dropFirst(prefix.count)) : commonName
        self.notValidBefore = window.lowerBound
        self.notValidAfter = window.upperBound
    }
}

/// A rotation in progress: the identity the node knows, its replacement, and the proof that links them.
public struct IdentityRotation: Sendable {
    /// The identity currently paired with the node. Keep using it until the daemon accepts the proof.
    public let current: DeviceIdentity
    /// The new identity, stored under the pending slot until ``DeviceIdentityStore/completeRotation(for:)``.
    public let replacement: DeviceIdentity
    /// The payload for `device.identity.rotate`.
    public let proof: RotationProof
}
