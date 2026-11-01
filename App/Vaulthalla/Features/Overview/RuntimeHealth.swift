import SwiftUI
import VHContract
import VHCore
import VHNodes

/// The web console's Health → Runtime: services, protocols, dependencies, the database pool and the S3 gateway; the
/// worker pools; the connected sessions.
struct RuntimeHealthPage: View {
    var queries: NodeQueries
    var overview: WsModel.DashboardOverview?

    var body: some View {
        let health = queries.query(Ws.Stats.System.Health.self)
        let pools = queries.query(Ws.Stats.System.Threadpools.self)
        let connections = queries.query(Ws.Stats.System.Connections.self)
        VStack(alignment: .leading, spacing: Theme.stackSpacing) {
            HealthDetailSection(anchor: .systemHealth, title: "System health", overview: overview, query: health,
                                subject: "system health") { response in
                SystemHealthBody(stats: response.stats)
            }
            AdaptiveColumns(weights: [1.25, 1], minColumnWidth: 520, spacing: Theme.stackSpacing) {
                HealthDetailSection(anchor: .threadPools, title: "Thread pools", overview: overview, query: pools,
                                    subject: "thread pools") { response in
                    ThreadPoolsBody(stats: response.stats)
                }
                HealthDetailSection(anchor: .connections, title: "Connections", overview: overview, query: connections,
                                    subject: "connections") { response in
                    ConnectionsBody(stats: response.stats)
                }
            }
        }
        .observing(health, polling: HealthPolling.detail)
        .observing(pools, polling: HealthPolling.detail)
        .observing(connections, polling: HealthPolling.detail)
    }
}

// MARK: - System health

private struct SystemHealthBody: View {
    var stats: WsModel.SystemHealth

    @Environment(AppModel.self) private var model

    private static let dependencies: [(KeyPath<WsModel.SystemHealth.Deps, Bool>, String)] = [
        (\.storageManager, "Storage manager"),
        (\.apiKeyManager, "Provider credentials"),
        (\.authManager, "Auth manager"),
        (\.sessionManager, "Session manager"),
        (\.secretsManager, "Secrets manager"),
        (\.syncController, "Sync controller"),
        (\.fsCache, "FS cache"),
        (\.shellUsageManager, "Shell usage"),
        (\.httpCacheStats, "HTTP cache stats"),
    ]

    var body: some View {
        let focus = model.healthTarget(on: .systemHealth)
        let summary = stats.summary
        VStack(alignment: .leading, spacing: 20) {
            StatGrid(minimum: 160, uniformHeight: true) {
                StatTile(label: "Services running", value: "\(summary.servicesReady)/\(summary.servicesTotal)",
                         tone: summary.servicesReady < summary.servicesTotal ? .warn : nil)
                StatTile(label: "Protocols ready", value: "\(summary.protocolsReady)/\(summary.protocolsTotal)",
                         tone: summary.protocolsReady < summary.protocolsTotal ? .warn : nil)
                StatTile(label: "Dependencies ready", value: "\(summary.depsReady)/\(summary.depsTotal)",
                         tone: summary.depsReady < summary.depsTotal ? .warn : nil)
                StatTile(label: "CLI shell admin",
                         value: stats.shell.adminUidBound.map { $0 ? "Bound" : "Not configured" })
            }

            if !stats.vaultsUnavailable.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SubHeading("Vaults not available")
                    ForEach(stats.vaultsUnavailable, id: \.vaultID) { vault in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(StatusTone.warn.color)
                            Text("\(Text(vault.vaultName).fontWeight(.medium).foregroundStyle(Color.fg))  "
                                 + "\(Format.words(vault.reason))\(vault.detail.isEmpty ? "" : ": \(vault.detail)")")
                                .foregroundStyle(.fgMuted)
                        }
                        .font(.callout)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SubHeading("Runtime services")
                FactGrid(facts: stats.runtime.services.map { service in
                    FactGrid.Fact(label: service.entryName.isEmpty ? service.serviceName : service.entryName,
                                  value: service.interrupted ? false : service.running, yes: "Running",
                                  no: service.interrupted ? "Interrupted" : "Stopped",
                                  highlighted: focus != nil && (!service.running || service.interrupted))
                }, minimum: 220)
            }

            AdaptiveColumns(minColumnWidth: 340, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    SubHeading("Protocols")
                    FactGrid(facts: [
                        .init(label: "Protocol service", value: stats.protocols.running, yes: "Running", no: "Stopped"),
                        .init(label: "I/O context", value: stats.protocols.ioContextInitialized, yes: "Initialized",
                              no: "Not initialized"),
                        .init(label: "WebSocket",
                              value: stats.protocols.websocketConfigured ? stats.protocols.websocketReady : nil),
                        .init(label: "HTTP preview",
                              value: stats.protocols.httpPreviewConfigured ? stats.protocols.httpPreviewReady : nil),
                    ], minimum: 220)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SubHeading("Dependencies")
                    FactGrid(facts: dependencyFacts(focus), minimum: 220)
                }
            }

