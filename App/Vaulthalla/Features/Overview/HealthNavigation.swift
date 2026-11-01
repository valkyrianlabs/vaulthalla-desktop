import Foundation
import VHContract

/// The Overview's pages: the summary and the web console's four Health drill-downs.
nonisolated enum HealthPage: String, CaseIterable, Identifiable, Codable, Sendable {
    case summary, runtime, filesystem, storage, activity

    var id: Self { self }

    var title: String {
        switch self {
        case .summary: "Summary"
        case .runtime: "Runtime"
        case .filesystem: "Filesystem"
        case .storage: "Storage"
        case .activity: "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .summary: "gauge.with.dots.needle.67percent"
        case .runtime: "cpu"
        case .filesystem: "folder.badge.gearshape"
        case .storage: "externaldrive"
        case .activity: "chart.xyaxis.line"
        }
    }

    var subtitle: String {
        switch self {
        case .summary: "Health, storage and activity for this node."
        case .runtime: "Services, protocols and dependencies, worker pools and connected sessions."
        case .filesystem: "FUSE operations and their errors, the filesystem cache and the preview cache."
        case .storage: "Vault backends, the database and retention cleanup."
        case .activity: "The operation queue, recent failures and trends over time."
        }
    }

    /// The overview sections whose severity this page shows (`stats.dashboard.overview` section ids).
    var sectionIDs: [String] {
        switch self {
        case .summary: []
        case .runtime: ["runtime"]
        case .filesystem: ["filesystem"]
        case .storage: ["storage"]
        case .activity: ["operations", "trends"]
        }
    }
}

/// A panel on a Health page, named as the daemon's links name it (`/health/filesystem#fuse`).
nonisolated enum HealthAnchor: String, CaseIterable, Sendable {
    case systemHealth = "system-health"
    case threadPools = "thread-pools"
    case connections
    case fuse
    case fsCache = "fs-cache"
    case httpCache = "http-cache"
    case storageBackend = "storage-backend"
    case database
    case retention
    case operationQueue = "operation-queue"
    case trends

    var page: HealthPage {
        switch self {
        case .systemHealth, .threadPools, .connections: .runtime
        case .fuse, .fsCache, .httpCache: .filesystem
        case .storageBackend, .database, .retention: .storage
        case .operationQueue, .trends: .activity
        }
    }

    /// The overview card that reports this panel's severity and issues.
    var cardID: String {
        switch self {
        case .systemHealth: "system.health"
        case .threadPools: "system.threadpools"
        case .connections: "system.connections"
        case .fuse: "system.fuse"
        case .fsCache: "system.fs_cache"
        case .httpCache: "system.http_cache"
        case .storageBackend: "system.storage"
        case .database: "system.db"
        case .retention: "system.retention"
        case .operationQueue: "system.operations"
        case .trends: "system.trends"
        }
    }

    init?(cardID: String) {
        guard let anchor = Self.allCases.first(where: { $0.cardID == cardID }) else { return nil }
        self = anchor
    }
}

/// Where a warning leads: a Health page, scrolled to its panel, with the metric behind it marked; or another section
/// (budget warnings live under Cost). `id` changes on every request, so following the same warning twice scrolls again.
nonisolated struct HealthFocus: Equatable, Sendable {
    var page: HealthPage
    var anchor: HealthAnchor?
    /// The issue's code (`system.fuse.error_rate_elevated`) and the metric it's about (`alertable_error_rate`).
    var code: String?
    var metricKey: String?
    var id = UUID()

    func targets(_ anchor: HealthAnchor) -> Bool { self.anchor == anchor }
}

/// Where a daemon link (`href`) or card leads in Desktop.
nonisolated enum HealthRoute: Equatable {
    case health(HealthPage, HealthAnchor?)
    case section(NodeSection)

    /// The daemon's console routes: `/health`, `/health/<page>#<anchor>`, `/cost#<anchor>`. A card id settles a link
    /// that's missing or unknown to this build.
    init(href: String?, cardID: String? = nil) {
        if let href, let route = Self.parse(href) {
            self = route
        } else if let cardID, let anchor = HealthAnchor(cardID: cardID) {
            self = .health(anchor.page, anchor)
        } else if let cardID, cardID.hasPrefix("system.pricing") {
            self = .section(.cost)
        } else {
            self = .health(.summary, nil)
        }
    }

    private static func parse(_ href: String) -> HealthRoute? {
        let parts = href.split(separator: "#", maxSplits: 1).map(String.init)
        let path = parts.first ?? ""
        let fragment = parts.count > 1 ? parts[1] : nil
        if path == "/cost" || path.hasPrefix("/cost/") { return .section(.cost) }
        guard path == "/health" || path.hasPrefix("/health/") else { return nil }
        let anchor = fragment.flatMap(HealthAnchor.init(rawValue:))
        let pageName = path.dropFirst("/health".count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if pageName.isEmpty { return .health(anchor?.page ?? .summary, anchor) }
        guard let page = HealthPage(rawValue: pageName) else { return nil }
        return .health(page, anchor)
    }
}

extension AppModel {
    /// The focus a followed warning set on `anchor`'s panel, if it points there.
    func healthFocus(on anchor: HealthAnchor) -> HealthFocus? {
        healthFocus.flatMap { $0.targets(anchor) ? $0 : nil }
    }

    /// Shows a Health page of the selected node, optionally scrolled to a panel with a metric marked.
    func openHealth(_ page: HealthPage, anchor: HealthAnchor? = nil, code: String? = nil, metricKey: String? = nil) {
        healthPage = page
        healthFocus = anchor == nil && code == nil ? nil
            : HealthFocus(page: page, anchor: anchor, code: code, metricKey: metricKey)
        select(.overview)
    }

    /// Follows a daemon link: an attention item, a card's issue, a card.
    func openHealth(href: String?, cardID: String?, code: String? = nil, metricKey: String? = nil) {
        switch HealthRoute(href: href, cardID: cardID) {
        case .health(let page, let anchor):
            openHealth(page, anchor: anchor ?? cardID.flatMap(HealthAnchor.init(cardID:)), code: code,
                       metricKey: metricKey)
        case .section(let section):
            select(section)
        }
    }

    func openHealth(_ item: WsModel.DashboardOverview.AttentionItem) {
        openHealth(href: item.href, cardID: item.cardID, code: item.code, metricKey: item.metricKey)
    }

    func openHealth(_ issue: WsModel.DashboardIssueSummary, cardID: String) {
        openHealth(href: issue.href, cardID: cardID, code: issue.code, metricKey: issue.metricKey)
    }
}
