import Foundation
import Testing
import VHCore
@testable import VHCloud
import VHKeykit
import VHRecovery
@testable import VHVault

/// What the provider behind a ``KeyedBucket`` takes, changed by a test as it goes: which key ids it accepts now, and
/// which key ids reach another bucket than the vault's (a key the person made for another bucket).
final class ProviderPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptsNow: @Sendable (String) -> Bool = { _ in true }
    private var buckets: [String: MemoryBucket] = [:]
    func accept(_ rule: @escaping @Sendable (String) -> Bool) { lock.withLock { acceptsNow = rule } }
    func route(_ keyID: String, to bucket: MemoryBucket) { lock.withLock { buckets[keyID] = bucket } }
    func accepts(_ id: String) -> Bool { lock.withLock { acceptsNow }(id) }
    func bucket(for id: String) -> MemoryBucket? { lock.withLock { buckets[id] } }
    private var made: [KeyedBucket] = []
    func record(_ store: KeyedBucket) { lock.withLock { made.append(store) } }
    /// Every store made over this provider (a session's, a key check's), newest last.
    var stores: [KeyedBucket] { lock.withLock { made } }
}

/// The bucket as a provider that checks keys: every request needs a key (a refusal otherwise, reported through the
/// credential source's `providerRefused()` as S3Store reports moto's 403), over the B2-like in-memory bucket (or the one ``ProviderPolicy`` routes the key to). Counts the
/// vault bucket's writes and the key ids requests were signed with, so a test sees nothing was written before a switch.
final class KeyedBucket: VaultStore, @unchecked Sendable {
    let inner: MemoryBucket
    let credentials: any S3CredentialSource
    let policy: ProviderPolicy
    private let lock = NSLock()
    private var writeCount = 0
    private var presented: [String] = []
    var versionLog: Bool { inner.versionLog }
    var writes: Int { lock.withLock { writeCount } }
    /// Every key id a request was signed with, in order.
    var keyIDs: [String] { lock.withLock { presented } }

    init(_ inner: MemoryBucket, credentials: any S3CredentialSource, policy: ProviderPolicy = ProviderPolicy()) {
        self.inner = inner
        self.credentials = credentials
        self.policy = policy
    }

    private func gate(write: Bool = false) throws(StoreError) -> MemoryBucket {
        let credentials = credentials
        guard let id = blocking({ await credentials.withS3Credentials { $0.accessKeyID } ?? nil }) else { throw .failed("no key: 403") }
        lock.withLock { presented.append(id) }
        guard policy.accepts(id) else {
            // As S3Store does on a 401 or 403: the credential source is told, and the error says only that it failed.
            blocking { await credentials.providerRefused() }
            throw .failed("the storage request was refused")
        }
        let target = policy.bucket(for: id) ?? inner
        if write, target === inner { lock.withLock { writeCount += 1 } }
        return target
    }

    func get(_ key: String, versionID: String?) throws(StoreError) -> ObjectBody { try gate().get(key, versionID: versionID) }
    func getRange(_ key: String, versionID: String?, offset: UInt64, length: UInt64) throws(StoreError) -> (bytes: Data, total: UInt64) {
        try gate().getRange(key, versionID: versionID, offset: offset, length: length)
    }
    func head(_ key: String) throws(StoreError) -> StoredObject { try gate().head(key) }
    func put(_ key: String, _ bytes: UnsafeRawBufferPointer, condition: PutCondition) throws(StoreError) -> StoredObject {
        try gate(write: true).put(key, bytes, condition: condition)
    }
    func list(prefix: String) throws(StoreError) -> [ListedObject] { try gate().list(prefix: prefix) }
    func versions(_ key: String, stopAt: String?, underPrefix: Bool) throws(StoreError) -> [ListedVersion] {
        try gate().versions(key, stopAt: stopAt, underPrefix: underPrefix)
    }
    func remove(_ key: String, versionID: String?) throws(StoreError) { try gate(write: true).remove(key, versionID: versionID) }
    func beginContent(_ key: String, size: UInt64?) throws(StoreError) -> any ContentUpload {
        try gate(write: true).beginContent(key, size: size)
    }
}

