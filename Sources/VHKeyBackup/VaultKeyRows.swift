import Foundation
public import VHContract
public import VHCore
public import VHNodes
public import VHOnePassword

extension DaemonKeyStatus {
    /// The daemon's `vault.keys.status` entry for one vault.
    public init(_ status: WsModel.VaultKeyStatus) {
        let current = Int(status.version)
        var needed: [Int] = []
        var checks: [Int: String] = [:]
        for version in status.neededVersions where Int(version.version) != current {
            needed.append(Int(version.version))
            if let check = version.keyCheck { checks[Int(version.version)] = check }
        }
        self.init(
            vaultUUID: String(status.vaultID), version: current, exportedVersion: status.exportedVersion.map(Int.init),
            exportedAt: status.exportedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            keyCheck: status.keyCheck, rotationInProgress: status.rotationInProgress, neededVersions: needed,
            neededKeyChecks: checks, keyAvailable: status.keyAvailable, unavailableReason: status.unavailableReason,
            unavailableDetail: status.unavailableDetail, missingVersions: status.missingVersions.map(Int.init)
        )
    }
}

/// A paired node as key backup sees it.
public struct KeyBackupNode: Sendable, Identifiable {
    public let id: NodeID
    /// The node id written into 1Password (`vh_node_id`): the server's node id, stable across removing and adding
    /// the node again; this Mac's id for it only when the server never said.
    public let backupID: String
    public let name: String
    public let transport: any NodeTransport

    public init(node: Node, transport: any NodeTransport) {
        id = node.id
        backupID = node.serverNodeID ?? node.id.rawValue
        name = node.displayName
        self.transport = transport
    }

    public init(id: NodeID, backupID: String, name: String, transport: any NodeTransport) {
        self.id = id
        self.backupID = backupID
        self.name = name
        self.transport = transport
    }
}

/// One (node, vault) of the Recovery Keys table.
public struct VaultKeyRow: Identifiable, Sendable, Equatable {
    public var id: String { "\(nodeID.rawValue)/\(vaultID)" }
    public let nodeID: NodeID
    public let nodeName: String
    public let backupNodeID: String
    public let vaultID: Int64
    public let vaultName: String
    /// A deleted vault within its key retention window.
    public let deleted: Bool
    public let daemon: DaemonKeyStatus
    /// The 1Password item backing this vault, when 1Password was read and holds one.
    public let item: BackupItem?
    public let status: BackupStatus
    /// False until 1Password's items were read: `status` then rests on the node's own record of confirmed backups.
    public let onePasswordChecked: Bool

    public init(
        nodeID: NodeID, nodeName: String, backupNodeID: String, vaultID: Int64, vaultName: String, deleted: Bool,
        daemon: DaemonKeyStatus, item: BackupItem?, status: BackupStatus, onePasswordChecked: Bool
    ) {
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.backupNodeID = backupNodeID
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.deleted = deleted
        self.daemon = daemon
        self.item = item
        self.status = status
        self.onePasswordChecked = onePasswordChecked
    }

    /// Counts toward "N vault keys need backup": a missing or stale backup, or a rotation's key not stored yet.
    public var needsBackup: Bool {
        switch status {
        case .needsBackup: true
        case .rotating(let missing): !missing.isEmpty
        default: false
        }
    }

    /// How sure a restore from 1Password is: guaranteed when every version the node needs is in 1Password with the
    /// node's attestation (the daemon then restores it as the vault's own), best effort otherwise (e.g. backed up
    /// before the node attested keys: "Back up again" refreshes them). nil without a backup to judge.
    public var recoveryAssurance: RecoveryAssurance? {
        guard let item, item.vaultUUID == daemon.vaultUUID else { return nil }
        let required = daemon.requiredVersions
        let held = required.compactMap { item.version($0) }
        guard !held.isEmpty else { return nil }
        let unattested = required.filter { item.version($0)?.isAttested != true }
        return unattested.isEmpty ? .guaranteed : .bestEffort(unattestedVersions: unattested)
    }

    /// The badge's count: everything that needs a person, never an offline node.
    public var needsAttention: Bool {
        status != .unknown && status.needsAttention && status != .backedUp(confirmed: false)
    }
}

public enum RecoveryAssurance: Sendable, Equatable {
    case guaranteed
    /// These needed versions are missing from 1Password or carry no attestation (newest first).
    case bestEffort(unattestedVersions: [Int])
}

public enum VaultKeyRows {
    /// The rows of one node's vaults. `items` nil means 1Password wasn't read: statuses then come from the node's
    /// own record (``recordStatus(_:)``).
    public static func rows(node: KeyBackupNode, statuses: [WsModel.VaultKeyStatus], items: [BackupItem]?) -> [VaultKeyRow] {
        statuses.map { status in
            let daemon = DaemonKeyStatus(status)
            let item = items?.first { $0.nodeID == node.backupID && $0.vaultUUID == daemon.vaultUUID }
            let evaluated = items == nil ? recordStatus(daemon) : BackupStatus.evaluate(daemon: daemon, item: item)
            return VaultKeyRow(
                nodeID: node.id, nodeName: node.name, backupNodeID: node.backupID, vaultID: status.vaultID,
                vaultName: status.vaultName, deleted: status.deleted, daemon: daemon, item: item, status: evaluated,
                onePasswordChecked: items != nil)
        }
    }

    /// A vault's status from the node's record alone: `exported_version` moves only when Desktop confirmed a backup
    /// 1Password had read back (or the CLI exported), so it is a sound stand-in until 1Password is read. Never
    /// `backedUp(confirmed: false)` (that needs the item).
    public static func recordStatus(_ daemon: DaemonKeyStatus) -> BackupStatus {
        if !daemon.keyAvailable {
            return .keyUnavailable(.init(
                reason: daemon.unavailableReason ?? "key_unavailable", detail: daemon.unavailableDetail,
                versions: daemon.unreadableVersions, backup: .notChecked))
        }
        let exported = daemon.exportedVersion == daemon.version
        if daemon.rotationInProgress {
            return .rotating(missingVersions: exported ? [] : [daemon.version])
        }
        if exported { return .backedUp(confirmed: true) }
        return daemon.exportedVersion == nil ? .needsBackup(.neverBackedUp) : .needsBackup(.newVersion(daemon.version))
    }
}
