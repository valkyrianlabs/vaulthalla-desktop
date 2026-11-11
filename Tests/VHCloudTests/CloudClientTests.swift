import CryptoKit
import Foundation
import Testing
import VHCore
@testable import VHCloud
import VHRecovery

/// The cloud's documented vectors (valkyrianlabs/vaulthalla-cloud docs/design/installation-requests.md and
/// recovery-restore.md), which the cloud's and the server's own tests pin too.
struct CloudVectorsTests {
    @Test func signsTheDocumentedVectorsStringAndItsSignatureVerifies() throws {
        let seed = Data((0x20 ... 0x3f).map { UInt8($0) })
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        #expect(Base64URL.encode(key.publicKey.rawRepresentation) == "Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc")
        let body = Data(#"{"vault":"kceypk9vfn5tv6yx5c6qpfebdm"}"#.utf8)
        let f = VHC1.Fields(method: "POST", path: "/v1/recovery/vaults/a%20b", query: "x=1&y", host: "api.vaulthalla.cloud",
                            installation: "kceypk9vfn5tv6yx5c6qpfebdm", timestamp: 1793664000,
                            nonce: "AAECAwQFBgcICQoLDA0ODw", bodySHA256: VHC1.sha256Hex(body))
        #expect(f.bodySHA256 == "c4293fac1f2924f97ffec5da0d43fe15fccb05f3275b033d295aa78c815dd567")
        #expect(VHC1.sha256Hex(Data(VHC1.stringToSign(f).utf8)) == "2bd1a0d0d0a4d8c2d694b793fe564018ac7b95e9a2d1306dbb1c4768017edd40")
        let documented = try #require(Base64URL.decode(
            "l-5sKNw58kNGX8pbTqy9HQgb97rosBuDb4RwLqIWcEILgRqpVIwEHCKsJVhIYNti5-MlBZeYWGDRLikjEPtPCQ"))
        #expect(key.publicKey.isValidSignature(documented, for: Data(VHC1.stringToSign(f).utf8)))
        // Desktop's own signature (CryptoKit's are randomized) is valid for the same string.
        let header = try #require(try VHC1.headers(f, key: key)["Authorization"])
        let ours = try #require(Base64URL.decode(String(header.split(separator: "=").last!)))
        #expect(key.publicKey.isValidSignature(ours, for: Data(VHC1.stringToSign(f).utf8)))
        #expect(header.hasPrefix("VHC1-Ed25519 Installation=kceypk9vfn5tv6yx5c6qpfebdm, Timestamp=1793664000, Nonce=AAECAwQFBgcICQoLDA0ODw, Signature="))
    }

    @Test func computesTheDocumentedRestoreCode() {
        let pk = Data((1 ... 32).map { UInt8($0) })
        #expect(pk.base64EncodedString() == "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=")
        #expect(RestoreCode.of(vaultUid: "0123456789abcdefghjkmnpqrs", temporaryPublicKey: pk) == "6adc-ef02-f4a4-4fd0")
    }

    @Test func base64URLIsStrict() {
        #expect(Base64URL.decode("AAECAwQFBgcICQoLDA0ODw")?.count == 16)
        #expect(Base64URL.decode("AAECAwQFBgcICQoLDA0ODw==") == nil)  // padding
        #expect(Base64URL.decode("AAECAwQFBgcICQoLDA0ODx") == nil)    // non-zero trailing bits
        #expect(Base64URL.decode("AAEC+wQF") == nil)                  // the standard alphabet
    }

    @Test func refusesEndpointsThatArentHttpsOrLocal() throws {
        let store = MemoryCloudLinkStore()
        #expect(try CloudClient(endpoint: "https://API.vaulthalla.cloud:443", store: store).host == "api.vaulthalla.cloud")
        #expect(try CloudClient(endpoint: "http://127.0.0.1:8085", store: store).host == "127.0.0.1:8085")
        for bad in ["http://api.vaulthalla.cloud", "https://x/v1", "ftp://x", "https://u@x"] {
            #expect(throws: CloudError.self) { try CloudClient(endpoint: bad, store: store) }
        }
    }
}

