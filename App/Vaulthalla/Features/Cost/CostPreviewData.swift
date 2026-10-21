#if DEBUG
import Foundation
import Synchronization
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: price budgets, spend windows, cost alerts and overrides for the preview nodes. The full
/// scenario is a super admin's view; the restricted one gets the daemon's refusal of the system-wide view.
nonisolated enum CostPreviewData: PreviewFeature {
    private struct State {
        var policies = CostPreviewData.policies
        var notifications = CostPreviewData.notifications
        var overrides = CostPreviewData.overrides
        var nextPolicyID: Int64 = 10
    }

    private static let state = Mutex(State())

    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        let full = transport.scenario == .full
        switch command {
        case .pricingBudgetStatus:
            guard full else {
                throw .denied("system-wide price budget status is for super admins; name a vault or a credential you own")
            }
            return state.withLock { state in
                Ws.Pricing.Budget.Status.Response(
                    policies: state.policies, ledger: Array(ledger.prefix(20)), trends: trends(state.policies),
                    notifications: state.notifications.filter { $0.acknowledgedAt == nil }, overrides: state.overrides)
            }
        case .statsPricingBudget:
            guard full else { throw .denied("Permission denied: this account lacks admin.stats.view.") }
            return state.withLock { state in
                let open = state.notifications.filter { $0.acknowledgedAt == nil }
                return Ws.Stats.Pricing.Budget.Response(stats: WsModel.PriceBudgetDashboardStats(
                    activePolicies: Int64(state.policies.filter(\.isActive).count), blockedSyncs24h: 1,
                    warningNotifications: Int64(open.filter { $0.severity == "warning" }.count),
                    criticalNotifications: Int64(open.filter { $0.severity == "critical" }.count),
                    unacknowledgedNotifications: Int64(open.count),
                    pendingOverrides: Int64(state.overrides.filter { $0.status == "requested" }.count),
                    currentMonthlySpend: "18.42310000", projectedMonthlySpend: nil, currency: "USD",
                    trends: trends(state.policies), activeNotifications: open, recentOverrides: state.overrides))
            }
        case .pricingNotificationsList:
            let request = payload as? Ws.Pricing.Notifications.List.Payload
            return state.withLock { state in
                // Others see the alerts of vaults they may view: none, in the restricted scenario.
                let visible = full ? state.notifications : []
                let open = visible.filter { $0.acknowledgedAt == nil }
                let rows = (request?.includeAcknowledged == true ? visible : open).prefix(Int(request?.limit ?? 50))
                let worst = open.map(\.severity).max { rank($0) < rank($1) }
                return Ws.Pricing.Notifications.List.Response(
                    notifications: Array(rows),
                    summary: .init(openCount: Int64(open.count), worstSeverity: worst))
            }
        case .pricingNotificationsAck:
            guard let ack = payload as? Ws.Pricing.Notifications.Ack.Payload else { throw .invalid("Bad payload.") }
            return try state.withLock { state throws(WsError) in
                guard let index = state.notifications.firstIndex(where: { $0.id == ack.notificationID }) else {
                    throw .notFound("No such alert.")
                }
                state.notifications[index].acknowledgedAt = "2026-10-20 12:00:00+00"
                state.notifications[index].acknowledgedBy = 1
                return Ws.Pricing.Notifications.Ack.Response(notification: state.notifications[index])
            }
        case .pricingBudgetLedgerList:
            guard full else { throw .denied("name a vault you can view to see its price budget ledger") }
            return Ws.Pricing.Budget.Ledger.List.Response(ledger: ledger)
        case .pricingBudgetPolicyUpsert:
            guard let upsert = payload as? Ws.Pricing.Budget.Policy.Upsert.Payload else { throw .invalid("Bad payload.") }
            return state.withLock { state in
                let vaultID = upsert.vaultID?.wrapped
                let provider = upsert.providerKey?.wrapped
                let id = state.policies.first {
                    $0.scope == upsert.scope.rawValue && $0.vaultID == vaultID && $0.providerKey == provider
                }?.id ?? state.nextPolicyID
                state.nextPolicyID += 1
                let policy = WsModel.PriceBudgetPolicy(
                    id: id, scope: upsert.scope.rawValue, providerKey: provider, vaultID: vaultID,
                    mode: upsert.mode?.wrapped?.rawValue ?? "report", currency: upsert.currency?.wrapped ?? "USD",
                    maxRunCost: upsert.maxRunCost?.wrapped, maxDailyCost: upsert.maxDailyCost?.wrapped,
                    maxMonthlyCost: upsert.maxMonthlyCost?.wrapped,
                    requireVerifiedCatalog: upsert.requireVerifiedCatalog ?? true,
                    allowStaleCatalog: upsert.allowStaleCatalog ?? false,
                    maxCatalogAgeSeconds: upsert.maxCatalogAgeSeconds?.wrapped, isActive: true)
                state.policies.removeAll { $0.id == id }
                state.policies.append(policy)
                return Ws.Pricing.Budget.Policy.Upsert.Response(policy: policy)
            }
        case .pricingBudgetPolicyDisable:
            guard let disable = payload as? Ws.Pricing.Budget.Policy.Disable.Payload else { throw .invalid("Bad payload.") }
            return state.withLock { state in
                var disabled = false
                for index in state.policies.indices where state.policies[index].scope == disable.scope.rawValue
                    && state.policies[index].vaultID == disable.vaultID?.wrapped
                    && state.policies[index].providerKey == disable.providerKey?.wrapped && state.policies[index].isActive {
                    state.policies[index].isActive = false
                    disabled = true
                }
                return Ws.Pricing.Budget.Policy.Disable.Response(disabled: disabled)
            }
        case .pricingBudgetOverrideApprove, .pricingBudgetOverrideDeny:
            let approving = command == .pricingBudgetOverrideApprove
            let id = approving ? (payload as? Ws.Pricing.Budget.Override.Approve.Payload)?.overrideID
                : (payload as? Ws.Pricing.Budget.Override.Deny.Payload)?.overrideID
            return try state.withLock { state throws(WsError) -> Any in
                guard let index = state.overrides.firstIndex(where: { $0.id == id }) else { throw .notFound("No such override.") }
                state.overrides[index].status = approving ? "approved" : "denied"
                state.overrides[index].decidedAt = "2026-10-20 12:00:00+00"
                let item = state.overrides[index]
                return approving ? Ws.Pricing.Budget.Override.Approve.Response(override: item) as Any
                    : Ws.Pricing.Budget.Override.Deny.Response(override: item) as Any
            }
        case .recoveryCosts:
            guard let vaultID = (payload as? Ws.Recovery.Costs.Payload)?.vaultID else { throw .invalid("Bad payload.") }
            return Ws.Recovery.Costs.Response(costs: recoveryCosts(vaultID))
        default:
            return nil
        }
    }

    private static func rank(_ severity: String) -> Int {
        ["info", "warning", "error", "critical"].firstIndex(of: severity) ?? -1
    }

    // MARK: Canned rows

    static let policies: [WsModel.PriceBudgetPolicy] = [
        policy(1, "global", mode: "warn", monthly: "50.00000000"),
        policy(2, "provider", provider: "aws-s3", mode: "report", monthly: nil),
        policy(3, "vault", vault: 3, mode: "enforce", run: "2.00000000", daily: "5.00000000", monthly: "25.00000000"),
    ]

    private static func policy(_ id: Int64, _ scope: String, provider: String? = nil, vault: Int64? = nil,
                               mode: String, run: String? = nil, daily: String? = nil,
                               monthly: String?) -> WsModel.PriceBudgetPolicy {
        WsModel.PriceBudgetPolicy(
            id: id, scope: scope, providerKey: provider, vaultID: vault, mode: mode, currency: "USD",
            maxRunCost: run, maxDailyCost: daily, maxMonthlyCost: monthly, requireVerifiedCatalog: true,
            allowStaleCatalog: false, maxCatalogAgeSeconds: 43_200, isActive: true)
    }

    /// The windows of the active policies with a limit. Projections only where enough spend was recorded.
    private static func trends(_ policies: [WsModel.PriceBudgetPolicy]) -> [WsModel.PriceBudgetTrendStats] {
        var rows: [WsModel.PriceBudgetTrendStats] = []
        for policy in policies where policy.isActive {
            if let limit = policy.maxMonthlyCost {
                let vault = policy.vaultID != nil
                rows.append(trend(policy, window: "monthly", total: vault ? "21.80000000" : "18.42310000", limit: limit,
                                  used: vault ? 0.872 : 0.368, projected: vault ? "31.40000000" : nil,
                                  overage: vault ? "6.40000000" : nil, exhaustion: vault ? "2026-10-24 09:00:00+00" : nil,
                                  confidence: vault ? "high" : "none"))
            }
            if let limit = policy.maxDailyCost {
                rows.append(trend(policy, window: "daily", total: "1.12000000", limit: limit, used: 0.224,
                                  projected: "2.10000000", overage: nil, exhaustion: nil, confidence: "medium"))
            }
        }
        return rows
    }

    private static func trend(_ policy: WsModel.PriceBudgetPolicy, window: String, total: String, limit: String,
                              used: Double, projected: String?, overage: String?, exhaustion: String?,
                              confidence: String) -> WsModel.PriceBudgetTrendStats {
        WsModel.PriceBudgetTrendStats(
            scope: policy.scope, providerKey: policy.providerKey, vaultID: policy.vaultID, policyID: policy.id,
            currency: policy.currency, windowType: window, windowStart: "2026-10-01 00:00:00+00",
            windowEnd: "2026-11-01 00:00:00+00", committedCost: total, reservedCost: "0.00000000", totalCost: total,
            limit: limit, remaining: nil, percentUsed: used, projectedWindowCost: projected, projectedOverage: overage,
            predictedExhaustionAt: exhaustion, confidence: confidence, recentDailyAverage: "0.95000000",
            recent7dAverage: "0.95000000", recent30dAverage: "0.61000000", warnings: [])
    }

    static let notifications: [WsModel.PriceBudgetNotification] = [
        notification(41, "warning", "Vault budget at 87%",
                     "Offsite Backup (preview) has used 87% of its monthly budget; it is projected to run out on Oct 24.",
                     vault: 3, at: "2026-10-20 08:12:00+00"),
        notification(40, "error", "Sync blocked by budget",
                     "A sync of Offsite Backup (preview) would exceed its $2.00 per-run limit and was stalled.",
                     vault: 3, at: "2026-10-19 22:40:00+00"),
        notification(37, "info", "Price catalog refreshed", "AWS S3 prices were verified (catalog 2026-10-18).",
                     vault: nil, at: "2026-10-18 06:00:00+00", acknowledged: true),
    ]

    private static func notification(_ id: Int64, _ severity: String, _ title: String, _ message: String,
                                     vault: Int64?, at: String, acknowledged: Bool = false)
        -> WsModel.PriceBudgetNotification
    {
        WsModel.PriceBudgetNotification(
            id: id, type: "price_budget", severity: severity, title: title, message: message,
            scope: vault == nil ? "global" : "vault", vaultID: vault, providerKey: vault == nil ? "aws-s3" : nil,
            policyID: 3, metadata: [:], acknowledgedAt: acknowledged ? "2026-10-18 07:00:00+00" : nil,
            acknowledgedBy: acknowledged ? 1 : nil, createdAt: at)
    }

    static let overrides: [WsModel.PriceBudgetOverride] = [
        WsModel.PriceBudgetOverride(
            id: 7, runUUID: "run-7", vaultID: 3, requestedBy: 2, status: "requested",
            reason: "Initial upload of the 2025 archive", scope: "single_run", policyIDs: [3],
            estimatedCost: "3.40000000", currency: "USD", expiresAt: "2026-10-20 14:00:00+00",
            createdAt: "2026-10-20 09:30:00+00"),
        WsModel.PriceBudgetOverride(
            id: 5, runUUID: "run-5", vaultID: 4, requestedBy: 2, approvedBy: 1, status: "used", reason: nil,
            scope: "single_run", policyIDs: [1], estimatedCost: nil, currency: "USD",
            expiresAt: "2026-10-12 14:00:00+00", createdAt: "2026-10-12 13:00:00+00",
            decidedAt: "2026-10-12 13:05:00+00", usedAt: "2026-10-12 13:20:00+00"),
    ]

    static let ledger: [WsModel.PriceBudgetLedgerEntry] = (0..<12).map { index in
        let committed = index % 4 != 0
        return WsModel.PriceBudgetLedgerEntry(
            id: Int64(100 - index), policyID: 3, runUUID: "run-\(100 - index)", vaultID: index % 3 == 0 ? 4 : 3,
            operation: "sync", estimatedCost: "0.\(40 + index)000000", usageSource: committed ? "measured" : "estimate",
            synthetic: false, providerKey: "aws-s3", currency: "USD", window: index % 2 == 0 ? "monthly" : "daily",
            windowStart: "2026-10-01 00:00:00+00", windowEnd: "2026-11-01 00:00:00+00",
            reservedCost: "0.\(50 + index)000000", committedCost: committed ? "0.\(38 + index)120000" : nil,
            status: committed ? "committed" : "reserved", createdAt: "2026-10-\(20 - index / 2) 0\(index % 10):15:00+00")
    }

    // MARK: Provider versioning

    private static func recoveryCosts(_ vaultID: Int64) -> WsModel.RecoveryCostReport {
        let active = vaultID == 3
        func figure(_ amount: String?, _ low: String? = nil, _ high: String? = nil, basis: String = "observed",
                    reason: String? = nil) -> WsModel.RecoveryCostFigure {
            WsModel.RecoveryCostFigure(expected: amount.map { .init(amount: $0, currency: "USD") },
                                       low: low.map { .init(amount: $0, currency: "USD") },
                                       high: high.map { .init(amount: $0, currency: "USD") }, basis: basis, reason: reason)
        }
        let unknown = figure(nil, basis: "scenario", reason: "fewer than 7 measured days")
        return WsModel.RecoveryCostReport(
            vaultID: vaultID, phase: active ? "active" : "pre_activation", priced: true, provider: "aws-s3",
            bucket: vaultID == 3 ? "vh-offsite-backup" : "media-archive", region: "us-east-1",
            storageClass: "STANDARD", currency: "USD",
            catalog: .init(version: "2026-10-18", source: "price-bot", verified: true, stale: false, ageSeconds: 7200),
            confidence: active ? "medium" : "low", confidenceReasons: [],
            observation: .init(windowDays: active ? 21 : 4, sufficient: active, putRequests: 12_400, copyRequests: 0,
                               deleteRequests: 310, getRequests: 4_100, listRequests: 220, firstPutObjects: 9_000,
                               overwriteObjects: 3_400, deletedObjects: 310, overwrittenBytes: 4_100_000_000,
                               deletedBytes: 380_000_000, uploadedBytes: 61_000_000_000, overwrittenBytesPerDay: "195238095"),
            current: .init(objects: 19_700, bytes: 61_200_000_000, monthlyStorage: .init(amount: "1.40760000", currency: "USD")),
            history: .init(knownNoncurrentVersions: active ? 3_710 : 0, knownNoncurrentBytes: active ? 4_480_000_000 : 0,
                           deleteMarkers: active ? 310 : 0, unknownSizeVersions: 0, unaccountedHistory: false),
            preActivationMonthly: active ? unknown : figure("0.42000000", "0.21000000", "0.88000000", basis: "scenario"),
            currentMonthToDate: active ? figure("0.07300000") : unknown,
            currentMonthProjected: active ? figure("0.11000000", "0.09000000", "0.15000000") : unknown,
            projectedMonthly: active ? figure("0.13000000", "0.10000000", "0.19000000") : unknown,
            accumulation: [], scenarios: [], recoveryPerGb: figure("0.09000000", basis: "illustrative"),
            recoveryPerObject: figure("0.00000040", basis: "illustrative"), unmodeled: [], assumptions: [],
            retention: "30d", alert: .init(threshold: nil, exceeded: false), computedAt: "2026-10-20T08:00:00Z")
    }
}
#endif
