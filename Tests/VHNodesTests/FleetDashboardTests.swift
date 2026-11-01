import Foundation
import Testing
import VHContract
import VHCore
@testable import VHTransport
@testable import VHNodes

/// The All Nodes dashboard's client logic against scripted nodes: each node's digest from its stats answers, the
/// fleet totals, and nodes that load independently (a slow or offline node never holds the others back).
@Suite struct FleetDashboardTests {
    // MARK: Digest

    @Test func healthSortsAlertsBySeverityAndGroupsAreas() {
        let health = NodeDigest.Health(FleetSamples.overview(status: "error", attention: [
            ("system.retention.warning", "warning", "system.retention"),
            ("system.fuse.error_rate_high", "error", "system.fuse"),
            ("system.db.warning", "warning", "system.db"),
        ], cards: [("system.fuse", "error"), ("system.fs_cache", "healthy"), ("system.db", "warning"),
                   ("system.storage", "healthy"), ("system.pricing_budget", "warning")]))

        #expect(health.hasErrors)
        #expect(health.alerts.map(\.code) == ["system.fuse.error_rate_high", "system.retention.warning", "system.db.warning"])
        #expect(health.alerts.map(\.area) == [.fuse, .storage, .database])
        #expect(health.areas == [.fuse: "error", .database: "warning", .storage: "healthy"])
    }

    @Test func storageAddsQuotasOnlyWhenEveryActiveVaultHasOne() {
        let quoted = NodeDigest.Storage(FleetSamples.storage([(1, 400, 1_000, true), (2, 100, 500, true),
                                                              (3, 50, 0, false)]))
        #expect(quoted.usedBytes == 550)
        #expect(quoted.quotaBytes == 1_500)
        #expect(quoted.fractionUsed == 550.0 / 1_500)

        let open = NodeDigest.Storage(FleetSamples.storage([(1, 400, 1_000, true), (2, 100, 0, true)]))
        #expect(open.quotaBytes == nil)
        #expect(open.unlimitedVaultCount == 1)
        #expect(open.fractionUsed == nil)
    }

    @Test func costPrefersTheGlobalMonthlyBudget() {
        let cost = NodeDigest.Cost(FleetSamples.budget(spend: "12.5", windows: [
            ("vault", "monthly", "9", "10", 0.9),
            ("global", "monthly", "12.5", "50", 0.25),
            ("global", "daily", "2", "2", 1.0),
        ]))
        #expect(cost.window?.scope == "global")
        #expect(cost.window?.limit == "50")
        #expect(cost.monthToDate == "12.5")

        let fullest = NodeDigest.Cost(FleetSamples.budget(spend: nil, windows: [
            ("vault", "monthly", "4", "10", 0.4), ("provider", "monthly", "9", "10", 0.9),
        ]))
        #expect(fullest.window?.scope == "provider")

        let untracked = NodeDigest.Cost(FleetSamples.budget(spend: nil, windows: [], policies: 0))
        #expect(!untracked.isTracked)
    }

    @Test func activityRollsUpEveryVaultNewestFirst() {
        let activity = NodeDigest.Activity([
            FleetSamples.activity(vault: 1, uploads: 3, last: 1_000, events: [("upload", 900), ("delete", 1_000)]),
            FleetSamples.activity(vault: 2, uploads: 2, last: 1_500, events: [("rename", 1_500)]),
        ], names: [1: "Photos", 2: "Docs"], asked: 3)

        #expect(activity.uploads24h == 5)
        #expect(activity.lastVault == "Docs")
        #expect(activity.recent.map(\.action) == ["rename", "delete", "upload"])
        #expect(activity.vaultsCounted == 2)
        #expect(activity.vaultsAsked == 3)
    }

    // MARK: Fleet

