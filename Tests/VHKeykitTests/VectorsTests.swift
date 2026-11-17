import CryptoKit
import Foundation
import Testing
import VHCore
import VHKeykit
import VHRecovery

/// vl-keykit's golden vectors (`vectors/vhc.json`, the cloud formats; `vectors/vectors.json`, KEV1 and the seed) run
/// through the Swift wrapper and the C API under it. `tools/keykit/build-vlkeykit.sh` refuses to build when these copies
/// differ from the pinned source's.
enum VHC {
    static var root: [String: Any] { load("vhc") }
    static var shared: [String: Any] { load("vectors") }

    static func load(_ name: String) -> [String: Any] {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    static func section(_ name: String) -> [String: Any] { root[name] as! [String: Any] }
    static func list(_ section: String, _ name: String) -> [[String: Any]] { Self.section(section)[name] as! [[String: Any]] }
    static var generations: [[String: Any]] { list("account_key", "generations") }
    static var publicID: String { section("account_key")["public_id"] as! String }

    /// The account key whose seed is `seedHex` (the vectors name seeds by their bytes; the C API reads the code).
    static func key(seedHex: String) -> AccountKey {
        // The seed's text through the independent Swift reader (VHRecovery), which the shared vectors check.
        let text = try! RecoverySeed(bytes: SecretBytes(hex(seedHex))).text()
        return try! AccountKey(recoveryCode: text)
    }

    static func key(generation: Int) -> AccountKey { try! AccountKey(recoveryCode: generations[generation - 1]["seed_text"] as! String) }
    static func statement(generation: Int) -> KeyStatement { try! KeyStatement(generations[generation - 1]["statement"] as! String) }

    static func chain(_ entries: Any?) -> [SignedStatement] {
        (entries as! [[String: Any]]).map {
            SignedStatement(statement: $0["statement"] as! String, signature: hex($0["signature_hex"]),
                            previousSignature: ($0["previous_signature_hex"] as? String).map(hex))
        }
    }
}

func hex(_ value: Any?) -> Data {
    let text = value as! String
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

/// The status name a negative vector's `error` stands for: the format's prefix and the vector's spelling.
func expectRefusal(_ error: KeykitError, _ name: Any?, prefix: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let want = name as! String
    #expect(error.name == "\(prefix)_\(want)" || error.name == want, "got \(error.name), want \(want)",
            sourceLocation: sourceLocation)
}

struct LibraryTests {
    @Test func isThePinnedVersion() {
        #expect(Keykit.version == "0.5.0")
    }
}

struct AccountKeyVectorsTests {
    @Test func generationsDeriveTheirStatementsAndSignatures() throws {
        var previous: AccountKey?
        for g in VHC.generations {
            let key = try AccountKey(recoveryCode: g["seed_text"] as! String)
            let keys = try key.publicKeys()
            #expect(hexText(keys.x25519) == g["x25519_pk_hex"] as? String)
            #expect(hexText(keys.ed25519) == g["ed25519_pk_hex"] as? String)
            let statement = try KeyStatement(g["statement"] as! String)
            #expect(key.matches(statement))
            #expect(hexText(statement.fingerprint.bytes) == g["fingerprint_hex"] as? String)
            #expect(statement.fingerprint.text == g["fingerprint_text"] as? String)
            // Built again from the key, the statement is byte for byte the vector's.
            let rebuilt = try key.statement(publicID: VHC.publicID, generation: statement.generation,
                                            previous: statement.previousFingerprint, reason: statement.reason)
            #expect(rebuilt.text == statement.text)
            // Ed25519 is deterministic: the signatures are the vector's.
            let link = g["link"] as! String
            let signed = try key.sign(statement, previous: link == "rotation" ? previous : nil)
            #expect(hexText(signed.signature) == g["signature_hex"] as? String)
            if let want = g["previous_signature_hex"] as? String { #expect(signed.previousSignature.map(hexText) == want) }
            // The recovery code leaves the handle as the vector's text.
            let code = try key.recoveryCode()
            #expect(code.withUnsafeBytes { String(decoding: $0, as: UTF8.self) } == g["seed_text"] as? String)
            previous = key
        }
    }

    @Test func aTypedRecoveryCodeIsLenient() throws {
        let text = VHC.generations[0]["seed_text"] as! String
        let typed = text.uppercased().enumerated().map { $0.offset % 5 == 4 ? "\($0.element)-" : "\($0.element)" }.joined()
        let key = try AccountKey(recoveryCode: typed)
        #expect(key.matches(VHC.statement(generation: 1)))
        #expect(!key.matches(VHC.statement(generation: 2)))
        #expect(throws: KeykitError.self) { try AccountKey(recoveryCode: String(text.dropLast())) }
    }

    @Test func statementNegatives() {
        for n in VHC.list("account_key", "statement_negative") {
            do {
                _ = try KeyStatement(n["statement"] as! String)
                Issue.record("\(n["name"]!) parsed")
            } catch {
                expectRefusal(error, n["error"], prefix: "account")
            }
        }
    }

    @Test func fingerprintText() throws {
        let f = VHC.section("account_key")["fingerprint_text"] as! [String: Any]
        let canonical = f["canonical"] as! String
        #expect(try Fingerprint(text: canonical).text == canonical)
        for typed in f["lenient_accepted"] as! [String] {
            #expect(try Fingerprint(text: typed, lenient: true).text == canonical)
            #expect(throws: KeykitError.self) { try Fingerprint(text: typed) }
        }
        for refused in f["refused"] as! [String] {
            #expect(throws: KeykitError.self) { try Fingerprint(text: refused, lenient: true) }
        }
    }

    @Test func theChainVerifies() throws {
        let chain = VHC.chain(VHC.generations)
        let verified = try KeyChain.verify(chain, publicID: VHC.publicID)
        #expect(verified.map(\.link) == [.initial, .rotation, .replacement])
        #expect(verified.map { hexText($0.fingerprint.bytes) } == VHC.generations.map { $0["fingerprint_hex"] as! String })
    }

    @Test func chainNegatives() {
        for n in VHC.list("account_key", "chain_negative") {
            do {
                _ = try KeyChain.verify(VHC.chain(n["chain"]), publicID: VHC.publicID)
                Issue.record("\(n["name"]!) verified")
            } catch {
                expectRefusal(error, n["error"], prefix: "account")
                #expect(error.index == n["index"] as? Int, "\(n["name"]!)")
            }
        }
    }

    @Test func followingFromAPin() throws {
        for f in VHC.list("account_key", "follow") {
            let pin = f["pin"] as! [String: Any]
            let expect = f["expect"] as! [String: Any]
            do {
                let r = try KeyChain.follow(VHC.chain(f["chain"]), publicID: VHC.publicID,
                                            pinGeneration: UInt32(pin["generation"] as! Int),
                                            pinFingerprint: try Fingerprint(bytes: hex(pin["fingerprint_hex"])))
                #expect(expect["error"] == nil, "\(f["name"]!) followed")
                #expect(Int(r.accepted) == expect["accepted"] as? Int && Int(r.newest) == expect["newest"] as? Int,
                        "\(f["name"]!)")
            } catch {
                expectRefusal(error, expect["error"], prefix: "account")
            }
        }
    }

