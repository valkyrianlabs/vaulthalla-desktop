public import Foundation

/// The daemon's view of one vault's key (`vault.keys.status`, architecture §2 S2).
public struct DaemonKeyStatus: Sendable, Equatable {
    public var vaultUUID: String
    /// The current key version.
    public var version: Int
    /// The version last confirmed exported (`vault.keys.export.confirm`), if any.
    public var exportedVersion: Int?
    public var exportedAt: Date?
    /// BLAKE2b-128 keyed by the vault key over "vh-key-check-v1" ‖ vault_id ‖ version: identifies the current key.
    public var keyCheck: String
    public var rotationInProgress: Bool
    /// Older versions the daemon still needs to decrypt files (`historical`).
    public var neededVersions: [Int]

    public init(
        vaultUUID: String, version: Int, exportedVersion: Int? = nil, exportedAt: Date? = nil, keyCheck: String,
        rotationInProgress: Bool = false, neededVersions: [Int] = []
    ) {
        self.vaultUUID = vaultUUID
        self.version = version
        self.exportedVersion = exportedVersion
        self.exportedAt = exportedAt
        self.keyCheck = keyCheck
        self.rotationInProgress = rotationInProgress
        self.neededVersions = neededVersions
    }

    /// Every version 1Password must hold for a restore: the current one and the needed older ones, newest first.
    public var requiredVersions: [Int] {
        Array(Set([version] + neededVersions)).sorted(by: >)
    }
}

/// Backup status of one vault (§6).
public enum BackupStatus: Sendable, Equatable {
    /// 1Password holds the daemon's current version with the same key check, and every version still needed.
    /// `confirmed` is false until the daemon has recorded the export (`exported_version == version`); Desktop then
    /// sends `vault.keys.export.confirm`.
    case backedUp(confirmed: Bool)
    case needsBackup(NeedsBackupReason)
    /// A rotation is under way. Desktop waits for it to finish; `missingVersions` are required versions 1Password
    /// doesn't hold yet (empty means the old keys are safe in the item meanwhile).
    case rotating(missingVersions: [Int])
    /// 1Password and the daemon disagree about a key. Never resolved automatically.
    case mismatch(MismatchReason)
    /// The daemon's status isn't available (node offline). Never shown as backed up.
    case unknown

    public enum NeedsBackupReason: Sendable, Equatable {
        /// No item for this vault.
        case neverBackedUp
        /// The daemon rotated to a version 1Password doesn't have.
        case newVersion(Int)
        /// Older versions the daemon still needs are missing from the item, newest first.
        case missingVersions([Int])
        /// The item has the current version but `credential` still points at an older one.
        case currentNotPromoted
    }

    public enum MismatchReason: Sendable, Equatable {
        /// 1Password's key for this version has a different key check than the daemon's.
        case keyCheckDiffers(version: Int)
        /// 1Password's current version is newer than the daemon's (a reset or restored daemon?).
        case itemAheadOfDaemon(itemVersion: Int, daemonVersion: Int)
        /// The item belongs to another vault.
        case wrongItem
        /// The helper found the item inconsistent (hand edits, damage).
        case damaged([String])
    }

    /// True for every state that needs the user's or Desktop's attention.
    public var needsAttention: Bool {
        switch self {
        case .backedUp: false
        case .rotating(let missing): !missing.isEmpty
        case .needsBackup, .mismatch, .unknown: true
        }
    }

    /// Computes a vault's status from the daemon's key status and the 1Password item (nil if none).
    ///
    /// Precedence: unknown (no daemon status) → mismatch (a key disagrees; safety first, even mid-rotation) →
    /// rotating → needs backup → backed up.
    public static func evaluate(daemon: DaemonKeyStatus?, item: BackupItem?) -> BackupStatus {
        guard let daemon else { return .unknown }
        let required = daemon.requiredVersions
        guard let item else {
            return daemon.rotationInProgress ? .rotating(missingVersions: required) : .needsBackup(.neverBackedUp)
        }

        if item.vaultUUID != daemon.vaultUUID {
            return .mismatch(.wrongItem)
        }
        if let stored = item.version(daemon.version), stored.keyCheck != daemon.keyCheck {
            return .mismatch(.keyCheckDiffers(version: daemon.version))
        }
        if item.currentVersion == daemon.version, item.keyCheck != daemon.keyCheck {
            return .mismatch(.keyCheckDiffers(version: daemon.version))
        }
        if item.currentVersion > daemon.version {
            return .mismatch(.itemAheadOfDaemon(itemVersion: item.currentVersion, daemonVersion: daemon.version))
        }
        if !item.issues.isEmpty {
            return .mismatch(.damaged(item.issues))
        }

        let held = Set(item.versions.map(\.version))
        let missing = required.filter { !held.contains($0) }
        if daemon.rotationInProgress {
            return .rotating(missingVersions: missing)
        }
        if missing.contains(daemon.version) {
            return .needsBackup(.newVersion(daemon.version))
        }
        if !missing.isEmpty {
            return .needsBackup(.missingVersions(missing))
        }
        if item.currentVersion != daemon.version {
            return .needsBackup(.currentNotPromoted)
        }
        return .backedUp(confirmed: daemon.exportedVersion == daemon.version)
    }
}
