import CryptoKit
import Foundation
import Testing
import VHKeykit

/// KAK1 sealed to a real Secure Enclave P-256 key and opened through the agreement callback, the key never leaving
/// the enclave. Skipped where there is no Secure Enclave (a VM, an Intel Mac); no keychain item is written (the key's
/// data representation stays in memory), so an unsigned `swift test` can run it.
struct SecureEnclaveTests {
    @Test(.enabled(if: SecureEnclave.isAvailable)) func kak1OpensWithAnEnclaveKey() throws {
        let holder = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        let key = try AccountKey.generate()
        let statement = try key.statement(publicID: "5f0c3a3e-8d1b-4c2a-9e47-6b1d2f3a4c5e", generation: 1, previous: nil,
                                          reason: .initial)
        let kak1 = try key.wrap(statement, suite: .p256, to: holder.publicKey.x963Representation)
        let opened = try AccountKey.unwrap(kak1, holderPublicKey: holder.publicKey.x963Representation, suite: .p256,
                                           statement: statement) { epk, z in
            let shared = try holder.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: epk))
            shared.withUnsafeBytes { z.copyMemory(from: $0) }
        }
        #expect(opened.matches(statement))
        #expect(try opened.publicKeys().x25519 == key.publicKeys().x25519)
    }
}