/// Enough of Vaulthalla Cloud to check Desktop's side: proofs and VHC1 signatures verified with the key the link
/// request registered, the restore relay's source and bundle.
final class FakeCloud: CloudTransport, @unchecked Sendable {
    let lock = NSLock()
    var publicKey: Data?
    var claimAnswer = "pending"
    var calls: [String] = []
    var restoreSummary: [String: Any] = [:]
    var envelopes: [String] = []
    var keyVersions: [UInt32] = []
    var bundle: [String]?
    var lieAboutTheCode = false
    let installation = "kceypk9vfn5tv6yx5c6qpfebdm"

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try lock.withLock { try handle(request) }
    }

    private func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        calls.append("\(request.httpMethod!) \(path)")
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func reply(_ status: Int, _ json: [String: Any]) -> (Data, HTTPURLResponse) {
            (try! JSONSerialization.data(withJSONObject: json),
             HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if path == "/v1/link-requests" {
            let pkText = body["public_key"] as! String
            publicKey = Base64URL.decode(pkText)
            let proof = Base64URL.decode(body["proof"] as! String)!
            let message = Data("vhc-link-request-v1\n\(pkText)\n\(body["name"] as! String)\n\(body["kind"] as! String)".utf8)
            guard body["kind"] as? String == "desktop",
                  try Curve25519.Signing.PublicKey(rawRepresentation: publicKey!).isValidSignature(proof, for: message)
            else { return reply(400, ["error": ["code": "invalid_argument", "message": "bad proof"]]) }
            return reply(201, ["request_id": "0123456789abcdefghjkmnpqrs", "user_code": "WXYZ-1234", "expires_at": 4102444800])
        }
        if path.hasSuffix("/claim") {
            let ts = (body["timestamp"] as! NSNumber).int64Value
            let message = Data("vhc-link-claim-v1\n0123456789abcdefghjkmnpqrs\n\(ts)".utf8)
            guard try Curve25519.Signing.PublicKey(rawRepresentation: publicKey!)
                .isValidSignature(Base64URL.decode(body["signature"] as! String)!, for: message)
            else { return reply(401, ["error": ["message": "bad claim"]]) }
            if claimAnswer == "linked" { return reply(200, ["status": "linked", "installation_id": installation, "account_id": 7]) }
            return reply(200, ["status": claimAnswer])
        }
        // Everything else is signed as the installation.
        guard verifies(request) else { return reply(401, ["error": ["message": "request signature rejected"]]) }
        var summary = restoreSummary
        if lieAboutTheCode { summary["restore_code"] = "0000-0000-0000-0000" }
        switch (request.httpMethod!, path) {
        case ("GET", "/v1/recovery/restores/deliverable"): return reply(200, ["restores": [summary]])
        case ("GET", _) where path.hasSuffix("/source"):
            summary["envelopes"] = envelopes
            summary["key_versions"] = keyVersions.map { ["version": $0, "key_check": "kc"] }
            return reply(200, summary)
        case ("POST", _) where path.hasSuffix("/bundle"):
            bundle = body["envelopes"] as? [String]
            return reply(200, summary)
        case ("DELETE", "/v1/installation"): return reply(204, [:])
        default: return reply(404, ["error": ["message": "no route"]])
        }
    }

    private func verifies(_ r: URLRequest) -> Bool {
        guard let auth = r.value(forHTTPHeaderField: "Authorization"), let pk = publicKey,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pk) else { return false }
        var fields: [String: String] = [:]
        for part in auth.dropFirst("VHC1-Ed25519 ".count).split(separator: ",") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        let body = r.httpBody ?? Data()
        guard r.value(forHTTPHeaderField: VHC1.contentHashHeader) == VHC1.sha256Hex(body),
              fields["Installation"] == installation, let ts = fields["Timestamp"].flatMap(Int64.init),
              let sig = fields["Signature"].flatMap(Base64URL.decode) else { return false }
        let f = VHC1.Fields(method: r.httpMethod!, path: r.url!.path, query: r.url!.query ?? "", host: "api.vaulthalla.test",
                            installation: installation, timestamp: ts, nonce: fields["Nonce"] ?? "",
                            bodySHA256: VHC1.sha256Hex(body))
        return key.isValidSignature(sig, for: Data(VHC1.stringToSign(f).utf8))
    }
}

struct CloudClientTests {
    func linked(_ fake: FakeCloud) async throws -> (CloudClient, MemoryCloudLinkStore) {
        let store = MemoryCloudLinkStore()
        let client = try CloudClient(endpoint: "https://api.vaulthalla.test", store: store, transport: fake)
        let started = try await client.startLink(name: "MacBook")
        #expect(started.userCode == "WXYZ-1234")
        #expect(started.fingerprint == VHC1.fingerprint(fake.publicKey!))
        #expect(try await client.claimLink() == .pending)
        fake.claimAnswer = "linked"
        #expect(try await client.claimLink() == .linked)
        #expect(try store.load()?.installationID == fake.installation)
        return (client, store)
    }

    @Test func linksAsADesktopInstallationAndSignsLaterRequests() async throws {
        let fake = FakeCloud()
        let (client, store) = try await linked(fake)
        #expect(try store.load()?.state == .linked)
        try await client.unlink()
        #expect(try store.load() == nil)
        #expect(fake.calls.last == "DELETE /v1/installation")
    }