/// Desktop-only vaults' lifecycle (``DesktopVaults``) against ``FakeDeviceCloud`` (the daemon's routes, extended from
/// its code with enrollment and the scoped envelope fetch) and the engine over an in-memory bucket that checks the
/// bucket key: the gates (link, account key, offline copy, plan), creating (the key enrolled before anything is stored,
/// registered with no deployment, storage on, the key, the first publish), a bucket that isn't ready yet, opening
/// again from the state, adopting on a replacement Mac from the account key's envelopes, and stopping holding.
@Suite(.serialized) struct DesktopVaultLifecycleTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    final class Mac {
        let fake: FakeDeviceCloud
        let clock: ManualClock
        let client: CloudClient
        let account: CloudAccount
        let memory = MemoryAccountItemStore()
        let items: LeasedAccountItems
        let container: URL
        let bucket: MemoryBucket
        let policy = ProviderPolicy()
        /// Writes to the vault's bucket through any store the vaults made.
        var bucketWrites: Int { policy.stores.reduce(0) { $0 + $1.writes } }
        var vaults: DesktopVaults!

        init(fake: FakeDeviceCloud, clock: ManualClock, bucket: MemoryBucket) async throws {
            self.fake = fake
            self.clock = clock
            self.bucket = bucket
            container = FileManager.default.temporaryDirectory.appending(path: "vh-desktop-vault-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            let lease = CredentialLease(forRegistry: container.appending(path: "nodes.json"), holder: "test")
            try lease.acquire()
            items = LeasedAccountItems(items: memory, lease: lease)
            client = try CloudClient(endpoint: "https://api.vaulthalla.test", store: AccountCloudLinkStore(items: items), transport: fake)
            _ = try await client.startLink(name: "MacBook")
            fake.base.claimAnswer = "linked"
            #expect(try await client.claimLink() == .linked)
            account = CloudAccount(client: client, items: items, holderKeys: HolderKeys(preferEnclave: false, userPresence: false))
            vaults = makeVaults()
        }

        /// The vaults over this Mac's keychain and container; `client` another view of the cloud (one that can't be reached).
        func makeVaults(client other: CloudClient? = nil) -> DesktopVaults {
            var sync = DesktopVaultSession.Settings()
            sync.automatic = false
            let bucket = bucket
            let policy = policy
            let client = other ?? client
            let account = other.map { CloudAccount(client: $0, items: items, holderKeys: HolderKeys(preferEnclave: false, userPresence: false)) }
                ?? account
            return DesktopVaults(client: client, account: account, items: items, container: container,
                                 makeStore: { credentials, _ in
                                     let store = KeyedBucket(bucket, credentials: credentials, policy: policy)
                                     policy.record(store)
                                     return store
                                 }, clock: clock, syncSettings: sync, bucketWait: 5)
        }

        func receive(_ key: AccountKey) async throws { _ = try await account.receive(recoveryCode: try key.recoveryCode()) }
    }

    func setUp() async throws -> (Mac, AccountKey) {
        let clock = ManualClock(Self.start)
        let fake = FakeDeviceCloud(clock: clock)
        let key = try AccountKey.generate()
        try fake.base.portalCreatesKey(key)
        let mac = try await Mac(fake: fake, clock: clock, bucket: MemoryBucket())
        return (mac, key)
    }

    @Test func theGatesLeadThePersonWhereTheyGo() async throws {
        let (mac, key) = try await setUp()
        #expect(await mac.vaults.readiness() == .noAccountKey)
        try await mac.receive(key)
        mac.fake.offlineCopy = false
        #expect(await mac.vaults.readiness() == .offlineCopyNeeded)
        await #expect(throws: DesktopVaultError.notReady(.offlineCopyNeeded)) { _ = try await mac.vaults.create(name: "Taxes") }
        #expect(mac.fake.vaults.isEmpty && mac.fake.enrolled.isEmpty)  // nothing reached the cloud
        mac.fake.offlineCopy = true
        mac.fake.entitle("restricted")
        #expect(await mac.vaults.readiness() == .noStorage(access: "read_delete", cause: "restricted"))
        mac.fake.entitle("active")
        #expect(await mac.vaults.readiness() == .ready)
    }

