import Foundation
import VHContract
import VHCore
import VHNodes
public import VHOnePassword
public import VHTransport

/// What happened to one vault in a sync.
public enum VaultSyncOutcome: Sendable, Equatable {
    /// 1Password holds every version the vault needs, read back, and the node recorded the backup. `written` is false
    /// when 1Password already held exactly this (only the node's record moved, or nothing at all).
    case backedUp(version: Int, written: Bool)
    /// 1Password stored the keys, but the node refused the confirmation: it rotated in between (`conflict`). The
    /// backup isn't recorded; the next sync stores the new key too.
    case storedNotConfirmed(version: Int, reason: String)
    /// The keys were already in 1Password; the node's attestations of these versions were added to the item (metadata
    /// only, no key moved), so the backup restores on its own.
    case attestationsStored(versions: [Int])
    /// Left alone, and why: already backed up, or a state a sync never writes over (a mismatch, an unreadable key,
    /// an offline node).
    case skipped(String)
    case failed(step: VaultSyncStep, message: String)

    public var succeeded: Bool {
        switch self {
        case .backedUp, .attestationsStored: true
        default: false
        }
    }
}

public enum VaultSyncStep: String, Sendable, Equatable {
    /// Reading the keys from the node (`vault.keys.export`).
    case export
    /// Writing them to 1Password (`item.upsert`).
    case store
    /// Recording the backup on the node (`vault.keys.export.confirm`).
    case confirm
}

/// Progress of a sync, vault by vault.
public enum VaultSyncEvent: Sendable {
    case started(rowID: String)
    case finished(rowID: String, VaultSyncOutcome)
}

/// Backs vault keys up to 1Password (architecture §6): for each vault that isn't backed up, `vault.keys.export` over
/// the node's Device session, every needed version handed to `item.upsert` as `SecretBytes`, the export released
/// right after, then `vault.keys.export.confirm {vault_id, version, key_check}` with what 1Password read back. A
/// vault that 1Password already holds only gets the confirmation, without moving any key, and the node's attestations
/// 1Password lacks (`item.attest`, metadata only). Vaults are done one at a time; a failure stops only its own vault.
public struct KeyBackupSync: Sendable {
    public let store: any KeyBackupStore
    public let settings: OnePasswordSettings

    public init(store: any KeyBackupStore, settings: OnePasswordSettings) {
        self.store = store
        self.settings = settings
    }

    /// Connects to the account and finds (or creates) the vault. Throws `OnePasswordHelperError` with the helper's
    /// hint for the user (integration off, locked, declined).
    public func prepare() async throws -> OnePasswordVault {
        _ = try await store.checkAccount(settings.account)
        return try await store.ensureVault(title: settings.vaultTitle)
    }

    /// Every item's metadata in the backup vault.
    public func items(in vault: OnePasswordVault) async throws -> [BackupItem] {
        try await store.listItems(onePasswordVaultID: vault.id)
    }

    /// Syncs `rows` (on `nodes`) into `vault`. Rows that don't want a sync come back skipped with the reason.
    /// `force` backs up vaults that are already backed up again ("Back up again": the node records an attestation of
    /// each version as it exports it, and the item stores them).
    public func run(
        _ rows: [VaultKeyRow], nodes: [KeyBackupNode], into vault: OnePasswordVault, force: Bool = false,
        progress: @Sendable (VaultSyncEvent) async -> Void = { _ in }
    ) async -> [String: VaultSyncOutcome] {
        var outcomes: [String: VaultSyncOutcome] = [:]
        for row in rows {
            if Task.isCancelled { break }
            await progress(.started(rowID: row.id))
            let outcome: VaultSyncOutcome
            if let node = nodes.first(where: { $0.id == row.nodeID }) {
                outcome = await backUp(row, on: node, into: vault, force: force)
            } else {
                outcome = .skipped("The node isn't connected.")
            }
            outcomes[row.id] = outcome
            await progress(.finished(rowID: row.id, outcome))
        }
        return outcomes
    }

