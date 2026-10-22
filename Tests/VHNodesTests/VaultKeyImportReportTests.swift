import Foundation
import Testing
import VHContract
import VHNodes

/// `vault.keys.import`'s answer as the daemon writes it (`ops::vault_keys::toJson(ImportResult)`), decoded with the
/// contract's model: no alternative names, no members the daemon doesn't send.
@Suite struct VaultKeyImportReportTests {
    static let recover = Data("""
    {"vault_id": 7, "vault_name": "Photos", "deleted": false, "mode": "recover", "written": true,
     "key_available": false, "note": "key version 1 needs salvage",
     "versions": [
       {"version": 1, "outcome": "needs_salvage", "detail": "the backup carries no attestation"},
       {"version": 2, "outcome": "restored", "detail": "attested by this node (signing key 3)"},
       {"version": 3, "outcome": "refused", "detail": "the vault has no record of key version 3"},
       {"version": 4, "outcome": "a_newer_word", "detail": "from a newer daemon"}
     ],
     "salvage": null}
    """.utf8)

    static let salvage = Data("""
    {"vault_id": 7, "vault_name": "Photos", "deleted": false, "mode": "salvage", "written": true,
     "key_available": true, "note": null,
     "versions": [{"version": 1, "outcome": "salvaged", "detail": "files re-encrypted under key version 3"}],
     "salvage": {"id": 4, "versions": [1], "new_version": 3, "state": "running", "started_at": 1790000000,
                 "finished_at": null, "salvaged": 120, "unrecoverable": 60, "skipped_remote": 2, "deferred": 1,
                 "failed": 0,
                 "failures": [{"path": "/a.jpg", "version": 1, "kind": "unrecoverable", "reason": "tag mismatch"},
                              {"path": "/b.mov", "version": 1, "kind": "skipped_remote", "reason": "budget"}]}}
    """.utf8)

    @Test func recoverSortsVersionsByOutcomeAndToleratesNewWords() throws {
        let report = try JSONDecoder().decode(VaultKeyImportReport.self, from: Self.recover)
        #expect(report.importMode == .recover && report.written && !report.keyAvailable && report.salvage == nil)
        #expect(report.needsSalvage.map(\.version) == [1])
        #expect(report.refused.map(\.version) == [3])
        #expect(report.versions.last?.outcome == "a_newer_word")
    }

    @Test func salvageCarriesItsReport() throws {
        let report = try JSONDecoder().decode(VaultKeyImportReport.self, from: Self.salvage)
        let pass = try #require(report.salvage)
        #expect(report.importMode == .salvage && report.note == nil)
        #expect(pass.newVersion == 3 && pass.isRunning && pass.finishedAt == nil)
        #expect(pass.notSalvaged == 63 && pass.unlistedFailures == 61)
        #expect(pass.failures.map(\.kind) == [WsModel.VaultKeySalvageFailure.Kind.unrecoverable,
                                              WsModel.VaultKeySalvageFailure.Kind.skippedRemote])
    }

    /// The fields revision 2 sent (`verified_files`, `failed_files`) and the guessed salvage names are gone; an answer
    /// missing what the daemon always sends is a contract mismatch, not a silent default.
    @Test func missingMembersAreNotGuessed() {
        let old = Data("""
        {"vault_id": 7, "vault_name": "Photos", "deleted": false, "written": false, "key_available": false,
         "versions": [{"version": 1, "outcome": "unverifiable", "detail": "", "verified_files": 0, "failed_files": 0}]}
        """.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(VaultKeyImportReport.self, from: old) }
    }

    @Test func modesAskForTheirOwnConfirmation() {
        #expect(VaultKeyImportMode.recover.confirmationCode == "vault_key_import")
        #expect(VaultKeyImportMode.salvage.confirmationCode == "vault_key_salvage")
        #expect(VaultKeyImportMode.confirmationCodes == ["vault_key_import", "vault_key_salvage"])
    }
}