    @Test func publicIDs() throws {
        for a in VHC.list("public_id", "accepted") {
            #expect(hexText(try Keykit.publicIDBytes(a["text"] as! String)) == a["bytes_hex"] as? String)
        }
        for r in VHC.section("public_id")["refused"] as! [String] {
            #expect(throws: KeykitError.self) { try Keykit.publicIDBytes(r) }
        }
    }
}

struct HolderAndKAK1VectorsTests {
    @Test func holderProofs() throws {
        for p in VHC.list("holder_proof", "positive") {
            let key = VHC.key(seedHex: p["seed_hex"] as! String)
            let statement = try KeyStatement(p["statement"] as! String)
            let suite = KeySuite(rawValue: UInt16(p["suite"] as! Int))!
            let proof = try key.holderProof(statement, installationID: p["installation_id"] as! String, suite: suite,
                                            holderPublicKey: hex(p["holder_pk_hex"]))
            #expect(hexText(proof) == p["signature_hex"] as? String, "\(p["name"]!)")
            try HolderProof.verify(proof, statement: statement, installationID: p["installation_id"] as! String,
                                   suite: suite, holderPublicKey: hex(p["holder_pk_hex"]))
        }
        for n in VHC.list("holder_proof", "negative") {
            do {
                try HolderProof.verify(hex(n["signature_hex"]), statement: try KeyStatement(n["statement"] as! String),
                                       installationID: n["installation_id"] as! String,
                                       suite: KeySuite(rawValue: UInt16(n["suite"] as! Int)) ?? .x25519,
                                       holderPublicKey: hex(n["holder_pk_hex"]))
                // An unknown suite can't be expressed as a KeySuite: the vector's refusal is the library's, not ours.
                if KeySuite(rawValue: UInt16(n["suite"] as! Int)) != nil { Issue.record("\(n["name"]!) verified") }
            } catch {
                if KeySuite(rawValue: UInt16(n["suite"] as! Int)) != nil { expectRefusal(error, n["error"], prefix: "account") }
            }
        }
    }

