import CryptoKit
import Foundation
import Testing
import VHCore
@testable import VHCloud
import VHKeykit
import VHRecovery

/// The account recovery key on this Mac, end to end against ``FakeCloud`` (the daemon's routes and checks, in
/// memory): receiving it by recovery code and by transfer, delivering a transfer and a restore, the create and rotate
/// key requests, following a signed rotation, refusing an unsigned replacement, and the lease.
struct CloudAccountTests {
    /// A linked Mac with a held lease and memory items. `enclave` uses a real Secure Enclave holder key (without
    /// Touch ID, so the test runs unattended).
    func linkedAccount(_ fake: FakeCloud, enclave: Bool = false) async throws -> (CloudAccount, MemoryAccountItemStore, CredentialLease) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vh-cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lease = CredentialLease(forRegistry: dir.appending(path: "nodes.json"), holder: "test")
        try lease.acquire()
        let memory = MemoryAccountItemStore()
        let items = LeasedAccountItems(items: memory, lease: lease)
        let client = try CloudClient(endpoint: "https://api.vaulthalla.test", store: AccountCloudLinkStore(items: items),
                                     transport: fake)
        _ = try await client.startLink(name: "MacBook")
        fake.claimAnswer = "linked"
        #expect(try await client.claimLink() == .linked)
        let account = CloudAccount(client: client, items: items,
                                   holderKeys: HolderKeys(preferEnclave: enclave, userPresence: false))
        return (account, memory, lease)
    }

    func code(_ key: AccountKey) throws -> SecretBytes { try key.recoveryCode() }

    @Test func noKeyYet() async throws {
        let fake = FakeCloud()
        let (account, _, _) = try await linkedAccount(fake)
        let status = try await account.status()
        #expect(status.cloud == nil && status.held == nil && !status.holdsCurrent)
    }

    @Test func receivesTheKeyByItsRecoveryCode() async throws {
        let fake = FakeCloud()
        let (account, memory, _) = try await linkedAccount(fake)
        let key = try AccountKey.generate()
        try fake.portalCreatesKey(key)
        // A wrong code is refused before anything is sent.
        await #expect(throws: CloudError.self) { _ = try await account.receive(recoveryCode: code(try AccountKey.generate())) }
        #expect(fake.holders.isEmpty)

        let fingerprint = try await account.receive(recoveryCode: code(key))
        #expect(fingerprint == fake.current?.fingerprint)
        // The cloud verified the holder proof and the KAK1's prefix; this Mac keeps only the sealed key.
        #expect(fake.holders.count == 1 && fake.holders[0].suite == 2)
        #expect(memory.names.contains(AccountKeyStore.heldItem))
        let status = try await account.status()
        #expect(status.holdsCurrent && status.fingerprint == fingerprint)
        // Unlocking opens the same key.
        #expect(try await account.withAccountKey { k, s in k.matches(s) })
        #expect(try await account.exportRecoveryCode().withUnsafeBytes { Data($0) } == (try code(key)).withUnsafeBytes { Data($0) })
    }

    @Test(.enabled(if: SecureEnclave.isAvailable)) func holdsTheKeyWithASecureEnclaveKey() async throws {
        let fake = FakeCloud()
        let (account, _, _) = try await linkedAccount(fake, enclave: true)
        let key = try AccountKey.generate()
        try fake.portalCreatesKey(key)
        _ = try await account.receive(recoveryCode: code(key))
        let held = try #require(try await account.keys.held())
        #expect(held.holderKind == .secureEnclave)
        #expect(try await account.withAccountKey { k, s in k.matches(s) })
    }

    @Test func receivesTheKeyByTransfer() async throws {
        let fake = FakeCloud()
        let (account, _, _) = try await linkedAccount(fake)
        let key = try AccountKey.generate()
        try fake.portalCreatesKey(key)
        let pending = try await account.requestTransfer()
        // Both screens show the code of the temporary key, which is this Mac's new holder key.
        let t = try #require(fake.transfers.first)
        #expect(pending.code == (try KeyCodes.transfer(publicID: fake.publicID, temporaryKey: t.key)))
        #expect(try await account.checkTransfer() == .waiting)
        // Another holder (or the portal) delivers KAK1 to the temporary key.
        fake.otherHolderDelivers(t.id, kak1: try key.wrap(fake.current!, suite: .p256, to: t.key))
        #expect(try await account.checkTransfer() == .received(fake.current!.fingerprint))
        #expect(fake.transfers.first?.status == "completed")
        #expect(fake.holders.first?.key == t.key)
        #expect(try await account.status().holdsCurrent)
    }

    @Test func deliversATransferToAnotherDevice() async throws {
        let fake = FakeCloud()
        let (account, _, _) = try await linkedAccount(fake)
        let key = try AccountKey.generate()
        try fake.portalCreatesKey(key)
        _ = try await account.receive(recoveryCode: code(key))
        let other = P256.KeyAgreement.PrivateKey()
        let id = fake.otherDeviceRequestsTransfer(key: other.publicKey.x963Representation)
        let list = try await account.deliverableTransfers()
        let t = try #require(list.first)
        let want = try KeyCodes.transfer(publicID: fake.publicID, temporaryKey: other.publicKey.x963Representation)
        #expect(t.id == id && t.code == want)
        try await account.deliver(t)
        let kak1 = try #require(fake.transfers.first?.kak1)
        let opened = try AccountKey.unwrap(kak1, secretKey: SecretBytes(other.rawRepresentation), suite: .p256, statement: fake.current!)
        #expect(opened.matches(fake.current!))
    }

    @Test func createsTheFirstKeyThroughAKeyRequest() async throws {
        let fake = FakeCloud()
        let (account, memory, _) = try await linkedAccount(fake)
        let new = try await account.prepareFirstKey()
        #expect(new.statement.generation == 1 && new.statement.reason == .initial)
        let open = try await account.submit(new, offlineCopyConfirmed: true)
        #expect(open.request.action == "create")
        #expect(open.code == open.request.requestCode)
        #expect(memory.names.contains(AccountKeyStore.pendingItem))
        #expect(try await account.checkPendingKey() == .waiting(code: open.code))
        try fake.approve(open.request.id)
        #expect(try await account.checkPendingKey() == .applied)
        let status = try await account.status()
        #expect(status.holdsCurrent && status.pending == nil)
        #expect(status.offlineCopyConfirmedAt != nil)
        #expect(fake.holders.count == 1)
    }

    @Test func aDeniedRequestForgetsTheNewKey() async throws {
        let fake = FakeCloud()
        let (account, memory, _) = try await linkedAccount(fake)
        let open = try await account.submit(try await account.prepareFirstKey(), offlineCopyConfirmed: true)
        fake.deny(open.request.id)
        #expect(try await account.checkPendingKey() == .closed("denied"))
        #expect(!memory.names.contains(AccountKeyStore.pendingItem))
    }

    @Test func rotatesThroughAKeyRequestSignedByBothGenerations() async throws {
        let fake = FakeCloud()
        let (account, _, _) = try await linkedAccount(fake)
        let first = try AccountKey.generate()
        try fake.portalCreatesKey(first)
        _ = try await account.receive(recoveryCode: code(first))
        let rotation = try await account.prepareRotation()
        let open = try await account.submit(rotation, offlineCopyConfirmed: true)
        #expect(open.request.action == "rotate")
        try fake.approve(open.request.id)  // verifies the chain (a signed rotation) and reseals this Mac
        #expect(try await account.checkPendingKey() == .applied)
        let status = try await account.status()
        #expect(status.held?.generation == 2 && status.holdsCurrent)
        #expect(status.chain.map(\.link) == [.initial, .rotation])
        #expect(try await account.withAccountKey { k, s in k.matches(s) && s.generation == 2 })
    }

    @Test func followsARotationAnotherDeviceMadeAndRefusesAnUnsignedReplacement() async throws {
        let fake = FakeCloud()
        let (account, _, _) = try await linkedAccount(fake)
        let first = try AccountKey.generate()
        try fake.portalCreatesKey(first)
        _ = try await account.receive(recoveryCode: code(first))
        let holderKey = fake.holders[0].key

        // Another device rotates: generation 2 signed by both, this Mac's holder row resealed.
        let second = try AccountKey.generate()
        let s2 = try second.statement(publicID: fake.publicID, generation: 2, previous: fake.current!.fingerprint, reason: .routine)
        fake.chain.append(.init(signed: try second.sign(s2, previous: first), reason: "routine", link: "rotation"))
        fake.holders[0].kak1 = try second.wrap(s2, suite: .p256, to: holderKey)
        fake.holders[0].proof = try second.holderProof(s2, installationID: fake.installation, suite: .p256, holderPublicKey: holderKey)
        fake.holders[0].generation = 2
        var status = try await account.status()
        #expect(status.held?.generation == 2 && status.holdsCurrent)

        // A replacement nobody signed for: never followed, shown with its fingerprint.
        let third = try AccountKey.generate()
        let s3 = try third.statement(publicID: fake.publicID, generation: 3, previous: s2.fingerprint, reason: .compromise)
        fake.chain.append(.init(signed: try third.sign(s3), reason: "compromise", link: "replacement"))
        fake.holders[0].kak1 = try third.wrap(s3, suite: .p256, to: holderKey)
        fake.holders[0].generation = 3
        status = try await account.status()
        #expect(status.held?.generation == 2 && !status.holdsCurrent)
        #expect(status.unsignedReplacement == s3.fingerprint)
    }

    @Test func refusesAChainThatDoesntVerify() async throws {
        let fake = FakeCloud()
        let (account, _, _) = try await linkedAccount(fake)
        let key = try AccountKey.generate()
        try fake.portalCreatesKey(key)
        var signed = fake.chain[0].signed
        signed.signature[0] ^= 1
        fake.chain[0].signed = signed
        await #expect(throws: CloudError.self) { _ = try await account.status() }
        await #expect(throws: CloudError.self) { _ = try await account.receive(recoveryCode: code(key)) }
        #expect(fake.holders.isEmpty)
    }

    @Test func deliversARestoreWithTheAccountKeyAndOpensLabels() async throws {
        let fake = FakeCloud()
        let (account, _, _) = try await linkedAccount(fake)
        let key = try AccountKey.generate()
        try fake.portalCreatesKey(key)
        _ = try await account.receive(recoveryCode: code(key))
        let uid = Uid.random()
        let recipient = try key.publicKeys().x25519
        for v in [UInt32(1), 2] {
            fake.envelopes.append(try KEV1.wrap(vaultKey: SecretBytes([UInt8](repeating: UInt8(v), count: 32)), suite: .x25519,
                                                keyVersion: v, vaultUid: uid, recipientPublicKey: recipient).base64EncodedString())
        }
        fake.keyVersions = [1, 2]
        let temporary = RecoverySeed.generate()
        let pk = temporary.x25519PublicKey()
        fake.restoreSummary = ["id": "rst0123456789abcdefghjkmnp", "vault_uid": uid.base32, "status": "approved",
                               "temporary_public_key": pk.base64EncodedString(),
                               "requester": ["installation_id": "x", "name": "nas-2", "kind": "server", "fingerprint": "f"]]
        let restore = try #require(try await account.client.deliverable().first)
        let delivered = try await account.deliver(restore)
        #expect(delivered.versions == [1, 2] && delivered.missing.isEmpty)
        for text in try #require(fake.bundle) {
            let opened = try KEV1.unwrap(Data(base64Encoded: text)!, recipient: temporary.recipient(), vaultUid: uid)
            #expect(opened.key.withUnsafeBytes { Array($0) } == [UInt8](repeating: UInt8(opened.keyVersion), count: 32))
        }
        // The vault's sealed name opens with the held key.
        let sealed = try VaultLabel.seal("Family photos", statement: fake.current!, vaultUid: Data(uid.bytes))
        let names = try await account.openLabels([CloudVault(vaultUid: uid.base32, label: Base64URL.encode(sealed), replicas: [])])
        #expect(names == [uid.base32: "Family photos"])
    }

    @Test func aConsumerProcessWritesNothing() async throws {
        let fake = FakeCloud()
        let (_, memory, lease) = try await linkedAccount(fake)
        let consumer = LeasedAccountItems(items: memory, lease: nil)
        #expect(throws: CredentialOwnershipError.self) { try AccountCloudLinkStore(items: consumer).delete() }
        #expect(try AccountCloudLinkStore(items: consumer).load()?.state == .linked)
        lease.release()
        #expect(throws: CredentialOwnershipError.self) {
            try AccountCloudLinkStore(items: LeasedAccountItems(items: memory, lease: lease)).delete()
        }
    }
}

