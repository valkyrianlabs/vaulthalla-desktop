#if DEBUG
import Foundation
import Synchronization
import VHContract
import VHCore
import VHKeyBackup
import VHNodes
import VHOnePassword
import VHTransport

/// PREVIEW DATA for Recovery Keys: `vault.keys.status` for the preview vaults (one of each state), an in-memory
/// stand-in for 1Password, and canned export/import answers with fake keys. Nothing here reaches 1Password or a node.
nonisolated enum RecoveryKeysPreviewData: PreviewFeature {
    static let now = Int64(Date.now.timeIntervalSince1970)
    static let homeLab = "preview-homelab"

    /// A made-up key check (32 hex digits), stable per vault and version.
    static func check(_ vault: Int64, _ version: Int64, other: Bool = false) -> String {
        let seed = UInt64(vault) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(version) &* 0xBF58_476D_1CE4_E5B9 ^ (other ? 0xA5A5_5A5A_F00D_BEEF : 0)
        return String(format: "%016llx%016llx", seed, seed &* 0x94D0_49BB_1331_11EB)
    }

    static func needed(_ vault: Int64, _ version: Int64, _ reason: String, readable: Bool = true) -> WsModel.VaultKeyNeededVersion {
        .init(version: version, keyCheck: readable ? check(vault, version) : nil, reason: reason)
    }

    static let statuses: [WsModel.VaultKeyStatus] = [
        // Backed up, every version attested: guaranteed recovery.
        .init(vaultID: 1, vaultName: "Family Photos (preview)", deleted: false, version: 3, keyCheck: check(1, 3),
              keyAvailable: true, exportedVersion: 3, exportedAt: now - 2 * 86_400, rotationInProgress: false,
              neededVersions: [needed(1, 3, "current"), needed(1, 2, "recovery")], missingVersions: []),
        // Never backed up.
        .init(vaultID: 2, vaultName: "Documents (preview)", deleted: false, version: 1, keyCheck: check(2, 1),
              keyAvailable: true, rotationInProgress: false, neededVersions: [needed(2, 1, "current")], missingVersions: []),
        // Rotating; the new key isn't in 1Password yet.
        .init(vaultID: 3, vaultName: "Offsite Backup (preview)", deleted: false, version: 2, keyCheck: check(3, 2),
              keyAvailable: true, exportedVersion: 1, exportedAt: now - 31 * 86_400, rotationInProgress: true,
              neededVersions: [needed(3, 2, "current"), needed(3, 1, "rotation")], missingVersions: []),
        // The key doesn't unseal here: the vault doesn't run until it is restored.
        .init(vaultID: 4, vaultName: "Media Archive (preview)", deleted: false, version: 1, keyCheck: nil,
              keyAvailable: false, unavailableReason: "key_unsealable",
              unavailableDetail: "The key of vault 'Media Archive' doesn't unseal on this host. Run vh vault keys import 4 --file <export.json>.",
              exportedVersion: 1, exportedAt: now - 140 * 86_400, rotationInProgress: false,
              neededVersions: [needed(4, 1, "current", readable: false)], missingVersions: [1]),
        // 1Password holds a different key under the current version.
        .init(vaultID: 5, vaultName: "Scratch (preview)", deleted: false, version: 2, keyCheck: check(5, 2),
              keyAvailable: true, exportedVersion: 2, exportedAt: now - 9 * 86_400, rotationInProgress: false,
              neededVersions: [needed(5, 2, "current")], missingVersions: []),
    ]

    static let vault = OnePasswordVault(id: "op-preview-vault", title: "Vaulthalla", created: false)

    static func attestation(_ vault: Int64, _ version: Int) -> KeyAttestation {
        KeyAttestation(keyID: 1, signature: Data("preview-signature-\(vault)-\(version)".utf8).base64EncodedString())
    }

    static func item(_ vault: Int64, _ name: String, current: Int, versions: [Int], attested: Bool = true,
                     differs: Bool = false, backedUp: Int64) -> BackupItem {
        BackupItem(
            itemID: "op-item-\(vault)", onePasswordVaultID: Self.vault.id, title: "Vaulthalla · \(name) · Home lab (preview)",
            nodeID: homeLab, vaultUUID: String(vault), vaultName: name, currentVersion: current,
            keyCheck: check(vault, Int64(current), other: differs),
            versions: versions.sorted(by: >).map { version in
                StoredKeyVersion(version: version, keyCheck: check(vault, Int64(version), other: differs && version == current),
                                 state: version == current ? .current : .needed,
                                 attestation: attested ? attestation(vault, version) : nil)
            },
            updatedAt: Date(timeIntervalSince1970: TimeInterval(backedUp)),
            backedUpAt: Date(timeIntervalSince1970: TimeInterval(backedUp)))
    }

    static let items: [BackupItem] = [
        item(1, "Family Photos (preview)", current: 3, versions: [3, 2, 1], backedUp: now - 2 * 86_400),
        item(3, "Offsite Backup (preview)", current: 1, versions: [1], backedUp: now - 31 * 86_400),
        item(4, "Media Archive (preview)", current: 1, versions: [1], attested: false, backedUp: now - 140 * 86_400),
        item(5, "Scratch (preview)", current: 2, versions: [2], differs: true, backedUp: now - 9 * 86_400),
    ]

    /// A finished salvage of the Media Archive's v1: most files re-encrypted under v2, a few the key didn't open.
    static func salvageResult(id: Int64, name: String) -> [String: Any] {
        let failures: [[String: Any]] = [
            ["path": "/2024/render-final.mov", "version": 1, "kind": "unrecoverable",
             "reason": "does not authenticate under the supplied key"],
            ["path": "/2024/render-final.prproj", "version": 1, "kind": "unrecoverable",
             "reason": "does not authenticate under the supplied key"],
            ["path": "/old/notes.txt", "version": 1, "kind": "unrecoverable", "reason": "the local copy is gone"],
            ["path": "/raw/day-2/A001_C014.braw", "version": 1, "kind": "skipped_remote",
             "reason": "the price budget refused the read (estimated $0.42); run the salvage again to retry"],
            ["path": "/edit/timeline.drp", "version": 1, "kind": "deferred", "reason": "open for writing"],
        ]
        return [
            "vault_id": id, "vault_name": name, "deleted": false, "mode": "salvage", "written": true,
            "key_available": true, "note": NSNull(),
            "versions": [["version": 1, "outcome": "salvaged",
                          "detail": "1,284 files re-encrypted under key version 2; the supplied key was not stored"]],
            "salvage": [
                "id": 1, "versions": [1], "new_version": 2, "state": "finished", "started_at": now - 600,
                "finished_at": now - 540, "salvaged": 1_284, "unrecoverable": 3, "skipped_remote": 1, "deferred": 1,
                "failed": 0, "failures": failures,
            ] as [String: Any],
        ]
    }

    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        guard command == .vaultKeysStatus else { return nil }
        guard transport.scenario == .full else {
            throw .denied("Permission denied: this account lacks the encryption-key View permission.")
        }
        return Ws.Vault.Keys.Status.Response(vaults: statuses)
    }

    /// Makes `model`'s Recovery Keys read the stand-in 1Password and start polling the preview nodes.
    @MainActor
    static func install(on model: AppModel) {
        model.recoveryKeys.usePreview(store: PreviewKeyBackupStore(items: items, vault: vault), items: items, vault: vault)
        model.recoveryKeys.start()
    }
}