            if let db = stats.database {
                VStack(alignment: .leading, spacing: 8) {
                    SubHeading("Database pool")
                    StatGrid(minimum: 140, uniformHeight: true) {
                        StatTile(label: "Reachable", value: db.reachable ? "Yes" : "No", tone: db.reachable ? nil : .danger)
                        StatTile(label: "In use / pool", value: "\(db.inUse) / \(db.poolSize)")
                        StatTile(label: "Idle", value: Format.count(db.idle))
                        StatTile(label: "Probe latency", value: "\(db.probeLatencyMs) ms")
                        StatTile(label: "Acquire timeouts", value: Format.count(db.acquireTimeouts))
                        StatTile(label: "Broken idle", value: Format.count(db.brokenIdle))
                        StatTile(label: "Reconnects", value: Format.count(db.reconnects))
                        StatTile(label: "Reconnect failures", value: Format.count(db.reconnectFailures),
                                 hint: db.consecutiveReconnectFailures > 0 ? "\(db.consecutiveReconnectFailures) in a row" : nil)
                    }
                    if let error = db.probeError, !error.isEmpty {
                        Text(error)
                            .font(.caption).fontDesign(.monospaced).foregroundStyle(.fgMuted)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
                    }
                }
            }

            if stats.s3Gateway.configured {
                let gateway = stats.s3Gateway
                VStack(alignment: .leading, spacing: 8) {
                    SubHeading("S3 gateway")
                    StatGrid(minimum: 140, uniformHeight: true) {
                        StatTile(label: "State", value: gateway.ready ? "Ready" : gateway.running ? "Running" : "Stopped",
                                 tone: gateway.ready ? nil : .warn)
                        StatTile(label: "Listening on", value: "\(gateway.host):\(gateway.port)")
                        StatTile(label: "Active sessions", value: Format.count(gateway.activeSessions))
                        StatTile(label: "Requests", value: Format.count(gateway.totalRequests))
                        StatTile(label: "Failed requests", value: Format.count(gateway.failedRequests))
                    }
                }
            }
        }
    }

    private func dependencyFacts(_ focus: HealthFocus?) -> [FactGrid.Fact] {
        let deps = stats.deps
        var facts = Self.dependencies.map { path, label in
            FactGrid.Fact(label: label, value: deps[keyPath: path], highlighted: focus != nil && !deps[keyPath: path])
        }
        if deps.fuseMount != "disabled" {
            facts.append(.init(label: "FUSE session", value: deps.fuseSession, yes: "Present", no: "Missing",
                               highlighted: focus?.metricKey == "fuse" && !deps.fuseSession))
        }
        facts.append(.init(label: "Filesystem mount", statement: Self.mountSummary(deps)))
        if !deps.secretsBackend.isEmpty {
            facts.append(.init(label: "Secrets backend", statement: deps.secretsBackend == "file"
                ? "file (development, no hardware binding)" : deps.secretsBackend))
        }
        return facts
    }

    /// The configured mode next to what the mount is (the web console's `mountSummary`).
    private static func mountSummary(_ deps: WsModel.SystemHealth.Deps) -> String {
        if deps.fuseMount == "disabled" { return deps.mountDetail.map { "Disabled — \($0)" } ?? "Disabled" }
        if deps.mountState.isEmpty { return deps.fuseMount }
        if deps.mountState == "mounted" {
            return "\(deps.fuseMount): mounted" + (deps.mountIsolation.isEmpty ? "" : " (isolation \(deps.mountIsolation))")
        }
        return "\(deps.fuseMount): \(deps.mountState.replacingOccurrences(of: "_", with: " "))"
            + (deps.mountDetail.map { " — \($0)" } ?? "")
    }
}

// MARK: - Thread pools

private struct ThreadPoolsBody: View {
    var stats: WsModel.ThreadPoolManagerSnapshot

    @Environment(AppModel.self) private var model
    @State private var sort: DataSort? = DataSort(column: "pressure", ascending: false)
    @State private var selection: String?

    var body: some View {
        let focus = model.healthTarget(on: .threadPools)
        VStack(alignment: .leading, spacing: 16) {
            StatGrid(minimum: 120, uniformHeight: true) {
                StatTile(label: "Workers", value: Format.count(stats.totalWorkerCount),
                         hint: "\(Format.count(stats.totalIdleWorkerCount)) idle")
                StatTile(label: "Queued tasks", value: Format.count(stats.totalQueueDepth))
                StatTile(label: "Max pressure", value: Self.ratio(stats.maxPressureRatio), hint: "queued work per worker",
                         highlighted: focus?.metricKey == "pressure")
                StatTile(label: "Pressured", value: Format.count(stats.pressuredPoolCount),
                         tone: stats.pressuredPoolCount > 0 ? .warn : nil)
                StatTile(label: "Saturated", value: Format.count(stats.saturatedPoolCount),
                         tone: stats.saturatedPoolCount > 0 ? .danger : nil)
            }
            DataTable(rows: stats.pools, id: \.name, columns: Self.columns, sort: $sort, selection: $selection,
                      tone: { pool in
                          let tone = StatusTone(severity: pool.stopped ? "error" : pool.status)
                          return tone == .warn || tone == .danger ? tone : nil
                      },
                      help: Self.describe, copyText: Self.describe, empty: "No thread pools reported.")
        }
    }