    /// One vault.
    public func backUp(
        _ row: VaultKeyRow, on node: KeyBackupNode, into vault: OnePasswordVault, force: Bool = false
    ) async -> VaultSyncOutcome {
        let keys = VaultKeyCommands(node.transport)
        switch row.status {
        case .backedUp where force:
            break
        case .backedUp(confirmed: true):
            return await storeAttestations(row, into: vault) ?? .skipped("Already backed up.")
        case .backedUp(confirmed: false):
            // 1Password holds it and the checks agree: only the node's record is behind. No key moves.
            if let item = row.item {
                if case .failed(let step, let message)? = await storeAttestations(row, into: vault) {
                    return .failed(step: step, message: message)
                }
                return await confirm(keys, vaultID: row.vaultID, version: item.currentVersion, keyCheck: item.keyCheck,
                                     written: false)
            }
        case .mismatch:
            return .skipped("1Password and \(row.nodeName) disagree about this key. Check the item before syncing.")
        case .keyUnavailable:
            // Versions the node still reads may carry attestations 1Password lacks; no key moves for those either.
            return await storeAttestations(row, into: vault)
                ?? .skipped("\(row.nodeName) can't read this vault's key. Restore it from 1Password instead.")
        case .unknown:
            return .skipped("\(row.nodeName) isn't connected.")
        case .rotating(let missing) where missing.isEmpty && !force:
            return await storeAttestations(row, into: vault)
                ?? .skipped("A key rotation is under way; 1Password already holds every key it needs.")
        case .needsBackup, .rotating:
            // The export carries the node's attestations; the upsert stores them with the keys.
            break
        }

        let stored: BackupUpsertOutcome
        let exportedVersion: Int
        do {
            // The export lives only in this scope: its SecretBytes are released (and zeroed) once the upsert returns.
            let exported: ExportedVaultKeys
            do {
                exported = try await keys.export(vaultID: row.vaultID)
            } catch {
                return .failed(step: .export, message: KeyBackupWords.export(error, node: row.nodeName))
            }
            guard exported.vaultID == row.vaultID, !exported.versions.isEmpty else {
                return .failed(step: .export, message: "\(row.nodeName) answered with another vault's keys.")
            }
            exportedVersion = exported.currentVersion
            stored = try await store.upsert(BackupUpsert(
                onePasswordVaultID: vault.id, nodeID: row.backupNodeID, nodeName: row.nodeName,
                vaultUUID: String(row.vaultID), vaultName: exported.vaultName, currentVersion: exported.currentVersion,
                versions: exported.versions.map {
                    KeyVersion(version: $0.version, key: $0.key, keyCheck: $0.keyCheck, needed: true,
                               attestation: $0.attestation)
                }))
        } catch {
            return .failed(step: .store, message: KeyBackupWords.onePassword(error))
        }
        guard stored.currentVersion == exportedVersion else {
            return .failed(step: .store, message: "1Password's copy doesn't hold the version \(row.nodeName) exported.")
        }
        // Confirm with what 1Password read back, never with what was sent.
        return await confirm(keys, vaultID: row.vaultID, version: stored.currentVersion, keyCheck: stored.keyCheck,
                             written: stored.written)
    }

    /// The node's attestations 1Password lacks for keys it already holds (``VaultKeyRow/attestationsToStore``), added
    /// to the item without moving a key. nil when there are none (or 1Password already had its own).
    private func storeAttestations(_ row: VaultKeyRow, into vault: OnePasswordVault) async -> VaultSyncOutcome? {
        guard let update = row.attestationUpdate(versions: row.attestationsToStore, in: vault) else { return nil }
        do {
            let outcome = try await store.attest(update)
            return outcome.stored.isEmpty ? nil : .attestationsStored(versions: outcome.stored)
        } catch {
            return .failed(step: .store, message: KeyBackupWords.onePassword(error))
        }
    }

    private func confirm(_ keys: VaultKeyCommands, vaultID: Int64, version: Int, keyCheck: String, written: Bool) async
        -> VaultSyncOutcome
    {
        do {
            _ = try await keys.confirm(vaultID: vaultID, version: version, keyCheck: keyCheck)
            return .backedUp(version: version, written: written)
        } catch .conflict(let message) {
            return .storedNotConfirmed(version: version, reason: message)
        } catch {
            return .failed(step: .confirm, message: KeyBackupWords.node(error))
        }
    }
}

/// Plain words for what went wrong, in the daemon's or the helper's terms where they have them.
public enum KeyBackupWords {
    public static func export(_ error: WsError, node: String) -> String {
        switch error {
        case .denied:
            "This account may not export vault keys on \(node) (it needs the encryption-key Export permission)."
        case .needsConfirmation(let code, let message) where code == "export_requires_device":
            message
        default:
            unsupported(error) ? "\(node) runs a Vaulthalla without key backup (vault.keys.export). Update it first."
                : self.node(error)
        }
    }

    public static func node(_ error: WsError) -> String {
        switch error {
        case .disconnected: "Not connected to the node."
        case .timeout: "The node hasn't answered yet; it may still be working on it."
        case .denied(let message): "Not allowed: \(message)"
        default: unsupported(error) ? "The node runs a Vaulthalla without key backup. Update it first." : error.message
        }
    }

    public static func onePassword(_ error: any Error) -> String {
        guard let error = error as? OnePasswordHelperError else { return "1Password: \(error.localizedDescription)" }
        switch error {
        case .refused(let code, let message, let hint, _):
            if code == .keyCheckMismatch {
                return "The node's key doesn't match its key check, so it wasn't stored. Nothing was written."
            }
            return hint.map { "\(message.capitalizedSentence). \($0)" } ?? message.capitalizedSentence + "."
        case .timeout: return "1Password didn't answer in time (an approval prompt may be waiting)."
        case .launchFailed: return "The 1Password helper couldn't start. Reinstall Vaulthalla."
        default: return error.description
        }
    }

    /// A daemon that doesn't know the command at all.
    public static func unsupported(_ error: WsError) -> Bool {
        switch error {
        case .error(let message), .notFound(let message), .invalid(let message):
            message.localizedCaseInsensitiveContains("unknown command")
                || message.localizedCaseInsensitiveContains("unknown action")
        default: false
        }
    }
}

extension String {
    var capitalizedSentence: String { prefix(1).uppercased() + dropFirst() }
}
