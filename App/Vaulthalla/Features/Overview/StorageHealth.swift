import SwiftUI
import VHContract
import VHCore
import VHNodes

/// The web console's Health → Storage: each vault's backend, the database, and retention cleanup.
struct StorageHealthPage: View {
    var queries: NodeQueries
    var overview: WsModel.DashboardOverview?

    var body: some View {
        let storage = queries.query(Ws.Stats.System.Storage.self)
        let db = queries.query(Ws.Stats.System.Db.self)
        let retention = queries.query(Ws.Stats.System.Retention.self)
        VStack(alignment: .leading, spacing: Theme.stackSpacing) {
            HealthDetailSection(anchor: .storageBackend, title: "Storage backends", overview: overview, query: storage,
                                subject: "storage backends") { response in
                StorageBody(stats: response.stats)
            }
            AdaptiveColumns(weights: [1.2, 1], minColumnWidth: 520, spacing: Theme.stackSpacing) {
                HealthDetailSection(anchor: .database, title: "Database", overview: overview, query: db,
                                    subject: "database statistics") { response in
                    if let stats = response.stats {
                        DatabaseBody(stats: stats)
                    } else {
                        Text("The daemon has no database statistics yet.").font(.callout).foregroundStyle(.fgSubtle)
                    }
                }
                HealthDetailSection(anchor: .retention, title: "Retention & cleanup", overview: overview,
                                    query: retention, subject: "retention") { response in
                    if let stats = response.stats {
                        RetentionBody(stats: stats)
                    } else {
                        Text("The daemon has no retention statistics yet.").font(.callout).foregroundStyle(.fgSubtle)
                    }
                }
            }
        }
        .observing(storage, polling: HealthPolling.detail)
        .observing(db, polling: HealthPolling.detail)
        .observing(retention, polling: HealthPolling.detail)
    }
}

// MARK: - Backends

private struct StorageBody: View {
    var stats: WsModel.StorageBackendStats

    @Environment(AppModel.self) private var model
    @State private var sort: DataSort? = DataSort(column: "name", ascending: true)
    @State private var selection: Int64?

    private static func needsLook(_ vault: WsModel.StorageVaultBackendStats) -> Bool {
        let tone = StatusTone(severity: vault.backendStatus)
        return tone == .warn || tone == .danger || vault.minFreeSpaceOk == false
    }

    var body: some View {
        let focus = model.healthFocus(on: .storageBackend)
        VStack(alignment: .leading, spacing: 16) {
            StatGrid(minimum: 120, uniformHeight: true) {
                StatTile(label: "Vaults", value: Format.count(stats.vaultCountTotal))
                StatTile(label: "Active", value: Format.count(stats.activeVaultCount))
                StatTile(label: "Inactive", value: Format.count(stats.inactiveVaultCount))
                StatTile(label: "Degraded", value: Format.count(stats.degradedVaultCount),
                         tone: stats.degradedVaultCount > 0 ? .warn : nil,
                         highlighted: focus != nil && stats.degradedVaultCount > 0)
                StatTile(label: "In error", value: Format.count(stats.errorVaultCount),
                         tone: stats.errorVaultCount > 0 ? .danger : nil,
                         highlighted: focus != nil && stats.errorVaultCount > 0)
                StatTile(label: "Local / S3", value: "\(stats.localVaultCount) / \(stats.s3VaultCount)")
            }
            DataTable(rows: stats.vaults, id: \.vaultID, columns: Self.columns, sort: $sort, selection: $selection,
                      tone: { vault in
                          let tone = StatusTone(severity: vault.backendStatus)
                          return tone == .warn || tone == .danger ? tone : vault.minFreeSpaceOk == false ? .warn : nil
                      },
                      help: Self.describe, copyText: Self.describe,
                      open: { _ in model.select(.vaults) },
                      empty: "No vaults are configured.")
        }
        .onChange(of: focus?.id, initial: true) {
            guard focus != nil, let first = stats.vaults.first(where: Self.needsLook) else { return }
            sort = DataSort(column: "status", ascending: true)
            selection = first.vaultID
        }
    }