    private static func ratio(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + "×"
    }

    static func describe(_ pool: WsModel.ThreadPoolSnapshot) -> String {
        "\(pool.name): \(pool.stopped ? "stopped" : pool.status) — \(pool.busyWorkerCount) busy, "
            + "\(pool.idleWorkerCount) idle of \(pool.workerCount), \(pool.queueDepth) queued, pressure \(ratio(pool.pressureRatio))"
    }

    @MainActor private static let columns: [DataColumn<WsModel.ThreadPoolSnapshot>] = [
        DataColumn("name", "Pool", width: .flexible(min: 90, weight: 1.4), sortKey: { .text($0.name) }) { pool in
            Text(pool.name).fontWeight(.medium).foregroundStyle(.fg)
        },
        DataColumn("status", "Status", width: .flexible(min: 90), sortKey: { .text($0.status) }) { pool in
            HStack(spacing: 6) {
                StatusDot(tone: StatusTone(severity: pool.stopped ? "error" : pool.status), size: 6)
                Text(pool.stopped ? "Stopped" : Format.words(pool.status)).foregroundStyle(.fgMuted)
            }
        },
        DataColumn("workers", "Workers", width: .flexible(min: 64), alignment: .trailing, hideBelow: 420,
                   sortKey: { .number(Double($0.workerCount)) }) { pool in
            Text(Format.count(pool.workerCount)).monospacedDigit().foregroundStyle(.fgMuted)
        },
        DataColumn("busy", "Busy", width: .flexible(min: 52), alignment: .trailing, hideBelow: 420,
                   sortKey: { .number(Double($0.busyWorkerCount)) }) { pool in
            Text(Format.count(pool.busyWorkerCount)).monospacedDigit().foregroundStyle(.fgMuted)
        },
        DataColumn("queue", "Queue", width: .flexible(min: 56), alignment: .trailing,
                   sortKey: { .number(Double($0.queueDepth)) }) { pool in
            Text(Format.count(pool.queueDepth)).monospacedDigit().foregroundStyle(pool.queueDepth > 0 ? .fg : .fgFaint)
        },
        DataColumn("pressure", "Pressure", width: .flexible(min: 70), alignment: .trailing,
                   sortKey: { .number($0.pressureRatio) }) { pool in
            Text(ratio(pool.pressureRatio)).monospacedDigit().foregroundStyle(.fg)
        },
    ]
}

// MARK: - Connections

private struct ConnectionsBody: View {
    var stats: WsModel.ConnectionStats

    @Environment(AppModel.self) private var model

    var body: some View {
        let focus = model.healthTarget(on: .connections)
        VStack(alignment: .leading, spacing: 16) {
            DonutChart(
                parts: [
                    .init(label: "Human", value: Double(stats.activeHumanSessions), color: .accentFill),
                    .init(label: "Share", value: Double(stats.activeShareSessions), color: StatusTone.info.color),
                    .init(label: "Share pending", value: Double(stats.activeSharePendingSessions),
                          color: StatusTone.ok.color.opacity(0.7)),
                    .init(label: "Unauthenticated", value: Double(stats.activeUnauthenticatedSessions),
                          color: StatusTone.warn.color),
                ],
                center: Format.count(stats.activeWsSessionsTotal), caption: "sessions",
                label: "Websocket sessions by kind")
            StatGrid(minimum: 140, uniformHeight: true) {
                StatTile(label: "Oldest session", value: stats.oldestSessionAgeSeconds.map { Format.duration(seconds: $0) })
                StatTile(label: "Oldest unauthenticated",
                         value: stats.activeUnauthenticatedSessions == 0 ? "none"
                            : stats.oldestUnauthenticatedSessionAgeSeconds.map { Format.duration(seconds: $0) },
                         highlighted: focus?.metricKey == "unauthenticated")
                StatTile(label: "Idle timeout", value: Format.duration(seconds: stats.idleTimeoutMinutes * 60))
                StatTile(label: "Unauthenticated timeout", value: Format.duration(seconds: stats.unauthenticatedTimeoutSeconds))
                StatTile(label: "Sweep interval", value: Format.duration(seconds: stats.sweepIntervalSeconds))
                StatTile(label: "Errors (24 h)", value: stats.connectionErrors24h.map(Format.count))
            }
        }
    }
}
