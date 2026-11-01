public import Foundation
public import VHContract
import VHTransport

/// What the All Nodes dashboard shows for one node, distilled from the node's own stats answers
/// (`stats.dashboard.overview`, `stats.system.storage`, `stats.pricing.budget`, `sync.conflicts.summary` and each
/// vault's `stats.vault.activity`). Every severity is the daemon's; a part the node didn't answer is a ``Part`` that
/// says why, never a zero or a healthy default.
public struct NodeDigest: Sendable, Hashable {
    public var health: Part<Health>
    public var storage: Part<Storage>
    public var cost: Part<Cost>
    public var conflicts: Part<Int64>
    public var activity: Part<Activity>

    public init(health: Part<Health> = .loading, storage: Part<Storage> = .loading, cost: Part<Cost> = .loading,
                conflicts: Part<Int64> = .loading, activity: Part<Activity> = .loading) {
        self.health = health
        self.storage = storage
        self.cost = cost
        self.conflicts = conflicts
        self.activity = activity
    }

    /// One figure of the digest: still coming, there, or why not.
    public enum Part<Value: Sendable & Hashable>: Sendable, Hashable {
        case loading
        case value(Value)
        /// RBAC said no (the account lacks `admin.stats.view`, or owns no vault): calm, not an error.
        case denied
        /// The node's Vaulthalla doesn't have the command.
        case unsupported
        case failed(String)

        public var value: Value? {
            if case .value(let value) = self { return value }
            return nil
        }

        init(_ value: Value?, error: WsError?) {
            if let value {
                self = .value(value)
            } else if let error {
                self = Self(error)
            } else {
                self = .loading
            }
        }

        init(_ error: WsError) {
            switch error {
            case .denied: self = .denied
            case .unknownCommand: self = .unsupported
            case .disconnected, .cancelled: self = .failed("Not connected.")
            case .timeout: self = .failed("No answer yet.")
            case .contractMismatch: self = .failed("Not readable by this version.")
            case .protocolUnsupported(let mismatch): self = .failed(mismatch.message)
            case .unauthorized(let message), .notFound(let message), .invalid(let message), .conflict(let message),
                 .error(let message), .needsConfirmation(_, let message), .refused(_, let message):
                self = .failed(message)
            }
        }
    }

    // MARK: Health

    /// The overview's overall status and what needs attention, in the daemon's order of importance.
    public struct Health: Sendable, Hashable {
        public var severity: String
        public var errorCount: Int64
        public var warningCount: Int64
        public var checkedAt: Date
        /// Every attention item, most severe first (errors, warnings, unknown, info), then the daemon's order.
        public var alerts: [Alert]
        /// Each area's worst severity on the node's cards (FUSE, database, storage, sync), for the at-a-glance row.
        public var areas: [Area: String]

        public init(_ overview: WsModel.DashboardOverview) {
            severity = overview.overallStatus
            errorCount = overview.errorCount
            warningCount = overview.warningCount
            checkedAt = Date(timeIntervalSince1970: TimeInterval(overview.checkedAt))
            alerts = overview.attention.enumerated()
                .sorted { lhs, rhs in
                    let (left, right) = (SeverityRank.of(lhs.element.severity), SeverityRank.of(rhs.element.severity))
                    return left != right ? left < right : lhs.offset < rhs.offset
                }
                .map { Alert($0.element) }
            var areas: [Area: String] = [:]
            for card in overview.cards {
                let area = Area(cardID: card.id)
                guard Area.watched.contains(area) else { continue }
                if let current = areas[area], SeverityRank.of(current) <= SeverityRank.of(card.severity) { continue }
                areas[area] = card.severity
            }
            self.areas = areas
        }

        /// Whether the daemon reports errors (a red node).
        public var hasErrors: Bool { errorCount > 0 || SeverityRank.of(severity) == 0 }
        public var hasWarnings: Bool { warningCount > 0 || SeverityRank.of(severity) == 1 }
    }

    /// One attention item of the overview, with the area it belongs to.
    public struct Alert: Sendable, Hashable, Identifiable {
        public var code: String
        public var severity: String
        public var cardID: String
        public var title: String
        public var message: String
        public var area: Area

        public var id: String { "\(cardID)|\(code)" }

        public init(code: String, severity: String, cardID: String, title: String, message: String) {
            self.code = code
            self.severity = severity
            self.cardID = cardID
            self.title = title
            self.message = message
            area = Area(cardID: cardID, code: code)
        }