    static func describe(_ vault: WsModel.StorageVaultBackendStats) -> String {
        var lines = ["\(vault.vaultName.isEmpty ? "Vault \(vault.vaultID)" : vault.vaultName) (\(vault.type.uppercased())): \(vault.backendStatus)\(vault.active ? "" : ", inactive")"]
        if let size = vault.vaultSizeBytes { lines.append("stored \(Format.bytes(size))") }
        if let free = vault.freeSpaceBytes {
            lines.append("free \(Format.bytes(free))" + (vault.minFreeSpaceOk == false ? ", below the minimum" : ""))
        }
        if let bucket = vault.bucket { lines.append("bucket \(bucket)") }
        if let total = vault.providerOpsTotal {
            lines.append("provider: \(Format.count(total)) ops, \(Format.count(vault.providerErrorsTotal ?? 0)) errors")
        }
        if let error = vault.lastProviderError, !error.isEmpty { lines.append("last error: \(error)") }
        return lines.joined(separator: "\n")
    }

    @MainActor private static let columns: [DataColumn<WsModel.StorageVaultBackendStats>] = [
        DataColumn("name", "Vault", width: .flexible(min: 140, weight: 1.6), sortKey: { .text($0.vaultName) }) { vault in
            Text(vault.vaultName.isEmpty ? "Vault \(vault.vaultID)" : vault.vaultName)
                .fontWeight(.medium).foregroundStyle(vault.active ? .fg : .fgSubtle)
        },
        DataColumn("type", "Backend", width: .flexible(min: 64, weight: 0.6), sortKey: { .text($0.type) }) { vault in
            Text(vault.type.uppercased()).font(.caption.weight(.medium)).foregroundStyle(.fgMuted)
        },
        DataColumn("status", "Status", width: .flexible(min: 96), sortKey: { vault in
            .number(Double(Severity.rank(Self.severityWord(vault.backendStatus))))
        }) { vault in
            HStack(spacing: 6) {
                StatusDot(tone: StatusTone(severity: vault.backendStatus), size: 6)
                Text(Format.words(vault.backendStatus)).foregroundStyle(.fgMuted)
            }
        },
        DataColumn("active", "Active", width: .flexible(min: 76, weight: 0.7), hideBelow: 760) { vault in
            FactLabel(value: vault.active, yes: "Active", no: "Inactive")
        },
        DataColumn("stored", "Stored", width: .flexible(min: 76), alignment: .trailing,
                   sortKey: { .number($0.vaultSizeBytes.map(Double.init)) }) { vault in
            Text(vault.vaultSizeBytes.map(Format.bytes) ?? "—").monospacedDigit().foregroundStyle(.fg)
        },
        DataColumn("quota", "Quota", width: .flexible(min: 70), alignment: .trailing, hideBelow: 560,
                   sortKey: { .number($0.quotaBytes == 0 ? nil : Double($0.quotaBytes)) }) { vault in
            Text(vault.quotaBytes == 0 ? "none" : Format.bytes(vault.quotaBytes)).monospacedDigit()
                .foregroundStyle(vault.quotaBytes == 0 ? .fgFaint : .fgMuted)
        },
        DataColumn("free", "Free", width: .flexible(min: 84), alignment: .trailing,
                   sortKey: { .number($0.freeSpaceBytes.map(Double.init)) }) { vault in
            HStack(spacing: 4) {
                if vault.minFreeSpaceOk == false {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StatusTone.warn.color)
                        .help("Below the minimum free space")
                }
                Text(vault.freeSpaceBytes.map(Format.bytes) ?? "—").monospacedDigit().foregroundStyle(.fgMuted)
            }
        },
        DataColumn("bucket", "Bucket", width: .flexible(min: 120, weight: 1.2), hideBelow: 900,
                   sortKey: { .text($0.bucket) }) { vault in
            Text(vault.bucket ?? "—").font(.caption).fontDesign(.monospaced).foregroundStyle(.fgMuted)
        },
        DataColumn("provider", "Provider errors", width: .flexible(min: 100), alignment: .trailing, hideBelow: 1040,
                   sortKey: { .number($0.providerErrorsTotal.map(Double.init)) }) { vault in
            Text(vault.providerErrorsTotal.map(Format.count) ?? "—").monospacedDigit()
                .foregroundStyle((vault.providerErrorsTotal ?? 0) > 0 ? .fg : .fgFaint)
        },
        DataColumn("encryption", "Upstream encryption", width: .flexible(min: 120), hideBelow: 1180) { vault in
            if vault.type == "s3" {
                FactLabel(value: vault.upstreamEncryptionEnabled, yes: "On", no: "Off")
            } else {
                Text("—").foregroundStyle(.fgFaint)
            }
        },
    ]

    /// Backend statuses ranked like severities, worst first.
    private static func severityWord(_ status: String) -> String {
        switch StatusTone(severity: status) {
        case .danger: "error"
        case .warn: "warning"
        case .unknown: "unknown"
        default: "healthy"
        }
    }
}

