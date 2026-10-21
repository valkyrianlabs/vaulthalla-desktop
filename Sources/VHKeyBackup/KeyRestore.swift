public import Foundation
public import VHContract
public import VHCore
import VHNodes
public import VHOnePassword
import VHTransport
import Darwin

/// Restoring a vault's keys from its 1Password backup (decision D7), in three steps:
///
/// 1. ``verify(daemon:item:)``: compare what 1Password stores (versions and key checks, metadata only) with what the
///    node reports. Nothing leaves 1Password.
/// 2. ``exportDocument(_:in:exportedBy:)``: reveal every stored version into the `vh vault keys export` JSON, for a
///    file the user picks (``SecretFile/write(_:to:)``, mode 0600).
/// 3. ``importToNode(_:on:in:confirmName:exportedBy:)``: reveal the versions the node needs and send them with
///    `vault.keys.import` over the paired connection. The daemon verifies every key against the vault's ciphertext
///    and asks for the vault's name before writing (`vault_key_import`). Only its answer says the vault is recovered.
///
/// Revealed keys live only for the duration of one call.
public struct KeyRestore: Sendable {
    public let store: any KeyBackupStore

    public init(store: any KeyBackupStore) {
        self.store = store
    }

    // MARK: 1. Verify

    public struct Verification: Sendable, Equatable {
        public enum Verdict: Sendable, Equatable {
            /// 1Password's key check equals the node's.
            case matches
            /// They differ: this backup holds another key under that version.
            case differs
            /// The node needs the version but can't read it; 1Password holds it (restorable).
            case restorable
            /// The node needs it; 1Password doesn't hold it.
            case missingFromBackup
            /// Neither side can vouch for it: the node can't read it and 1Password doesn't hold it.
            case lost
            /// 1Password holds it; the node no longer needs it (kept, never removed).
            case retired
        }

        public struct Line: Sendable, Equatable, Identifiable {
            public var id: Int { version }
            public let version: Int
            public let nodeCheck: String?
            public let backupCheck: String?
            public let verdict: Verdict
        }

        /// Newest first.
        public let lines: [Line]

        /// Every needed version is in 1Password with the node's key check (or restorable), and none differs.
        public var isComplete: Bool {
            lines.allSatisfy { [.matches, .restorable, .retired].contains($0.verdict) }
        }

        public var hasConflict: Bool { lines.contains { $0.verdict == .differs } }
    }

    /// Compares 1Password's stored versions and key checks with the node's.
    public static func verify(daemon: DaemonKeyStatus, item: BackupItem?) -> Verification {
        var nodeChecks = daemon.neededKeyChecks
        if let check = daemon.keyCheck { nodeChecks[daemon.version] = check }
        let required = Set(daemon.requiredVersions)
        let stored = Dictionary((item?.versions ?? []).map { ($0.version, $0.keyCheck) }, uniquingKeysWith: { a, _ in a })
        let all = required.union(stored.keys).sorted(by: >)
        let lines = all.map { version -> Verification.Line in
            let node = nodeChecks[version]
            let backup = stored[version]
            let verdict: Verification.Verdict
            switch (required.contains(version), node, backup) {
            case (false, _, _): verdict = .retired
            case (true, .some(let n), .some(let b)): verdict = n == b ? .matches : .differs
            case (true, nil, .some): verdict = .restorable
            case (true, .some, nil): verdict = .missingFromBackup
            case (true, nil, nil): verdict = .lost
            }
            return .init(version: version, nodeCheck: node, backupCheck: backup, verdict: verdict)
        }
        return Verification(lines: lines)
    }

    // MARK: 2. Export to a file

    /// The item's every version as the `vh vault keys export` JSON for one vault (pretty enough to read, not
    /// indented). The caller writes it with ``SecretFile/write(_:to:)`` and drops it.
    public func exportDocument(_ row: VaultKeyRow, in vault: OnePasswordVault, exportedBy: String) async throws -> SecretBytes {
        guard let item = row.item else { throw RestoreError.noBackup }
        let revealed = try await store.reveal(onePasswordVaultID: vault.id, itemID: item.itemID, versions: nil)
        let set = try Self.keySet(revealed, row: row)
        let writer = SecretJSONWriter(capacity: 1024 + set.versions.count * 160)
        set.write(to: writer, exportedBy: exportedBy)
        return writer.finish()
    }

    // MARK: 3. Import to the node

