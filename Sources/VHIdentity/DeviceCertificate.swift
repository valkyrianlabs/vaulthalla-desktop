public import Foundation
public import Security
import X509

/// The self-signed certificate that carries a device key into TLS (profile in docs/pairing.md §2).
///
/// Nobody validates a chain to it: the daemon authorizes the device by the certificate's SPKI hash. The certificate
/// still has to be well-formed, because OpenSSL parses it during the handshake and Security.framework has to accept
/// it to pair it with the key into a `SecIdentity`.
public enum DeviceCertificate {
    /// How long a device certificate is valid. Rotation (every 90 days) replaces it long before it expires; the
    /// daemon doesn't enforce the dates, but a sane window keeps strict TLS stacks happy.
    public static let validity: TimeInterval = 2 * 365 * 24 * 60 * 60

    /// Clock-skew allowance applied to `notValidBefore`.
    static let backdate: TimeInterval = 60 * 60

    /// The subject common name for a device certificate.
    public static func commonName(deviceName: String) -> String {
        "Vaulthalla Desktop \(deviceName)"
    }

    /// Builds and signs a certificate for `privateKey` (EC P-256, Secure Enclave or software). Returns DER.
    ///
    /// Signing goes through `SecKeyCreateSignature` (swift-certificates wraps the `SecKey` directly), so a Secure
    /// Enclave key signs its own certificate without the private key ever leaving the enclave.
    public static func make(
        privateKey: SecKey,
        commonName: String,
        now: Date = .now,
        validity: TimeInterval = DeviceCertificate.validity
    ) throws -> Data {
        _ = try SPKI.p256DER(of: privateKey)  // device certificates are ECDSA P-256 only
        let signer: Certificate.PrivateKey
        do {
            signer = try Certificate.PrivateKey(privateKey)
        } catch {
            throw IdentityError.unsupportedKey("swift-certificates can't use the key: \(error)")
        }

        do {
            let name = try DistinguishedName { CommonName(commonName) }
            let extensions = try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.clientAuth])
            }
            let certificate = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(),  // 20 random bytes, positive
                publicKey: signer.publicKey,
                notValidBefore: now.addingTimeInterval(-backdate),
                notValidAfter: now.addingTimeInterval(validity),
                issuer: name,
                subject: name,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: extensions,
                issuerPrivateKey: signer
            )
            return Data(try certificate.serializeAsPEM().derBytes)
        } catch let error as IdentityError {
            throw error
        } catch {
            throw IdentityError.certificate("building the certificate failed: \(error)")
        }
    }

    /// Parses DER into a `SecCertificate`, failing if Security.framework rejects it.
    public static func secCertificate(der: Data) throws -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw IdentityError.certificate("Security.framework rejected the DER encoding")
        }
        return certificate
    }

    /// The certificate's validity window, read with swift-certificates.
    static func validityWindow(of certificate: SecCertificate) throws -> ClosedRange<Date> {
        do {
            let parsed = try Certificate(certificate)
            return parsed.notValidBefore...parsed.notValidAfter
        } catch {
            throw IdentityError.certificate("unparseable certificate: \(error)")
        }
    }
}
