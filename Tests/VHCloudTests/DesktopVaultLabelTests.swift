import Foundation
import Testing
import VHCore
@testable import VHCloud
import VHKeykit
import VHRecovery
@testable import VHVault

/// A Desktop-only vault's name for the portal and the account's other installations: sealed to the account key with
/// vl-keykit (`vh.vault-label.v1`) on creation, on a rename and after a rotation, sent with `PUT /v1/vaults/{uid}/label`
/// to ``FakeDeviceCloud`` (Deployments.cpp's route and checks), and opened with the real vl-keykit where Desktop lists
/// the account's vaults. The cloud never sees the name in the clear.
@Suite(.serialized) struct DesktopVaultLabelTests {
    typealias Mac = DesktopVaultLifecycleTests.Mac

    func setUp() async throws -> (Mac, AccountKey, KeyStatement) {
        let clock = ManualClock(DesktopVaultLifecycleTests.start)
        let fake = FakeDeviceCloud(clock: clock)
        let key = try AccountKey.generate()
        try fake.base.portalCreatesKey(key)
        let statement = try #require(fake.base.current)
        fake.labelMagic = try VaultLabel.seal("x", statement: statement, vaultUid: Data(Uid.random().bytes)).prefix(4)
        fake.provisionAtOnce = true
        let mac = try await Mac(fake: fake, clock: clock, bucket: MemoryBucket())
        try await mac.receive(key)
        return (mac, key, statement)
    }

    func labelPuts(_ mac: Mac, _ uid: String) -> [String] { mac.fake.sent.filter { $0.hasPrefix("PUT") && $0.contains("/v1/vaults/\(uid)/label") } }

    @Test func aNewVaultsNameIsSealedSentAndOpensOnlyWithTheAccountKey() async throws {
        let (mac, key, statement) = try await setUp()
        let session = try await mac.vaults.create(name: "Family photos")
        let uid = session.uid
        let sealed = try #require(mac.fake.vaults[uid]?.label)
        #expect(sealed.count == VaultLabel.sealedSize)
        #expect(labelPuts(mac, uid).count == 1)
        #expect(try mac.vaults.registry.record(uid)?.labelGeneration == statement.generation)
        // The cloud never saw the name: not in any request, in any encoding Desktop uses.
        let name = "Family photos"
        #expect(!mac.fake.sent.contains { $0.contains(name) || $0.contains(Base64URL.encode(Data(name.utf8))) })
        // The account key opens it (real vl-keykit), as the portal and another installation would.
        let names = try await mac.account.openLabels(try await mac.client.vaults())
        #expect(names[uid] == name)
        // Another account's key doesn't.
        let other = try AccountKey.generate()
        #expect(throws: KeykitError.self) { _ = try other.openLabel(sealed, statement: statement, vaultUid: Data(Uid(base32: uid)!.bytes)) }
        _ = key
    }

    @Test func aRenameResealsAndAnOpenSendsNothingWhenCurrent() async throws {
        let (mac, _, _) = try await setUp()
        let uid = try await { () async throws -> String in
            let s = try await mac.vaults.create(name: "Taxes")
            return s.uid
        }()
        let first = try #require(mac.fake.vaults[uid]?.label)
        try await mac.vaults.rename(uid, to: "Taxes 2026")
        let second = try #require(mac.fake.vaults[uid]?.label)
        #expect(second != first && labelPuts(mac, uid).count == 2)
        #expect(try mac.vaults.registry.record(uid)?.name == "Taxes 2026")
        #expect(try await mac.account.openLabels(try await mac.client.vaults())[uid] == "Taxes 2026")
        #expect(!mac.fake.sent.contains { $0.contains("Taxes 2026") })
        // Opened again with the label current: no PUT.
        await mac.vaults.closeAll()
        let again = mac.makeVaults()
        _ = try await again.open(uid)
        await again.closeAll()
        #expect(labelPuts(mac, uid).count == 2)
        // A vault from before labels (no generation recorded) gets its label at the next open.
        var r = try #require(try mac.vaults.registry.record(uid))
        r.labelGeneration = nil
        try mac.vaults.registry.save(r)
        let third = mac.makeVaults()
        _ = try await third.open(uid)
        await third.closeAll()
        #expect(labelPuts(mac, uid).count == 3)
    }

    @Test func otherInstallationsLabelsOpenWhereDesktopListsVaults() async throws {
        let (mac, _, statement) = try await setUp()
        let server = mac.fake.serverVault()
        let otherMac = mac.fake.vault(heldBy: mac.fake.otherMac)
        mac.fake.storeLabel(server, try VaultLabel.seal("NAS backups", statement: statement, vaultUid: Data(Uid(base32: server)!.bytes)))
        mac.fake.storeLabel(otherMac, try VaultLabel.seal("iMac projects", statement: statement,
                                                          vaultUid: Data(Uid(base32: otherMac)!.bytes)))
        let names = try await mac.account.openLabels(try await mac.client.vaults())
        #expect(names[server] == "NAS backups" && names[otherMac] == "iMac projects")
        // A label sealed for one vault doesn't open as another's (the uid is in its authenticated prefix).
        mac.fake.storeLabel(server, try #require(mac.fake.vaults[otherMac]?.label))
        #expect(try await mac.account.openLabels(try await mac.client.vaults())[server] == nil)
    }

    @Test func theCloudsRefusalsOfALabel() async throws {
        let (mac, _, statement) = try await setUp()
        // Another Mac's vault: 409 held_by_desktop, with its name.
        let theirs = mac.fake.vault(heldBy: mac.fake.otherMac)
        let sealed = try VaultLabel.seal("Not mine", statement: statement, vaultUid: Data(Uid(base32: theirs)!.bytes))
        await #expect(throws: DeviceAccessError.heldByAnotherMac(name: "iMac")) {
            do { try await mac.client.putVaultLabel(theirs, sealed: sealed) } catch { throw DeviceAccessError.from(error) }
        }
        #expect(mac.fake.vaults[theirs]?.label == nil)
        // Not a label: 400 invalid_label (size, then structure).
        let mine = mac.fake.vault(heldBy: mac.fake.mac)
        for bad in [Data(count: 188), Data(count: VaultLabel.sealedSize)] {
            await #expect(throws: DeviceAccessError.invalidRequest(reason: "invalid_label")) {
                do { try await mac.client.putVaultLabel(mine, sealed: bad) } catch { throw DeviceAccessError.from(error) }
            }
        }
        // An unknown vault: 404 no_such_vault.
        await #expect(throws: DeviceAccessError.noSuchVault) {
            do { try await mac.client.putVaultLabel(Uid.random().base32, sealed: sealed) } catch { throw DeviceAccessError.from(error) }
        }
    }

    @Test func namesAreCutAsAServerCutsThem() throws {
        #expect(VaultLabel.sealableName("Tax\u{7}es\n2026") == "Taxes2026")
        #expect(VaultLabel.sealableName("\u{1}\u{2}") == "vault")
        let long = String(repeating: "\u{E9}", count: 100)  // 200 bytes of UTF-8
        let cut = VaultLabel.sealableName(long)
        #expect(cut.utf8.count == 128 && cut == String(repeating: "\u{E9}", count: 64))
        let key = try AccountKey.generate()
        let statement = try key.statement(publicID: "00000000-0000-4000-8000-000000000001", generation: 1, previous: nil,
                                          reason: .initial)
        let uid = Data(Uid.random().bytes)
        #expect(try key.openLabel(VaultLabel.seal(cut, statement: statement, vaultUid: uid), statement: statement, vaultUid: uid) == cut)
    }
}
