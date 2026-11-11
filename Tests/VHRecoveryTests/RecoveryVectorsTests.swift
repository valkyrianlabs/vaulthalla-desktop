import CryptoKit
import Foundation
import Testing
import VHCore
@testable import VHRecovery

/// The golden vectors every Vaulthalla implementation reproduces (vaulthalla-server design/encryption/vectors/,
/// vl-keykit vectors/), vendored byte for byte: Resources/SOURCE.json pins their SHA-256.
enum Vectors {
    static let data: Data = {
        let url = Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Resources")!
        return try! Data(contentsOf: url)
    }()
    static var root: [String: Any] { try! JSONSerialization.jsonObject(with: data) as! [String: Any] }
    static func section(_ name: String) -> [String: Any] { root[name] as! [String: Any] }
    static func list(_ section: String, _ name: String) -> [[String: Any]] { Self.section(section)[name] as! [[String: Any]] }
}

func hex(_ s: Any?) -> Data {
    let text = s as! String
    var out = Data()
    var i = text.startIndex
    while i < text.endIndex {
        let j = text.index(i, offsetBy: 2)
        out.append(UInt8(text[i ..< j], radix: 16)!)
        i = j
    }
    return out
}

func hexText(_ d: some DataProtocol) -> String { d.map { String(format: "%02x", $0) }.joined() }

struct VendoredVectorsTests {
    @Test func areTheServersCopyByteForByte() throws {
        let url = Bundle.module.url(forResource: "SOURCE", withExtension: "json", subdirectory: "Resources")!
        let source = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(hexText(Data(SHA256.hash(data: Vectors.data))) == source["sha256"] as? String)
    }
}

struct KEV1VectorsTests {
    @Test func reproducesEveryPositiveVector() throws {
        let positives = Vectors.list("kev1", "positive")
        #expect(positives.count >= 3)
        for v in positives {
            let name = v["name"] as! String
            let suite = KEV1.Suite(rawValue: UInt16(v["suite"] as! Int))!
            let uid = Uid(bytes: hex(v["vault_uid_hex"]))!
            let env = try KEV1.wrap(vaultKey: SecretBytes(hex(v["vault_key_hex"])), suite: suite,
                                    keyVersion: UInt32(v["key_version"] as! Int), vaultUid: uid,
                                    recipientPublicKey: hex(v["recipient_pk_hex"]),
                                    ephemeralSecretForTesting: hex(v["ephemeral_sk_hex"]))
            #expect(hexText(env) == v["envelope_hex"] as? String, "\(name): wrap")
            #expect(KEV1.objectPrefix + KEV1.kid(env) == v["object_key"] as? String, "\(name): kid")
            #expect(hexText(KEV1.recipientID(hex(v["recipient_pk_hex"]))) == v["recipient_id_hex"] as? String)

            let recipient = KEV1.RecipientSecret(suite: suite, secret: SecretBytes(hex(v["recipient_sk_hex"])))
            #expect(hexText(try recipient.publicKey()) == v["recipient_pk_hex"] as? String, "\(name): public key")
            let opened = try KEV1.unwrap(hex(v["envelope_hex"]), recipient: recipient, vaultUid: uid)
            #expect(opened.keyVersion == UInt32(v["key_version"] as! Int))
            #expect(opened.key.withUnsafeBytes { hexText($0) } == v["vault_key_hex"] as? String, "\(name): unwrap")

            let h = try KEV1.inspect(hex(v["envelope_hex"]))
            #expect(h.suite == suite.rawValue && h.keyVersion == UInt32(v["key_version"] as! Int) && h.vaultUid == uid)
        }
    }

    @Test func refusesEveryNegativeVectorWithItsErrorCode() {
        let negatives = Vectors.list("kev1", "negative")
        #expect(negatives.count >= 9)
        for v in negatives {
            let name = v["name"] as! String
            let expected = (v["expect"] as! [String: Any])["error"] as! String
            let suite = KEV1.Suite(rawValue: UInt16(v["suite_expected"] as! Int)) ?? .x25519
            let recipient = KEV1.RecipientSecret(suite: suite, secret: SecretBytes(hex(v["recipient_sk_hex"])))
            do {
                _ = try KEV1.unwrap(hex(v["envelope_hex"]), recipient: recipient, vaultUid: Uid(bytes: hex(v["vault_uid_hex"]))!)
                Issue.record("\(name): opened, expected \(expected)")
            } catch {
                #expect(error.rawValue == expected, "\(name)")
            }
        }
    }