/// PREVIEW DATA: 1Password in memory. Upserts store metadata; reveals hand out fake keys.
nonisolated final class PreviewKeyBackupStore: KeyBackupStore {
    private let items: Mutex<[BackupItem]>
    private let vault: OnePasswordVault

    init(items: [BackupItem], vault: OnePasswordVault) {
        self.items = Mutex(items)
        self.vault = vault
    }

    func checkAccount(_ account: String) async throws -> OnePasswordAccountStatus {
        OnePasswordAccountStatus(account: account, connected: true, vaultCount: 4)
    }

    func ensureVault(title: String) async throws -> OnePasswordVault { vault }

    func listItems(onePasswordVaultID: String) async throws -> [BackupItem] {
        try? await Task.sleep(for: .milliseconds(150))
        return items.withLock { $0 }
    }

    func upsert(_ backup: BackupUpsert) async throws -> BackupUpsertOutcome {
        try? await Task.sleep(for: .milliseconds(400))
        let current = backup.versions.first { $0.version == backup.currentVersion }
        let stored = backup.versions.sorted { $0.version > $1.version }.map {
            StoredKeyVersion(version: $0.version, keyCheck: $0.keyCheck, state: $0.version == backup.currentVersion ? .current : .needed,
                             attestation: $0.attestation)
        }
        let item = BackupItem(
            itemID: "op-item-\(backup.vaultUUID)", onePasswordVaultID: vault.id,
            title: "Vaulthalla · \(backup.vaultName) · \(backup.nodeName)", nodeID: backup.nodeID,
            nodeName: backup.nodeName, vaultUUID: backup.vaultUUID, vaultName: backup.vaultName,
            currentVersion: backup.currentVersion, keyCheck: current?.keyCheck ?? "", versions: stored,
            updatedAt: .now, backedUpAt: .now)
        items.withLock { list in
            list.removeAll { $0.nodeID == item.nodeID && $0.vaultUUID == item.vaultUUID }
            list.append(item)
        }
        return BackupUpsertOutcome(itemID: item.itemID, onePasswordVaultID: vault.id, created: true, written: true,
                                   currentVersion: item.currentVersion, keyCheck: item.keyCheck, storedVersions: stored,
                                   updatedAt: .now)
    }

    func reveal(onePasswordVaultID: String, itemID: String, versions: [Int]?) async throws -> RevealedKeys {
        guard let item = items.withLock({ $0.first { $0.itemID == itemID } }) else {
            throw OnePasswordHelperError.refused(code: .notFound, message: "not found in 1Password", hint: nil, detail: nil)
        }
        let wanted = item.versions.filter { versions?.contains($0.version) ?? true }
        return RevealedKeys(
            itemID: item.itemID, onePasswordVaultID: vault.id, nodeID: item.nodeID, vaultUUID: item.vaultUUID,
            currentVersion: item.currentVersion,
            versions: wanted.map {
                KeyVersion(version: $0.version, key: SecretBytes([UInt8](repeating: UInt8($0.version), count: 32)),
                           keyCheck: $0.keyCheck, needed: $0.state != .retired, attestation: $0.attestation)
            })
    }
}

