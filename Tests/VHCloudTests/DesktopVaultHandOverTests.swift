import Foundation
import Testing
import VHCore
@testable import VHCloud
import VHRecovery
@testable import VHVault

/// Finder showing a Desktop-only vault: the app hands the engine to the extension (its state lock goes with the
/// handle) and keeps renewing the bucket key, written to the group the extension reads; then takes it back.
@Suite(.serialized) struct DesktopVaultHandOverTests {
    @Test func theEngineGoesToFinderAndTheKeyKeepsRenewingHere() async throws {
        let (mac, key) = try await DesktopVaultLifecycleTests().setUp()
        try await mac.receive(key)
        mac.fake.provisionAtOnce = true
        let session = try await mac.vaults.create(name: "Photos")
        let uid = session.uid
        #expect(try mac.vaults.registry.record(uid)?.nodeID == mac.fake.mac)  // what the extension opens it as

        await mac.vaults.handOver(uid)
        #expect(await session.openedVault() == nil)
        // The state is free for the extension's engine.
        let other = try await Vault.open(uid: Uid(base32: uid)!, store: mac.bucket, keys: KeychainVaultKeys(store: VaultKeyStore(items: mac.items), uid: uid),
                                   stateURL: mac.vaults.registry.stateURL(uid), nodeID: mac.fake.mac)
        #expect(other.info.anchor == .state)
        // The bucket key is still renewed here, into the store the extension reads.
        mac.clock.advance(13 * 3600)
        await session.access.step()
        #expect(await session.accessPhase == .holding)
        let renewed = try #require(try BucketKeyStore(items: mac.items).load(uid))
        #expect(renewed.expiresAt > mac.clock.now)
        _ = other

        // A refusal the extension signalled: DeviceAccess asks for a new key at once.
        let before = mac.fake.credentialRequests
        mac.vaults.refusals.post(uid: uid, keyID: renewed.keyID)
        await mac.vaults.followRefusals()
        #expect(mac.fake.credentialRequests == before + 1)
    }
}