    @Test func kak1OpensWithTheHolderSecret() throws {
        for p in VHC.list("kak1", "positive") {
            let suite = KeySuite(rawValue: UInt16(p["suite"] as! Int))!
            let statement = try KeyStatement(p["statement"] as! String)
            let header = try KAK1Header(hex(p["envelope_hex"]))
            #expect(hexText(header.recipientID) == p["recipient_id_hex"] as? String)
            #expect(Int(header.generation) == Int(statement.generation))
            let opened = try AccountKey.unwrap(hex(p["envelope_hex"]), secretKey: SecretBytes(hex(p["holder_sk_hex"])),
                                               suite: suite, statement: statement)
            #expect(opened.matches(statement))
            #expect(try hexText(opened.publicKeys().x25519) == hexText(VHC.key(seedHex: p["seed_hex"] as! String).publicKeys().x25519))
        }
    }

    /// The Secure Enclave path: the agreement runs in CryptoKit through the callback (a software P-256 key here, the
    /// vector's; `SecureEnclaveTests` uses a real one).
    @Test func kak1OpensThroughTheAgreementCallback() throws {
        let p = VHC.list("kak1", "positive").first { $0["suite"] as? Int == 2 }!
        let holder = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex(p["holder_sk_hex"]))
        #expect(hexText(holder.publicKey.x963Representation) == p["holder_pk_hex"] as? String)
        let statement = try KeyStatement(p["statement"] as! String)
        var calls = 0
        let opened = try AccountKey.unwrap(hex(p["envelope_hex"]), holderPublicKey: holder.publicKey.x963Representation,
                                           suite: .p256, statement: statement) { epk, z in
            calls += 1
            let shared = try holder.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: epk))
            shared.withUnsafeBytes { z.copyMemory(from: $0) }
        }
        #expect(calls == 1)
        #expect(opened.matches(statement))
    }

    @Test func aCancelledAgreementIsTheCallersError() throws {
        struct Cancelled: Error {}
        let p = VHC.list("kak1", "positive").first { $0["suite"] as? Int == 2 }!
        #expect(throws: Cancelled.self) {
            _ = try AccountKey.unwrap(hex(p["envelope_hex"]), holderPublicKey: hex(p["holder_pk_hex"]), suite: .p256,
                                      statement: try KeyStatement(p["statement"] as! String)) { _, _ in throw Cancelled() }
        }
    }

    @Test func kak1Negatives() {
        for n in VHC.list("kak1", "negative") {
            let suite = KeySuite(rawValue: UInt16(n["suite_expected"] as! Int))!
            do {
                _ = try AccountKey.unwrap(hex(n["envelope_hex"]), secretKey: SecretBytes(hex(n["holder_sk_hex"])),
                                          suite: suite, statement: try KeyStatement(n["statement"] as! String))
                Issue.record("\(n["name"]!) opened")
            } catch let error as KeykitError {
                expectRefusal(error, n["error"], prefix: "kak1")
            } catch {
                Issue.record("\(error)")
            }
        }
    }

    @Test func wrapAndUnwrapRoundTrip() throws {
        let key = VHC.key(generation: 2)
        let statement = VHC.statement(generation: 2)
        let holder = P256.KeyAgreement.PrivateKey()
        let kak1 = try key.wrap(statement, suite: .p256, to: holder.publicKey.x963Representation)
        #expect(kak1.count == 179)
        let opened = try AccountKey.unwrap(kak1, secretKey: SecretBytes(holder.rawRepresentation), suite: .p256,
                                           statement: statement)
        #expect(opened.matches(statement))
        // Wrapping for a generation that isn't the key's is refused.
        #expect(throws: KeykitError.seedMismatch) { try key.wrap(VHC.statement(generation: 1), suite: .p256, to: holder.publicKey.x963Representation) }
    }
}

