import Foundation
import Testing
import VHCore
@testable import VHCloud
import VHKeykit
import VHRecovery
@testable import VHVault

/// Leaving managed storage (an ejection: managed-storage.md "As built" 13 and 25) for a vault this Mac holds, against
/// ``FakeDeviceCloud`` (the daemon's `eject`, `account.eject` job, `ejection` and `reportConverted`) and the B2-like
/// in-memory bucket (versions ordered by upload start) behind a provider that checks keys: the vault converts in place
/// and reports at once (so the ejection doesn't wait for its deadline), syncs on the cloud's last key until it ends,
/// then pauses until the person's own key, which is checked with reads only before the switch; from then on the cloud
/// is never asked for a key. Nothing local is deleted in any branch.
@Suite(.serialized) struct DesktopVaultEjectionTests {
    typealias Mac = DesktopVaultLifecycleTests.Mac
    static let ownID = "004own0000000001"
    static let ownSecret = "K004ownApplicationKeySecret0000000000"

    /// A Mac holding a published vault with one file; the provider takes the cloud's keys in force and, once the account
    /// is the customer's, the key they make there.
    func setUp() async throws -> (Mac, String, String) {
        let clock = ManualClock(DesktopVaultLifecycleTests.start)
        let fake = FakeDeviceCloud(clock: clock)
        let key = try AccountKey.generate()
        try fake.base.portalCreatesKey(key)
        fake.provisionAtOnce = true
        let mac = try await Mac(fake: fake, clock: clock, bucket: MemoryBucket())
        try await mac.receive(key)
        mac.policy.accept { [fake] id in
            fake.providerAccepts(id) || (id == Self.ownID && fake.lock.withLock { fake.ejection == "complete" })
        }
        let session = try await mac.vaults.create(name: "Taxes")
        let vault = try #require(await session.openedVault())
        let file = try await vault.perform { v throws(VaultError) in
            try v.write(Data("2025 return".utf8), parent: try v.rootUID(), name: "return.pdf").entry.uid
        }
        await session.noteChange()
        await session.syncNow(force: true)
        #expect(await session.status.state == .upToDate)
        return (mac, session.uid, file)
    }

    func session(_ mac: Mac, _ uid: String) async throws -> DesktopVaultSession { try #require(await mac.vaults.session(uid)) }

    /// The access loop reads the cloud's view now.
    func stepWithView(_ mac: Mac, _ uid: String) async throws {
        let s = try await session(mac, uid)
        await s.access.apply(try await mac.client.storage())
        _ = await s.access.step()
    }

    func write(_ s: DesktopVaultSession, _ name: String) async throws {
        let vault = try #require(await s.openedVault())
        try await vault.perform { v throws(VaultError) in _ = try v.write(Data(name.utf8), parent: try v.rootUID(), name: name) }
        await s.noteChange()
    }

    /// A change kept on this Mac alone (a folder: no content to upload), as one made while the vault is paused.
    func change(_ s: DesktopVaultSession, _ name: String) async throws {
        let vault = try #require(await s.openedVault())
        try await vault.perform { v throws(VaultError) in _ = try v.mkdir(parent: try v.rootUID(), name: name) }
        await s.noteChange()
    }

    func useOwnKey(_ mac: Mac, _ uid: String, id: String = ownID, secret: String = ownSecret) async throws(DesktopVaultError) {
        try await mac.vaults.useOwnKey(uid, keyID: id, secret: SecretBytes(Data(secret.utf8)))
    }

    @Test func anEjectionConvertsInPlaceReportsAtOnceAndPausesWhenTheCloudsKeyEnds() async throws {
        let (mac, uid, file) = try await setUp()
        let s = try await session(mac, uid)
        let requests = mac.fake.credentialRequests
        let keyEnds = try #require(await s.access.status.expiresAt)

        // The account holder leaves managed storage in the portal.
        mac.fake.ownerEjects()
        #expect(mac.fake.runEjectionJob() == false)  // it waits for this Mac's report
        try await stepWithView(mac, uid)
        #expect(await s.access.phase == .leaving(keyUntil: keyEnds))
        #expect(mac.fake.vaults[uid]?.converted["desktop:\(mac.fake.mac)"] != nil && mac.fake.conversionReports == 1)
        #expect(mac.fake.runEjectionJob())  // reported: the ejection finishes now, not at its 72-hour deadline
        #expect(mac.fake.vaults[uid]?.bucketState == "ejected")

        // Still syncing on the cloud's last key, which the ejection left with the Mac.
        try await write(s, "late.txt")
        await s.syncNow(force: true)
        let leaving = await s.status
        #expect(leaving.state == .upToDate && !leaving.unpublished)
        #expect(leaving.sentence.contains("own storage provider account") && leaving.sentence.contains("Up to date"))
        #expect(try await s.openedVault()?.perform { v throws(VaultError) in try v.readData(file) } == Data("2025 return".utf8))

        // The key ends (24 hours from issue): paused, waiting for the person's own key; nothing local goes.
        mac.clock.set(keyEnds + 1)
        _ = await s.access.step()
        #expect(await s.access.phase == .needsOwnKey(.cloudKeyEnded))
        try await change(s, "while-paused")
        await s.syncNow(force: true)
        let paused = await s.status
        #expect(paused.state == .needsOwnKey(.cloudKeyEnded) && paused.unpublished)
        #expect(paused.sentence.hasPrefix("Paused:") && paused.sentence.contains("Nothing on this Mac is deleted")
            && paused.sentence.contains("vhc-\(uid)"))
        #expect(FileManager.default.fileExists(atPath: mac.vaults.registry.stateURL(uid).path(percentEncoded: false)))
        #expect(try mac.vaults.registry.record(uid)?.hold == .holding)
        #expect(try VaultKeyStore(items: mac.items).versions(uid) != nil)

        // Days later: still no key asked of the cloud, and no second report.
        mac.clock.advance(3 * 86400)
        for _ in 0 ..< 3 { _ = await s.access.step() }
        #expect(mac.fake.credentialRequests == requests && mac.fake.conversionReports == 1)
        #expect(!mac.fake.sent.contains { $0.contains(Self.ownSecret) })
    }

