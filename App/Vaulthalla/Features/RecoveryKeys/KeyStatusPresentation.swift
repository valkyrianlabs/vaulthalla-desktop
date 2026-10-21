import SwiftUI
import VHCore
import VHKeyBackup
import VHNodes
import VHOnePassword

/// How a vault's backup state reads: a word, a tone (never green for unknown) and a sentence.
nonisolated extension VaultKeyRow {
    var stateLabel: String {
        switch status {
        case .backedUp: "Backed up"
        case .needsBackup: "Needs backup"
        case .rotating: "Rotating"
        case .mismatch: "Mismatch"
        case .keyUnavailable: "Key unavailable"
        case .unknown: "Unknown"
        }
    }

    var stateTone: StatusTone {
        switch status {
        case .backedUp: .ok
        case .needsBackup: .warn
        case .rotating(let missing): missing.isEmpty ? .info : .warn
        case .mismatch, .keyUnavailable: .danger
        case .unknown: .unknown
        }
    }

    var stateDetail: String {
        switch status {
        case .backedUp(let confirmed):
            if !onePasswordChecked { return "\(nodeName) recorded a backup of key version \(daemon.version)." }
            return confirmed ? "1Password holds key version \(daemon.version) and every older version the vault still needs."
                : "1Password holds the key; \(nodeName) hasn't recorded the backup yet. Back Up Now records it without moving the key."
        case .needsBackup(.neverBackedUp):
            return onePasswordChecked ? "1Password holds no backup of this vault's key."
                : "\(nodeName) has no record of a backup of this vault's key."
        case .needsBackup(.newVersion(let version)):
            return "The key rotated to version \(version), which isn't backed up yet."
        case .needsBackup(.missingVersions(let versions)):
            return "Older key \(Self.versionWords(versions)) the vault still needs \(versions.count == 1 ? "is" : "are") missing from 1Password."
        case .needsBackup(.currentNotPromoted):
            return "1Password holds version \(daemon.version), but the item still names an older version as current."
        case .rotating(let missing):
            return missing.isEmpty
                ? "A key rotation is under way. 1Password holds the new key and the old one files still need."
                : "A key rotation is under way and \(Self.versionWords(missing)) isn't in 1Password yet. Back up now: the old key stays in the item."
        case .mismatch(let reason):
            switch reason {
            case .keyCheckDiffers(let version):
                return "1Password holds a different key for version \(version) than \(nodeName) uses. Nothing is synced over it; check the item."
            case .itemAheadOfDaemon(let item, let daemon):
                return "1Password holds key version \(item), newer than \(nodeName)'s \(daemon). Was the node's database restored from an older backup?"
            case .wrongItem:
                return "The 1Password item belongs to another vault."
            case .damaged(let issues):
                return "The 1Password item looks edited or damaged: \(issues.joined(separator: "; "))."
            }
        case .keyUnavailable(let unavailable):
            let what = "\(nodeName) can't use \(Self.versionWords(unavailable.versions)) of this vault's key (\(Self.reasonWords(unavailable.reason))), so the vault doesn't run."
            switch unavailable.backup {
            case .complete: return what + " 1Password holds \(unavailable.versions.count == 1 ? "it" : "them"): restore from 1Password."
            case .partial(let missing): return what + " 1Password holds some of them; \(Self.versionWords(missing)) \(missing.count == 1 ? "is" : "are") missing."
            case .none: return what + " 1Password holds no usable backup of \(unavailable.versions.count == 1 ? "it" : "them")."
            case .notChecked: return what + " Check 1Password for a backup."
            }
        case .unknown:
            return "\(nodeName) isn't connected; the backup state is unknown until it is."
        }
    }

    /// The first 8 hex digits: enough to compare by eye, never the key.
    var shortCheck: String {
        guard let check = daemon.keyCheck, !check.isEmpty else { return "—" }
        return String(check.prefix(8))
    }

    var lastBackedUp: Date? { item?.backedUpAt ?? daemon.exportedAt }

    var sortVault: String { vaultName.lowercased() }
    var sortNode: String { nodeName.lowercased() }
    var sortState: Int {
        switch status {
        case .keyUnavailable: 0
        case .mismatch: 1
        case .needsBackup: 2
        case .rotating: 3
        case .unknown: 4
        case .backedUp: 5
        }
    }
    var sortBackedUp: Double { lastBackedUp?.timeIntervalSince1970 ?? 0 }

    static func versionWords(_ versions: [Int], capitalized: Bool = false) -> String {
        let list = versions.map { "v\($0)" }
        let word = capitalized ? "Version" : "version"
        return versions.count == 1 ? "\(word) \(versions[0])" : "\(word)s \(list.joined(separator: ", "))"
    }

    static func reasonWords(_ reason: String) -> String {
        switch reason {
        case "key_missing": "no key record"
        case "key_unsealable": "it doesn't unseal on this host"
        case "version_missing": "a version its files need is gone"
        default: Format.words(reason).lowercased()
        }
    }
}

nonisolated extension RecoveryAssurance {
    var label: String {
        switch self {
        case .guaranteed: "Guaranteed recovery"
        case .bestEffort: "Best effort only"
        }
    }

    var tone: StatusTone {
        switch self {
        case .guaranteed: .ok
        case .bestEffort: .warn
        }
    }

    var detail: String {
        switch self {
        case .guaranteed:
            "Every key version the vault needs is in 1Password with the node's attestation, so the node restores it as its own."
        case .bestEffort(let versions):
            "\(VaultKeyRow.versionWords(versions, capitalized: true)) \(versions.count == 1 ? "has" : "have") no attestation from the node (backed up before it attested keys, or not at all). A restore may only salvage what those keys still decrypt. Back up again once the node attests keys."
        }
    }
}

extension View {
    /// On the Recovery Keys sidebar rows: vaults that need attention (a missing or stale backup, a mismatch, an
    /// unusable key), for one node or all of them. Hidden at 0.
    func recoveryKeysBadge(section: NodeSection? = nil, node: Node? = nil) -> some View {
        modifier(RecoveryKeysBadge(applies: section == nil || section == .recoveryKeys, node: node))
    }
}

private struct RecoveryKeysBadge: ViewModifier {
    var applies: Bool
    var node: Node?

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if applies {
            content.badge(min(model.recoveryKeys.attentionCount(for: node), 9_999))
        } else {
            content
        }
    }
}