/// PREVIEW DATA: the key-carrying commands, with fake keys.
extension PreviewTransport {
    nonisolated func sendSensitive(_ command: WsCommand, payload: SecretBytes) async throws(WsError) -> SecretBytes {
        try? await Task.sleep(for: .milliseconds(300))
        guard scenario == .full else { throw .denied("Permission denied: this account may not export vault keys.") }
        let request = payload.withUnsafeBytes { Data($0) }
        let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any] ?? [:]
        guard let id = (object["vault_id"] as? NSNumber)?.int64Value,
              let status = RecoveryKeysPreviewData.statuses.first(where: { $0.vaultID == id }) else {
            throw .notFound("No such vault.")
        }
        let data: [String: Any]
        switch command {
        case .vaultKeysExport:
            let key = Data(repeating: UInt8(status.version), count: 32).base64EncodedString()
            let check = RecoveryKeysPreviewData.check(id, status.version)
            let attestation: [String: Any] = ["key_id": 1, "signature": Data("preview-signature".utf8).base64EncodedString()]
            data = [
                "vault_id": id, "vault_name": status.vaultName, "key": key, "key_check": check, "attestation": attestation,
                "key_info": [
                    "type": "AES-256-GCM", "key_size": 32, "key_version": status.version, "iv_size": 12, "tag_size": 16,
                    "iv_gen": "libsodium::randombytes_buf", "cipher_impl": "libsodium::crypto_aead_aes256gcm",
                    "hardware_accel": "AES-NI (runtime checked)", "aad": false, "files_hashed_with": "libsodium",
                    "sealed_by": "Vaulthalla v1.15.0", "created_at": "2026-10-01 10:00:00", "exported_by": "preview",
                    "exported_at": "2026-10-21 09:00:00", "key_check": check, "attestation": attestation,
                ] as [String: Any],
            ]
        case .vaultKeysImport:
            let salvage = object["mode"] as? String == "salvage"
            let named = object["confirm_name"] as? String == status.vaultName
            if salvage {
                guard named else {
                    throw .needsConfirmation(code: "vault_key_salvage", message: "Salvaging vault '\(status.vaultName)' (ID \(id)) re-encrypts every file sealed under key version(s) 1 that the supplied key decrypts under a fresh key this host creates; files it doesn't decrypt are reported unrecoverable, and the supplied key is never stored. Confirm by typing the vault's name.")
                }
                data = RecoveryKeysPreviewData.salvageResult(id: id, name: status.vaultName)
            } else {
                // The preview backup of v1 predates attestations: recover can't prove it is the vault's key.
                data = ["vault_id": id, "vault_name": status.vaultName, "deleted": false, "mode": "recover",
                        "written": false, "key_available": false,
                        "note": "Key version 1 needs salvage: the backup can't prove it is this vault's key.",
                        "versions": [["version": 1, "outcome": "needs_salvage",
                                      "detail": "the backup carries no attestation (an export from before attestations)"]],
                        "salvage": NSNull()]
            }
        default:
            throw .error("Unknown command: \(command.rawValue)")
        }
        let frame: [String: Any] = ["command": command.rawValue + ".response", "status": "OK", "requestId": "preview", "data": data]
        let bytes = (try? JSONSerialization.data(withJSONObject: frame)) ?? Data()
        return SecretBytes(bytes)
    }
}
#endif