struct CloudErrorsAndBillingTests {
    func linkedClient(_ fake: FakeCloud) async throws -> CloudClient {
        let client = try CloudClient(endpoint: "https://api.vaulthalla.test", store: MemoryCloudLinkStore(), transport: fake)
        _ = try await client.startLink(name: "MacBook")
        fake.claimAnswer = "linked"
        _ = try await client.claimLink()
        return client
    }

    @Test func paymentRequiredAndRateLimitedAreTyped() async throws {
        let fake = FakeCloud()
        let client = try await linkedClient(fake)
        fake.failNext = (402, "payment_required", nil)
        await #expect(throws: CloudError.paymentRequired("refused for the test")) { _ = try await client.vaults() }
        fake.failNext = (429, "rate_limited", "30")
        await #expect(throws: CloudError.rateLimited(retryAfter: 30, message: "refused for the test")) { _ = try await client.vaults() }
        #expect(CloudError.rateLimited(retryAfter: 30, message: "").message.contains("30 seconds"))
        fake.failNext = (401, "unauthenticated", nil)
        await #expect(throws: CloudError.unauthenticated("refused for the test")) { _ = try await client.deployments() }
    }

    @Test func readsTheAccountAndStartsABillingHandoff() async throws {
        let fake = FakeCloud()
        let client = try await linkedClient(fake)
        #expect(try await client.installation().accountPublicId == fake.publicID)
        let billing = try await client.billing()
        #expect(billing.plan == "free" && billing.state == nil && billing.recoveryVaults.allowance == .limited(10))
        #expect(try await client.plans().plans.first?.recoveryVaults == .unlimited)
        let handoff = try await client.billingHandoff(kind: "checkout")
        #expect(fake.handoffKinds == ["checkout"])
        let env = CloudEnvironment(api: "https://api.vaulthalla.test", portal: URL(string: "https://app.vaulthalla.test")!)
        #expect(env.mayOpen(URL(string: handoff.url)!))
    }

