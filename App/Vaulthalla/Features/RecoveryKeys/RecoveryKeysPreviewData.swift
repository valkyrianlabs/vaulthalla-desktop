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

    static func needed(_ vault: Int64, _ version: Int64, _ reason: String, readable: Bool = true,
                       attested: Bool = true) -> WsModel.VaultKeyNeededVersion {
        .init(version: version, keyCheck: readable ? check(vault, version) : nil, reason: reason,
              attestation: attested ? nodeAttestation(vault, Int(version)) : nil)
    }

    /// `-VHDebugRecoveryKeys attest`: the Media Archive's key unseals again, so no vault's key is unusable and the
    /// "Back Up Again" banner shows (its v1 has no attestation anywhere).
    static var mediaArchiveReadable: Bool {
        UserDefaults.standard.string(forKey: "VHDebugRecoveryKeys") == "attest"
    }

    /// The node's recorded attestation of a version (public, like the key check).
    static func nodeAttestation(_ vault: Int64, _ version: Int) -> WsModel.VaultKeyAttestation {
        let attestation = attestation(vault, version)
        return .init(keyID: attestation.keyID, signature: attestation.signature)
    }

    /// An earlier salvage of Family Photos' v1 (into v2, before the rotation to v3), shown in the inspector.
    static let oldSalvage = WsModel.VaultKeySalvageReport(
        id: 1, versions: [1], newVersion: 2, state: WsModel.VaultKeySalvageReport.State.finished,
        startedAt: now - 60 * 86_400, finishedAt: now - 60 * 86_400 + 420, salvaged: 312, unrecoverable: 2,
        skippedRemote: 0, deferred: 0, failed: 0,
        failures: [.init(path: "/2019/Lisbon/IMG_0412.heic", version: 1, kind: WsModel.VaultKeySalvageFailure.Kind.unrecoverable,
                         reason: "does not authenticate under the supplied key"),
                   .init(path: "/2019/Lisbon/IMG_0413.heic", version: 1, kind: WsModel.VaultKeySalvageFailure.Kind.unrecoverable,
                         reason: "does not authenticate under the supplied key")])

    static let statuses: [WsModel.VaultKeyStatus] = [
        // Backed up, every version attested: guaranteed recovery. Salvaged once, long ago.
        .init(vaultID: 1, vaultName: "Family Photos (preview)", deleted: false, version: 3, keyCheck: check(1, 3),
              keyAvailable: true, exportedVersion: 3, exportedAt: now - 2 * 86_400, rotationInProgress: false,
              neededVersions: [needed(1, 3, "current"), needed(1, 2, "recovery")], missingVersions: [],
              attestation: nodeAttestation(1, 3), lastSalvage: oldSalvage),
        // Never backed up.
        .init(vaultID: 2, vaultName: "Documents (preview)", deleted: false, version: 1, keyCheck: check(2, 1),
              keyAvailable: true, rotationInProgress: false, neededVersions: [needed(2, 1, "current")], missingVersions: [],
              attestation: nodeAttestation(2, 1)),
        // Rotating; the new key isn't in 1Password yet, and the old one was backed up before the node recorded
        // attestations (back up again to add it).
        .init(vaultID: 3, vaultName: "Offsite Backup (preview)", deleted: false, version: 2, keyCheck: check(3, 2),
              keyAvailable: true, exportedVersion: 1, exportedAt: now - 31 * 86_400, rotationInProgress: true,
              neededVersions: [needed(3, 2, "current"), needed(3, 1, "rotation")], missingVersions: [],
              attestation: nodeAttestation(3, 2)),
        // The key doesn't unseal here: the vault doesn't run until it is restored. The node recorded v2's attestation
        // before it stopped unsealing, but never v1's (retired before the node's update): a restore fills in v2's from
        // the node's records and leaves v1 for salvage.
        mediaArchiveReadable
            ? .init(vaultID: 4, vaultName: "Media Archive (preview)", deleted: false, version: 2, keyCheck: check(4, 2),
                    keyAvailable: true, exportedVersion: 2, exportedAt: now - 140 * 86_400, rotationInProgress: false,
                    neededVersions: [needed(4, 2, "current"), needed(4, 1, "recovery", attested: false)],
                    missingVersions: [], attestation: nodeAttestation(4, 2))
            : .init(vaultID: 4, vaultName: "Media Archive (preview)", deleted: false, version: 2, keyCheck: nil,
                    keyAvailable: false, unavailableReason: "key_unsealable",
                    unavailableDetail: "The key of vault 'Media Archive' doesn't unseal on this host. Run vh vault keys import 4 --file <export.json>.",
                    exportedVersion: 2, exportedAt: now - 140 * 86_400, rotationInProgress: false,
                    neededVersions: [needed(4, 2, "current", readable: false),
                                     needed(4, 1, "recovery", readable: false, attested: false)],
                    missingVersions: [2, 1], attestation: nodeAttestation(4, 2)),
        // 1Password holds a different key under the current version.
        .init(vaultID: 5, vaultName: "Scratch (preview)", deleted: false, version: 2, keyCheck: check(5, 2),
              keyAvailable: true, exportedVersion: 2, exportedAt: now - 9 * 86_400, rotationInProgress: false,
              neededVersions: [needed(5, 2, "current")], missingVersions: [], attestation: nodeAttestation(5, 2)),
    ]

    static let vault = OnePasswordVault(id: "op-preview-vault", title: "Vaulthalla", created: false)

    /// A made-up but well-formed attestation (64 signature bytes), stable per vault and version.
    static func attestation(_ vault: Int64, _ version: Int) -> KeyAttestation {
        KeyAttestation(keyID: 1, signature: Data((0..<64).map { UInt8(truncatingIfNeeded: Int(vault) &* 31 &+ version &* 7 &+ $0) })
            .base64EncodedString())
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
        item(3, "Offsite Backup (preview)", current: 1, versions: [1], attested: false, backedUp: now - 31 * 86_400),
        item(4, "Media Archive (preview)", current: 2, versions: [2, 1], attested: false, backedUp: now - 140 * 86_400),
        item(5, "Scratch (preview)", current: 2, versions: [2], differs: true, backedUp: now - 9 * 86_400),
    ]

    /// A finished salvage of `version` (the Media Archive's v1) into `newVersion`: `restored` (attested) put back
    /// first, then most files re-encrypted, a few the key didn't open.
    static func salvageResult(id: Int64, name: String, version: Int64, newVersion: Int64, restored: [Int64]) -> [String: Any] {
        let failures: [[String: Any]] = [
            ["path": "/2024/render-final.mov", "version": version, "kind": "unrecoverable",
             "reason": "does not authenticate under the supplied key"],
            ["path": "/2024/render-final.prproj", "version": version, "kind": "unrecoverable",
             "reason": "does not authenticate under the supplied key"],
            ["path": "/old/notes.txt", "version": version, "kind": "unrecoverable", "reason": "the local copy is gone"],
            ["path": "/raw/day-2/A001_C014.braw", "version": version, "kind": "skipped_remote",
             "reason": "the price budget refused the read (estimated $0.42); run the salvage again to retry"],
            ["path": "/edit/timeline.drp", "version": version, "kind": "deferred", "reason": "open for writing"],
        ]
        return [
            "vault_id": id, "vault_name": name, "deleted": false, "mode": "salvage", "written": true,
            "key_available": true, "note": NSNull(),
            "versions": restored.map { ["version": $0, "outcome": "restored", "detail": "attested by this node (signing key 1)"] }
                + [["version": version, "outcome": "salvaged",
                    "detail": "1,284 files re-encrypted under key version \(newVersion); the supplied key was not stored"]],
            "salvage": [
                "id": 2, "versions": [version], "new_version": newVersion, "state": "finished", "started_at": now - 600,
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

    func attest(_ update: AttestationUpdate) async throws -> AttestationUpdateOutcome {
        try? await Task.sleep(for: .milliseconds(200))
        return try items.withLock { list in
            guard let index = list.firstIndex(where: { $0.itemID == update.itemID }) else {
                throw OnePasswordHelperError.refused(code: .notFound, message: "not found in 1Password", hint: nil, detail: nil)
            }
            let item = list[index]
            var stored: [Int] = []
            var kept: [Int] = []
            let versions = item.versions.map { version -> StoredKeyVersion in
                guard let new = update.versions.first(where: { $0.version == version.version }) else { return version }
                if version.isAttested {
                    kept.append(version.version)
                    return version
                }
                stored.append(version.version)
                return StoredKeyVersion(version: version.version, keyCheck: version.keyCheck, state: version.state,
                                        attestation: new.attestation)
            }
            list[index] = BackupItem(
                itemID: item.itemID, onePasswordVaultID: item.onePasswordVaultID, title: item.title, nodeID: item.nodeID,
                nodeName: item.nodeName, vaultUUID: item.vaultUUID, vaultName: item.vaultName,
                currentVersion: item.currentVersion, keyCheck: item.keyCheck, versions: versions, updatedAt: .now,
                backedUpAt: item.backedUpAt, issues: item.issues)
            return AttestationUpdateOutcome(itemID: item.itemID, onePasswordVaultID: item.onePasswordVaultID,
                                            written: !stored.isEmpty, stored: stored, kept: kept, storedVersions: versions)
        }
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
            let signed = RecoveryKeysPreviewData.attestation(id, Int(status.version))
            let attestation: [String: Any] = ["key_id": signed.keyID, "signature": signed.signature]
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
            // Per version sent: restored when its attestation is the node's (the preview node's own signature), else
            // it needs salvage.
            let keys = object["keys"] as? [String: Any] ?? [:]
            var sent: [(version: Int64, attestation: [String: Any]?)] = []
            if let head = (keys["key_info"] as? [String: Any])?["key_version"] as? NSNumber {
                sent.append((head.int64Value, keys["attestation"] as? [String: Any]))
            }
            for entry in keys["historical_keys"] as? [[String: Any]] ?? [] {
                if let version = entry["key_version"] as? NSNumber {
                    sent.append((version.int64Value, entry["attestation"] as? [String: Any]))
                }
            }
            func verifies(_ version: Int64, _ attestation: [String: Any]?) -> Bool {
                let expected = RecoveryKeysPreviewData.attestation(id, Int(version))
                return (attestation?["key_id"] as? NSNumber)?.int64Value == expected.keyID
                    && attestation?["signature"] as? String == expected.signature
            }
            let restorable = sent.filter { verifies($0.version, $0.attestation) }.map(\.version)
            let unproven = sent.map(\.version).filter { !restorable.contains($0) }
            if (salvage || !restorable.isEmpty), !named {
                throw salvage
                    ? .needsConfirmation(code: "vault_key_salvage", message: "Salvaging vault '\(status.vaultName)' (ID \(id)) restores key version(s) \(restorable.map(String.init).joined(separator: ", ")) attested by this node and re-encrypts every file sealed under key version(s) \(unproven.map(String.init).joined(separator: ", ")) that the supplied key decrypts under a fresh key this host creates; files it doesn't decrypt are reported unrecoverable, and the supplied key is never stored. Confirm by typing the vault's name.")
                    : .needsConfirmation(code: "vault_key_import", message: "Restoring vault '\(status.vaultName)' (ID \(id)) writes key version(s) \(restorable.map(String.init).joined(separator: ", ")), attested by this node. Version(s) \(unproven.map(String.init).joined(separator: ", ")) can't be proven and are left for salvage. Confirm by typing the vault's name.")
            }
            if salvage, let version = unproven.first {
                data = RecoveryKeysPreviewData.salvageResult(id: id, name: status.vaultName, version: version,
                                                             newVersion: status.version + 1, restored: restorable)
            } else {
                data = ["vault_id": id, "vault_name": status.vaultName, "deleted": false, "mode": "recover",
                        "written": !restorable.isEmpty, "key_available": status.keyAvailable || unproven.isEmpty,
                        "note": unproven.isEmpty ? NSNull() : "Key version(s) \(unproven.map(String.init).joined(separator: ", ")) need salvage: the backup can't prove they are this vault's key." as Any,
                        "versions": sent.sorted { $0.version < $1.version }.map { entry -> [String: Any] in
                            restorable.contains(entry.version)
                                ? ["version": entry.version, "outcome": "restored", "detail": "attested by this node (signing key 1)"]
                                : ["version": entry.version, "outcome": "needs_salvage",
                                   "detail": "no attestation: an export from before attestations, and this node recorded none"]
                        },
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
