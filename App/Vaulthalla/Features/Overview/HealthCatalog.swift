import VHContract

/// Which of a card's metrics the overview shows first, ported from the web console's catalog
/// (web/src/features/health/catalog.ts). Ordering only: every value, tone and severity comes from
/// `stats.dashboard.overview`.
enum HealthCatalog {
    /// The card the overview's header summarizes.
    static let heroCardID = "system.health"
    /// Sections the overview doesn't lay out (trend samples have no tiles of their own).
    static let hiddenSections: Set<String> = ["trends"]

    private static let priority: [String: [String]] = [
        "system.threadpools": ["pressure", "queue", "saturated", "pressured", "workers", "busy", "idle", "pools"],
        "system.connections": ["sessions", "unauthenticated", "share_pending", "human", "share", "oldest_session"],
        "system.fuse": ["alertable_error_rate", "ops", "avg_latency", "open_handles", "alertable_errors", "max_latency"],
        "system.fs_cache": ["hit_rate", "requests", "used", "evictions", "occupancy", "hits", "misses"],
        "system.http_cache": ["hit_rate", "requests", "used", "evictions", "occupancy", "hits", "misses"],
        "system.storage": ["vaults", "problem", "backend_errors", "degraded", "inactive", "healthy", "local", "s3"],
        "system.db": ["cache_hit", "connections", "size", "oldest_tx", "idle_tx_connections", "deadlocks"],
        "system.retention": ["overdue", "trash", "trash_bytes", "sync_backlog", "audit_backlog", "cache_expired"],
        "system.operations": ["pending", "in_progress", "stalled", "failed_24h", "active_uploads", "stalled_uploads"],
        "system.trends": ["latest_sample_age", "coverage", "window", "points"],
        "system.pricing_budget": ["monthly_spend", "projected_monthly", "active_policies", "blocked_syncs", "warnings"],
        "system.pricing_providers": ["aws-s3_current", "aws-s3_projected", "cloudflare-r2_current",
                                     "cloudflare-r2_projected", "provider_policies"],
        "system.pricing_vaults": ["top_spend", "top_vault", "tracked_vaults", "projected_overage_vaults"],
        "system.pricing_alerts": ["unacknowledged", "critical", "warnings", "active_alerts"],
        "system.pricing_catalog": ["catalog_issues", "stale", "unverified", "unsupported"],
        "system.pricing_overrides": ["blocked_syncs", "pending", "approved", "denied", "used"],
    ]

    /// Metrics that say nothing at 0, shown only when nothing better fills the slots.
    private static let quietWhenZero: [String: Set<String>] = [
        "system.threadpools": ["saturated", "pressured", "busy", "stopped", "degraded"],
        "system.connections": ["share_pending"],
        "system.db": ["idle_tx_connections", "deadlocks"],
    ]

    /// Up to `limit` metrics: the catalog's priority first, then the daemon's order; quiet zeros and unmeasured
    /// values last.
    static func metrics(of card: WsModel.DashboardCardSummary, limit: Int = 4) -> [WsModel.DashboardMetricSummary] {
        let order = priority[card.id] ?? []
        let quiet = quietWhenZero[card.id] ?? []
        let rank = { (metric: WsModel.DashboardMetricSummary) -> Int in
            order.firstIndex(of: metric.key) ?? order.count
        }
        let isQuiet = { (metric: WsModel.DashboardMetricSummary) -> Bool in
            metric.display == nil || (quiet.contains(metric.key) && metric.numericValue == 0)
        }
        let sorted = card.metrics.enumerated().sorted { lhs, rhs in
            let (left, right) = (lhs.element, rhs.element)
            if isQuiet(left) != isQuiet(right) { return !isQuiet(left) }
            if rank(left) != rank(right) { return rank(left) < rank(right) }
            return lhs.offset < rhs.offset
        }
        return sorted.prefix(limit).map(\.element)
    }
}