    @Test func fleetAddsUpOnlyWhatNodesReported() {
        var healthy = NodeDigest()
        healthy.health = .value(NodeDigest.Health(FleetSamples.overview(status: "healthy")))
        healthy.storage = .value(NodeDigest.Storage(FleetSamples.storage([(1, 400, 1_000, true)])))
        healthy.cost = .value(NodeDigest.Cost(FleetSamples.budget(spend: "1.25", windows: [])))
        healthy.conflicts = .value(2)

        var failing = NodeDigest()
        failing.health = .value(NodeDigest.Health(FleetSamples.overview(status: "error", attention: [
            ("system.db.disconnected", "error", "system.db"),
        ])))
        failing.storage = .value(NodeDigest.Storage(FleetSamples.storage([(1, 600, 0, true)])))
        failing.cost = .value(NodeDigest.Cost(FleetSamples.budget(spend: "2.50", windows: [])))

        var denied = NodeDigest()
        denied.health = .denied
        denied.storage = .denied

        let summary = FleetSummary([
            .init(id: NodeID(rawValue: "a"), name: "A", reachability: .online, digest: healthy),
            .init(id: NodeID(rawValue: "b"), name: "B", reachability: .online, digest: failing),
            .init(id: NodeID(rawValue: "c"), name: "C", reachability: .online, digest: denied),
            .init(id: NodeID(rawValue: "d"), name: "D", reachability: .offline, digest: NodeDigest()),
            .init(id: NodeID(rawValue: "e"), name: "E", reachability: .notPaired, digest: NodeDigest()),
        ])

        #expect(summary.nodeCount == 5)
        #expect(summary.onlineCount == 3)
        #expect(summary.unreachableCount == 1)
        #expect(summary.unpairedCount == 1)
        #expect(summary.nodesWithErrors == [NodeID(rawValue: "b")])
        #expect(summary.healthUnknownCount == 1)
        #expect(summary.usedBytes == 1_000)
        #expect(summary.storageReporting == 2)
        #expect(summary.quotaBytes == 1_000)
        #expect(summary.quotaCoverage == 1)
        #expect(summary.openConflicts == 2)
        #expect(summary.monthToDate == ["USD": Decimal(string: "3.75")!])
        #expect(summary.alerts.map(\.nodeName) == ["B"])
        #expect(summary.needsAttention)
    }

    // MARK: Independent loading

    @MainActor @Test func aSlowNodeDoesntHoldBackTheOthers() async throws {
        let fast = FleetSamples.scriptedNode(status: "healthy")
        let slow = FleetSamples.scriptedNode(status: "warning", delay: .seconds(30))
        let fastPulse = NodePulse(queries: NodeQueries(transport: fast))
        let slowPulse = NodePulse(queries: NodeQueries(transport: slow))

        let slowTask = Task { await slowPulse.refresh() }
        defer { slowTask.cancel() }
        await fastPulse.refresh()

        #expect(fastPulse.digest.health.value?.severity == "healthy")
        #expect(fastPulse.digest.storage.value?.usedBytes == 400)
        #expect(fastPulse.digest.activity.value?.uploads24h == 3)
        #expect(slowPulse.digest.health == .loading)
        #expect(slowPulse.isRefreshing)
    }

    @MainActor @Test func anOfflineNodeReportsWhyAndTheRestStillLoad() async throws {
        let online = FleetSamples.scriptedNode(status: "healthy")
        let offline = FleetSamples.scriptedNode(status: "healthy")
        offline.stop()
        let pulses = [NodePulse(queries: NodeQueries(transport: online)),
                      NodePulse(queries: NodeQueries(transport: offline))]

        await withTaskGroup(of: Void.self) { group in
            for pulse in pulses { group.addTask { await pulse.refresh() } }
        }

        #expect(pulses[0].digest.health.value != nil)
        #expect(pulses[1].digest.health == .failed("Not connected."))
        let summary = FleetSummary([
            .init(id: NodeID(rawValue: "on"), name: "On", reachability: .online, digest: pulses[0].digest),
            .init(id: NodeID(rawValue: "off"), name: "Off", reachability: .offline, digest: pulses[1].digest),
        ])
        #expect(summary.usedBytes == 400)
        #expect(summary.unreachableCount == 1)
    }

