import CryptoKit
import Foundation
import Security
import Testing
import VHIdentity
import X509

@Suite struct DeviceCertificateTests {
    @Test func profile() throws {
        let key = try ephemeralKey()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let der = try DeviceCertificate.make(
            privateKey: key, commonName: DeviceCertificate.commonName(deviceName: "Cooper's MacBook Pro"), now: now)

        // Security.framework accepts it.
        let secCertificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(secCertificate) as String? == "Vaulthalla Desktop Cooper's MacBook Pro")

        let certificate = try Certificate(derEncoded: Array(der))
        #expect(certificate.version == .v3)
        #expect(certificate.signatureAlgorithm == .ecdsaWithSHA256)
        #expect(certificate.issuer == certificate.subject)
        #expect(certificate.serialNumber.bytes.count >= 16)
        #expect(certificate.notValidAfter.timeIntervalSince(now) == DeviceCertificate.validity)
        #expect(certificate.notValidBefore < now)
        #expect(P256.Signing.PublicKey(certificate.publicKey) != nil)

        let keyUsage = try #require(try certificate.extensions.keyUsage)
        #expect(keyUsage.digitalSignature && !keyUsage.keyCertSign)
        let extendedKeyUsage = try #require(try certificate.extensions.extendedKeyUsage)
        #expect(Array(extendedKeyUsage) == [.clientAuth])
        #expect(try certificate.extensions.basicConstraints == .notCertificateAuthority)

        // Self-signed: the certificate's own key verifies its signature.
        #expect(certificate.publicKey.isValidSignature(certificate.signature, for: certificate))
    }

    @Test func serialsAreRandom() throws {
        let key = try ephemeralKey()
        let first = try Certificate(derEncoded: Array(DeviceCertificate.make(privateKey: key, commonName: "a")))
        let second = try Certificate(derEncoded: Array(DeviceCertificate.make(privateKey: key, commonName: "a")))
        #expect(first.serialNumber != second.serialNumber)
    }
}