// MARK: - Database

private struct DatabaseBody: View {
    var stats: WsModel.DbStats

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = stats.error, !error.isEmpty {
                Callout(tone: .danger, systemImage: "xmark.octagon") {
                    Text(error).fontDesign(.monospaced).textSelection(.enabled)
                }
            }
            StatGrid(minimum: 130, uniformHeight: true) {
                StatTile(label: "Connected", value: stats.connected ? "Yes" : "No", hint: stats.databaseName,
                         tone: stats.connected ? nil : .danger)
                StatTile(label: "Size", value: Format.bytes(stats.dbSizeBytes))
                StatTile(label: "Connections",
                         value: "\(stats.connectionsTotal) / \(stats.connectionsMax.map(String.init) ?? "—")",
                         hint: stats.connectionsMax == nil ? "limit not reported" : "in use / max")
                StatTile(label: "Active / idle", value: "\(stats.connectionsActive) / \(stats.connectionsIdle)")
                StatTile(label: "Idle in transaction", value: Format.count(stats.connectionsIdleInTransaction))
                StatTile(label: "Cache hit ratio", value: stats.cacheHitRatio.map { Format.percent($0) })
                StatTile(label: "Oldest transaction",
                         value: stats.oldestTransactionAgeSeconds.map { Format.duration(seconds: $0) })
                StatTile(label: "Deadlocks", value: Format.count(stats.deadlocks))
                StatTile(label: "Temp files", value: Format.bytes(stats.tempBytes))
                StatTile(label: "Slow queries", value: stats.slowQueryCount.map(Format.count),
                         hint: stats.pgStatStatementsEnabled ? nil : "needs pg_stat_statements")
            }
            VStack(alignment: .leading, spacing: 8) {
                SubHeading("Largest tables")
                BarList(items: stats.largestTables.map { table in
                    BarItem(id: table.tableName,
                            label: table.tableName.replacingOccurrences(of: "public.", with: ""),
                            detail: "~\(Format.count(table.rowEstimate)) rows",
                            value: Double(table.totalBytes), display: Format.bytes(table.totalBytes),
                            help: "\(table.tableName): table \(Format.bytes(table.tableBytes)), "
                                + "indexes \(Format.bytes(table.indexBytes))",
                            monospaced: true)
                }, empty: "No table sizes reported.")
            }
        }
    }
}

// MARK: - Retention

private struct RetentionBody: View {
    var stats: WsModel.RetentionStats

    @Environment(AppModel.self) private var model
    @State private var sort: DataSort?

