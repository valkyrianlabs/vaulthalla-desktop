import Foundation
import Testing
import VHCore
@testable import VHCloud
import VHKeykit
import VHRecovery

/// Desktop-only vaults against ``FakeDeviceCloud`` (the daemon's routes, rules and reasons, in memory): registering a
/// vault with no deployment and the one-writer refusals, the switch, the sealed exchange with a one-time key, renewal
/// at `renew_after` on an injected clock, backing off, expiry, the cloud superseding, pausing and revoking, a server
/// adopting the vault, another Mac, a release, an unlinked Mac, and that the secret appears in nothing but the key's
/// own buffer and its keychain item.
struct DeviceAccessTests {
    struct Setup {
        let fake: FakeDeviceCloud
        let clock: ManualClock
        let client: CloudClient
        let memory: MemoryAccountItemStore
        let store: BucketKeyStore
        let lease: CredentialLease

        func access(_ uid: String, settings: DeviceAccess.Settings = .init()) throws -> DeviceAccess {
            try DeviceAccess(client: client, vaultUid: uid, installationID: fake.mac, store: store, clock: clock, settings: settings)
        }
    }

    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    func linked() async throws -> Setup {
        let clock = ManualClock(Self.start)
        let fake = FakeDeviceCloud(clock: clock)
        let dir = FileManager.default.temporaryDirectory.appending(path: "vh-device-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lease = CredentialLease(forRegistry: dir.appending(path: "nodes.json"), holder: "test")
        try lease.acquire()
        let memory = MemoryAccountItemStore()
        let items = LeasedAccountItems(items: memory, lease: lease)
        let client = try CloudClient(endpoint: "https://api.vaulthalla.test", store: AccountCloudLinkStore(items: items), transport: fake)
        _ = try await client.startLink(name: "MacBook")
        fake.base.claimAnswer = "linked"
        #expect(try await client.claimLink() == .linked)
        return Setup(fake: fake, clock: clock, client: client, memory: memory, store: BucketKeyStore(items: items), lease: lease)
    }

    func refusal(_ work: () async throws -> Void) async -> DeviceAccessError? {
        do { try await work(); return nil } catch { return DeviceAccessError.from(error) }
    }

    // MARK: registering, the switch, the one-writer refusals

    @Test func aMacRegistersAVaultWithNoDeploymentAndIsItsOnlyWriter() async throws {
        let s = try await linked()
        let uid = Uid.random().base32
        let first = try await s.client.registerDesktopVault(uid)
        #expect(first.created && first.vault.replicas.isEmpty && first.vault.desktop?.installationId == s.fake.mac)
        #expect(first.vault.desktop?.name == "MacBook")
        #expect(try await s.client.registerDesktopVault(uid).created == false)  // idempotent for its Mac

        // The switch, as the vault's writer: on waits for its bucket, which then is ready.
        #expect(try await s.client.setManagedStorage(uid, enabled: true).state == "waiting")
        s.fake.provision(uid)
        #expect(try await s.client.storage().vault(uid)?.state == "ready")
        #expect(try await s.client.setManagedStorage(uid, enabled: false).state == "off")

        // Another Mac's vault, a server's, nobody's, none at all: each refusal typed, with the daemon's reason.
        let theirs = s.fake.vault(heldBy: s.fake.otherMac)
        #expect(await refusal { _ = try await s.client.registerDesktopVault(theirs) } == .heldByAnotherMac(name: "iMac"))
        let server = s.fake.serverVault()
        #expect(await refusal { _ = try await s.client.registerDesktopVault(server) } == .heldByServer(name: "nas"))
        #expect(await refusal { _ = try await s.client.requestStorageCredential(server, publicKey: Data(count: 32)) }
                == .heldByServer(name: "nas"))
        // A Mac that doesn't hold a vault changes its switch only.
        #expect(await refusal {
            _ = try await s.client.signedData("PUT", "/v1/storage/vaults/\(theirs)", body: Data(#"{"content_retention_days":5}"#.utf8))
        } == .switchOnly)
        #expect(await refusal { try await s.client.releaseDesktopVault(theirs) } == .heldByAnotherMac(name: "iMac"))
        try await s.client.releaseDesktopVault(uid)
        #expect(await refusal { _ = try await s.client.registerDesktopVault(uid) } == .unplaced)  // nobody takes it back by declaring it
        #expect(await refusal { _ = try await s.client.requestStorageCredential(uid, publicKey: Data(count: 32)) } == .unplaced)
        #expect(await refusal { _ = try await s.client.requestStorageCredential(Uid.random().base32, publicKey: Data(count: 32)) }
                == .noSuchVault)
        #expect(await refusal { try await s.client.acknowledgeStorageCredential("005nope") } == .noSuchKey)
        // Inputs Desktop never sends: a malformed uid, a key id it can't put in a path.
        #expect(await refusal { _ = try await s.client.registerDesktopVault("NOT-A-UID") } == .noSuchVault)
        #expect(await refusal { try await s.client.acknowledgeStorageCredential("a/b") } == .malformed("a key id Desktop can't put in a path"))
        // The messages a person reads.
        #expect(DeviceAccessError.heldByAnotherMac(name: "iMac").message.contains("\u{201C}iMac\u{201D}"))
        #expect(DeviceAccessError.unplaced.message.contains("portal"))
    }

    // MARK: the exchange and the keychain

    @Test func theExchangeOpensTheSealedSecretAcknowledgesAndKeepsItInTheKeychain() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        let next = await access.step()
        let issued = try #require(s.fake.activeKey(uid))
        #expect(s.fake.credentialRequests == 1 && issued.state == "active")
        // The secret the cloud sealed is the one this Mac holds, read only into a buffer for the call.
        let held = await access.withCredentials { c in (c.accessKeyID, Data(c.secret), c.bucket, c.region, c.access) }
        #expect(held?.0 == issued.id && held?.1 == issued.secret && held?.2 == "vhc-\(uid)" && held?.3 == "us-west-004" && held?.4 == "full")
        let status = await access.status
        #expect(status.phase == .holding && status.expiresAt == issued.expiresAt && status.renewAfter == issued.renewAfter)
        // 24 hours, renewed from 12 hours before the end (the daemon's defaults).
        #expect(issued.expiresAt.timeIntervalSince(Self.start) == 24 * 3600 && issued.renewAfter.timeIntervalSince(Self.start) == 12 * 3600)
        #expect(next == Self.start + 30 * 60)  // the next read of the cloud's view comes first
        // The keychain: what the key is, and its secret's bytes in an item of their own.
        #expect(s.memory.names.sorted() == ["link", BucketKeyStore.item(uid), "\(BucketKeyStore.item(uid)).\(issued.id)"].sorted())
        #expect(try s.memory.read("\(BucketKeyStore.item(uid)).\(issued.id)") == issued.secret)
        let metadata = try #require(try s.memory.read(BucketKeyStore.item(uid)))
        #expect(metadata.range(of: issued.secret) == nil)
        // A relaunch finds it and asks for nothing until it's due.
        let again = try s.access(uid)
        #expect(await again.step() == Self.start + 30 * 60)
        #expect(s.fake.credentialRequests == 1)
        #expect(await again.withCredentials { Data($0.secret) } == issued.secret)
    }

    @Test func aSecretSealedForAnotherBindingOrAKeyWithoutExpiryIsNeverUsed() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        s.fake.sealForAnotherInstallation = true
        _ = await access.step()
        guard case .retrying(.malformed, 1, _) = await access.phase else { Issue.record("\(await access.phase)"); return }
        #expect(s.fake.keys(uid).allSatisfy { $0.state == "issued" })  // never acknowledged
        #expect(await access.withCredentials { _ in true } == nil)
        s.fake.sealForAnotherInstallation = false
        s.fake.omitExpiry = true
        s.clock.advance(31)
        _ = await access.step()
        guard case .retrying(.malformed, 2, _) = await access.phase else { Issue.record("\(await access.phase)"); return }
        #expect(s.fake.activeKey(uid) == nil)
        s.fake.omitExpiry = false
        s.clock.advance(61)
        _ = await access.step()
        #expect(await access.phase == .holding)
        #expect(s.fake.activeKey(uid) != nil)
        // The unacknowledged ones were revoked when the next was asked for.
        #expect(s.fake.keys(uid).filter { $0.revokeReason == "replaced_unacknowledged" }.count == 2)
    }

    // MARK: renewal timing, backoff, expiry

    @Test func renewsAtRenewAfterAndTheAcknowledgementRetiresTheOldKey() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        _ = await access.step()
        let first = try #require(s.fake.activeKey(uid))
        // Before renew_after: the view is read (every 30 minutes) but nothing is asked for.
        s.clock.set(first.renewAfter - 60)
        #expect(await access.step() == first.renewAfter)
        #expect(s.fake.credentialRequests == 1)
        // At renew_after: a new key; its acknowledgement revokes the old one, whose secret this Mac forgets.
        s.clock.set(first.renewAfter)
        let next = await access.step()
        let second = try #require(s.fake.activeKey(uid))
        #expect(second.id != first.id && s.fake.credentialRequests == 2)
        #expect(s.fake.keys(uid).first { $0.id == first.id }?.revokeReason == "replaced")
        #expect(await access.withCredentials { $0.accessKeyID } == second.id)
        #expect(!s.memory.names.contains("\(BucketKeyStore.item(uid)).\(first.id)"))
        #expect(next == s.clock.now + 30 * 60)  // the next view read comes before the new renew_after
        // The loop itself, on the injected clock: it renews again exactly at the new renew_after.
        let runner = Task { await access.run() }
        while s.fake.credentialRequests < 3 { await Task.yield() }
        runner.cancel()
        _ = await runner.value
        let third = s.fake.keys(uid).sorted { $0.issuedAt < $1.issuedAt }[2]
        #expect(third.issuedAt == Date(timeIntervalSince1970: second.renewAfter.timeIntervalSince1970.rounded(.down)))
    }

    @Test func failuresBackOffAndASuccessResetsThem() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        var waits: [TimeInterval] = []
        for _ in 0 ..< 8 {
            s.fake.failNext = (503, "unavailable", nil, nil)
            let next = try #require(await access.step())
            waits.append(next.timeIntervalSince(s.clock.now))
            s.clock.set(next)
        }
        #expect(waits == [30, 60, 120, 240, 480, 960, 1800, 1800])  // doubling from 30 s, capped at 30 minutes
        // 429 waits as long as the cloud says when that is longer.
        s.fake.failNext = (429, "rate_limited", nil, "3600")
        let limited = try #require(await access.step())
        #expect(limited.timeIntervalSince(s.clock.now) == 3600)
        guard case .retrying(.rateLimited(3600), _, _) = await access.phase else { Issue.record("\(await access.phase)"); return }
        s.clock.set(limited)
        _ = await access.step()
        #expect(await access.phase == .holding)
        // A later failure starts from the beginning again.
        s.clock.set(try #require(s.fake.activeKey(uid)).renewAfter)
        s.fake.failNext = (503, "unavailable", nil, nil)
        #expect(try #require(await access.step()).timeIntervalSince(s.clock.now) == 30)
    }

    @Test func aKeyIsForgottenAtItsExpiryOfflineAndRenewedLateOnceTheCloudAnswers() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        _ = await access.step()
        let first = try #require(s.fake.activeKey(uid))
        // Offline from renew_after on: every attempt fails, and the next wake never passes the expiry.
        s.clock.set(first.renewAfter)
        while s.clock.now < first.expiresAt {
            s.fake.failNext = (503, "unavailable", nil, nil)
            let next = try #require(await access.step())
            #expect(next <= first.expiresAt)
            s.clock.set(next)
        }
        s.fake.failNext = (503, "unavailable", nil, nil)
        _ = await access.step()
        s.fake.failNext = nil
        #expect(await access.withCredentials { _ in true } == nil)
        #expect(!s.memory.names.contains { $0.hasPrefix(BucketKeyStore.item(uid)) })
        // The cloud expired it too; back online, its view says `expired` and a new key comes at once.
        s.fake.expireDue()
        #expect(try await s.client.storage().vault(uid)?.credential?.state == "expired")
        s.clock.advance(30 * 60)
        _ = await access.step()
        let late = try #require(s.fake.activeKey(uid))
        #expect(late.id != first.id)
        #expect(await access.phase == .holding)
    }

    /// A clock whose sleep lasts until the test moves it (or the sleep is cancelled).
    final class HeldClock: DeviceAccessClock, @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date) { current = start }
        var now: Date { lock.withLock { current } }
        func sleep(until: Date) async throws {
            while now < until { try await Task.sleep(for: .milliseconds(2)) }
        }
    }

    /// Found by the drill (tools/vaultfmt/desktop-drill.sh): the cloud expired the Mac's key and deleted it at the
    /// provider; the sync engine's 403 reported it, but the loop slept on until `renew_after` (hours, in production)
    /// with a dead key. The refusal now wakes the loop: the view is read and a new key asked for at once.
    @Test func aKeyTheProviderRefusesIsReplacedWithoutWaitingForRenewAfter() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let held = HeldClock(Self.start)
        let access = try DeviceAccess(client: s.client, vaultUid: uid, installationID: s.fake.mac, store: s.store, clock: held)
        let runner = Task { await access.run() }
        defer { runner.cancel() }
        let first = try await #require(eventuallyKey(s, uid))
        // The cloud expires it (its clock ahead of this Mac's) and deletes it at the provider; this Mac's clock stays.
        s.fake.clock.set(first.expiresAt)
        s.fake.expireDue()
        s.fake.clock.set(Self.start)
        await access.providerRefusedKey()
        let end = Date() + 5
        while Date() < end, s.fake.activeKey(uid).map({ $0.id == first.id }) ?? true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(s.fake.activeKey(uid).map { $0.id != first.id } == true)
        #expect(held.now == Self.start)  // nothing waited for renew_after
        runner.cancel()
        _ = await runner.value
    }

    func eventuallyKey(_ s: Setup, _ uid: String) async throws -> FakeDeviceCloud.Key? {
        let end = Date() + 5
        while Date() < end {
            if let k = s.fake.activeKey(uid) { return k }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func theCloudsExpiredViewIsRenewNow() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        _ = await access.step()
        let first = try #require(s.fake.activeKey(uid))
        // The cloud's clock is ahead of this Mac's: its view says the key expired before this Mac thinks.
        s.fake.clock.set(first.expiresAt)
        s.fake.expireDue()
        s.fake.clock.set(Self.start + 3600)
        await access.apply(try await s.client.storage())
        #expect(await access.withCredentials { _ in true } == nil)
        _ = await access.step()
        #expect(s.fake.activeKey(uid).map { $0.id != first.id } == true)
    }

    // MARK: entitlement states, revocation, moves, another Mac, release, unlinking

    @Test func restrictedSupersedesTheFullKeyAndTheRenewalIsReadAndDeleteOnly() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        _ = await access.step()
        let full = try #require(s.fake.activeKey(uid))
        s.fake.entitle("restricted")
        await access.apply(try await s.client.storage())
        // Superseded: no longer the key in force here, though the cloud lets it work for its grace period.
        #expect(await access.withCredentials { _ in true } == nil)
        #expect(!s.memory.names.contains("\(BucketKeyStore.item(uid)).\(full.id)"))
        _ = await access.step()
        #expect(await access.withCredentials { $0.access } == "read_delete")
        #expect(DeviceAccessWording.status(await access.status, now: s.clock.now).text.contains("read and delete only"))
        // Over the quota while active works the same way, and back under it the renewal is full again.
        s.fake.entitle("active", overQuota: true)
        s.clock.advance(30 * 60)
        _ = await access.step()
        #expect(await access.withCredentials { $0.access } == "read_delete")
        s.fake.entitle("active")
        s.clock.advance(30 * 60)
        _ = await access.step()
        #expect(await access.withCredentials { $0.access } == "full")
    }

    @Test func suspendedAndEndedPauseWithNoKeyAndAPaidPlanResumes() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        _ = await access.step()
        for state in ["suspended", "ended"] {
            s.fake.entitle(state)
            s.clock.advance(60 * 60)
            let next = await access.step()
            #expect(await access.phase == .paused(entitlement: state))
            #expect(next == s.clock.now + 3600)
            #expect(await access.withCredentials { _ in true } == nil)
            #expect(!s.memory.names.contains { $0.hasPrefix(BucketKeyStore.item(uid)) })
        }
        let requests = s.fake.credentialRequests
        s.clock.advance(1800)
        _ = await access.step()
        #expect(s.fake.credentialRequests == requests)  // nothing asked for while paused
        // A 402 on the request itself (the plan changed between the view and the request) pauses too.
        // The keys went at the suspension (ended found none live): the newest one's reason stays.
        #expect(try await s.client.storage().vault(uid)?.credential?.revokedReason == "suspended")
        s.fake.entitle("active")
        s.clock.advance(1800)
        _ = await access.step()
        #expect(await access.phase == .holding)  // renewed by itself: the plan's revocation isn't a person's
        #expect(s.fake.credentialRequests == requests + 1)
        s.clock.set(try #require(s.fake.activeKey(uid)).renewAfter)
        await access.apply(try await s.client.storage())
        s.fake.storageAccess = "none"  // decide() at the request, before enforce ran
        _ = await access.step()
        #expect(await access.phase == .paused(entitlement: nil))
    }

    @Test func aKeyTheAccountHolderRevokedStopsTheLoopAcrossRelaunchesUntilAskedAgain() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        _ = await access.step()
        s.fake.ownerRevokesKeys(uid)
        s.clock.advance(30 * 60)
        #expect(await access.step() == nil)
        #expect(await access.phase == .stopped(.keyRevoked(reason: "account_holder")))
        let view = try await s.client.storage().vault(uid)?.credential
        #expect(view?.state == "none" && view?.revokedReason == "account_holder" && view?.revokedAt != nil && view?.keyId == nil)
        // The view alone doesn't restart it.
        await access.apply(try await s.client.storage())
        #expect(await access.phase == .stopped(.keyRevoked(reason: "account_holder")))
        #expect(await access.withCredentials { _ in true } == nil)
        // Only the tombstone remains: no secret.
        #expect(s.memory.names.filter { $0.hasPrefix("storage-key") } == [BucketKeyStore.item(uid)])
        let relaunched = try s.access(uid)
        #expect(await relaunched.step() == nil)
        #expect(s.fake.credentialRequests == 1)
        await relaunched.resume()
        _ = await relaunched.step()
        #expect(await relaunched.phase == .holding)
        #expect(s.fake.credentialRequests == 2)
    }

    @Test func aServerAdoptingTheVaultStopsItSaysWhereAndKeepsLocalFiles() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        _ = await access.step()
        s.fake.serverAdopts(uid)
        let view = try await s.client.storage()
        #expect(view.vault(uid)?.movedTo?.name == "nas" && view.vault(uid)?.credential?.state == "none")
        await access.apply(view)
        #expect(await access.phase == .stopped(.moved(deploymentID: s.fake.deployment, name: "nas")))
        #expect(await access.withCredentials { _ in true } == nil)
        #expect(!s.memory.names.contains { $0.hasPrefix("storage-key") })
        #expect(DeviceAccessWording.stop(.moved(deploymentID: "d", name: "nas")).text.contains("keeps its local copy"))
        // And the cloud refuses this Mac's request from now on.
        #expect(await refusal { _ = try await s.client.requestStorageCredential(uid, publicKey: Data(count: 32)) }
                == .heldByServer(name: "nas"))
        #expect(view.vault(uid)?.released == CloudStorage.Released(reason: "moved", to: .init(kind: "server", installationId: nil,
                                                                  deploymentId: s.fake.deployment, name: "nas"), at: Int64(Self.start.timeIntervalSince1970)))
    }

    @Test func anotherMacOrNobodyHoldingItStopsIt() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        _ = await access.step()
        s.fake.ownerPlaces(uid, on: s.fake.otherMac)
        s.clock.advance(30 * 60)
        _ = await access.step()
        #expect(await access.phase == .stopped(.reassigned(to: "iMac")))
        #expect(s.fake.keys(uid).first?.revokeReason == "desktop_reassigned")
        #expect(DeviceAccessWording.holder(try #require(try await s.client.storage().vault(uid)), thisMac: s.fake.mac, server: nil).text
                == "The account holder gave it to the Mac \u{201C}iMac\u{201D}. This Mac keeps its local copy.")

        let gone = s.fake.vault(heldBy: s.fake.mac)
        let second = try s.access(gone)
        _ = await second.step()
        s.fake.ownerTakesOff(gone)
        s.clock.advance(30 * 60)
        _ = await second.step()
        #expect(await second.phase == .stopped(.takenOff))
        // The account holder places it here again: the view ends the stop, and the old key's reason doesn't stop it.
        s.fake.ownerPlacesHere(gone)
        let back = try await s.client.storage()
        #expect(back.vault(gone)?.released == nil && back.vault(gone)?.credential?.revokedReason == "hold_removed")
        await second.apply(back)
        _ = await second.step()
        #expect(await second.phase == .holding)

        let server = s.fake.serverVault()
        let third = try s.access(server)
        _ = await third.step()
        #expect(await third.phase == .stopped(.notHeld(.heldByServer(name: nil))))
        #expect(s.fake.credentialRequests == 3)
    }

    @Test func releasingTheVaultRevokesTheKeyAndLeavesItUnplaced() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        _ = await access.step()
        try await access.release()
        #expect(await access.phase == .stopped(.released))
        #expect(s.fake.keys(uid).allSatisfy { $0.state == "revoked" && $0.revokeReason == "desktop_desktop" })
        #expect(!s.memory.names.contains { $0.hasPrefix("storage-key") })
        #expect(try await s.client.storage().vault(uid)?.desktop == nil)
        // Releasing a vault this Mac doesn't hold is refused with its reason.
        let theirs = s.fake.vault(heldBy: s.fake.otherMac)
        await #expect(throws: DeviceAccessError.heldByAnotherMac(name: "iMac")) { try await s.access(theirs).release() }
    }

    @Test func anUnlinkedMacStops() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        _ = await access.step()
        s.fake.installationRevoked = true
        s.clock.advance(30 * 60)
        #expect(await access.step() == nil)
        #expect(await access.phase == .stopped(.unlinked))
        #expect(!s.memory.names.contains { $0.hasPrefix("storage-key") })
    }

    @Test func waitingRefusalsAreCheckedAgainLater() async throws {
        let s = try await linked()
        let cases: [(prepare: (FakeDeviceCloud, String) -> Void, want: DeviceAccessError)] = [
            ({ f, u in f.lock.withLock { f.vaults[u]!.bucketState = "waiting"; f.vaults[u]!.waitingReason = nil } }, .bucketNotReady),
            ({ f, u in f.lock.withLock { f.vaults[u]!.bucketState = "waiting"; f.vaults[u]!.waitingReason = "account_key_unconfirmed" } },
             .accountKeyUnconfirmed),
            ({ f, u in f.lock.withLock { f.vaults[u]!.bucketState = "off" } }, .bucketOff),
            ({ f, _ in f.ejection = "converting" }, .ejecting),
        ]
        for c in cases {
            s.fake.ejection = nil
            let uid = s.fake.vault(heldBy: s.fake.mac)
            c.prepare(s.fake, uid)
            let access = try s.access(uid)
            let next = await access.step()
            #expect(await access.phase == .waiting(c.want))
            // A bucket still being provisioned is checked again soon (below); the other reasons every 15 minutes.
            #expect(next == s.clock.now + (c.want == .bucketNotReady ? 10 : 15 * 60))
        }
        #expect(s.fake.credentialRequests == 0)
        // The same reasons on the request itself (the view was older than the cloud's state).
        s.fake.ejection = nil
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        s.fake.offlineCopy = false
        _ = await access.step()
        #expect(await access.phase == .waiting(.accountKeyUnconfirmed))
        s.fake.offlineCopy = true
        s.clock.advance(15 * 60)
        _ = await access.step()
        #expect(await access.phase == .holding)
    }

    /// Found by the drill (tools/vaultfmt/desktop-drill.sh): a new vault's bucket is still being provisioned when its
    /// storage is switched on, and the creation waits for its key; checked only every 15 minutes, the creation gave up.
    @Test func aBucketBeingProvisionedIsCheckedSoonThenLessOften() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        s.fake.lock.withLock { s.fake.vaults[uid]!.bucketState = "waiting"; s.fake.vaults[uid]!.waitingReason = nil }
        let access = try s.access(uid)
        var waits: [TimeInterval] = []
        for _ in 0 ..< 9 {
            let next = try #require(await access.step())
            waits.append(next.timeIntervalSince(s.clock.now))
            s.clock.set(next)
        }
        #expect(waits == [10, 20, 40, 80, 160, 320, 640, 900, 900])
        #expect(s.fake.credentialRequests == 0)
        // Ready: the key at once, and the next provisioning wait starts short again.
        s.fake.lock.withLock { s.fake.vaults[uid]!.bucketState = "ready" }
        s.clock.advance(900)
        _ = await access.step()
        #expect(await access.phase == .holding && s.fake.credentialRequests == 1)
    }

    // MARK: the secret stays out of everything else

    @Test func theSecretNeverAppearsInLogsErrorsOrRequests() async throws {
        let s = try await linked()
        let uid = s.fake.vault(heldBy: s.fake.mac)
        let access = try s.access(uid)
        var texts: [String] = []
        _ = await access.step()
        let key = try #require(s.fake.activeKey(uid))
        let secret = String(decoding: key.secret, as: UTF8.self)
        texts.append(String(describing: await access.status))
        texts.append(String(describing: try #require(try s.store.load(uid))))
        texts.append(String(describing: await access.phase))
        // Every refusal and failure on the way, and the messages a person reads.
        for (status, code, reason) in [(409, "conflict", "held_by_desktop"), (402, "payment_required", nil), (503, "unavailable", nil),
                                       (409, "conflict", "key_revoked"), (429, "rate_limited", nil)] {
            s.fake.failNext = (status, code, reason, nil)
            let e = await refusal { _ = try await s.client.requestStorageCredential(uid, publicKey: Data(count: 32)) }
            texts += [String(describing: e as Any), e?.message ?? "", e?.name ?? ""]
        }
        texts += DeviceAccessWording.status(await access.status, now: s.clock.now).text.split(separator: "\n").map(String.init)
        // What this Mac sent: its one-time public keys, key ids, never the secret.
        texts += s.fake.sent
        texts.append(String(decoding: try #require(try s.memory.read(BucketKeyStore.item(uid))), as: UTF8.self))
        for t in texts { #expect(!t.contains(secret), "\(t)") }
        #expect(!s.fake.sent.joined().contains(Base64URL.encode(key.secret)))
        #expect("\(try #require(try s.store.load(uid)).secret)".contains("redacted"))
    }

    // MARK: the error envelope and the wording

    @Test func theErrorEnvelopesReasonIsKept() throws {
        let body = Data(#"{"error":{"code":"conflict","message":"the Mac \"iMac\" holds this vault; for now one Mac writes to a vault","reason":"held_by_desktop"}}"#.utf8)
        // Without details the name isn't guessed from the message.
        #expect(DeviceAccessError.from(CloudError.from(status: 409, body: body, retryAfter: nil)) == .heldByAnotherMac(name: nil))
        let detailed = Data(#"{"error":{"code":"conflict","message":"m","reason":"held_by_desktop","details":{"holder":"desktop","installation_id":"x","name":"iMac"}}}"#.utf8)
        let e = CloudError.from(status: 409, body: detailed, retryAfter: nil)
        #expect(e == .declined(status: 409, code: "conflict", reason: "held_by_desktop", message: "m",
                               details: ["holder": "desktop", "installation_id": "x", "name": "iMac"]))
        #expect(DeviceAccessError.from(e) == .heldByAnotherMac(name: "iMac"))
        // Details that aren't all strings are dropped, never the whole answer.
        let odd = Data(#"{"error":{"code":"conflict","message":"m","reason":"unplaced","details":{"n":3}}}"#.utf8)
        #expect(CloudError.from(status: 409, body: odd, retryAfter: nil) == .declined(status: 409, code: "conflict", reason: "unplaced",
                                                                                         message: "m", details: [:]))
        // 401 and 429 keep their cases whatever their reason (429's Retry-After matters).
        #expect(CloudError.from(status: 401, body: Data(#"{"error":{"code":"unauthenticated","message":"m","reason":"request_not_verified"}}"#.utf8),
                                retryAfter: nil) == .unauthenticated("m"))
        #expect(CloudError.from(status: 429, body: Data(#"{"error":{"code":"rate_limited","message":"m","reason":"rate_limited"}}"#.utf8),
                                retryAfter: "60") == .rateLimited(retryAfter: 60, message: "m"))
        // Without a reason the status's meaning stays (and every existing caller sees what it saw before).
        #expect(CloudError.from(status: 409, body: Data(#"{"error":{"code":"conflict","message":"m"}}"#.utf8), retryAfter: nil) == .conflict("m"))
        #expect(CloudError.from(status: 402, body: Data(#"{"error":{"code":"payment_required","message":"m"}}"#.utf8), retryAfter: nil)
                == .paymentRequired("m"))
        for (reason, want) in [("held_by_server", DeviceAccessError.heldByServer(name: nil)), ("unplaced", .unplaced),
                               ("no_such_vault", .noSuchVault), ("no_such_key", .noSuchKey), ("bucket_not_ready", .bucketNotReady),
                               ("bucket_off", .bucketOff), ("bucket_deleting", .bucketDeleting), ("ejecting", .ejecting),
                               ("account_key_unconfirmed", .accountKeyUnconfirmed), ("key_superseded", .keyNotIssued(state: "superseded")),
                               ("ejected", .ejected), ("switch_only", .switchOnly), ("portal_only", .wrongCaller(reason: "portal_only")),
                               ("provider_unavailable", .providerUnavailable(reason: "provider_unavailable")),
                               ("provider_key_id_invalid", .providerUnavailable(reason: "provider_key_id_invalid")),
                               ("managed_bucket", .other(status: 409, reason: "managed_bucket", message: "m"))] {
            #expect(DeviceAccessError.from(CloudError.declined(status: 409, code: "conflict", reason: reason, message: "m", details: [:])) == want)
        }
        #expect(DeviceAccessError.from(CloudError.declined(status: 402, code: "payment_required", reason: "payment_required",
                                                           message: "m", details: ["cause": "suspended"])) == .paymentRequired(cause: "suspended"))
        #expect(DeviceAccessError.paymentRequired(cause: "suspended").message.contains("paused"))
        #expect(DeviceAccessError.from(CloudError.declined(status: 403, code: "forbidden", reason: "step_up_required", message: "m",
                                                           details: ["action": "storage.eject"])) == .stepUpRequired(action: "storage.eject"))
        #expect(DeviceAccessError.from(CloudError.declined(status: 400, code: "invalid_argument", reason: "invalid_public_key",
                                                           message: "m", details: [:])) == .invalidRequest(reason: "invalid_public_key"))
        // A 404 without a reason is a route the daemon doesn't serve, not a vault it lacks.
        #expect(DeviceAccessError.from(CloudError.notFound("no route")) == .other(status: 404, reason: nil, message: "no route"))
        #expect(DeviceAccessError.from(CloudError.unauthenticated("x")) == .unlinked)
        #expect(DeviceAccessError.from(CloudError.rateLimited(retryAfter: 9, message: "x")) == .rateLimited(retryAfter: 9))
    }

    @Test func wording() {
        let now = Self.start
        let s = Int64(now.timeIntervalSince1970)
        typealias K = CloudStorage.KeyView
        #expect(DeviceAccessWording.key(nil, now: now, mine: true).text == "This Mac has no storage key")
        #expect(DeviceAccessWording.key(K(state: "issued"), now: now, mine: false).text == "The Mac holding it is getting a storage key")
        let active = DeviceAccessWording.key(K(state: "active", access: "full", expiresAt: s + 86400, renewAfter: s + 43200), now: now, mine: true)
        #expect(active.text.hasPrefix("Storage key valid until tomorrow") && active.text.hasSuffix("renews within 12 hours") && active.tone == .ok)
        let due = DeviceAccessWording.key(K(state: "active", access: "read_delete", expiresAt: s + 600, renewAfter: s - 1), now: now, mine: true)
        #expect(due.text.contains("read and delete only") && due.text.hasSuffix("renewal due") && due.tone == .warn)
        #expect(DeviceAccessWording.key(K(state: "expired", expiresAt: s - 60), now: now, mine: true).text.contains("gets a new one when online"))
        #expect(DeviceAccessWording.key(K(state: "superseded"), now: now, mine: true).tone == .warn)
        #expect(DeviceAccessWording.stop(.keyRevoked(reason: "account_holder")).text.hasPrefix("The account holder revoked"))
        #expect(DeviceAccessWording.key(K(state: "none", revokedReason: "suspended", revokedAt: s), now: now, mine: true).text
                == "This Mac has no storage key: storage is paused until payment is updated")
        #expect(DeviceAccessWording.key(K(state: "none", revokedReason: "account_holder"), now: now, mine: true).tone == .danger)
        #expect(DeviceAccessWording.stop(.notHeld(.unplaced)).text == DeviceAccessError.unplaced.message)
        #expect(DeviceAccessWording.status(.init(phase: .paused(entitlement: "suspended")), now: now).text.contains("Storage paused"))
        #expect(DeviceAccessWording.status(.init(phase: .paused(entitlement: "ended")), now: now).text.contains("plan ended"))
        // Nothing says files are stored, or that Vaulthalla Cloud is available.
        let all = [active.text, due.text, DeviceAccessWording.stop(.released).text]
        for t in all { #expect(!t.lowercased().contains("backed up") && !t.lowercased().contains("available")) }
    }
}

