import Foundation
import Testing
import VHCore
import VHKeykit

/// The sealed storage credential through the Swift wrapper and the C API under it, against `vhc.json`
/// `storage_credential`: every positive opens to its secret under its binding, every negative fails at its first check,
/// and a one-time key seals and opens only for itself.
struct StorageCredentialTests {
    static func context(_ v: [String: Any]) -> (installation: String, uid: Data, keyID: String) {
        let c = v["context"] as! [String: Any]
        return (c["installation_id"] as! String, hex(c["vault_uid_hex"]), c["key_id"] as! String)
    }

    @Test func positivesOpenUnderTheirBinding() throws {
        let positives = VHC.list("storage_credential", "positive")
        #expect(positives.count >= 3)
        for v in positives {
            let key = try CredentialKey(secretKey: SecretBytes(hex(v["server_sk_hex"])))
            #expect(hexText(try key.publicKey()) == v["server_pk_hex"] as! String)
            let (installation, uid, keyID) = Self.context(v)
            let sealed = hex(v["sealed_hex"])
            let opened = try key.open(sealed, installationID: installation, vaultUid: uid, keyID: keyID)
            #expect(opened.count == (v["secret"] as! String).utf8.count)
            #expect(try opened.withSecret { Data($0) } == Data((v["secret"] as! String).utf8))
            #expect("\(opened)" == "OpenedCredential(redacted)")
        }
    }

    @Test func negativesFailAtTheirFirstCheck() throws {
        for v in VHC.list("storage_credential", "negative") {
            let key = try CredentialKey(secretKey: SecretBytes(hex(v["server_sk_hex"])))
            let (installation, uid, keyID) = Self.context(v)
            do {
                _ = try key.open(hex(v["sealed_hex"]), installationID: installation, vaultUid: uid, keyID: keyID)
                Issue.record("\(v["name"]!) opened")
            } catch {
                expectRefusal(error, v["error"], prefix: "credential")
            }
        }
    }

    @Test func aOneTimeKeyOpensOnlyWhatWasSealedToIt() throws {
        let a = try CredentialKey.generate(), b = try CredentialKey.generate()
        #expect(try a.publicKey() != b.publicKey())
        let installation = "kceypk9vfn5tv6yx5c6qpfebdm", uid = Data(repeating: 9, count: 16), keyID = "005f3c2a9b1d4e6"
        let secret = SecretBytes(Array("an application key secret".utf8))
        let sealed = try StorageCredential.seal(secret, installationID: installation, vaultUid: uid, keyID: keyID,
                                                to: a.publicKey())
        #expect(sealed.count == 44 + secret.count + 16)
        let opened = try a.open(sealed, installationID: installation, vaultUid: uid, keyID: keyID)
        #expect(try opened.secretBytes().withUnsafeBytes { Data($0) } == Data("an application key secret".utf8))
        #expect(throws: KeykitError.self) { _ = try b.open(sealed, installationID: installation, vaultUid: uid, keyID: keyID) }
        // The binding: another installation, vault or key id; and ranges the format refuses.
        let other = "t8strmqnma7qe89214v79ecrmc"
        for (i, u, k, name) in [(other, uid, keyID, "credential_auth_failed"),
                                (installation, Data(repeating: 8, count: 16), keyID, "credential_auth_failed"),
                                (installation, uid, keyID + "x", "credential_auth_failed"),
                                (installation, uid, "", "invalid_argument"),
                                (installation, uid, "key id", "invalid_argument"),
                                (String(installation.dropLast()), uid, keyID, "invalid_argument")] {
            #expect(throws: KeykitError.self) { _ = try a.open(sealed, installationID: i, vaultUid: u, keyID: k) }
            do { _ = try a.open(sealed, installationID: i, vaultUid: u, keyID: k) } catch { #expect(error.name == name) }
        }
        #expect(throws: KeykitError.invalidArgument) {
            _ = try a.open(sealed, installationID: installation, vaultUid: Data(count: 15), keyID: keyID)
        }
        #expect(throws: KeykitError.invalidArgument) { _ = try CredentialKey(secretKey: SecretBytes([1, 2, 3])) }
        #expect(throws: KeykitError.invalidArgument) {
            _ = try StorageCredential.seal(SecretBytes([UInt8](repeating: 1, count: StorageCredential.maxSecretSize + 1)),
                                           installationID: installation, vaultUid: uid, keyID: keyID, to: a.publicKey())
        }
    }
}