    @MainActor @Test func withoutStatsAccessActivityComesFromAccessibleVaults() async throws {
        let node = FleetSamples.scriptedNode(status: "healthy")
        let refusal = ScriptedNode.Reply.refuse("Permission denied: this account lacks admin.stats.view.", code: "denied")
        for command in ["stats.dashboard.overview", "stats.system.storage", "stats.pricing.budget"] {
            node.answer(command) { _ in refusal }
        }
        node.answer("storage.vault.accessible.list") { _ in
            .ok(["vaults": [FleetSamples.accessibleVault(id: 7, name: "Mine")]])
        }
        let pulse = NodePulse(queries: NodeQueries(transport: node))
        await pulse.refresh()

        #expect(pulse.digest.health == .denied)
        #expect(pulse.digest.storage == .denied)
        #expect(pulse.digest.activity.value?.lastVault == "Mine")
        #expect(node.payloads(of: "stats.vault.activity") == [["vault_id": 7]])
    }

    @MainActor @Test func activityAsksAtMostTheVaultLimit() async throws {
        let node = FleetSamples.scriptedNode(status: "healthy", vaults: 10)
        let pulse = NodePulse(queries: NodeQueries(transport: node), activityVaultLimit: 4)
        await pulse.refresh()

        #expect(node.count(of: "stats.vault.activity") == 4)
        #expect(pulse.digest.activity.value?.vaultsAsked == 10)
        #expect(pulse.digest.activity.value?.vaultsCounted == 4)
    }
}

/// Stats answers shaped like the contract's models, built from the generated types.
enum FleetSamples {
    static let now: Int64 = 1_790_000_000