    @Test func createsAVaultRecoverableBeforeAnythingIsStored() async throws {
        let (mac, key) = try await setUp()
        try await mac.receive(key)
        mac.fake.provisionAtOnce = true
        let steps = StepLog()
        let session = try await mac.vaults.create(name: "Taxes") { steps.add($0) }
        let uid = session.uid
        #expect(steps.all.first == .makingKey && steps.all.last == .done && steps.all.contains(.publishing))

        // The order the cloud saw: enrollment (registering the vault as this Mac's), then the switch, then the key.
        let sent = mac.fake.sent.map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
        let enroll = try #require(sent.firstIndex { $0.hasPrefix("PUT") && $0.contains("/v1/recovery/vaults/\(uid)") })
        let storageOn = try #require(sent.firstIndex { $0.hasPrefix("PUT") && $0.contains("/v1/storage/vaults/\(uid)") })
        let bucketKey = try #require(sent.firstIndex { $0.contains("/v1/storage/vaults/\(uid)/credentials") })
        #expect(enroll < storageOn && storageOn < bucketKey)
        #expect(mac.fake.vaults[uid]?.holder == mac.fake.mac && mac.fake.vaults[uid]?.replicas.isEmpty == true)

        // The enrolled envelope opens with the account key to the key this Mac sealed with.
        let envelope = try #require(mac.fake.enrolled[uid]?.first)
        let seed = try (try key.recoveryCode()).withUnsafeBytes { try RecoverySeed(text: String(decoding: $0, as: UTF8.self)) }
        let opened = try KEV1.unwrap(envelope, recipient: seed.recipient(), vaultUid: Uid(base32: uid)!)
        let held = try #require(try VaultKeyStore(items: mac.items).withKey(uid, version: 1) { Data($0) })
        #expect(opened.keyVersion == 1 && opened.key.withUnsafeBytes { Data($0) } == held)
        // The vault key never left this Mac but wrapped.
        #expect(!mac.fake.sent.contains { $0.contains(held.base64EncodedString()) })

        // The bucket holds the first root and the key's envelope; the record says it is published.
        #expect(mac.bucket.currentKeys.contains(".vaulthalla/root"))
        #expect(mac.bucket.currentKeys.contains { $0.hasPrefix(".vaulthalla/key/") })
        #expect(try mac.vaults.registry.record(uid)?.published == true)
        #expect(await session.status.state == .upToDate)

        // A file, published shortly after.
        let vault = try #require(await session.openedVault())
        try await vault.perform { v throws(VaultError) in _ = try v.write(Data("2025 return".utf8), parent: try v.rootUID(), name: "a.txt") }
        await session.noteChange()
        #expect(await session.status.unpublished)
        await session.syncNow(force: true)
        let after = await session.status
        #expect(after.state == .upToDate && !after.unpublished)
        #expect(try await vault.perform { v throws(VaultError) in try v.status().epoch } == 2)
    }

    @Test func aBucketNotReadyYetFinishesOnItsOwn() async throws {
        let (mac, key) = try await setUp()
        try await mac.receive(key)
        let session = try await mac.vaults.create(name: "Later")
        let uid = session.uid
        guard case .waiting(.bucketNotReady) = await session.accessPhase else {
            Issue.record("expected to wait for the bucket")
            return
        }
        #expect(try mac.vaults.registry.record(uid)?.published == false)
        #expect(mac.bucket.currentKeys.isEmpty)
        await session.syncNow()
        #expect(await session.status.state == .waitingForStorage(.bucketNotReady))
        #expect(await session.status.sentence.contains("storage isn't ready"))

        mac.fake.provision(uid)
        mac.clock.advance(16 * 60)
        await session.access.step()
        #expect(await session.accessPhase == .holding)
        await session.syncNow()
        #expect(await session.status.state == .upToDate)
        #expect(try mac.vaults.registry.record(uid)?.published == true)
        #expect(mac.bucket.currentKeys.contains(".vaulthalla/root"))
    }

