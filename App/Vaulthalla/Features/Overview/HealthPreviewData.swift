#if DEBUG
import Foundation
import VHContract
import VHTransport

/// PREVIEW DATA for the Health pages: the `stats.system.*`, cache, trend and severity reads, shaped like a busy node
/// whose FUSE mount sees mostly expected errors (missing names, denied callers) and a few alertable read failures.
nonisolated enum HealthPreviewData: PreviewFeature {
    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any? {
        let full = transport.scenario == .full
        let denied = WsError.denied("Needs the \"view stats\" admin permission.")
        switch command {
        case .statsDashboardSeverity:
            guard full else { throw denied }
            let overview = PreviewData.overview
            return Ws.Stats.Dashboard.Severity.Response(stats: .init(
                overallStatus: overview.overallStatus, errorCount: overview.errorCount,
                warningCount: overview.warningCount, checkedAt: overview.checkedAt))
        case .statsSystemFuse:
            guard full else { throw denied }
            return Ws.Stats.System.Fuse.Response(stats: fuse)
        case .statsFsCache:
            guard full else { throw denied }
            return Ws.Stats.Fs.Cache.Response(stats: cache(hits: 1_912_440, misses: 54_210, used: 1_930_000_000,
                                                           capacity: nil))
        case .statsHttpCache:
            guard full else { throw denied }
            return Ws.Stats.Http.Cache.Response(stats: cache(hits: 8_412, misses: 1_103, used: 3_400_000_000,
                                                             capacity: 10_000_000_000))
        case .statsSystemHealth:
            guard full else { throw denied }
            return Ws.Stats.System.Health.Response(stats: systemHealth)
        case .statsSystemThreadpools:
            guard full else { throw denied }
            return Ws.Stats.System.Threadpools.Response(stats: threadPools)
        case .statsSystemConnections:
            guard full else { throw denied }
            return Ws.Stats.System.Connections.Response(stats: connections)
        case .statsSystemDb:
            guard full else { throw denied }
            return Ws.Stats.System.Db.Response(stats: database)
        case .statsSystemRetention:
            guard full else { throw denied }
            return Ws.Stats.System.Retention.Response(stats: retention)
        case .statsSystemOperations:
            guard full else { throw denied }
            return Ws.Stats.System.Operations.Response(stats: operations)
        case .statsSystemTrends:
            guard full else { throw denied }
            let hours = (payload as? Ws.Stats.System.Trends.Payload)?.windowHours ?? 168
            return Ws.Stats.System.Trends.Response(stats: trends(hours: hours))
        default:
            return nil
        }
    }

    private static let now = PreviewData.now

    // MARK: FUSE

    /// (op, calls, expected errors, alertable errors, avg ms, max ms, bytes read, bytes written)
    private static let opRows: [(String, Int64, Int64, Int64, Double, Double, Int64, Int64)] = [
        ("getattr", 812_400, 4_210, 0, 0.21, 38, 0, 0),
        ("lookup", 401_220, 61_880, 0, 0.34, 52, 0, 0),
        ("readdir", 48_310, 120, 0, 1.8, 140, 0, 0),
        ("open", 31_870, 2_904, 0, 0.62, 61, 0, 0),
        ("read", 228_400, 0, 38_400, 3.1, 1_480, 41_200_000_000, 0),
        ("write", 64_120, 0, 18, 2.4, 380, 0, 9_800_000_000),
        ("create", 2_210, 340, 0, 4.2, 210, 0, 0),
        ("rename", 940, 12, 3, 6.8, 95, 0, 0),
        ("unlink", 1_120, 48, 0, 3.3, 60, 0, 0),
        ("flush", 33_400, 0, 0, 0.1, 9, 0, 0),
        ("release", 33_390, 0, 0, 0.08, 7, 0, 0),
        ("access", 15_200, 1_870, 0, 0.12, 11, 0, 0),
        ("statfs", 2_400, 0, 0, 0.4, 20, 0, 0),
        ("setattr", 0, 0, 0, 0, 0, 0, 0),
        ("symlink", 0, 0, 0, 0, 0, 0, 0),
        ("fsync", 0, 0, 0, 0, 0, 0, 0),
    ]

    static let fuse: WsModel.FuseStatsSnapshot = {
        let ops = opRows.map { name, count, expected, alertable, avg, max, read, written in
            let errors = expected + alertable
            let ratio = { (value: Int64) in count == 0 ? 0 : Double(value) / Double(count) }
            return WsModel.FuseStatsSnapshot.Op(
                op: name, count: count, successes: count - errors, errors: errors, expectedErrors: expected,
                alertableErrors: alertable, bytesRead: read, bytesWritten: written,
                totalUs: Int64(Double(count) * avg * 1000), maxUs: Int64(max * 1000), avgMs: avg, maxMs: max,
                errorRate: ratio(errors), expectedErrorRate: ratio(expected), alertableErrorRate: ratio(alertable))
        }
        let total = ops.reduce(0) { $0 + $1.count }
        let expected = ops.reduce(0) { $0 + $1.expectedErrors }
        let alertable = ops.reduce(0) { $0 + $1.alertableErrors }
        let ratio = { (value: Int64) in Double(value) / Double(total) }
        return WsModel.FuseStatsSnapshot(
            totalOps: total, totalSuccesses: total - expected - alertable, totalErrors: expected + alertable,
            expectedErrors: expected, alertableErrors: alertable, errorRate: ratio(expected + alertable),
            expectedErrorRate: ratio(expected), alertableErrorRate: ratio(alertable),
            readBytes: 41_200_000_000, writeBytes: 9_800_000_000, openHandlesCurrent: 37, openHandlesPeak: 212,
            ops: ops,
            topErrors: [
                .init(errnoValue: 2, name: "ENOENT", count: 62_320, alertableCount: 0),
                .init(errnoValue: 13, name: "EACCES", count: 8_756, alertableCount: 0),
                .init(errnoValue: 5, name: "EIO", count: 38_406, alertableCount: 38_406),
                .init(errnoValue: 17, name: "EEXIST", count: 340, alertableCount: 0),
                .init(errnoValue: 1, name: "EPERM", count: 268, alertableCount: 15),
            ],
            alertableErrnoTypes: 2, checkedAt: now - 5)
    }()

    private static func cache(hits: Int64, misses: Int64, used: Int64, capacity: Int64?) -> WsModel.CacheStatsSnapshot {
        WsModel.CacheStatsSnapshot(
            hits: hits, misses: misses, evictions: misses / 9, inserts: misses, invalidations: misses / 40,
            bytesRead: used * 6, bytesWritten: used, usedBytes: used, capacityBytes: capacity,
            freeBytes: capacity.map { $0 - used },
            op: .init(count: misses, totalUs: misses * 900, maxUs: 84_000, avgMs: 0.9, maxMs: 84))
    }

    // MARK: Runtime

    static let systemHealth = WsModel.SystemHealth(
        overallStatus: "healthy",
        runtime: .init(allRunning: true, serviceCount: 9, services: [
            "FUSE", "SyncController", "StatsSnapshotService", "DBJanitor", "VaultRetentionService",
            "ProtocolService", "DeviceServer", "S3GatewayService", "ShellServer",
        ].map { .init(entryName: $0, serviceName: $0, running: true, interrupted: false) }),
        protocols: .init(running: true, ioContextInitialized: true, websocketConfigured: true, websocketReady: true,
                         httpPreviewConfigured: true, httpPreviewReady: true),
        s3Gateway: .init(running: true, configured: true, ready: true, host: "0.0.0.0", port: 39000, activeSessions: 0,
                         totalRequests: 1_204, failedRequests: 3),
        deps: .init(storageManager: true, apiKeyManager: true, authManager: true, sessionManager: true,
                    secretsManager: true, syncController: true, fsCache: true, shellUsageManager: true,
                    httpCacheStats: true, fuseSession: true, fuseMount: "multiuser", mountState: "mounted",
                    mountBackend: "linux-fuse", mountIsolation: "enforced", secretsBackend: "tpm2"),
        shell: .init(adminUidBound: true),
        database: .init(poolSize: 4, idle: 3, inUse: 1, brokenIdle: 0, reconnects: 0, reconnectFailures: 0,
                        consecutiveReconnectFailures: 0, acquireTimeouts: 0, reachable: true, probeLatencyMs: 1),
        vaultsUnavailable: [],
        summary: .init(servicesReady: 9, servicesTotal: 9, depsReady: 9, depsTotal: 9, protocolsReady: 2,
                       protocolsTotal: 2, checkedAt: now - 5))

    static let threadPools = WsModel.ThreadPoolManagerSnapshot(
        overallStatus: "healthy", totalWorkerCount: 48, totalQueueDepth: 3, totalIdleWorkerCount: 41,
        maxPressureRatio: 0.18, pressuredPoolCount: 0, saturatedPoolCount: 0, checkedAt: now - 5,
        pools: [
            .init(name: "fuse", queueDepth: 2, workerCount: 16, idleWorkerCount: 13, busyWorkerCount: 3,
                  hasIdleWorker: true, stopped: false, pressureRatio: 0.18, status: "healthy"),
            .init(name: "sync", queueDepth: 1, workerCount: 8, idleWorkerCount: 7, busyWorkerCount: 1,
                  hasIdleWorker: true, stopped: false, pressureRatio: 0.12, status: "healthy"),
            .init(name: "thumbnail", queueDepth: 0, workerCount: 8, idleWorkerCount: 8, busyWorkerCount: 0,
                  hasIdleWorker: true, stopped: false, pressureRatio: 0, status: "idle"),
            .init(name: "http", queueDepth: 0, workerCount: 8, idleWorkerCount: 7, busyWorkerCount: 1,
                  hasIdleWorker: true, stopped: false, pressureRatio: 0, status: "healthy"),
            .init(name: "stats", queueDepth: 0, workerCount: 4, idleWorkerCount: 4, busyWorkerCount: 0,
                  hasIdleWorker: true, stopped: false, pressureRatio: 0, status: "idle"),
            .init(name: "shell", queueDepth: 0, workerCount: 4, idleWorkerCount: 2, busyWorkerCount: 2,
                  hasIdleWorker: true, stopped: false, pressureRatio: 0.05, status: "healthy"),
        ])

    static let connections = WsModel.ConnectionStats(
        status: "healthy", activeWsSessionsTotal: 7, activeHumanSessions: 4, activeShareSessions: 3,
        activeSharePendingSessions: 0, activeUnauthenticatedSessions: 0, oldestSessionAgeSeconds: 22_320,
        idleTimeoutMinutes: 30, unauthenticatedTimeoutSeconds: 60, sweepIntervalSeconds: 30,
        connectionErrors24h: 2, sessionsByMode: ["human": 4, "share": 3], topUserAgents: [],
        topUserAgentsAvailable: false, topRemoteIpsLimited: [], topRemoteIpsAvailable: false, checkedAt: now - 5)

    // MARK: Storage

    static let database = WsModel.DbStats(
        connected: true, status: "healthy", databaseName: "vaulthalla", dbSizeBytes: 412_000_000, connectionsActive: 2,
        connectionsIdle: 10, connectionsIdleInTransaction: 0, connectionsTotal: 12, connectionsMax: 100,
        cacheHitRatio: 0.9961, pgStatStatementsEnabled: false, deadlocks: 0, tempBytes: 0,
        oldestTransactionAgeSeconds: 0,
        largestTables: [
            .init(tableName: "public.files", totalBytes: 182_000_000, tableBytes: 121_000_000, indexBytes: 61_000_000,
                  rowEstimate: 1_204_000),
            .init(tableName: "public.sync_events", totalBytes: 96_000_000, tableBytes: 70_000_000,
                  indexBytes: 26_000_000, rowEstimate: 840_000),
            .init(tableName: "public.audit_log", totalBytes: 41_000_000, tableBytes: 33_000_000, indexBytes: 8_000_000,
                  rowEstimate: 212_000),
            .init(tableName: "public.metric_samples", totalBytes: 28_000_000, tableBytes: 20_000_000,
                  indexBytes: 8_000_000, rowEstimate: 301_000),
        ],
        checkedAt: now - 5)

    static let retention = WsModel.RetentionStats(
        scope: "system", cleanupStatus: "healthy", trashRetentionDays: 30, syncEventRetentionDays: 14,
        syncEventMaxEntries: 1_000_000, auditLogRetentionDays: 365, cacheExpiryDays: 30, cacheMaxSizeBytes: 10_000_000_000,
        trashedFilesCount: 41, trashedBytesTotal: 2_300_000_000, oldestTrashedAgeSeconds: 1_900_000,
        trashedFilesPastRetentionCount: 0, trashedBytesPastRetention: 0, syncEventsTotal: 840_000,
        syncEventsPastRetentionCount: 0, auditLogEntriesTotal: 212_000, oldestAuditLogAgeSeconds: 24_000_000,
        auditLogEntriesPastRetentionCount: 0, shareAccessEventsTotal: 3_120, oldestShareAccessEventAgeSeconds: 8_000_000,
        cacheEntriesTotal: 9_515, cacheBytesTotal: 3_400_000_000, cacheEvictionCandidates: 0, cacheEntriesExpired: 0,
        checkedAt: now - 5)

    // MARK: Activity

    static let operations = WsModel.OperationStats(
        scope: "system", overallStatus: "info", staleThresholdSeconds: 900, pendingOperations: 2,
        inProgressOperations: 1, failedOperations24h: 1, cancelledOperations24h: 0, stalledOperations: 0,
        oldestPendingOperationAgeSeconds: 42, oldestInProgressOperationAgeSeconds: 18,
        operationsByType: ["upload": 2, "move": 1], operationsByStatus: ["pending": 2, "in_progress": 1, "failed": 1],
        activeShareUploads: 1, stalledShareUploads: 0, failedShareUploads24h: 0,
        uploadBytesExpectedActive: 840_000_000, uploadBytesReceivedActive: 512_000_000,
        oldestActiveUploadAgeSeconds: 96,
        recentOperationErrors: [
            .init(source: "fs", operation: "move", status: "failed", target: "vault 3",
                  path: "/Offsite Backup (preview)/2026/Q3/ledger.xlsx", error: "Upstream returned 503 Slow Down",
                  occurredAt: now - 3_400),
        ],
        checkedAt: now - 5)

    private static func trends(hours: Int64) -> WsModel.StatsTrends {
        let step: Int64 = hours > 24 ? 3_600 : 600
        let count = Int(hours * 3_600 / step)
        func serie(_ key: String, _ label: String, _ unit: String, _ value: (Double) -> Double)
            -> WsModel.StatsTrends.Serie {
            let points = (0..<count).map { index in
                WsModel.StatsTrends.Serie.Point(createdAt: now - Int64(count - index) * step,
                                                value: value(Double(index) / Double(max(count - 1, 1))))
            }
            return .init(key: key, label: label, unit: unit, snapshotType: "system", points: points)
        }
        let wave = { (t: Double, period: Double) in (sin(t * .pi * 2 * period) + 1) / 2 }
        return WsModel.StatsTrends(scope: "system", windowHours: hours, series: [
            serie("fuse_ops_per_second", "FUSE ops/sec", "ops/s") { 40 + 220 * wave($0, 7) },
            serie("fuse_error_rate", "FUSE alertable error rate", "ratio") { $0 > 0.82 ? 0.004 + 0.02 * wave($0, 30) : 0.0004 },
            serie("fuse_expected_error_rate", "FUSE expected error rate", "ratio") { 0.04 + 0.03 * wave($0, 7) },
            serie("fuse_latency_avg_ms", "FUSE latency", "ms") { 0.4 + 1.6 * wave($0, 5) },
            serie("operations_pending", "Pending operations", "count") { (4 * wave($0, 3)).rounded() },
            serie("operations_in_progress", "In-progress operations", "count") { (2 * wave($0, 4)).rounded() },
            serie("threadpool_pressure", "Max thread pool pressure", "ratio") { 0.05 + 0.2 * wave($0, 6) },
            serie("fs_cache_hit_rate", "FS cache hit rate", "ratio") { 0.95 + 0.04 * wave($0, 2) },
            serie("db_cache_hit_ratio", "DB cache hit ratio", "ratio") { 0.99 + 0.009 * wave($0, 3) },
            serie("db_size_bytes", "Database size", "bytes") { 380_000_000 + 32_000_000 * $0 },
            serie("connections_active_ws", "Active sessions", "count") { (3 + 6 * wave($0, 7)).rounded() },
        ], checkedAt: now - 5)
    }
}
#endif