    static func json(_ value: some Encodable) -> JSONValue {
        // The models encode to JSON the contract decodes; a failure here is a test bug.
        try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    static func overview(status: String, attention: [(code: String, severity: String, card: String)] = [],
                         cards: [(id: String, severity: String)] = []) -> WsModel.DashboardOverview {
        WsModel.DashboardOverview(
            overallStatus: status,
            warningCount: Int64(attention.filter { $0.severity == "warning" }.count),
            errorCount: Int64(attention.filter { $0.severity == "error" }.count),
            checkedAt: now,
            attention: attention.map {
                .init(code: $0.code, severity: $0.severity, cardID: $0.card, title: $0.card, message: $0.code)
            },
            sections: [],
            cards: cards.map {
                WsModel.DashboardCardSummary(id: $0.id, sectionID: "s", title: $0.id, description: "", href: "",
                                             variant: "visual", size: "2x1", severity: $0.severity, available: true,
                                             summary: "", metrics: [], series: [], warnings: [], errors: [],
                                             checkedAt: now)
            })
    }

    static func storage(_ vaults: [(id: Int64, used: Int64, quota: Int64, active: Bool)]) -> WsModel.StorageBackendStats {
        WsModel.StorageBackendStats(
            overallStatus: "healthy", vaultCountTotal: Int64(vaults.count), localVaultCount: Int64(vaults.count),
            s3VaultCount: 0, activeVaultCount: Int64(vaults.filter(\.active).count),
            inactiveVaultCount: Int64(vaults.filter { !$0.active }.count), degradedVaultCount: 0, errorVaultCount: 0,
            vaults: vaults.map {
                WsModel.StorageVaultBackendStats(vaultID: $0.id, vaultName: "Vault \($0.id)", type: "local",
                                                 active: $0.active, allowFsWrite: true, quotaBytes: $0.quota,
                                                 vaultSizeBytes: $0.used, backendStatus: "healthy")
            },
            checkedAt: now)
    }

    static func budget(spend: String?, windows: [(scope: String, window: String, spent: String, limit: String, used: Double)],
                       policies: Int64 = 1) -> WsModel.PriceBudgetDashboardStats {
        WsModel.PriceBudgetDashboardStats(
            activePolicies: policies, blockedSyncs24h: 0, warningNotifications: 0, criticalNotifications: 0,
            unacknowledgedNotifications: 0, pendingOverrides: 0, currentMonthlySpend: spend,
            projectedMonthlySpend: spend, currency: "USD",
            trends: windows.enumerated().map { index, window in
                WsModel.PriceBudgetTrendStats(
                    scope: window.scope, policyID: Int64(index + 1), currency: "USD", windowType: window.window,
                    windowStart: "2026-11-01 00:00:00+00", windowEnd: "2026-12-01 00:00:00+00", committedCost: window.spent,
                    reservedCost: "0", totalCost: window.spent, limit: window.limit, percentUsed: window.used,
                    confidence: "high", recentDailyAverage: "0", recent7dAverage: "0", recent30dAverage: "0", warnings: [])
            },
            activeNotifications: [], recentOverrides: [])
    }

    static func activity(vault: Int64, uploads: Int64, last: Int64,
                         events: [(action: String, at: Int64)] = []) -> WsModel.VaultActivity {
        WsModel.VaultActivity(
            vaultID: vault, lastActivityAt: last, lastActivityAction: events.last?.action, uploads24h: uploads,
            uploads7d: uploads, deletes24h: 0, deletes7d: 0, renames24h: 0, renames7d: 0, moves24h: 0, moves7d: 0,
            copies24h: 0, copies7d: 0, restores24h: 0, restores7d: 0, bytesAdded24h: uploads * 100, bytesRemoved24h: 0,
            topActiveUsers: [], topTouchedPaths: [],
            recentActivity: events.map {
                .init(source: "fs", action: $0.action, path: "/\($0.action)", userName: "admin", bytes: 1,
                      occurredAt: $0.at)
            },
            checkedAt: now)
    }

    static func accessibleVault(id: Int64, name: String) -> JSONValue {
        [
            "id": .integer(id), "name": .string(name), "slug": .string(name.lowercased()),
            "effective_fuse_name": .string(name.lowercased()), "type": "local", "description": "", "quota": 0,
            "owner_id": 1, "owner": "admin", "is_active": true, "created_at": "2026-10-20T12:00:00Z", "browse": true,
            "manage": false, "via": ["owner"],
        ]
    }

    /// A node that answers every dashboard read: one healthy 400-byte vault (or `vaults` of them), three uploads.
    static func scriptedNode(status: String, delay: Duration? = nil, vaults: Int = 1) -> ScriptedNode {
        let node = ScriptedNode()
        node.answer("stats.dashboard.overview", after: delay) { _ in .ok(["stats": json(overview(status: status))]) }
        node.answer("stats.system.storage", after: delay) { _ in
            .ok(["stats": json(storage((1...vaults).map { (Int64($0), 400 / Int64(vaults), 0, true) }))])
        }
        node.answer("stats.pricing.budget", after: delay) { _ in
            .ok(["stats": json(budget(spend: nil, windows: [], policies: 0))])
        }
        node.answer("sync.conflicts.summary", after: delay) { _ in .ok(["total": 0, "vaults": []]) }
        node.answer("stats.vault.activity", after: delay) { payload in
            guard case .object(let fields) = payload, case .integer(let id)? = fields["vault_id"] else {
                return .refuse("bad payload", code: "invalid")
            }
            return .ok(["stats": json(activity(vault: id, uploads: 3, last: now, events: [("upload", now)]))])
        }
        return node
    }
}

extension FleetDashboardTests {
    /// Observing loads every part once even while the app is inactive (a window in the background), like a query's
    /// first fetch; only the polling waits for the app.
    @MainActor @Test func observingLoadsOnceWhileInactive() async throws {
        let node = FleetSamples.scriptedNode(status: "healthy")
        let queries = NodeQueries(transport: node)
        queries.isActive = false
        let pulse = NodePulse(queries: queries)
        let observing = Task { await pulse.observe() }
        defer { observing.cancel() }

        let deadline = ContinuousClock.now + .seconds(3)
        while pulse.digest.activity.value == nil || pulse.digest.health.value == nil {
            guard ContinuousClock.now < deadline else { throw TestFailure("pulse didn't load while inactive") }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(node.count(of: "stats.vault.activity") == 1)
    }
}
