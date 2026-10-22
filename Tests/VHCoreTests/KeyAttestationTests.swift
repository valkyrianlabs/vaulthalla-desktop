import Foundation
import Testing
import VHCore

struct KeyAttestationTests {
    private let signature = Data(repeating: 7, count: 64).base64EncodedString()

    @Test func wellFormedMeansASerialKeyIDAnd64SignatureBytes() {
        #expect(KeyAttestation(keyID: 1, signature: signature).isWellFormed)
        #expect(KeyAttestation(keyID: Int64(Int32.max), signature: signature).isWellFormed)
        // The daemon's key ids are a SERIAL: 1...2^31 - 1.
        #expect(!KeyAttestation(keyID: 0, signature: signature).isWellFormed)
        #expect(!KeyAttestation(keyID: Int64(Int32.max) + 1, signature: signature).isWellFormed)
        #expect(!KeyAttestation(keyID: -1, signature: signature).isWellFormed)
        // Ed25519: exactly 64 bytes, base64.
        #expect(!KeyAttestation(keyID: 1, signature: "c2ln").isWellFormed)
        #expect(!KeyAttestation(keyID: 1, signature: "").isWellFormed)
        #expect(!KeyAttestation(keyID: 1, signature: "not base64!").isWellFormed)
        #expect(!KeyAttestation(keyID: 1, signature: Data(repeating: 7, count: 65).base64EncodedString()).isWellFormed)
    }
}