    @Test func opensOnlyThePortalsOrigin() {
        let env = CloudEnvironment.production
        #expect(env.mayOpen(env.billing))
        #expect(env.mayOpen(env.keyRequest("0123456789abcdefghjkmnpqrs")!))
        #expect(env.keyRequest("abc")?.absoluteString == "https://app.vaulthalla.cloud/approvals/key-request#abc")
        for bad in ["http://app.vaulthalla.cloud/billing", "https://evil.example/billing", "https://app.vaulthalla.cloud.evil/x",
                    "https://user@app.vaulthalla.cloud/", "https://app.vaulthalla.cloud:8443/", "file:///etc/passwd"] {
            #expect(!env.mayOpen(URL(string: bad)!), "\(bad)")
        }
        let local = CloudEnvironment(api: "http://127.0.0.1:8085", portal: URL(string: "http://localhost:5173")!)
        #expect(local.mayOpen(URL(string: "http://localhost:5173/approvals")!))
        #expect(!local.mayOpen(URL(string: "http://localhost:5174/approvals")!))
        // Release builds never take another endpoint.
        let defaults = UserDefaults(suiteName: "vh-cloud-test-\(UUID().uuidString)")!
        defaults.set("https://staging.example", forKey: "cloud.endpoint")
        #expect(CloudEnvironment.resolve(debug: false, defaults: defaults) == .production)
        #expect(CloudEnvironment.resolve(debug: true, defaults: defaults).api == "https://staging.example")
    }

