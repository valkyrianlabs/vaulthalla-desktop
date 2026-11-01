#if DEBUG
import Foundation
import Synchronization
import VHContract
import VHNodes
import VHTransport

/// PREVIEW DATA, DEBUG only: canned daemon answers for `#Preview`s and `DebugSnapshot`, served through the same
/// query layer as a live node. Names say "(preview)" where they appear; nothing here reaches a real node.
nonisolated final class PreviewTransport: NodeTransport {
    enum Scenario: Sendable {
        /// An admin's view: health, vaults, usage.
        case full
        /// An account without admin.stats.view whose role's vault policy covers no vaults.
        case restricted
    }

    let scenario: Scenario
    /// The vault list; feature answers may read and change it.
    let vaults = Mutex(PreviewData.vaults)

    /// Feature folders' own canned answers (`PreviewFeature`), asked in order for commands answered nowhere here.
    static let features: [any PreviewFeature.Type] = [CostPreviewData.self, CredentialsPreviewData.self, NewVaultPreviewData.self, SyncConflictsPreviewData.self, AccessPreviewData.self, SharesPreviewData.self, DevicesPreviewData.self, GatewayPreviewData.self, RecoveryKeysPreviewData.self, AllNodesPreviewData.self, HealthPreviewData.self]

    init(_ scenario: Scenario) {
        self.scenario = scenario
    }

    func send<R: WsRequest>(_ request: R.Type, payload: R.Payload) async throws(WsError) -> R.Response {
        try? await Task.sleep(for: .milliseconds(120))
        let answer = try self.answer(R.command, payload)
        guard let typed = answer as? R.Response else {
            throw .contractMismatch("preview data has no \(R.command.rawValue) answer")
        }
        return typed
    }

    private func answer(_ command: WsCommand, _ payload: some Sendable) throws(WsError) -> Any {
        let denied = WsError.denied("Permission denied: this account lacks admin.stats.view.")
        switch command {
        case .metaContractGet:
            return Ws.Meta.Contract.Get.Response(contractVersion: Int64(WsContract.contractVersion),
                                                 contractHash: "preview", wsHash: WsContract.wsHash,
                                                 modelsHash: WsContract.modelsHash)
        case .statsDashboardOverview:
            guard scenario == .full else { throw denied }
            return Ws.Stats.Dashboard.Overview.Response(stats: PreviewData.overview)
        case .statsSystemStorage:
            guard scenario == .full else { throw denied }
            return Ws.Stats.System.Storage.Response(stats: PreviewData.storage)
        case .storageVaultList:
            return Ws.Storage.Vault.List.Response(vaults: scenario == .full ? vaults.withLock { $0 } : [])
        case .storageVaultGet:
            let vault = try find((payload as? Ws.Storage.Vault.Get.Payload)?.id)
            var detailed = vault
            if vault.type == WsModel.Vault.TypeValue.s3 { detailed.sync = PreviewData.syncPolicy(vault.id) }
            return Ws.Storage.Vault.Get.Response(vault: detailed)
        case .statsVault:
            let vault = try find((payload as? Ws.Stats.Vault.Payload)?.vaultID)
            return Ws.Stats.Vault.Response(stats: PreviewData.stat(vault))
        case .vaultRecoveryStatus:
            let vault = try find((payload as? Ws.Vault.Recovery.Status.Payload)?.vaultID)
            return Ws.Vault.Recovery.Status.Response(status: PreviewData.recovery(vault))
        case .storageVaultRemovePlan:
            let vault = try find((payload as? Ws.Storage.Vault.Remove.Plan.Payload)?.id)
            return Ws.Storage.Vault.Remove.Plan.Response(plan: PreviewData.plan(vault))
        case .storageVaultUpdate:
            guard let patch = payload as? Ws.Storage.Vault.Update.Payload else { throw .invalid("Bad payload.") }
            var vault = try find(patch.id)
            if let name = patch.name?.wrapped { vault.name = name }
            if let description = patch.description?.wrapped { vault.description = description }
            vaults.withLock { list in list = list.map { $0.id == vault.id ? vault : $0 } }
            return Ws.Storage.Vault.Update.Response(vault: vault)
        case .storageVaultRemove:
            guard let remove = payload as? Ws.Storage.Vault.Remove.Payload else { throw .invalid("Bad payload.") }
            let vault = try find(remove.id)
            let plan = PreviewData.plan(vault)
            let keepsUpstream = remove.deleteUpstream?.wrapped != true
            if plan.type == "s3", plan.encryptedUpstream, !plan.keyExported, keepsUpstream, remove.acceptKeyLoss != true {
                throw .needsConfirmation(
                    code: "vault_upstream_key_loss",
                    message: "The key of “\(vault.name)” was never exported. Once it is destroyed, the objects in \(vault.bucket ?? "the bucket") can never be decrypted.")
            }
            if remove.now == true, remove.confirmNow != true {
                throw .needsConfirmation(code: "vault_delete_now",
                                         message: "Delete “\(vault.name)” now? It can't be restored.")
            }
            vaults.withLock { $0.removeAll { $0.id == vault.id } }
            return Ws.Storage.Vault.Remove.Response(deletion: nil)
        default:
            for feature in Self.features {
                if let answer = try feature.answer(command, payload, from: self) { return answer }
            }
            throw .notFound("The preview has no answer for \(command.rawValue).")
        }
    }

    private func find(_ id: Int64?) throws(WsError) -> WsModel.Vault {
        guard let id, let vault = vaults.withLock({ $0.first { $0.id == id } }) else {
            throw .notFound("No such vault.")
        }
        return vault
    }
}

