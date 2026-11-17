import Foundation
import Testing
import VHCore
@testable import VHCloud
import VHKeykit
import VHRecovery
@testable import VHVault

/// Leaving managed storage against a real S3-compatible endpoint that checks every credential and IAM policy (moto on
/// `ssh dev`: `tools/vaultfmt/live-s3.sh`): ``DesktopVaults`` with its real ``S3Store``, ``FakeDeviceCloud`` issuing the
/// "cloud's key" (an IAM key scoped to the bucket), the ejection, and the switch to the "customer's own key" (a second
/// IAM key scoped to the same bucket), checked by a read before anything is written; a wrong secret and a key scoped to
/// another bucket are refused and switch nothing. Opt-in: runs only with VH_LIVE_S3 and the second key.
///
///   VH_LIVE_S3_ENDPOINT, VH_LIVE_S3_REGION, VH_LIVE_S3_EJECT_BUCKET, VH_LIVE_S3_CLOUD_ACCESS_KEY and _SECRET_KEY (the
///   cloud's), VH_LIVE_S3_OWN_ACCESS_KEY and _SECRET_KEY (the customer's), VH_LIVE_S3_ACCESS_KEY and _SECRET_KEY (scoped
///   to LiveS3Tests' bucket: a key for another bucket)
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VH_LIVE_S3_OWN_ACCESS_KEY"] != nil), .serialized)
struct LiveS3EjectionTests {
    let env = ProcessInfo.processInfo.environment

    @Test func theSwitchToTheCustomersOwnKey() async throws {
        let clock = ManualClock(Date())
        let fake = FakeDeviceCloud(clock: clock)
        let bucket = try #require(env["VH_LIVE_S3_EJECT_BUCKET"])
        fake.bucketName = { _ in bucket }
        fake.endpoint = try #require(env["VH_LIVE_S3_ENDPOINT"])
        fake.region = env["VH_LIVE_S3_REGION"] ?? "us-east-1"
        fake.issueAs = (try #require(env["VH_LIVE_S3_CLOUD_ACCESS_KEY"]), Data(try #require(env["VH_LIVE_S3_CLOUD_SECRET_KEY"]).utf8))
        fake.provisionAtOnce = true
        let key = try AccountKey.generate()
        try fake.base.portalCreatesKey(key)
        let mac = try await DesktopVaultLifecycleTests.Mac(fake: fake, clock: clock, bucket: MemoryBucket())
        try await mac.receive(key)
        var sync = DesktopVaultSession.Settings()
        sync.automatic = false
        let vaults = DesktopVaults(client: mac.client, account: mac.account, items: mac.items, container: mac.container,
                                   clock: clock, syncSettings: sync, bucketWait: 30)
        defer { try? FileManager.default.removeItem(at: mac.container) }

        // A vault on the cloud's key, with a file.
        let session = try await vaults.create(name: "Live ejection")
        let uid = session.uid
        let vault = try #require(await session.openedVault())
        let file = try await vault.perform { v throws(VaultError) in
            try v.write(Data("before".utf8), parent: try v.rootUID(), name: "before.txt").entry.uid
        }
        await session.noteChange()
        await session.syncNow(force: true)
        #expect(await session.status.state == .upToDate)

        // Ejected; reported at once; the cloud's key ends.
        fake.ownerEjects()
        await session.access.apply(try await mac.client.storage())
        _ = await session.access.step()
        #expect(fake.vaults[uid]?.converted.isEmpty == false)
        #expect(fake.runEjectionJob())
        clock.advance(FakeDeviceCloud.keyMinutes * 60 + 1)
        _ = await session.access.step()
        #expect(await session.access.phase == .needsOwnKey(.cloudKeyEnded))

        // Refused, nothing switched: a wrong secret, a key scoped to another bucket.
        let own = try #require(env["VH_LIVE_S3_OWN_ACCESS_KEY"])
        let ownSecret = try #require(env["VH_LIVE_S3_OWN_SECRET_KEY"])
        await #expect(throws: DesktopVaultError.ownKey(.keyRefused)) {
            try await vaults.useOwnKey(uid, keyID: own, secret: SecretBytes(Data("not-the-secret-000000000000000000000000".utf8)))
        }
        if let other = env["VH_LIVE_S3_ACCESS_KEY"], let otherSecret = env["VH_LIVE_S3_SECRET_KEY"] {
            await #expect(throws: DesktopVaultError.ownKey(.keyRefused)) {
                try await vaults.useOwnKey(uid, keyID: other, secret: SecretBytes(Data(otherSecret.utf8)))
            }
        }
        #expect(await session.access.phase == .needsOwnKey(.cloudKeyEnded))

        // The customer's own key: checked, switched, and the vault syncs with it.
        try await vaults.useOwnKey(uid, keyID: own, secret: SecretBytes(Data(ownSecret.utf8)))
        #expect(await session.access.phase == .ownStorage)
        let requests = fake.credentialRequests
        let after = try await vault.perform { v throws(VaultError) in
            try v.write(Data("after".utf8), parent: try v.rootUID(), name: "after.txt").entry.uid
        }
        await session.noteChange()
        await session.syncNow(force: true)
        let synced = await session.status
        #expect(synced.state == .upToDate && !synced.unpublished)
        #expect(fake.credentialRequests == requests)

        // A fresh reader with the customer's key alone sees both files.
        let store = S3Store(credentials: StaticS3Credentials(accessKeyID: own, secret: Data(ownSecret.utf8), bucket: bucket,
                                                             endpoint: fake.endpoint, region: fake.region),
                            scratch: mac.container.appending(path: "reader-scratch"))
        let keys = KeychainVaultKeys(store: VaultKeyStore(items: mac.items), uid: uid)
        let (reader, _) = try await Vault.open(uid: Uid(base32: uid)!, store: store, keys: keys,
                                               stateURL: mac.container.appending(path: "reader.state"), nodeID: "live-reader")
        try await reader.perform { v throws(VaultError) in
            #expect(try v.readData(file) == Data("before".utf8))
            #expect(try v.readData(after) == Data("after".utf8))
        }
        await vaults.closeAll()
    }
}