        init(_ item: WsModel.DashboardOverview.AttentionItem) {
            self.init(code: item.code, severity: item.severity, cardID: item.cardID, title: item.title,
                      message: item.message)
        }
    }

    /// Where an alert or card belongs, by its card id (`system.fuse`, `system.pricing_budget`).
    public enum Area: String, Sendable, Hashable, CaseIterable {
        case fuse, database, storage, sync, cost, runtime, operations, other

        /// The areas the dashboard shows a dot for on every node.
        public static let watched: [Area] = [.fuse, .database, .storage, .sync]

        public init(cardID: String, code: String = "") {
            let id = cardID.hasPrefix("system.") ? String(cardID.dropFirst(7)) : cardID
            switch id {
            case "fuse", "fs_cache": self = .fuse
            case "db": self = .database
            case "storage", "http_cache": self = .storage
            case "retention": self = code.contains("sync") ? .sync : .storage
            case "operations": self = .operations
            case "health", "threadpools", "connections", "trends": self = .runtime
            case _ where id.hasPrefix("pricing"): self = .cost
            case _ where id.hasPrefix("sync"): self = .sync
            default: self = .other
            }
        }

        public var title: String {
            switch self {
            case .fuse: "FUSE"
            case .database: "Database"
            case .storage: "Storage"
            case .sync: "Sync"
            case .cost: "Cost"
            case .runtime: "Runtime"
            case .operations: "Operations"
            case .other: "Other"
            }
        }
    }

    // MARK: Storage

    /// The node's vaults and what they hold (`stats.system.storage`).
    public struct Storage: Sendable, Hashable {
        public var vaultCount: Int
        public var activeVaultCount: Int
        public var degradedVaultCount: Int
        public var errorVaultCount: Int
        /// What every vault holds, summed over the vaults that reported a size.
        public var usedBytes: Int64
        /// The sum of the quotas, when every active vault has one; nil when any can grow to its disk.
        public var quotaBytes: Int64?
        /// Active vaults without a quota.
        public var unlimitedVaultCount: Int
        /// The vaults, for the activity fan-out.
        public var vaults: [VaultRef]

        public struct VaultRef: Sendable, Hashable {
            public var id: Int64
            public var name: String
        }

        public init(_ stats: WsModel.StorageBackendStats) {
            vaultCount = Int(stats.vaultCountTotal)
            activeVaultCount = Int(stats.activeVaultCount)
            degradedVaultCount = Int(stats.degradedVaultCount)
            errorVaultCount = Int(stats.errorVaultCount)
            usedBytes = stats.vaults.reduce(0) { $0 + ($1.vaultSizeBytes ?? 0) }
            let active = stats.vaults.filter(\.active)
            unlimitedVaultCount = active.filter { $0.quotaBytes == 0 }.count
            quotaBytes = active.isEmpty || unlimitedVaultCount > 0 ? nil : active.reduce(0) { $0 + $1.quotaBytes }
            vaults = stats.vaults.map { VaultRef(id: $0.vaultID, name: $0.vaultName) }
        }

        /// How full the quotas are, when every vault has one.
        public var fractionUsed: Double? {
            guard let quotaBytes, quotaBytes > 0 else { return nil }
            return Double(usedBytes) / Double(quotaBytes)
        }
    }

    // MARK: Cost

    /// S3 spend this month against the node's budgets (`stats.pricing.budget`, system-wide). Amounts stay decimal
    /// strings until shown; nil means not estimated (no monthly budget yet), never zero.
    public struct Cost: Sendable, Hashable {
        public var currency: String
        public var monthToDate: String?
        public var projectedMonth: String?
        /// The budget window to measure spend against: the global monthly budget, else the fullest monthly one, else
        /// the fullest of any window with a limit.
        public var window: Window?
        public var blockedSyncs24h: Int64
        public var criticalAlerts: Int64
        public var warningAlerts: Int64
        public var activeBudgets: Int64

        public struct Window: Sendable, Hashable {
            public var scope: String
            public var windowType: String
            public var spent: String
            public var limit: String
            public var fractionUsed: Double
        }

