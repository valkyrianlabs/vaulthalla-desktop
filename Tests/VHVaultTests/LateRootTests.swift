import Foundation
import Testing
import VHCore
import VHRecovery
@testable import VHVaultEngine

/// vl-vaultfmt 0.4.0 through VHVault, on the in-memory bucket ordered as Backblaze orders versions (by upload start): a
/// manifest root PUT whose reply was lost (outcome unknown) and that completes later lands below roots written since.
/// It is adopted or removed, never an `order_violation`, and nothing local is lost. A second Mac can't join.
@Suite struct LateRootTests {
    /// A vault at epoch 1 with one file, and a change waiting.
    func pending(_ f: Fixture) throws -> (Vault, String) {
        let v = try f.created()
        let root = try v.rootUID()
        let file = try v.write(Data("one".utf8), parent: root, name: "a.txt").entry.uid
        #expect(try v.publish().epoch == 1)
        _ = try v.write(Data("two".utf8), uid: file)
        return (v, file)
    }

    /// The publish is "outcome unknown" (603) as vl-vaultfmt 0.4.1 reports it through its C API: `Vault` maps nothing.
    func loseTheRootPut(_ f: Fixture, _ v: Vault) {
        f.bucket.loseNextPut(keyPrefix: ".vaulthalla/root")
        #expect { try v.publish() } throws: { ($0 as? VaultError)?.status == VaultStatus.storeOutcomeUnknown }
    }

    func expectHealthy(_ f: Fixture, _ v: Vault, file: String, content: String) throws {
        _ = try v.refresh()
        let s = try v.status()
        #expect(s.refusedReason == nil && !s.updateNeeded)
        #expect(try v.readData(file) == Data(content.utf8))
        // A fresh reader of the bucket (this Mac with its state gone) sees the same.
        let fresh = try f.open(state: f.directory.appending(path: "fresh-\(UUID().uuidString)")).vault
        #expect(try fresh.readData(file) == Data(content.utf8))
    }

    @Test func aLostRootThatLandsAfterTheRetryIsRemovedNotRefused() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let (v, file) = try pending(f)
        loseTheRootPut(f, v)
        let retry = try v.publish()
        #expect(retry.published)
        f.bucket.landLost()  // the lost attempt completes now, below the retry (its upload started first)
        try expectHealthy(f, v, file: file, content: "two")
        _ = try v.write(Data("three".utf8), uid: file)
        #expect(try v.publish().published)
        try expectHealthy(f, v, file: file, content: "three")
    }

    @Test func aLostRootThatLandsBeforeTheRetryIsAdopted() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let (v, file) = try pending(f)
        loseTheRootPut(f, v)
        f.bucket.landLost()
        _ = try v.publish()
        #expect(try !v.status().unpublished)
        try expectHealthy(f, v, file: file, content: "two")
    }

    @Test func aLostRootLandingAcrossARestartLosesNothing() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        var file = ""
        do {
            let (v, uid) = try pending(f)
            file = uid
            loseTheRootPut(f, v)
        }  // the app quits with the attempt in flight
        let (again, _) = try f.open()
        #expect(try again.readData(file) == Data("two".utf8))
        _ = try again.publish()
        f.bucket.landLost()
        try expectHealthy(f, again, file: file, content: "two")
    }

    @Test func aSecondMacCantJoinAVersionLogVault() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let v = try f.created()
        _ = try v.mkdir(parent: try v.rootUID(), name: "A")
        _ = try v.publish()
        let other = try f.open(state: f.directory.appending(path: "other"), node: "mac-b").vault
        #expect { try other.join() } throws: { ($0 as? VaultError)?.status == VaultStatus.writersRefused }
        #expect(try !other.status().unpublished)  // nothing recorded
        #expect(VaultError(status: VaultStatus.writersRefused).name == "writers_refused")
    }
}