    public enum ImportOutcome: Sendable, Equatable {
        /// The daemon answered. `keyAvailable` in it says whether the vault runs again.
        case imported(WsModel.VaultKeyImportResult)
        /// The daemon would write and wants the vault's name typed; `message` says what it would write.
        case needsConfirmation(message: String)
        case failed(String)
    }

    /// Sends the stored versions the node needs (`vault.keys.import`). Without `confirmName` the daemon only plans;
    /// pass the name the person typed to write.
    public func importToNode(
        _ row: VaultKeyRow, on node: KeyBackupNode, in vault: OnePasswordVault, confirmName: String?, exportedBy: String
    ) async -> ImportOutcome {
        guard let item = row.item else { return .failed(RestoreError.noBackup.description) }
        // Only what the node needs: its required versions (and what it reports missing) that 1Password holds.
        let wanted = Set(row.daemon.requiredVersions + row.daemon.missingVersions)
        let held = item.versions.map(\.version).filter { wanted.contains($0) }.sorted(by: >)
        guard !held.isEmpty else { return .failed(RestoreError.nothingToRestore.description) }

        let set: VaultKeySet
        do {
            let revealed = try await store.reveal(onePasswordVaultID: vault.id, itemID: item.itemID, versions: held)
            set = try Self.keySet(revealed, row: row)
        } catch let error as RestoreError {
            return .failed(error.description)
        } catch {
            return .failed(KeyBackupWords.onePassword(error))
        }
        do {
            let result = try await VaultKeyCommands(node.transport).importKeys(set, confirmName: confirmName,
                                                                             exportedBy: exportedBy)
            return .imported(result)
        } catch .needsConfirmation(let code, let message) where code == "vault_key_import" {
            return .needsConfirmation(message: message)
        } catch {
            return .failed(Self.words(error, node: row.nodeName))
        }
    }

    static func words(_ error: WsError, node: String) -> String {
        switch error {
        case .denied: "This account may not import vault keys on \(node) (it needs the encryption-key Export permission)."
        case .invalid(let message): "\(node) refused the keys: \(message)"
        case .conflict(let message): "\(node) refused the keys: \(message)"
        case .needsConfirmation(let code, let message) where code == "import_requires_device": message
        default: KeyBackupWords.unsupported(error)
            ? "\(node) runs a Vaulthalla without key import (vault.keys.import). Update it first."
            : KeyBackupWords.node(error)
        }
    }

    /// The revealed versions as a key set for the row's vault; refuses an item for another node or vault.
    static func keySet(_ revealed: RevealedKeys, row: VaultKeyRow) throws -> VaultKeySet {
        guard revealed.nodeID == row.backupNodeID, revealed.vaultUUID == String(row.vaultID) else {
            throw RestoreError.wrongItem
        }
        guard !revealed.versions.isEmpty else { throw RestoreError.nothingToRestore }
        return VaultKeySet(
            vaultID: row.vaultID, vaultName: row.vaultName, currentVersion: revealed.currentVersion,
            versions: revealed.versions.map {
                .init(version: $0.version, key: $0.key, keyCheck: $0.keyCheck,
                      reason: $0.version == revealed.currentVersion ? "current" : nil)
            })
    }

    public enum RestoreError: Error, Sendable, CustomStringConvertible {
        case noBackup
        case wrongItem
        case nothingToRestore

        public var description: String {
            switch self {
            case .noBackup: "1Password holds no backup of this vault."
            case .wrongItem: "The 1Password item belongs to another node or vault; nothing was sent."
            case .nothingToRestore: "1Password holds none of the key versions the node needs."
            }
        }
    }
}

/// Writes key material to a file the user chose: created with mode 0600 (never wider, even briefly), written from
/// the `SecretBytes` buffer itself, synced, closed.
public enum SecretFile {
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    public static func write(_ secret: SecretBytes, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(description: "Couldn't create \(url.lastPathComponent): \(errnoText())") }
        defer { close(fd) }
        // An existing file keeps its mode through O_TRUNC: narrow it.
        guard fchmod(fd, 0o600) == 0 else { throw Failure(description: "Couldn't restrict the file: \(errnoText())") }
        try secret.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Failure(description: "Couldn't write \(url.lastPathComponent): \(errnoText())")
                }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw Failure(description: "Couldn't save \(url.lastPathComponent): \(errnoText())") }
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}
