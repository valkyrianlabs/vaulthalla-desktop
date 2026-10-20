import CryptoKit
import Foundation
import Security
import Testing
import VHIdentity
import X509

@Suite struct SPKITests {
    /// The P-256 generator point (private scalar 1): docs/pairing.md §8 vector.
    static let generator = Data(
        hex: "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce"
            + "33576b315ececbb6406837bf51f5")

    @Test func generatorVector() throws {
        let key = try publicKey(x963: Self.generator)
        let der = try SPKI.p256DER(of: key)
        #expect(der.count == 91)
        #expect(der.hex.hasPrefix("3059301306072a8648ce3d020106082a8648ce3d030107034200"))
        let hash = try spkiSHA256(publicKey: key)
        #expect(hash.hex == "5cd252fb0ce8932436faf8ccd1040981b89ee4ad6b9fe9e2a2b7e71aacb27cd3")
        #expect(deviceID(spkiSHA256: hash) == hash.hex)
    }

    /// Our hand-built DER must equal swift-certificates' own SubjectPublicKeyInfo serialization of the same key.
    @Test(arguments: 0..<8) func matchesSwiftCertificates(_ round: Int) throws {
        let key = try ephemeralKey()
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let point = try #require(SecKeyCopyExternalRepresentation(publicKey, nil))
        let cryptoKitKey = try P256.Signing.PublicKey(x963Representation: point as Data)
        let reference = try Certificate.PublicKey(cryptoKitKey).serializeAsPEM().derBytes
        #expect(try SPKI.p256DER(of: key) == Data(reference))
        #expect(try spkiSHA256(publicKey: key) == Data(SHA256.hash(data: reference)))
    }

    @Test func certificateAndKeyAgree() throws {
        let key = try ephemeralKey()
        let certificate = try DeviceCertificate.secCertificate(
            der: DeviceCertificate.make(privateKey: key, commonName: "Vaulthalla Desktop Test"))
        #expect(try spkiSHA256(certificate) == spkiSHA256(publicKey: key))
        // Also through Security.framework's own view of the certificate's key.
        let certificateKey = try #require(SecCertificateCopyKey(certificate))
        #expect(try spkiSHA256(publicKey: certificateKey) == spkiSHA256(publicKey: key))
    }

    @Test func rejectsNonP256Keys() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 384]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        #expect(throws: IdentityError.self) { try spkiSHA256(publicKey: key) }
    }
}
