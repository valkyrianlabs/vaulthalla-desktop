import Foundation
import Security
import Testing
import VHIdentity

@Suite struct RotationProofTests {
    /// docs/pairing.md §8 rotation vector (signature made with Python `cryptography`).
    static let oldPublicKey = Data(
        hex: "04cb6cf2c3631fb1cd0931b5f154f8f255592fbcb76c96ec1a68f80dd0f1510393b0ff71f18a3c3dd81af6ff0311d2ef98b66"
            + "4b8437b5ebf80aa4beb29649bb58a")
    static let newSPKI = Data(hex: "c5a4bd12f47b9e4a810de5de3dc0b906e20e710dfcfd344e8f934b47b6df4fe1")
    static let serverSPKI = Data.counting(from: 0x00)
    static let timestamp: UInt64 = 1_790_000_000
    static let message = Data(
        hex: "76682d6465766963652d726f746174652d7631c5a4bd12f47b9e4a810de5de3dc0b906e20e710dfcfd344e8f934b47b6df4fe1"
            + "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f000000006ab13b80")
    static let signature = Data(
        hex: "30440220768b64330311652f611615e15e6260f1bd4bc913557e19aaa5a45a4f16fde19002201daae21d09e5a1f875214711"
            + "95900aa3be36b3fba00e654966453018ccf80205")

    @Test func messageLayoutVector() throws {
        let message = try RotationProof.message(
            newSPKISHA256: Self.newSPKI, serverSPKISHA256: Self.serverSPKI, timestamp: Self.timestamp)
        #expect(message == Self.message)
        #expect(message.count == 91)
    }

    @Test func externalSignatureVerifies() throws {
        let key = try publicKey(x963: Self.oldPublicKey)
        #expect(
            SecKeyVerifySignature(
                key, .ecdsaSignatureMessageX962SHA256, Self.message as CFData, Self.signature as CFData, nil))
    }

    @Test func signAndVerify() throws {
        let oldKey = try ephemeralKey()
        let newKey = try ephemeralKey()
        let newCertificate = try DeviceCertificate.make(privateKey: newKey, commonName: "Vaulthalla Desktop New")
        let proof = try RotationProof.sign(
            oldKey: oldKey, newCertificateDER: newCertificate, serverSPKISHA256: Self.serverSPKI,
            at: Date(timeIntervalSince1970: 1_790_000_000.9))

        #expect(proof.timestamp == 1_790_000_000)
        #expect(proof.newSPKISHA256 == (try spkiSHA256(publicKey: newKey)))
        let oldPublic = try #require(SecKeyCopyPublicKey(oldKey))
        #expect(proof.isValid(oldPublicKey: oldPublic, serverSPKISHA256: Self.serverSPKI))

        // Bound to the server, the signer and the certificate.
        #expect(!proof.isValid(oldPublicKey: oldPublic, serverSPKISHA256: Data.counting(from: 0x01)))
        let newPublic = try #require(SecKeyCopyPublicKey(newKey))
        #expect(!proof.isValid(oldPublicKey: newPublic, serverSPKISHA256: Self.serverSPKI))
        let otherCertificate = try DeviceCertificate.make(privateKey: try ephemeralKey(), commonName: "other")
        let swapped = RotationProof(
            newCertificateDER: otherCertificate, newSPKISHA256: proof.newSPKISHA256, timestamp: proof.timestamp,
            signature: proof.signature)
        #expect(!swapped.isValid(oldPublicKey: oldPublic, serverSPKISHA256: Self.serverSPKI))
    }
}