    @Test func theOwnKeyIsCheckedWithReadsBeforeTheSwitchAndEveryRefusalChangesNothing() async throws {
        let (mac, uid, file) = try await setUp()
        let s = try await session(mac, uid)
        let requests = mac.fake.credentialRequests

        // Still managed: no key of the person's is taken.
        await #expect(throws: DesktopVaultError.stillManaged) { try await useOwnKey(mac, uid) }

        mac.fake.ownerEjects()
        try await stepWithView(mac, uid)
        mac.fake.runEjectionJob()
        mac.clock.advance(FakeDeviceCloud.keyMinutes * 60 + 1)
        try await stepWithView(mac, uid)
        #expect(await s.access.phase == .needsOwnKey(.cloudKeyEnded))
        #expect(await s.access.status.ejection?.complete == true)
        try await change(s, "waiting")
        let writes = mac.bucketWrites

        // What the person typed isn't a key.
        await #expect(throws: DesktopVaultError.invalidKey("key ID")) { try await useOwnKey(mac, uid, id: "has space") }
        await #expect(throws: DesktopVaultError.invalidKey("application key")) { try await useOwnKey(mac, uid, secret: "a b") }
        // The provider refuses it.
        await #expect(throws: DesktopVaultError.ownKey(.keyRefused)) { try await useOwnKey(mac, uid, id: "004nobody") }
        // A key for another bucket, holding another vault, or nothing at all.
        let another = MemoryBucket()
        let otherUid = Uid.random()
        let otherKey = newVaultKey()
        let otherEnvelope = try KEV1.wrap(vaultKey: otherKey, suite: .x25519, keyVersion: 1, vaultUid: otherUid,
                                          recipientPublicKey: RecoverySeed.generate().x25519PublicKey())
        let other = try await Vault.open(uid: otherUid, store: another, keys: MemoryVaultKeys([1: otherKey], current: 1),
                                         stateURL: mac.container.appending(path: "other.state"), nodeID: "other", createName: "Other")
        try await other.vault.perform { v throws(VaultError) in
            try v.addKey(version: 1, key: otherKey, envelopes: [otherEnvelope])
            _ = try v.publish()
        }
        mac.policy.route("004another", to: another)
        mac.policy.route("004empty", to: MemoryBucket())
        mac.policy.accept { [fake = mac.fake] id in
            fake.providerAccepts(id) || [Self.ownID, "004another", "004empty"].contains(id)
        }
        await #expect(throws: DesktopVaultError.ownKey(.anotherVault)) { try await useOwnKey(mac, uid, id: "004another") }
        await #expect(throws: DesktopVaultError.ownKey(.noVault)) { try await useOwnKey(mac, uid, id: "004empty") }
        #expect(await s.access.phase == .needsOwnKey(.cloudKeyEnded))
        #expect(mac.bucketWrites == writes)  // nothing written to the vault's bucket by any check
        #expect((try? BucketKeyStore(items: mac.items).load(uid)) ?? nil == nil)

        // The right key: one GET of the root with it, then the switch.
        let probesBefore = mac.policy.stores.count
        try await useOwnKey(mac, uid)
        let probe = try #require(mac.policy.stores.dropFirst(probesBefore).first)
        #expect(probe.writes == 0 && probe.keyIDs == [Self.ownID])
        #expect(await s.access.phase == .ownStorage)
        let kept = try #require(try BucketKeyStore(items: mac.items).load(uid))
        #expect(kept.origin == .customer && kept.keyID == Self.ownID && kept.bucket == "vhc-\(uid)" && kept.expiresAt == BucketKey.noExpiry)
        // Syncing with it: the change that waited is sent, signed with the person's key.
        let synced = await s.status
        #expect(synced.state == .upToDate && !synced.unpublished)
        let sessionStore = try #require(mac.policy.stores.first)
        #expect(sessionStore.keyIDs.last == Self.ownID)
        #expect(try await s.openedVault()?.perform { v throws(VaultError) in try v.readData(file) } == Data("2025 return".utf8))
        #expect(synced.sentence.contains("In your own storage provider account"))

        // Never asks the cloud for a key again, across a relaunch too.
        mac.clock.advance(7 * 86400)
        for _ in 0 ..< 3 { _ = await s.access.step() }
        await mac.vaults.closeAll()
        let again = mac.makeVaults()
        let reopened = try await again.open(uid)
        #expect(await reopened.access.phase == .ownStorage)
        _ = await reopened.access.step()
        try await write(reopened, "after-relaunch.txt")
        await reopened.syncNow(force: true)
        #expect(await reopened.status.state == .upToDate)
        #expect(mac.fake.credentialRequests == requests)
        #expect(!mac.fake.sent.contains { $0.contains(Self.ownSecret) })
        await again.closeAll()
    }