    @Test func roundTripsWithFreshEphemeralsForBothSuites() throws {
        let uid = Uid.random()
        let key = SecretBytes((0 ..< 32).map { UInt8($0) })
        for suite in [KEV1.Suite.x25519, .p256] {
            let secret: SecretBytes
            switch suite {
            case .x25519: secret = Curve25519.KeyAgreement.PrivateKey().rawRepresentation.withUnsafeBytes { SecretBytes($0) }
            case .p256: secret = P256.KeyAgreement.PrivateKey().rawRepresentation.withUnsafeBytes { SecretBytes($0) }
            }
            let recipient = KEV1.RecipientSecret(suite: suite, secret: secret)
            let env = try KEV1.wrap(vaultKey: key, suite: suite, keyVersion: 7, vaultUid: uid,
                                    recipientPublicKey: try recipient.publicKey())
            let opened = try KEV1.unwrap(env, recipient: recipient, vaultUid: uid)
            #expect(opened.keyVersion == 7)
            #expect(opened.key.withUnsafeBytes { Array($0) } == Array(0 ..< 32))
            // Another vault's uid, a flipped byte of the wrapped key.
            #expect(throws: KEV1.Failure.vaultMismatch) { try KEV1.unwrap(env, recipient: recipient, vaultUid: Uid.random()) }
            var tampered = env
            tampered[tampered.count - 1] ^= 1
            #expect(throws: KEV1.Failure.wrapAuthFailed) { try KEV1.unwrap(tampered, recipient: recipient, vaultUid: uid) }
        }
    }
}

struct RecoverySeedVectorsTests {
    @Test func derivesTheRecipientAndSigningKeysOfEveryVector() throws {
        for v in Vectors.list("recovery_seed", "positive") {
            let seed = try RecoverySeed(text: v["seed_text"] as! String)
            #expect(seed.text() == v["seed_text"] as? String)
            #expect(seed.seed.withUnsafeBytes { hexText($0) } == v["seed_hex"] as? String)
            #expect(seed.x25519Secret().withUnsafeBytes { hexText($0) } == v["x25519_sk_hex"] as? String)
            #expect(hexText(seed.x25519PublicKey()) == v["x25519_pk_hex"] as? String)
            #expect(hexText(KEV1.recipientID(seed.x25519PublicKey())) == v["recipient_id_hex"] as? String)
            #expect(seed.ed25519Seed().withUnsafeBytes { hexText($0) } == v["ed25519_seed_hex"] as? String)
            #expect(hexText(seed.ed25519PublicKey()) == v["ed25519_pk_hex"] as? String)
            // The text form tolerates spaces, dashes and upper case.
            let text = v["seed_text"] as! String
            let spaced = text.uppercased().enumerated().map { $0.offset % 5 == 4 ? "\($0.element)-" : "\($0.element)" }.joined()
            #expect(try RecoverySeed(text: spaced).text() == text)
        }
        for v in Vectors.list("recovery_seed", "negative") {
            #expect(throws: RecoverySeed.Failure(rawValue: v["error"] as! String)!) {
                try RecoverySeed(text: v["seed_text"] as! String)
            }
        }
        #expect(throws: RecoverySeed.Failure.badLength) { try RecoverySeed(text: "short") }
    }

    @Test func generatedSeedsRoundTripThroughTheirText() throws {
        let seed = RecoverySeed.generate()
        #expect(try RecoverySeed(text: seed.text()).x25519PublicKey() == seed.x25519PublicKey())
    }
}

struct UidVectorsTests {
    @Test func encodesAndRefusesAsTheVectorsSay() {
        for v in Vectors.list("object_ids", "encode") {
            let uid = Uid(bytes: hex(v["uid_hex"]))!
            #expect(uid.base32 == v["b32"] as? String)
            #expect(Uid(base32: v["b32"] as! String) == uid)
        }
        for v in Vectors.list("object_ids", "decode_negative") {
            let why = v["why"] as? String ?? ""
            #expect(Uid(base32: v["text"] as! String) == nil, "\(why)")
        }
    }
}

struct RecoveryKitTests {
    @Test func readsAKitAndRefusesWhatIsntOne() throws {
        let seed = RecoverySeed.generate()
        let uid = Uid.random()
        let pk = Data(repeating: 9, count: 32).base64EncodedString()
        let json = """
        {"type": "vh.recovery-kit", "v": 1, "recovery_seed": "\(seed.text())", "unknown": true,
         "vaults": [{"vault_uid": "\(uid.base32)", "origin": {"node_id": "n-1", "vault_id": 42},
                     "attestation_public_keys": [{"key_id": 3, "public_key": "\(pk)"}],
                     "checkpoint": {"epoch": 812, "root_sha256": "\(String(repeating: "a", count: 64))"}}]}
        """
        let kit = try RecoveryKit(json: Data(json.utf8))
        #expect(kit.seed.x25519PublicKey() == seed.x25519PublicKey())
        let v = try #require(kit.vault(uid))
        #expect(v.originVaultID == 42 && v.originNodeID == "n-1" && v.attestationKeys.first?.keyID == 3)
        #expect(v.checkpoint?.epoch == 812)
        #expect(kit.vault(Uid.random()) == nil)

        #expect(throws: RecoveryKit.Failure.badKit("not a recovery kit")) {
            try RecoveryKit(json: Data(#"{"type": "x", "v": 1}"#.utf8))
        }
        #expect(throws: RecoveryKit.Failure.unsupportedVersion) {
            try RecoveryKit(json: Data(#"{"type": "vh.recovery-kit", "v": 2}"#.utf8))
        }
        #expect(throws: RecoveryKit.Failure.seed(.badLength)) {
            try RecoveryKit(json: Data(#"{"type": "vh.recovery-kit", "v": 1, "recovery_seed": "x"}"#.utf8))
        }
    }
}