struct LabelPolicyAndCodeVectorsTests {
    /// The account key of a vector's statement: every generation-n statement in the vectors is generation n's key.
    func key(for statement: KeyStatement) -> AccountKey { VHC.key(generation: Int(statement.generation)) }

    @Test func labels() throws {
        for p in VHC.list("vault_label", "positive") {
            let statement = try KeyStatement(p["statement"] as! String)
            let uid = hex(p["vault_uid_hex"])
            #expect(try key(for: statement).openLabel(hex(p["sealed_hex"]), statement: statement, vaultUid: uid) == p["label"] as? String)
            let resealed = try VaultLabel.seal(p["label"] as! String, statement: statement, vaultUid: uid)
            #expect(resealed.count == VaultLabel.sealedSize)
            #expect(try key(for: statement).openLabel(resealed, statement: statement, vaultUid: uid) == p["label"] as? String)
        }
        for n in VHC.list("vault_label", "negative") {
            let statement = try KeyStatement(n["statement"] as! String)
            // Negative vectors name the key by its X25519 secret (wrong_key opens with another generation's).
            let sk = hex(n["account_x25519_sk_hex"])
            let g = VHC.generations.first {
                try! RecoverySeed(bytes: SecretBytes(hex($0["seed_hex"]))).x25519Secret().withUnsafeBytes { Data($0) } == sk
            }!
            do {
                _ = try AccountKey(recoveryCode: g["seed_text"] as! String)
                    .openLabel(hex(n["sealed_hex"]), statement: statement, vaultUid: hex(n["vault_uid_hex"]))
                Issue.record("\(n["name"]!) opened")
            } catch {
                expectRefusal(error, n["error"], prefix: "label")
            }
        }
    }

    @Test func policies() throws {
        for p in VHC.list("recovery_policy", "positive") {
            let pinned = VHC.statement(generation: p["pinned_generation"] as! Int)
            let signed = SignedPolicy(policy: p["policy"] as! String, signature: hex(p["signature_hex"]))
            let info = try signed.verify(against: pinned)
            #expect(hexText(info.sha256) == p["hash_hex"] as? String)
            // Signed again from its own fields, the policy is byte for byte the vector's (Ed25519 is deterministic).
            let lines = signed.policy.split(separator: "\n", omittingEmptySubsequences: false)
            let again = try VHC.key(generation: Int(pinned.generation)).signPolicy(
                pinned, sequence: info.sequence, issuedAt: String(lines[4]), recipients: info.recipients)
            #expect(again == signed, "\(p["name"]!)")
        }
        for n in VHC.list("recovery_policy", "negative") {
            do {
                _ = try SignedPolicy(policy: n["policy"] as! String, signature: hex(n["signature_hex"]))
                    .verify(against: VHC.statement(generation: n["pinned_generation"] as! Int))
                Issue.record("\(n["name"]!) verified")
            } catch {
                expectRefusal(error, n["error"], prefix: "account")
            }
        }
    }