    /// The cloud can't be reached at all.
    struct UnreachableCloud: CloudTransport {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
    }

    /// The vault saw the ejection; the cloud's key then ended. Returns the bucket's location as the cloud gave it.
    func leftWithTheCloudsKeyEnded(_ mac: Mac, _ uid: String) async throws -> BucketLocation {
        let s = try await session(mac, uid)
        mac.fake.ownerEjects()
        try await stepWithView(mac, uid)
        mac.fake.runEjectionJob()
        mac.clock.advance(FakeDeviceCloud.keyMinutes * 60 + 1)
        _ = await s.access.step()
        #expect(await s.access.phase == .needsOwnKey(.cloudKeyEnded))
        await mac.vaults.closeAll()
        return try #require(await s.access.ownKeyLocation)
    }

    /// Found in review: a vault that left managed storage must not need the cloud to say so. After a relaunch, with
    /// the cloud unreachable, this Mac unlinked by the cloud, or the vault gone from the account, it still waits for the
    /// person's key (with the bucket's location, from the record kept beside the bucket key) and takes it.
    @Test func aVaultThatLeftManagedStorageNeedsNoCloudAfterARelaunch() async throws {
        let (mac, uid, file) = try await setUp()
        let location = try await leftWithTheCloudsKeyEnded(mac, uid)
        let me = try #require(try mac.client.link()?.installationID)
        let store = BucketKeyStore(items: mac.items)
        #expect(try store.hasLeftManagedStorage(uid) && (try store.load(uid)) == nil)  // the record without the key
        let requests = mac.fake.credentialRequests

        let unreachable = try CloudClient(endpoint: "https://api.vaulthalla.test", store: AccountCloudLinkStore(items: mac.items),
                                          transport: UnreachableCloud())
        let clouds: [(String, CloudClient, () -> Void)] = [
            ("unreachable", unreachable, {}),
            ("unlinked", mac.client, { mac.fake.installationRevoked = true }),
            ("no such vault", mac.client, {
                mac.fake.installationRevoked = false
                mac.fake.lock.withLock { mac.fake.vaults[uid] = nil; mac.fake.order.removeAll { $0 == uid } }
            }),
        ]
        var last: DeviceAccess?
        for (why, client, prepare) in clouds {
            prepare()
            let access = try DeviceAccess(client: client, vaultUid: uid, installationID: me, store: store, clock: mac.clock)
            #expect(await access.phase == .needsOwnKey(.cloudKeyEnded), "\(why)")
            #expect(await access.ownKeyLocation == location, "\(why)")
            for _ in 0 ..< 3 {
                _ = await access.step()
                mac.clock.advance(3600)
            }
            // A view without the vault (when the cloud answers at all) changes nothing either.
            if let view = try? await mac.client.storage() { await access.apply(view) }
            #expect(await access.phase == .needsOwnKey(.cloudKeyEnded), "\(why)")
            last = access
        }
        #expect(mac.fake.credentialRequests == requests)

        // The person's key, checked against the bucket, switches the vault; it syncs with it.
        let access = try #require(last)
        let own = BucketKey(vaultUid: uid, keyID: Self.ownID, access: "full", bucket: location.bucket, bucketID: location.bucketID,
                            s3Endpoint: location.s3Endpoint, region: location.region, expiresAt: BucketKey.noExpiry,
                            renewAfter: BucketKey.noExpiry, secret: SecretBytes(Data(Self.ownSecret.utf8)), origin: .customer)
        let keys = KeychainVaultKeys(store: VaultKeyStore(items: mac.items), uid: uid)
        let probe = KeyedBucket(mac.bucket, credentials: OwnKeyCredentials(own), policy: mac.policy)
        _ = try VaultBucketCheck.verify(probe, uid: Uid(base32: uid)!, keys: keys, known: nil)
        try await access.useOwnKey(own)
        #expect(await access.phase == .ownStorage)
        let bucket = KeyedBucket(mac.bucket, credentials: access, policy: mac.policy)
        let (vault, _) = try await Vault.open(uid: Uid(base32: uid)!, store: bucket, keys: keys,
                                              stateURL: mac.vaults.registry.stateURL(uid), nodeID: me)
        try await vault.perform { v throws(VaultError) in
            #expect(try v.readData(file) == Data("2025 return".utf8))
            _ = try v.write(Data("offline".utf8), parent: try v.rootUID(), name: "offline.txt")
            #expect(try v.publish().published)
        }
        #expect(bucket.keyIDs.allSatisfy { $0 == Self.ownID } && bucket.writes > 0)
        #expect(mac.fake.credentialRequests == requests)
    }