    @Test func planStatesInPlainWords() throws {
        func billing(_ state: String?) throws -> CloudBilling {
            let json = #"{"state": \#(state.map { "\"\($0)\"" } ?? "null"), "plan": "storage_1tb", "storage_quota_bytes": 1,"#
                + #""recovery_vaults": {"allowance": "unlimited", "enrolled": null}, "storage_access": "full","#
                + #""next": {"state": "restricted", "at": 0}, "deletion_at": 0, "current_period_end": null, "cancel_at_period_end": false}"#
            return try CloudClient.decoder.decode(CloudBilling.self, from: Data(json.utf8))
        }
        let date: (Date) -> String = { _ in "1 Dec" }
        #expect(PlanWording.state(try billing("active"), formatDate: date) == "Your plan is active.")
        #expect(PlanWording.state(try billing("past_due"), formatDate: date).hasSuffix("until 1 Dec."))
        #expect(PlanWording.state(try billing("ended"), formatDate: date).contains("deleted on 1 Dec"))
        #expect(PlanWording.action(try billing("suspended")) == .updatePayment)
        #expect(PlanWording.action(try billing(nil)) == .choosePlan)
        #expect(PlanWording.action(try billing("active")) == .manageBilling)
    }

    @Test func theTransportIsEphemeralAndRefusesRedirects() {
        let c = URLSessionCloudTransport.configuration()
        #expect(c.httpCookieStorage == nil && c.urlCache == nil && c.urlCredentialStorage == nil)
        #expect(!c.httpShouldSetCookies && c.httpCookieAcceptPolicy == .never)
        #expect(c.tlsMinimumSupportedProtocolVersion == .TLSv12)
        #expect(URLSessionCloudTransport.maximumResponse == 1 << 20)
    }