    @Test func codes() throws {
        for r in VHC.list("codes", "request") {
            #expect(try KeyCodes.request(id: r["request_id"] as! String, payload: r["payload"] as! String) == r["code"] as? String)
        }
        for t in VHC.list("codes", "transfer") {
            #expect(try KeyCodes.transfer(publicID: t["public_id"] as! String, temporaryKey: hex(t["temporary_public_key_hex"]))
                    == t["code"] as? String)
        }
        for r in VHC.list("codes", "restore") {
            #expect(try KeyCodes.restore(vaultUid: r["vault_uid"] as! String, temporaryKey: hex(r["temporary_public_key_hex"]))
                    == r["code"] as? String)
        }
        for r in VHC.list("codes", "refused") {
            #expect(throws: KeykitError.self, "\(r["name"]!)") {
                switch r["kind"] as! String {
                case "request": _ = try KeyCodes.request(id: r["request_id"] as! String, payload: r["payload"] as! String)
                case "transfer": _ = try KeyCodes.transfer(publicID: r["public_id"] as! String, temporaryKey: hex(r["temporary_public_key_hex"]))
                default: _ = try KeyCodes.restore(vaultUid: r["vault_uid"] as! String, temporaryKey: hex(r["temporary_public_key_hex"]))
                }
            }
        }
    }
}

/// A restore's re-wrap: the vectors' vault keys, wrapped to the account key, opened by the library with the seed and
/// wrapped again to a temporary key, which the independent Swift KEV1 reader (VHRecovery, checked against the same
/// vectors) opens to the same key and version.
struct KEV1DeliveryTests {
    @Test func reWrapsVectorVaultKeys() throws {
        let account = VHC.key(generation: 2)
        let accountRecipient = try account.publicKeys().x25519
        for v in (VHC.shared["kev1"] as! [String: Any])["positive"] as! [[String: Any]] where v["suite"] as? Int == 1 {
            let uid = Uid(bytes: [UInt8](hex(v["vault_uid_hex"])))!
            let vaultKey = SecretBytes(hex(v["vault_key_hex"]))
            let version = UInt32(v["key_version"] as! Int)
            let toAccount = try KEV1.wrap(vaultKey: vaultKey, suite: .x25519, keyVersion: version, vaultUid: uid,
                                          recipientPublicKey: accountRecipient)
            #expect(try KEV1Header(toAccount).keyVersion == version)
            let opened = try account.openVaultKey(toAccount, vaultUid: Data(uid.bytes))
            #expect(opened.keyVersion == version)
            let temporary = RecoverySeed.generate()
            let delivered = try opened.wrap(suite: .x25519, to: temporary.x25519PublicKey())
            let read = try KEV1.unwrap(delivered, recipient: temporary.recipient(), vaultUid: uid)
            #expect(read.keyVersion == version)
            #expect(read.key.withUnsafeBytes { Data($0) } == hex(v["vault_key_hex"]))
            // Another vault's uid, or another recipient's envelope, is refused; the latter is one a restore skips.
            #expect(throws: KeykitError.self) { try account.openVaultKey(toAccount, vaultUid: Data(count: 16)) }
            do {
                _ = try VHC.key(generation: 1).openVaultKey(toAccount, vaultUid: Data(uid.bytes))
                Issue.record("another key opened it")
            } catch {
                #expect(KEV1Header.isSkippedByRestore(error))
            }
        }
    }
}