    /// A bucket key kept before `origin` and `leftManaged` existed still loads, as the cloud's, in managed storage.
    @Test func anOlderStoredKeyStillDecodes() throws {
        let memory = MemoryAccountItemStore()
        let container = FileManager.default.temporaryDirectory.appending(path: "vh-old-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let lease = CredentialLease(forRegistry: container.appending(path: "nodes.json"), holder: "test")
        try lease.acquire()
        let items = VaultItems(shared: LeasedAccountItems(items: memory, lease: lease))
        let uid = Uid.random().base32
        let old = #"{"keyID":"key-1","access":"full","bucket":"vhc-b","bucketID":"b-b","s3Endpoint":"https://s3.test","region":"r","expiresAt":1900000000,"renewAfter":1890000000,"revoked":false}"#
        try items.write(BucketKeyStore.item(uid), Data(old.utf8), operation: "test")
        try items.write("storage-key.\(uid).key-1", Data("secret".utf8), operation: "test")
        let store = BucketKeyStore(vaultItems: items)
        let key = try #require(try store.load(uid))
        let left = try store.hasLeftManagedStorage(uid)
        #expect(key.origin == .cloud && key.keyID == "key-1" && !left)
        #expect(try store.revokedReason(uid) == nil)
    }

    /// The same through ``DesktopVaults/useOwnKey(_:keyID:secret:)``, with the cloud unreachable.
    @Test func theOwnKeyIsTakenWithTheCloudUnreachable() async throws {
        let (mac, uid, file) = try await setUp()
        _ = try await leftWithTheCloudsKeyEnded(mac, uid)
        let unreachable = try CloudClient(endpoint: "https://api.vaulthalla.test", store: AccountCloudLinkStore(items: mac.items),
                                          transport: UnreachableCloud())
        let offline = mac.makeVaults(client: unreachable)
        let s = try await offline.open(uid)
        #expect(await s.access.phase == .needsOwnKey(.cloudKeyEnded))
        await s.syncNow(force: true)
        #expect(await s.status.state == .needsOwnKey(.cloudKeyEnded))
        try await offline.useOwnKey(uid, keyID: Self.ownID, secret: SecretBytes(Data(Self.ownSecret.utf8)))
        #expect(await s.access.phase == .ownStorage)
        try await write(s, "offline.txt")
        await s.syncNow(force: true)
        let synced = await s.status
        #expect(synced.state == .upToDate && !synced.unpublished)
        #expect(try await s.openedVault()?.perform { v throws(VaultError) in try v.readData(file) } == Data("2025 return".utf8))
        await offline.closeAll()
    }

    func keyRequests(_ mac: Mac) -> Int { mac.fake.sent.filter { $0.hasPrefix("POST ") && $0.contains("/credentials ") }.count }

    /// While the bucket is `ejecting` and the cloud can still issue (vaulthalla-cloud feat/desktop-renew-while-ejecting,
    /// in the fake as `issueWhileEjecting`), the key is renewed at `renew_after` as a held vault's; a transient failure
    /// backs off and retries; the first 409 ends renewal for good, across a relaunch; the last key then ends as before.
    @Test func whileEjectingTheKeyIsRenewedUntilA409EndsItForGood() async throws {
        let (mac, uid, _) = try await setUp()
        let s = try await session(mac, uid)
        mac.fake.issueWhileEjecting = true
        mac.fake.ownerEjects()
        try await stepWithView(mac, uid)
        guard case .leaving(let first) = await s.access.phase else { Issue.record("not leaving"); return }
        let me = try #require(try mac.client.link()?.installationID)

        // Renewed at renew_after: the same exchange, a later end.
        let asked = keyRequests(mac)
        mac.clock.set(try #require(await s.access.status.renewAfter) + 1)
        _ = await s.access.step()
        guard case .leaving(let second) = await s.access.phase else { Issue.record("not leaving"); return }
        #expect(second > first && keyRequests(mac) == asked + 1)
        #expect(mac.fake.activeKey(uid)?.expiresAt == second)
        #expect(try BucketKeyStore(items: mac.items).hasLeftManagedStorage(uid))
        try await write(s, "renewed.txt")
        await s.syncNow(force: true)
        #expect(await s.status.state == .upToDate)
        #expect(await s.status.sentence.contains("or later"))

        // A transient failure backs off and retries; the vault keeps leaving.
        mac.clock.set(try #require(await s.access.status.renewAfter) + 1)
        mac.fake.failNext = (503, "unavailable", "provider_unavailable", nil)
        _ = await s.access.step()
        #expect(await s.access.phase == .leaving(keyUntil: second))
        mac.clock.advance(31)
        _ = await s.access.step()
        guard case .leaving(let third) = await s.access.phase else { Issue.record("not leaving"); return }
        #expect(third > second)

        // The cloud destroyed its own credential: 409 ejecting ends renewal, recorded.
        mac.fake.issueWhileEjecting = false
        mac.clock.set(try #require(await s.access.status.renewAfter) + 1)
        let before409 = keyRequests(mac)
        _ = await s.access.step()
        #expect(keyRequests(mac) == before409 + 1)
        #expect(await s.access.phase == .leaving(keyUntil: third))
        #expect(await s.access.status.ejection?.renewalOver == true)
        #expect(try BucketKeyStore(items: mac.items).renewalIsOver(uid))
        mac.clock.advance(3600)
        _ = await s.access.step()
        #expect(keyRequests(mac) == before409 + 1)  // asked once, never again

        // Across a relaunch: the key in hand is the last; nothing is asked; it ends as before.
        await mac.vaults.closeAll()
        let again = try DeviceAccess(client: mac.client, vaultUid: uid, installationID: me, store: BucketKeyStore(items: mac.items),
                                     clock: mac.clock)
        #expect(await again.phase == .leaving(keyUntil: third))
        _ = await again.step()
        #expect(keyRequests(mac) == before409 + 1)
        mac.clock.set(third + 1)
        _ = await again.step()
        #expect(await again.phase == .needsOwnKey(.cloudKeyEnded))
        #expect(keyRequests(mac) == before409 + 1)
    }

    /// The cloud's key view saying renewal is over ends it without a request; a vault on the person's own key asks the
    /// cloud for nothing, even while the cloud could still issue.
    @Test func theKeyViewEndsRenewalAndTheOwnKeyNeverAsks() async throws {
        let (mac, uid, _) = try await setUp()
        let s = try await session(mac, uid)
        mac.fake.issueWhileEjecting = true
        mac.fake.sendRenewable = true
        mac.fake.ownerEjects()
        try await stepWithView(mac, uid)
        #expect(await s.access.status.ejection?.renewalOver == false)
        let asked = keyRequests(mac)
        mac.fake.issueWhileEjecting = false
        mac.clock.advance(16 * 60)  // the view is read again, before renew_after
        _ = await s.access.step()
        #expect(await s.access.status.ejection?.renewalOver == true)
        #expect(keyRequests(mac) == asked)

        mac.fake.issueWhileEjecting = true
        mac.policy.accept { [fake = mac.fake] id in fake.providerAccepts(id) || id == Self.ownID }
        try await useOwnKey(mac, uid)  // taken early, while the key in hand still works
        #expect(await s.access.phase == .ownStorage)
        for _ in 0 ..< 4 {
            mac.clock.advance(13 * 3600)
            _ = await s.access.step()
        }
        #expect(keyRequests(mac) == asked)
        #expect(await s.access.phase == .ownStorage)
    }

    @Test func aMacOfflineThroughTheEjectionReportsLateAndSwitches() async throws {
        let (mac, uid, _) = try await setUp()
        let s = try await session(mac, uid)
        mac.fake.ownerEjects()
        // This Mac is away for the cloud's whole wait: the ejection finishes at its deadline without the report.
        mac.clock.advance(FakeDeviceCloud.ejectWaitHours * 3600 + 1)
        #expect(mac.fake.runEjectionJob())
        #expect(mac.fake.vaults[uid]?.converted.isEmpty == true)
        try await stepWithView(mac, uid)
        #expect(await s.access.phase == .needsOwnKey(.cloudKeyEnded))
        #expect(mac.fake.vaults[uid]?.converted["desktop:\(mac.fake.mac)"] != nil)  // the late report is taken
        try await useOwnKey(mac, uid)
        #expect(await s.access.phase == .ownStorage)
        #expect(mac.fake.conversionReports == 1)
    }

    @Test func aRefusedOwnKeyPausesAgainAndNeverFallsBackToTheCloud() async throws {
        let (mac, uid, _) = try await setUp()
        let s = try await session(mac, uid)
        let requests = mac.fake.credentialRequests
        mac.fake.ownerEjects()
        try await stepWithView(mac, uid)
        mac.fake.runEjectionJob()
        mac.clock.advance(FakeDeviceCloud.keyMinutes * 60 + 1)
        _ = await s.access.step()
        try await useOwnKey(mac, uid)

        // The person deletes that key at the provider.
        mac.policy.accept { [fake = mac.fake] id in fake.providerAccepts(id) }
        try await change(s, "refused")
        await s.syncNow(force: true)
        #expect(await s.access.phase == .needsOwnKey(.refused))
        await s.syncNow(force: true)
        let paused = await s.status
        #expect(paused.state == .needsOwnKey(.refused) && paused.unpublished && paused.sentence.contains("refused the key"))
        // Across a relaunch: still theirs, still waiting for their key, no cloud key asked for.
        await mac.vaults.closeAll()
        let again = mac.makeVaults()
        let reopened = try await again.open(uid)
        #expect(await reopened.access.phase == .needsOwnKey(.refused))
        _ = await reopened.access.step()
        #expect(mac.fake.credentialRequests == requests)
        // Another key from them.
        mac.policy.accept { [fake = mac.fake] id in fake.providerAccepts(id) || id == "004own0000000002" }
        try await again.useOwnKey(uid, keyID: "004own0000000002", secret: SecretBytes(Data(Self.ownSecret.utf8)))
        #expect(await reopened.access.phase == .ownStorage)
        await reopened.syncNow(force: true)
        let after = await reopened.status
        #expect(after.state == .upToDate && !after.unpublished)
        await again.closeAll()
    }
}