    @Test func keychainItemsAreThisDeviceOnlyInTheAppOnlyGroup() {
        let store = KeychainAccountItemStore(keychain: .dataProtection(accessGroup: "ZG2G6V7GLC.sh.vaulthalla.app.account"))
        let q = store.query("link")
        #expect(q[kSecAttrService as String] as? String == "sh.vaulthalla.app.account")
        #expect(q[kSecAttrAccessGroup as String] as? String == "ZG2G6V7GLC.sh.vaulthalla.app.account")
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(store.addAttributes()[kSecAttrAccessible as String] as! CFString == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        #expect(KeychainAccountItemStore(keychain: .fileBased).query("link")[kSecAttrAccessGroup as String] == nil)
    }
}

struct NodeMappingTests {
    let account = "5f0c3a3e-8d1b-4c2a-9e47-6b1d2f3a4c5e"
    let nas = CloudDeployment(id: "dep-nas", name: "nas", nodeId: "node-nas")
    let attic = CloudDeployment(id: "dep-attic", name: "attic", nodeId: "node-attic")
    let office = CloudDeployment(id: "dep-office", name: "office", nodeId: "node-office")

    @Test func mapsEveryCase() {
        let nodes: [NodeMapping.Node] = [
            .init(id: NodeID(rawValue: "a"), name: "nas", serverNodeID: "node-nas",
                  link: .linked(deploymentID: "dep-nas", accountPublicID: account),
                  vaults: [.init(id: 4, name: "Photos", uid: "uid-photos"), .init(id: 5, name: "Docs", uid: "uid-other")]),
            .init(id: NodeID(rawValue: "b"), name: "attic", serverNodeID: "node-attic", link: .unknown),
            .init(id: NodeID(rawValue: "c"), name: "lab", serverNodeID: "node-lab", link: .notLinked),
            .init(id: NodeID(rawValue: "d"), name: "friend", serverNodeID: "x",
                  link: .linked(deploymentID: "dep-elsewhere", accountPublicID: "another")),
            .init(id: NodeID(rawValue: "e"), name: "old", serverNodeID: "node-office", link: .unsupported),
        ]
        let vaults = [CloudVault(vaultUid: "uid-photos", replicas: [.init(deploymentId: "dep-nas", originVaultId: 4)]),
                      CloudVault(vaultUid: "uid-docs", replicas: [.init(deploymentId: "dep-nas", originVaultId: 5)]),
                      CloudVault(vaultUid: "uid-attic", replicas: [.init(deploymentId: "dep-attic", originVaultId: 1)])]
        let r = NodeMapping.map(deployments: [nas, attic, office, CloudDeployment(id: "dep-far", name: "far", nodeId: nil)],
                                vaults: vaults, nodes: nodes, accountPublicID: account)
        #expect(r.servers == [.linked(node: NodeID(rawValue: "a"), deployment: nas),
                              .likely(node: NodeID(rawValue: "b"), deployment: attic),
                              .notLinked(node: NodeID(rawValue: "c")),
                              .otherAccount(node: NodeID(rawValue: "d")),
                              .needsUpdate(node: NodeID(rawValue: "e"), deployment: office),
                              .unpaired(deployment: CloudDeployment(id: "dep-far", name: "far", nodeId: nil))])
        // Photos agrees on both sides; Docs' vault id 5 reports another uid there: shown, not mapped; attic isn't
        // confirmed, so its vault stays the cloud's.
        #expect(r.vaults[0].placements[0].node == NodeID(rawValue: "a") && r.vaults[0].placements[0].nodeVaultID == 4)
        #expect(r.vaults[1].placements[0].uidMismatch && r.vaults[1].placements[0].node == nil)
        #expect(r.vaults[2].placements[0].node == nil && !r.vaults[2].placements[0].uidMismatch)
    }

    @Test func serverKeyAdvice() {
        let held = "b4ad-7378-e4dc-5d1d-118b-7242-10b4-31b0"
        #expect(ServerKeyAdvice.advise(state: "pending", accountPublicID: account, pinned: nil, waiting: held.uppercased(),
                                       held: held, ourAccount: account) == .confirm(fingerprint: held))
        #expect(ServerKeyAdvice.advise(state: "pending", accountPublicID: account, pinned: nil,
                                       waiting: "0000-7378-e4dc-5d1d-118b-7242-10b4-31b0", held: held, ourAccount: account)
            == .mismatch(waiting: "0000-7378-e4dc-5d1d-118b-7242-10b4-31b0"))
        #expect(ServerKeyAdvice.advise(state: "pinned", accountPublicID: account, pinned: held, waiting: nil, held: held,
                                       ourAccount: account) == .pinned)
        #expect(ServerKeyAdvice.advise(state: "pinned", accountPublicID: "other", pinned: held, waiting: nil, held: held,
                                       ourAccount: account) == .none("Linked to a different Vaulthalla Cloud account."))
        if case .none = ServerKeyAdvice.advise(state: "pending", accountPublicID: account, pinned: nil, waiting: held, held: nil,
                                               ourAccount: account) {} else { Issue.record("advised without a held key") }
    }
}