    private struct Row {
        var key: String
        var label: String
        var kept: String
        var overdue: String
        var overdueCount: Int64
        var policy: String
        var oldest: String
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Cleanup").foregroundStyle(.fgSubtle)
                StatusBadge(label: Format.words(stats.cleanupStatus), tone: StatusTone(severity: stats.cleanupStatus))
            }
            .font(.callout)
            DataTable(rows: rows, id: \.key, columns: Self.columns, sort: $sort,
                      selection: .constant(nil),
                      tone: { $0.overdueCount > 0 && model.healthFocus(on: .retention) != nil ? .warn : nil },
                      help: { "\($0.label): \($0.kept) kept, \($0.overdue) past retention. Policy: \($0.policy)." })
        }
    }

    @MainActor private static let columns: [DataColumn<Row>] = [
        DataColumn("label", "Data", width: .flexible(min: 110, weight: 1.2)) { row in
            Text(row.label).fontWeight(.medium).foregroundStyle(.fg)
        },
        DataColumn("kept", "Kept", width: .flexible(min: 90), alignment: .trailing) { row in
            Text(row.kept).monospacedDigit().foregroundStyle(.fgMuted)
        },
        DataColumn("overdue", "Past retention", width: .flexible(min: 100), alignment: .trailing,
                   sortKey: { .number(Double($0.overdueCount)) }) { row in
            Text(row.overdue).monospacedDigit().foregroundStyle(row.overdueCount > 0 ? .fg : .fgFaint)
        },
        DataColumn("policy", "Policy", width: .flexible(min: 110, weight: 1.2), hideBelow: 560) { row in
            Text(row.policy).foregroundStyle(.fgMuted)
        },
        DataColumn("oldest", "Oldest", width: .flexible(min: 64), alignment: .trailing, hideBelow: 460) { row in
            Text(row.oldest).monospacedDigit().foregroundStyle(.fgMuted)
        },
    ]

    private var rows: [Row] {
        let days = { (value: Int64) in "\(value) days" }
        let withBytes = { (count: Int64, size: Int64) in "\(Format.count(count)) · \(Format.bytes(size))" }
        let age = { (count: Int64, seconds: Int64?) in
            count == 0 ? "none" : seconds.map { Format.duration(seconds: $0) } ?? "—"
        }
        return [
            Row(key: "trash", label: "Trash", kept: withBytes(stats.trashedFilesCount, stats.trashedBytesTotal),
                overdue: withBytes(stats.trashedFilesPastRetentionCount, stats.trashedBytesPastRetention),
                overdueCount: stats.trashedFilesPastRetentionCount, policy: days(stats.trashRetentionDays),
                oldest: age(stats.trashedFilesCount, stats.oldestTrashedAgeSeconds)),
            Row(key: "sync", label: "Sync events", kept: Format.count(stats.syncEventsTotal),
                overdue: Format.count(stats.syncEventsPastRetentionCount),
                overdueCount: stats.syncEventsPastRetentionCount,
                policy: days(stats.syncEventRetentionDays)
                    + (stats.syncEventMaxEntries > 0 ? ", max \(Format.count(stats.syncEventMaxEntries))" : ""),
                oldest: "—"),
            Row(key: "audit", label: "Audit log", kept: Format.count(stats.auditLogEntriesTotal),
                overdue: Format.count(stats.auditLogEntriesPastRetentionCount),
                overdueCount: stats.auditLogEntriesPastRetentionCount, policy: days(stats.auditLogRetentionDays),
                oldest: age(stats.auditLogEntriesTotal, stats.oldestAuditLogAgeSeconds)),
            Row(key: "share", label: "Share access events", kept: Format.count(stats.shareAccessEventsTotal),
                overdue: "—", overdueCount: 0, policy: "no separate policy",
                oldest: age(stats.shareAccessEventsTotal, stats.oldestShareAccessEventAgeSeconds)),
            Row(key: "cache", label: "Cache index", kept: withBytes(stats.cacheEntriesTotal, stats.cacheBytesTotal),
                overdue: "\(Format.count(stats.cacheEntriesExpired)) expired · \(Format.count(stats.cacheEvictionCandidates)) to evict",
                overdueCount: stats.cacheEntriesExpired,
                policy: days(stats.cacheExpiryDays)
                    + (stats.cacheMaxSizeBytes > 0 ? ", max \(Format.bytes(stats.cacheMaxSizeBytes))" : ""),
                oldest: "—"),
        ]
    }
}
