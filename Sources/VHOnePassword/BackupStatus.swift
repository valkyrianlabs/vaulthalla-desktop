public import Foundation

/// The daemon's view of one vault's key (`vault.keys.status`, architecture §2 S2).
public struct DaemonKeyStatus: Sendable, Equatable {
    /// The Vaulthalla vault's id, as ASCII decimal (the key check binds it).
    public var vaultUUID: String
    /// The current key version (with no key record, the highest version data records).
    public var version: Int
    /// The version last confirmed exported (`vault.keys.export.confirm`), if any.
    public var exportedVersion: Int?
    public var exportedAt: Date?
    /// BLAKE2b-128 keyed by the vault key over "vh-key-check-v1" ‖ vault_id ‖ version: identifies the current key.
    /// nil when the daemon can't read its own key (`keyAvailable` false).
    public var keyCheck: String?
    public var rotationInProgress: Bool
    /// Older versions the daemon still needs to decrypt files (`needed_versions` other than the current one).
    public var neededVersions: [Int]
    /// The daemon's key checks of needed older versions, where it can read them.
    public var neededKeyChecks: [Int: String]
    /// Every key the vault needs to run is readable on the node (`key_available`).
    public var keyAvailable: Bool
    /// Why not: `key_missing`, `key_unsealable`, `version_missing`, or a newer daemon's code.
    public var unavailableReason: String?
    /// The daemon's words for it.
    public var unavailableDetail: String?
    /// Needed versions the node can't read (`missing_versions`).
    public var missingVersions: [Int]

    public init(
        vaultUUID: String, version: Int, exportedVersion: Int? = nil, exportedAt: Date? = nil, keyCheck: String?,
        rotationInProgress: Bool = false, neededVersions: [Int] = [], neededKeyChecks: [Int: String] = [:],
        keyAvailable: Bool = true, unavailableReason: String? = nil, unavailableDetail: String? = nil,
        missingVersions: [Int] = []
    ) {
        self.vaultUUID = vaultUUID
        self.version = version
        self.exportedVersion = exportedVersion
        self.exportedAt = exportedAt
        self.keyCheck = keyCheck
        self.rotationInProgress = rotationInProgress
        self.neededVersions = neededVersions
        self.neededKeyChecks = neededKeyChecks
        self.keyAvailable = keyAvailable
        self.unavailableReason = unavailableReason
        self.unavailableDetail = unavailableDetail
        self.missingVersions = missingVersions
    }

    /// Every version 1Password must hold for a restore: the current one and the needed older ones, newest first.
    public var requiredVersions: [Int] {
        Array(Set([version] + neededVersions)).sorted(by: >)
    }

    /// The versions a restore must put back: those the node can't read, newest first. The current version counts
    /// when its key check is unknown (it doesn't unseal); with nothing named, every required version.
    public var unreadableVersions: [Int] {
        var versions = Set(missingVersions)
        if keyCheck == nil { versions.insert(version) }
        return (versions.isEmpty ? requiredVersions : Array(versions)).sorted(by: >)
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
    /// The node can't use the vault's key (`key_available: false`): the vault doesn't run until the keys are put
    /// back. The most urgent state; the fix is restoring from 1Password when it holds them.
    case keyUnavailable(KeyUnavailable)
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

    public struct KeyUnavailable: Sendable, Equatable {
        /// The daemon's code (`key_missing`, `key_unsealable`, `version_missing`, or a newer one).
        public var reason: String
        /// The daemon's words, when it sent them.
        public var detail: String?
        /// The versions the node can't use, newest first.
        public var versions: [Int]
        /// What 1Password holds for them.
        public var backup: Backup

        public init(reason: String, detail: String?, versions: [Int], backup: Backup) {
            self.reason = reason
            self.detail = detail
            self.versions = versions
            self.backup = backup
        }

        public enum Backup: Sendable, Equatable {
            /// 1Password holds every version the node can't use: restore it.
            case complete
            /// 1Password holds some of them; these are missing (newest first). A restore puts back what it has.
            case partial(missing: [Int])
            /// No usable item (none, another vault's, or one whose stored keys don't match their checks).
            case none
            /// 1Password's items haven't been read yet (the status rests on the node's own record).
            case notChecked
        }

        public var canRestore: Bool {
            switch backup {
            case .complete, .partial: true
            case .none, .notChecked: false
            }
        }
    }

    /// True for every state that needs the user's or Desktop's attention.
    public var needsAttention: Bool {
        switch self {
        case .backedUp: false
        case .rotating(let missing): !missing.isEmpty
        case .needsBackup, .mismatch, .keyUnavailable, .unknown: true
        }
    }

    /// Whether a sync would write to 1Password (`vault.keys.export` → `item.upsert`): a backup is missing or stale,
    /// or a rotation's new key isn't stored yet. Mismatches and unavailable keys are never synced over.
    public var wantsSync: Bool {
        switch self {
        case .needsBackup: true
        case .rotating(let missing): !missing.isEmpty
        case .backedUp(let confirmed): !confirmed
        case .mismatch, .keyUnavailable, .unknown: false
        }
    }

    /// Computes a vault's status from the daemon's key status and the 1Password item (nil if none).
    ///
    /// Precedence: unknown (no daemon status) → key unavailable (the vault doesn't run) → mismatch (a key disagrees;
    /// safety first, even mid-rotation) → rotating → needs backup → backed up.
    public static func evaluate(daemon: DaemonKeyStatus?, item: BackupItem?) -> BackupStatus {
        guard let daemon else { return .unknown }
        if !daemon.keyAvailable {
            return .keyUnavailable(unavailable(daemon: daemon, item: item))
        }
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
        for (version, check) in daemon.neededKeyChecks.sorted(by: { $0.key > $1.key }) {
            if let stored = item.version(version), stored.keyCheck != check {
                return .mismatch(.keyCheckDiffers(version: version))
            }
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

    private static func unavailable(daemon: DaemonKeyStatus, item: BackupItem?) -> KeyUnavailable {
        let versions = daemon.unreadableVersions
        let reason = daemon.unavailableReason ?? "key_unavailable"
        // Only a backup of this vault whose stored keys the helper verified against their checks can restore it.
        guard let item, item.vaultUUID == daemon.vaultUUID, item.issues.isEmpty else {
            return KeyUnavailable(reason: reason, detail: daemon.unavailableDetail, versions: versions, backup: .none)
        }
        // Where the daemon still knows a version's check, 1Password's must agree, or that copy can't restore it.
        var known = daemon.neededKeyChecks
        if let check = daemon.keyCheck { known[daemon.version] = check }
        let usable = Set(item.versions.filter { stored in
            known[stored.version].map { $0 == stored.keyCheck } ?? true
        }.map(\.version))
        let missing = versions.filter { !usable.contains($0) }
        let backup: KeyUnavailable.Backup = missing.isEmpty ? .complete
            : missing.count == versions.count ? .none : .partial(missing: missing)
        return KeyUnavailable(reason: reason, detail: daemon.unavailableDetail, versions: versions, backup: backup)
    }
}