/// A feature folder's PREVIEW DATA: answers the commands it owns, nil for the rest. Register it in
/// `PreviewTransport.features`.
nonisolated protocol PreviewFeature: SendableMetatype {
    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
}

/// The canned answers themselves.
nonisolated enum PreviewData {
    static let now = Int64(Date.now.timeIntervalSince1970)

    // MARK: Vaults

    static let vaults: [WsModel.Vault] = [
        vault(1, "Family Photos (preview)", "Phone backups and the shared albums.", quota: 200_000_000_000, owner: "cooper"),
        vault(2, "Documents (preview)", "", owner: "cooper"),
        vault(3, "Offsite Backup (preview)", "Nightly copy of Documents.", s3: "vh-offsite-backup", owner: "admin"),
        vault(4, "Media Archive (preview)", "Finished projects.", s3: "media-archive", quota: 2_000_000_000_000,
              owner: "studio", encrypted: false),
        vault(5, "Scratch (preview)", "", owner: "", active: false),
    ]

    private static func vault(_ id: Int64, _ name: String, _ description: String, s3 bucket: String? = nil,
                              quota: Int64 = 0, owner: String, active: Bool = true,
                              encrypted: Bool = true) -> WsModel.Vault {
        let slug = name.lowercased().replacingOccurrences(of: " (preview)", with: "").replacingOccurrences(of: " ", with: "-")
        return WsModel.Vault(
            id: id, name: name, slug: slug, effectiveFuseName: slug,
            type: bucket == nil ? WsModel.Vault.TypeValue.local : WsModel.Vault.TypeValue.s3,
            description: description, quota: quota, ownerID: owner.isEmpty ? 0 : id + 10, mountPoint: slug,
            allowFsWrite: true, isActive: active, createdAt: "2026-0\(id)-1\(id)T09:30:00Z",
            apiKeyID: bucket == nil ? nil : 1, bucket: bucket, encryptUpstream: bucket == nil ? nil : encrypted,
            owner: owner)
    }

    static let storage = WsModel.StorageBackendStats(
        overallStatus: "warning", vaultCountTotal: 5, localVaultCount: 3, s3VaultCount: 2, activeVaultCount: 4,
        inactiveVaultCount: 1, degradedVaultCount: 1, errorVaultCount: 0,
        vaults: [
            backend(1, "local", size: 148_300_000_000, status: "healthy"),
            backend(2, "local", size: 12_700_000_000, status: "healthy"),
            backend(3, "s3", size: 61_200_000_000, status: "degraded"),
            backend(4, "s3", size: 1_870_000_000_000, status: "healthy"),
            backend(5, "local", size: nil, status: "inactive"),
        ],
        checkedAt: now)

    private static func backend(_ id: Int64, _ type: String, size: Int64?, status: String)
        -> WsModel.StorageVaultBackendStats
    {
        WsModel.StorageVaultBackendStats(vaultID: id, vaultName: vaults.first { $0.id == id }?.name ?? "",
                                         type: type, active: status != "inactive", allowFsWrite: true, quotaBytes: 0,
                                         freeSpaceBytes: type == "local" ? 1_400_000_000_000 : nil,
                                         vaultSizeBytes: size, backendStatus: status,
                                         bucket: type == "s3" ? "vh-preview-\(id)" : nil)
    }

    static func syncPolicy(_ id: Int64) -> WsModel.RemoteSyncPolicy {
        WsModel.RemoteSyncPolicy(
            id: id, vaultID: id, interval: "15m 0s", enabled: true, lastSyncAt: "2026-10-20T08:45:00Z",
            lastSuccessAt: "2026-10-20T08:45:00Z", createdAt: "2026-03-13T09:30:00Z",
            updatedAt: "2026-10-01T10:00:00Z", strategy: "sync", conflictPolicy: "keep_newest",
            s3RequestBudget: .init())
    }

    static func stat(_ vault: WsModel.Vault) -> WsModel.VaultStat {
        let size = storage.vaults.first { $0.vaultID == vault.id }?.vaultSizeBytes ?? 0
        return WsModel.VaultStat(capacity: WsModel.VaultCapacity(
            capacity: vault.quota, logicalSize: size, physicalSize: size + size / 40, freeSpace: 0, cacheSize: 0,
            fileCount: size / 3_100_000, directoryCount: size / 410_000_000 + 3, averageFileSize: 3_100_000,
            largestFileSize: 4_200_000_000, topFileExtensions: [:]))
    }

    static func recovery(_ vault: WsModel.Vault) -> WsModel.RecoveryStatus {
        let s3 = vault.type == WsModel.Vault.TypeValue.s3
        return WsModel.RecoveryStatus(
            vaultID: vault.id, mode: s3 ? "provider_versioning" : "local_snapshots",
            localVersioning: .init(enabled: !s3, keepLast: s3 ? nil : 10),
            provider: .init(supported: s3, unsupportedReason: s3 ? "" : "Local vault", bucketState: s3 ? "versioned" : "none",
                            status: s3 ? "enabled" : "unsupported", enabledByVaulthalla: s3, settled: true,
                            retentionMode: "none", foreignNoncurrentRules: [], warnings: []),
            snapshots: .init(count: s3 ? 0 : 14, storedBytes: s3 ? 0 : 3_400_000_000, plaintextBytes: 0),
            versions: .init(count: 220, storedBytes: 1_200_000_000, plaintextBytes: 0),
            backlog: .init(pendingVersions: 0, pendingBytes: 0, failing: 0),
            retainedKeyVersions: vault.id == 3 ? [1, 2] : [1],
            warnings: vault.id == 3 ? ["Provider versioning settles in 2 days; restores before then use local versions."] : [])
    }

    static func plan(_ vault: WsModel.Vault) -> WsModel.VaultRemovalPlan {
        let s3 = vault.type == WsModel.Vault.TypeValue.s3
        let exported = vault.id != 3
        return WsModel.VaultRemovalPlan(
            vaultID: vault.id, name: vault.name, type: vault.type, provider: s3 ? "aws-s3" : nil, bucket: vault.bucket,
            encryptedUpstream: vault.encryptUpstream ?? false, keyVersion: vault.id == 3 ? 2 : 1, keyExported: exported,
            keyExportedAt: exported ? "2026-09-02T17:12:00Z" : nil, retentionWindow: "30d",
            retentionWindowSeconds: 2_592_000, keyRetentionWindow: "90d", keyRetentionWindowSeconds: 7_776_000,
            exportCommand: "sudo vh vault keys export \(vault.slug) --output ~/\(vault.slug).vhkey")
    }

    // MARK: Health

    static let overview = WsModel.DashboardOverview(
        overallStatus: "warning", warningCount: 3, errorCount: 0, checkedAt: now - 40,
        attention: [
            .init(code: "system.fuse.error_rate_elevated", severity: "warning", cardID: "system.fuse",
                  title: "FUSE Filesystem", message: "FUSE alertable error rate is above 2%.",
                  href: "/health/filesystem#fuse", metricKey: "alertable_error_rate"),
            .init(code: "system.storage.degraded_vaults", severity: "warning", cardID: "system.storage",
                  title: "Storage Backend", message: "1 vault backend(s) are degraded."),
            .init(code: "system.pricing.warnings", severity: "warning", cardID: "system.pricing_budget",
                  title: "S3 Price Budget Overview", message: "Unacknowledged S3 price budget warnings are active."),
        ],
        sections: [
            section("runtime", "Runtime", "Runtime services, worker pressure, and connected sessions.", "healthy"),
            section("filesystem", "Filesystem", "FUSE activity and preview cache readiness.", "warning", warnings: 1),
            section("storage", "Storage", "Backing providers, database health, and cleanup pressure.", "warning", warnings: 1),
            section("operations", "Operations", "Queued work, active transfers, and stuck-operation pressure.", "info"),
            section("cost_control", "Cost Control", "S3 price budgets, projected spend, catalog health, and override activity.",
                    "warning", warnings: 1),
            section("trends", "Trends", "Historical samples for live telemetry surfaces.", "healthy"),
        ],
        cards: [
            card("system.health", "runtime", "System Health", "healthy", [
                metric("services", "Services", "9/9"), metric("protocols", "Protocols", "2/2"),
                metric("deps", "Deps", "4/4"), metric("db", "Database", "ready"),
                metric("fuse", "FUSE", "mounted"), metric("s3_gateway", "S3 Gateway", "running"),
            ]),
            card("system.threadpools", "runtime", "Thread Pools", "healthy", [
                metric("pressure", "Max Pressure", "18%", 0.18), metric("queue", "Queue", "0", 0),
                metric("saturated", "Saturated", "0", 0), metric("workers", "Workers", "48", 48),
                metric("busy", "Busy", "3", 3), metric("pools", "Pools", "6", 6),
            ], series: series([4, 6, 5, 9, 7, 12, 8, 6, 10, 18, 11, 7])),
            card("system.connections", "runtime", "Connection Health", "healthy", [
                metric("sessions", "Sessions", "7", 7), metric("unauthenticated", "Unauth", "0", 0),
                metric("human", "Human", "4", 4), metric("share", "Share", "3", 3),
                metric("oldest_session", "Oldest", "6h 12m", 22_320),
            ]),
            card("system.fuse", "filesystem", "FUSE Filesystem", "warning", [
                metric("alertable_error_rate", "Alertable Errors", "2.29%", 0.0229, tone: "warning"),
                metric("ops", "Ops", "1.67M", 1_670_000), metric("avg_latency", "Avg Latency", "0.9 ms", 0.9),
                metric("open_handles", "Open Handles", "37", 37),
            ], series: series([120, 340, 280, 510, 460, 390, 720, 650, 300, 280, 410, 380]),
               warnings: [.init(code: "system.fuse.error_rate_elevated", severity: "warning",
                                message: "FUSE alertable error rate is above 2%.", href: "/health/filesystem#fuse",
                                metricKey: "alertable_error_rate")]),
            card("system.fs_cache", "filesystem", "FS Cache", "healthy", [
                metric("hit_rate", "Hit Rate", "97.2%", 0.972), metric("requests", "Requests", "88.1K", 88_100),
                metric("used", "Used", "1.9 GB", 1.9e9), metric("evictions", "Evictions", "212", 212),
            ]),
            card("system.http_cache", "filesystem", "HTTP Preview Cache", "info", [
                metric("hit_rate", "Hit Rate", "unknown", nil, tone: "unknown"), metric("requests", "Requests", "0", 0),
                metric("used", "Used", "0 B", 0), metric("occupancy", "Occupancy", "unknown", nil, tone: "unknown"),
            ], summary: "No preview traffic yet."),
            card("system.storage", "storage", "Storage Backend", "warning", [
                metric("vaults", "Vaults", "5", 5), metric("problem", "Problem", "1", 1, tone: "warning"),
                metric("backend_errors", "Backend Errors", "0", 0), metric("degraded", "Degraded", "1", 1, tone: "warning"),
            ], warnings: [.init(code: "system.storage.degraded_vaults", severity: "warning",
                                message: "1 vault backend(s) are degraded.")]),
            card("system.db", "storage", "Database Health", "healthy", [
                metric("cache_hit", "Cache Hit", "99.6%", 0.996), metric("connections", "Connections", "12/100"),
                metric("size", "Size", "412 MB", 4.12e8), metric("oldest_tx", "Oldest Tx", "0s", 0),
            ], series: series([10, 11, 12, 12, 11, 13, 12, 12, 14, 12, 12, 12])),
            card("system.retention", "storage", "Retention / Cleanup", "healthy", [
                metric("overdue", "Overdue", "0", 0), metric("trash", "Trash", "41", 41),
                metric("trash_bytes", "Trash Size", "2.3 GB", 2.3e9), metric("sync_backlog", "Sync Backlog", "0", 0),
            ]),
            card("system.operations", "operations", "Operation Queue", "info", [
                metric("pending", "Pending", "2", 2, tone: "info"), metric("in_progress", "In Progress", "1", 1, tone: "info"),
                metric("stalled", "Stalled", "0", 0), metric("failed_24h", "Failed 24h", "0", 0),
            ]),
            card("system.pricing_budget", "cost_control", "S3 Price Budget Overview", "warning", [
                metric("monthly_spend", "Spend This Month", "$4.12", 4.12, unit: "USD"),
                metric("projected_monthly", "Projected", "not estimated", nil, unit: "USD", tone: "unknown"),
                metric("active_policies", "Policies", "2", 2), metric("warnings", "Warnings", "1", 1, tone: "warning"),
            ], warnings: [.init(code: "system.pricing.warnings", severity: "warning",
                                message: "Unacknowledged S3 price budget warnings are active.")]),
            card("system.pricing_catalog", "cost_control", "Catalog Health", "unknown", [], available: false,
                 reason: "The pricing catalog hasn't been verified on this node yet."),
        ])

    private static let sectionHrefs = [
        "runtime": "/health/runtime", "filesystem": "/health/filesystem", "storage": "/health/storage",
        "operations": "/health/activity#operation-queue", "cost_control": "/cost", "trends": "/health/activity#trends",
    ]

    private static func section(_ id: String, _ title: String, _ description: String, _ severity: String,
                                warnings: Int64 = 0) -> WsModel.DashboardSectionSummary {
        WsModel.DashboardSectionSummary(id: id, title: title, description: description,
                                        href: sectionHrefs[id] ?? "/health",
                                        severity: severity, warningCount: warnings, errorCount: 0, summary: "",
                                        metrics: [], warnings: [], errors: [], checkedAt: now - 40)
    }

    private static func card(_ id: String, _ section: String, _ title: String, _ severity: String,
                             _ metrics: [WsModel.DashboardMetricSummary], series: [WsModel.DashboardCardSummary.Serie] = [],
                             warnings: [WsModel.DashboardIssueSummary] = [], summary: String = "",
                             available: Bool = true, reason: String? = nil) -> WsModel.DashboardCardSummary {
        WsModel.DashboardCardSummary(id: id, sectionID: section, title: title, description: "",
                                     href: HealthAnchor(cardID: id).map { "/health/\($0.page.rawValue)#\($0.rawValue)" }
                                        ?? (id.hasPrefix("system.pricing") ? "/cost" : "/health"),
                                     variant: "tiles", size: "2x1", severity: available ? severity : "unavailable",
                                     available: available, unavailableReason: reason, summary: summary,
                                     metrics: metrics, series: series, warnings: warnings, errors: [],
                                     checkedAt: now - 40)
    }

    private static func metric(_ key: String, _ label: String, _ value: String, _ number: Double? = nil,
                               unit: String? = nil, tone: String = "healthy") -> WsModel.DashboardMetricSummary {
        WsModel.DashboardMetricSummary(key: key, label: label, value: value, unit: unit, tone: tone, numericValue: number)
    }

    private static func series(_ values: [Double]) -> [WsModel.DashboardCardSummary.Serie] {
        let points = values.enumerated().map { index, value in
            WsModel.DashboardCardSummary.Serie.Point(createdAt: now - Int64((values.count - index) * 300), value: value)
        }
        return [.init(key: "trend", label: "Trend", unit: "", tone: "info", points: points)]
    }
}
#endif