    /// docs/desktop-vaults.md, "Key provenance": creating a vault enrolls version 1 with this Mac's key check and
    /// attestation (vl-keykit) under its own origin, with the signing key in the account's app-only items; the
    /// attestation verifies only over that origin, vault id and version; opening a vault it created backfills a bare
    /// enrollment (one from before Desktop attested).
    @Test func aCreatedVaultsVersionIsAttestedByThisMacAndBackfilledOnOpen() async throws {
        let (mac, key) = try await setUp()
        try await mac.receive(key)
        mac.fake.provisionAtOnce = true
        let uid = try await { () async throws -> String in
            let session = try await mac.vaults.create(name: "Taxes")
            await mac.vaults.closeAll()
            return session.uid
        }()
        let me = try #require(try mac.client.link()?.installationID)
        let wire = Data(try #require(Uid(base32: uid)).bytes)
        let vaultID = try Provenance.macOriginVaultID(uid: wire)
        let recorded = try #require(mac.fake.provenance[uid]?[1])
        #expect(recorded.nodeID == me && recorded.vaultID == vaultID)
        let check = try #require(try VaultKeyStore(items: mac.items).withKey(uid, version: 1) {
            try Provenance.keyCheck(key: $0, vaultID: UInt64(vaultID), version: 1)
        })
        #expect(recorded.keyCheck == check)
        let pk = try #require((recorded.attestation["public_key"] as? String).flatMap { Data(base64Encoded: $0) })
        let sig = try #require((recorded.attestation["signature"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(Provenance.verify(publicKey: pk, nodeID: me, vaultID: UInt64(vaultID), version: 1, keyCheck: check, signature: sig))
        #expect(!Provenance.verify(publicKey: pk, nodeID: me, vaultID: UInt64(vaultID) + 1, version: 1, keyCheck: check, signature: sig))
        #expect(!Provenance.verify(publicKey: pk, nodeID: "00000000-0000-4000-8000-000000000001", vaultID: UInt64(vaultID),
                                   version: 1, keyCheck: check, signature: sig))
        #expect((recorded.attestation["key_id"] as? NSNumber)?.uint32Value == Provenance.keyID(publicKey: pk))
        #expect(mac.memory.names.contains(AttestationKeyStore.item))

        // A vault enrolled before Desktop attested: the next open records its provenance, with the cloud's envelopes.
        mac.fake.provenance[uid] = nil
        let enveloped = mac.fake.enrolled[uid]?.count
        let again = mac.makeVaults()
        _ = try await again.open(uid)
        await again.closeAll()
        #expect(mac.fake.provenance[uid]?[1]?.keyCheck == check)
        #expect(mac.fake.enrolled[uid]?.count == enveloped)  // no new envelope
    }

    @Test func opensAgainFromTheStateAndAdoptsOnAReplacementMac() async throws {
        let (mac, key) = try await setUp()
        try await mac.receive(key)
        mac.fake.provisionAtOnce = true
        // Scoped: a Vault handle someone still holds keeps the state locked (one engine per state file).
        let (uid, file) = try await { () async throws -> (String, String) in
            let session = try await mac.vaults.create(name: "Photos")
            let vault = try #require(await session.openedVault())
            let file = try await vault.perform { v throws(VaultError) in
                try v.write(Data("beach".utf8), parent: try v.rootUID(), name: "beach.jpg").entry.uid
            }
            await session.syncNow(force: true)
            await mac.vaults.closeAll()
            return (session.uid, file)
        }()

        // The same Mac after a relaunch: from the state file.
        let again = mac.makeVaults()
        #expect(await again.openHeld().isEmpty)
        try await { () async throws in
            let reopened = try #require(await again.session(uid))
            let v2 = try #require(await reopened.openedVault())
            #expect(try await v2.perform { v throws(VaultError) in try v.readData(file) } == Data("beach".utf8))
            await again.closeAll()
        }()

        // A replacement Mac: no keychain item, no state; the account holder placed the vault on it (the fake's one
        // installation stands for it). Its keys come from the account key's envelopes.
        let replacement = try await Mac(fake: mac.fake, clock: mac.clock, bucket: mac.bucket)
        await #expect(throws: DesktopVaultError.self) { _ = try await replacement.vaults.adopt(uid, name: "Photos") }  // no account key
        try await replacement.receive(key)
        #expect(try await replacement.vaults.adoptable() == [uid])
        let adopted = try await replacement.vaults.adopt(uid, name: "Photos")
        let v3 = try #require(await adopted.openedVault())
        #expect(try await v3.perform { v throws(VaultError) in try v.readData(file) } == Data("beach".utf8))
        await adopted.syncNow(force: true)
        #expect(await adopted.status.state == .upToDate)
        try await v3.perform { v throws(VaultError) in _ = try v.write(Data("dunes".utf8), parent: try v.rootUID(), name: "dunes.jpg") }
        await adopted.noteChange()
        await adopted.syncNow(force: true)
        let adoptedStatus = await adopted.status
        #expect(!adoptedStatus.unpublished)

        // Stopping holding: the cloud's hold goes, local keys and state stay.
        try await replacement.vaults.stopHolding(uid)
        #expect(mac.fake.vaults[uid]?.holder == nil)
        #expect(try replacement.vaults.registry.record(uid)?.hold == .released)
        #expect(try VaultKeyStore(items: replacement.items).versions(uid) != nil)
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [DesktopVaultCreationStep] = []
    func add(_ s: DesktopVaultCreationStep) { lock.withLock { steps.append(s) } }
    var all: [DesktopVaultCreationStep] { lock.withLock { steps } }
}