    @Test func aDeniedLinkForgetsTheKey() async throws {
        let fake = FakeCloud()
        let store = MemoryCloudLinkStore()
        let client = try CloudClient(endpoint: "https://api.vaulthalla.test", store: store, transport: fake)
        _ = try await client.startLink(name: "MacBook")
        fake.claimAnswer = "denied"
        #expect(try await client.claimLink() == .denied)
        #expect(try store.load() == nil)
        await #expect(throws: CloudError.notLinked) { _ = try await client.deliverable() }
    }

    /// The vault as the cloud holds it: two key versions wrapped to the kit's recipient (and one to someone else's).
    func vault(_ fake: FakeCloud, kit: RecoverySeed, temporary: Curve25519.KeyAgreement.PrivateKey)
        throws -> (Uid, [UInt32: [UInt8]]) {
        let uid = Uid.random()
        var keys: [UInt32: [UInt8]] = [:]
        for v in [UInt32(1), 2] {
            let k = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            keys[v] = k
            fake.envelopes.append(try KEV1.wrap(vaultKey: SecretBytes(k), suite: .x25519, keyVersion: v, vaultUid: uid,
                                                recipientPublicKey: kit.x25519PublicKey()).base64EncodedString())
        }
        fake.envelopes.append(try KEV1.wrap(vaultKey: SecretBytes([UInt8](repeating: 1, count: 32)), suite: .x25519,
                                            keyVersion: 1, vaultUid: uid,
                                            recipientPublicKey: RecoverySeed.generate().x25519PublicKey()).base64EncodedString())
        fake.keyVersions = [1, 2, 3]
        let pk = temporary.publicKey.rawRepresentation
        fake.restoreSummary = ["id": "rst0123456789abcdefghjkmnp", "vault_uid": uid.base32, "status": "approved",
                               "temporary_public_key": pk.base64EncodedString(),
                               "restore_code": RestoreCode.of(vaultUid: uid.base32, temporaryPublicKey: pk),
                               "requester": ["installation_id": "x", "name": "new-server", "kind": "server",
                                             "fingerprint": "aaaa-bbbb-cccc-dddd"]]
        return (uid, keys)
    }

    func kitJSON(_ seed: RecoverySeed) -> Data {
        Data(#"{"type": "vh.recovery-kit", "v": 1, "recovery_seed": "\#(seed.text())", "vaults": []}"#.utf8)
    }

    @Test func deliversEveryVersionTheKitOpensToTheTemporaryKeyOnly() async throws {
        let fake = FakeCloud()
        let (client, _) = try await linked(fake)
        let seed = RecoverySeed.generate()
        let temporary = Curve25519.KeyAgreement.PrivateKey()
        let (uid, keys) = try vault(fake, kit: seed, temporary: temporary)

        let list = try await client.deliverable()
        let restore = try #require(list.first)
        #expect(restore.restoreCode == RestoreCode.of(vaultUid: uid.base32, temporaryPublicKey: temporary.publicKey.rawRepresentation))
        #expect(restore.requesterName == "new-server")

        let delivered = try await client.deliver(restore, kit: try RecoveryKit(json: kitJSON(seed)))
        #expect(delivered.versions == [1, 2])
        #expect(delivered.missing == [3])
        let bundle = try #require(fake.bundle)
        #expect(bundle.count == 2)
        let receiver = KEV1.RecipientSecret(suite: .x25519, secret: temporary.rawRepresentation.withUnsafeBytes { SecretBytes($0) })
        for text in bundle {
            let env = try #require(Data(base64Encoded: text))
            let opened = try KEV1.unwrap(env, recipient: receiver, vaultUid: uid)
            #expect(opened.key.withUnsafeBytes { Array($0) } == keys[opened.keyVersion])
            // The kit's own recipient can't open what was delivered: it is for the temporary key alone.
            #expect(throws: KEV1.Failure.recipientMismatch) { try KEV1.unwrap(env, recipient: seed.recipient(), vaultUid: uid) }
        }
    }

    @Test func refusesACloudWhoseRestoreCodeIsntTheTemporaryKeysOrAKitThatOpensNothing() async throws {
        let fake = FakeCloud()
        let (client, _) = try await linked(fake)
        let seed = RecoverySeed.generate()
        _ = try vault(fake, kit: seed, temporary: Curve25519.KeyAgreement.PrivateKey())
        let restore = try #require(try await client.deliverable().first)
        // Another kit: nothing opens, nothing is sent.
        await #expect(throws: CloudError.noEnvelopeOpens) {
            _ = try await client.deliver(restore, kit: try RecoveryKit(json: kitJSON(RecoverySeed.generate())))
        }
        #expect(fake.bundle == nil)
        // A cloud claiming a code that isn't the one the key gives.
        fake.lieAboutTheCode = true
        await #expect(throws: CloudError.restoreCodeMismatch) { _ = try await client.deliverable() }
        await #expect(throws: CloudError.restoreCodeMismatch) {
            _ = try await client.deliver(restore, kit: try RecoveryKit(json: kitJSON(seed)))
        }
        #expect(fake.bundle == nil)
    }
}
