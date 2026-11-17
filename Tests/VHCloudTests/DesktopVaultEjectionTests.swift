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