        public init(_ stats: WsModel.PriceBudgetDashboardStats) {
            currency = stats.currency
            monthToDate = stats.currentMonthlySpend
            projectedMonth = stats.projectedMonthlySpend
            blockedSyncs24h = stats.blockedSyncs24h
            criticalAlerts = stats.criticalNotifications
            warningAlerts = stats.warningNotifications
            activeBudgets = stats.activePolicies
            let limited = stats.trends.filter { $0.limit != nil }
            let monthly = limited.filter { $0.windowType == WsModel.PriceBudgetTrendStats.WindowType.monthly }
            let pick = monthly.first { $0.scope == WsModel.PriceBudgetPolicy.Scope.global }
                ?? monthly.max { $0.percentUsed < $1.percentUsed }
                ?? limited.max { $0.percentUsed < $1.percentUsed }
            window = pick.flatMap { trend in
                trend.limit.map {
                    Window(scope: trend.scope, windowType: trend.windowType, spent: trend.totalCost, limit: $0,
                           fractionUsed: trend.percentUsed)
                }
            }
        }

        /// Whether there's anything to say: a node without S3 budgets reports no spend and no windows.
        public var isTracked: Bool { activeBudgets > 0 || monthToDate != nil || window != nil }
    }

    // MARK: Activity

    /// The node's recent activity, rolled up from each vault's `stats.vault.activity`: the node has no node-wide
    /// activity command, so Desktop asks per vault.
    public struct Activity: Sendable, Hashable {
        public var lastActivityAt: Date?
        public var lastAction: String?
        public var lastVault: String?
        public var uploads24h: Int64 = 0
        public var deletes24h: Int64 = 0
        /// Renames, moves, copies and restores in the last 24 hours.
        public var otherChanges24h: Int64 = 0
        public var bytesAdded24h: Int64 = 0
        public var bytesRemoved24h: Int64 = 0
        /// The latest events across the node's vaults, newest first.
        public var recent: [Event] = []
        /// Vaults whose activity is counted, and how many were asked.
        public var vaultsCounted = 0
        public var vaultsAsked = 0

        public struct Event: Sendable, Hashable {
            public var vault: String
            public var action: String
            public var path: String
            public var user: String?
            public var bytes: Int64
            public var at: Date
            public var failed: Bool
        }

        public init() {}

        /// Rolls up the vaults' answers; `names` labels each vault id. `asked` counts every vault asked, including
        /// those that refused or haven't answered.
        public init(_ answers: [WsModel.VaultActivity], names: [Int64: String], asked: Int, recentLimit: Int = 6) {
            let names = names.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            vaultsAsked = asked
            vaultsCounted = answers.count
            var latest: (at: Int64, action: String?, vault: Int64)?
            var events: [Event] = []
            for answer in answers {
                uploads24h += answer.uploads24h
                deletes24h += answer.deletes24h
                otherChanges24h += answer.renames24h + answer.moves24h + answer.copies24h + answer.restores24h
                bytesAdded24h += answer.bytesAdded24h
                bytesRemoved24h += answer.bytesRemoved24h
                if let at = answer.lastActivityAt, at > (latest?.at ?? -1) {
                    latest = (at, answer.lastActivityAction, answer.vaultID)
                }
                let name = names[answer.vaultID] ?? "Vault \(answer.vaultID)"
                for item in answer.recentActivity {
                    events.append(Event(vault: name, action: item.action, path: item.path, user: item.userName,
                                        bytes: item.bytes, at: Date(timeIntervalSince1970: TimeInterval(item.occurredAt)),
                                        failed: item.error != nil || item.status.map(Self.isFailure) == true))
                }
            }
            if let latest {
                lastActivityAt = Date(timeIntervalSince1970: TimeInterval(latest.at))
                lastAction = latest.action
                lastVault = names[latest.vault] ?? "Vault \(latest.vault)"
            }
            recent = Array(events.sorted { $0.at > $1.at }.prefix(recentLimit))
        }

        public var changes24h: Int64 { uploads24h + deletes24h + otherChanges24h }

        private static func isFailure(_ status: String) -> Bool {
            ["error", "failed", "failure"].contains(status.lowercased())
        }
    }
}

/// The daemon's severities in order of importance, shared by the digest and the fleet summary.
public enum SeverityRank {
    /// 0 error, 1 warning, 2 unknown (anything unrecognized), 3 info, 4 healthy.
    public static func of(_ severity: String) -> Int {
        switch severity.lowercased() {
        case "error", "critical", "failed", "failing", "saturated", "stalled", "overdue": 0
        case "warning", "warn", "degraded", "pressured", "stale": 1
        case "info", "syncing", "success": 3
        case "healthy", "ok", "normal", "ready", "idle": 4
        default: 2
        }
    }
}