extension DeviceAccess.Status {
    init(phase: DeviceAccess.Phase) { self.init(phase: phase, access: nil, expiresAt: nil, renewAfter: nil, nextCheck: nil) }
}

/// What a key the cloud shows as gone means, by `revoked_reason` (managed-storage.md "As built" 27's list).
struct RevocationRuleTests {
    @Test func eachReasonsRule() {
        typealias A = DeviceAccess.AfterRevocation
        let table: [(String?, Bool, A)] = [
            ("account_holder", true, .stopRevoked("account_holder")), ("account_holder", false, .stopRevoked("account_holder")),
            ("other", true, .stopRevoked("other")), ("something_new", true, .stopRevoked("something_new")),
            ("suspended", true, .renew), ("ended", true, .renew), ("no_plan", true, .renew), ("restricted", true, .renew),
            ("over_quota", true, .renew), ("replaced", true, .renew), ("not_acknowledged", true, .renew),
            ("not_delivered", true, .renew), ("access_changed", true, .renew), ("hold_removed", true, .renew),
            ("hold_reassigned", true, .renew), ("released", true, .renew), ("moved", true, .renew),
            ("installation_revoked", true, .unlinked), ("ejection", true, .ejecting),
            (nil, true, .stopRevoked("account_holder")), (nil, false, .renew),
        ]
        for (reason, had, want) in table { #expect(DeviceAccess.afterRevocation(reason, hadKey: had) == want, "\(reason ?? "nil")") }
        // Which stops end by themselves once this Mac holds the vault again.
        #expect(!DeviceAccess.endsWhenHeldAgain(.keyRevoked(reason: "account_holder")) && !DeviceAccess.endsWhenHeldAgain(.unlinked))
        #expect(DeviceAccess.endsWhenHeldAgain(.takenOff) && DeviceAccess.endsWhenHeldAgain(.reassigned(to: nil))
                && DeviceAccess.endsWhenHeldAgain(.released))
    }
}
