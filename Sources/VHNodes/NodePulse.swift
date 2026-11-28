public import Foundation
public import Observation
public import VHContract
public import VHTransport

/// One node's figures for the All Nodes dashboard (``NodeDigest``), kept fresh on the node's own ``NodeQueries``.
///
/// Each node has its own pulse and its own transport, and every part loads on its own: a slow answer delays only
/// that part of that node, and an offline node only stops its own refreshes. The health, storage, budget and
/// conflict reads are the same queries the node's sections show, so opening a node shows them at once. Activity
/// fans out over the node's vaults (``activityVaultLimit`` at most), since the daemon has no node-wide activity
/// command.
@MainActor
@Observable
public final class NodePulse {
    public struct Intervals: Sendable {
        public var health: Duration = .seconds(30)
        public var figures: Duration = .seconds(60)
        public var activity: Duration = .seconds(60)

        public init() {}
    }

    public nonisolated let intervals: Intervals
    /// Vaults asked for activity, at most: the rest are left out of the rollup (``NodeDigest/Activity/vaultsAsked``).
    public nonisolated let activityVaultLimit: Int
    @ObservationIgnored public let queries: NodeQueries

    public let overview: NodeQuery<Ws.Stats.Dashboard.Overview>
    /// The overview's four headline numbers on their own: what the background check asks (``checkHealth()``).
    public let severity: NodeQuery<Ws.Stats.Dashboard.Severity>
    public let storage: NodeQuery<Ws.Stats.System.Storage>
    public let budget: NodeQuery<Ws.Stats.Pricing.Budget>
    public let conflicts: NodeQuery<Ws.Sync.Conflicts.Summary>
    /// The findings with their state (`health.findings.list`), on a node that has the command: the background check
    /// asks it instead of the four numbers, since it carries them too.
    public let findings: NodeQuery<Ws.Health.Findings.List>

    public private(set) var activity: NodeDigest.Part<NodeDigest.Activity> = .loading
    public private(set) var isFetchingActivity = false
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    /// The headline numbers the overview on hand was fetched for, and how many checks ago it was fetched.
    @ObservationIgnored private var checkedMark: HealthMark?
    @ObservationIgnored private var checksSinceOverview = 0
    /// A full overview at least every this many checks: the numbers can stay the same while the findings change.
    public nonisolated let fullCheckEvery: Int

    private struct HealthMark: Equatable {
        var status: String
        var errors: Int64
        var warnings: Int64
    }

    public init(queries: NodeQueries, intervals: Intervals = Intervals(), activityVaultLimit: Int = 24,
                fullCheckEvery: Int = 5) {
        self.queries = queries
        self.intervals = intervals
        self.activityVaultLimit = activityVaultLimit
        self.fullCheckEvery = max(1, fullCheckEvery)
        overview = queries.query(Ws.Stats.Dashboard.Overview.self, .init())
        severity = queries.query(Ws.Stats.Dashboard.Severity.self)
        storage = queries.query(Ws.Stats.System.Storage.self)
        budget = queries.query(Ws.Stats.Pricing.Budget.self, .init())
        conflicts = queries.query(Ws.Sync.Conflicts.Summary.self)
        findings = queries.healthFindings()
    }

    /// The node's findings as last reported, when it has the command; nil otherwise (older Vaulthalla, no answer).
    public var healthFindings: HealthFindings? {
        guard queries.hasHealthFindings, let value = findings.value else { return nil }
        return HealthFindings(value.health)
    }

    /// The node's figures as they stand.
    public var digest: NodeDigest {
        NodeDigest(
            health: .init(overview.value.map { NodeDigest.Health($0.stats, findings: healthFindings) },
                          error: overview.error),
            storage: .init(storage.value.map { NodeDigest.Storage($0.stats) }, error: storage.error),
            cost: .init(budget.value.map { NodeDigest.Cost($0.stats) }, error: budget.error),
            conflicts: .init(conflicts.value?.total, error: conflicts.error),
            activity: activity)
    }

    /// Whether anything is being fetched right now.
    public var isRefreshing: Bool {
        overview.isFetching || storage.isFetching || budget.isFetching || conflicts.isFetching || isFetchingActivity
    }

    /// When the health figures were taken, the dashboard's "checked" time.
    public var updatedAt: Date? { overview.updatedAt ?? storage.updatedAt }

    /// Keeps every part fresh while the calling task runs (a view's `.task`): each part polls on its own schedule
    /// while the app is active. Returns when cancelled.
    public func observe() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.overview.observe(polling: self.intervals.health) }
            group.addTask { await self.storage.observe(polling: self.intervals.figures) }
            group.addTask { await self.budget.observe(polling: self.intervals.figures) }
            group.addTask { await self.conflicts.observe(polling: self.intervals.figures) }
            group.addTask { await self.pollActivity() }
            if queries.hasHealthFindings {
                group.addTask { await self.findings.observe(polling: self.intervals.health) }
            }
        }
    }

    /// Fetches every part now (⌘R), each on its own: returns once all have settled.
    public func refresh() async {
        async let health: Void = overview.refresh()
        async let figures: Void = storage.refresh()
        async let spend: Void = budget.refresh()
        async let open: Void = conflicts.refresh()
        async let marked: Void = refreshFindings()
        _ = await (health, figures, spend, open, marked)
        await refreshActivity()
    }

    // MARK: Background check

    /// The check that runs with no window open (docs/mac-experience.md §3): asks the node for its four headline
    /// numbers, and fetches the whole overview only when they differ from the ones the overview on hand was fetched
    /// for (or there is none, or it is ``fullCheckEvery`` checks old). A node without the small command is asked for
    /// the overview each time. Returns once settled; never polls on its own.
    public func checkHealth() async {
        guard queries.isConnected else { return }
        if queries.hasHealthFindings {
            await findings.refresh()
            if findings.error == nil, let now = findings.value?.health {
                await refreshOverviewIfChanged(HealthMark(status: now.overallStatus, errors: now.errorCount,
                                                          warnings: now.warningCount))
                return
            }
            // Refused or unanswered: the four numbers decide, as on a node without the command.
        }
        if queries.supports(command: .statsDashboardSeverity) == .no {
            await overview.refresh()
            return
        }
        await severity.refresh()
        guard severity.error == nil, let now = severity.value?.stats else {
            if case .denied? = severity.error {
                // No stats access: the overview says so once, and the node is left in peace.
                if overview.value == nil, overview.error == nil { await overview.refresh() }
            } else {
                // The small question went unanswered (an older node, a slow one): ask for the whole picture instead.
                await overview.refresh()
            }
            return
        }
        await refreshOverviewIfChanged(HealthMark(status: now.overallStatus, errors: now.errorCount,
                                                  warnings: now.warningCount))
    }

    private func refreshOverviewIfChanged(_ mark: HealthMark) async {
        checksSinceOverview += 1
        guard mark != checkedMark || overview.value == nil || checksSinceOverview >= fullCheckEvery else { return }
        await overview.refresh()
        if overview.refreshError == nil, overview.value != nil {
            checkedMark = mark
            checksSinceOverview = 0
        }
    }

    /// The slow figures (storage, spend, open conflicts), fetched now. The background check calls it every few minutes.
    public func refreshFigures() async {
        guard queries.isConnected else { return }
        async let figures: Void = storage.refresh()
        async let spend: Void = budget.refresh()
        async let open: Void = conflicts.refresh()
        _ = await (figures, spend, open)
    }

    // MARK: Findings

    private func refreshFindings() async {
        guard queries.hasHealthFindings else { return }
        await findings.refresh()
    }

    /// Runs a person's action on a finding (``NodeQueries/perform(_:findingClass:subject:)``) and shows its answer
    /// at once. Returns why the node refused, nil on success.
    public func perform(_ action: HealthFindingAction, findingClass: String, subject: String = "") async -> WsError? {
        switch await queries.perform(action, findingClass: findingClass, subject: subject) {
        case .success(let health):
            findings.seed(.init(health: health))
            return nil
        case .failure(let error):
            return error
        }
    }

    // MARK: Activity

    /// Loads once when first observed (like a query's first fetch), then polls while the app is active and connected.
    private func pollActivity() async {
        var loaded = activity != .loading
        while !Task.isCancelled {
            if !loaded || (queries.isActive && queries.isConnected) {
                await refreshActivity()
                loaded = true
            }
            do { try await Task.sleep(for: intervals.activity) } catch { return }
        }
    }

    /// Asks each vault for its activity (four at a time) and rolls the answers up. Joins a rollup already under way.
    public func refreshActivity() async {
        if let activityTask { return await activityTask.value }
        let task = Task { await self.loadActivity() }
        activityTask = task
        await task.value
        activityTask = nil
    }

    private func loadActivity() async {
        isFetchingActivity = true
        defer { isFetchingActivity = false }
        if queries.supports(command: .statsVaultActivity) == .no {
            activity = .unsupported
            return
        }
        guard let vaults = await vaultsForActivity() else { return }
        let asked = Array(vaults.prefix(activityVaultLimit))
        let names = Dictionary(asked.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let transport = queries.transport
        var answers: [WsModel.VaultActivity] = []
        var errors: [WsError] = []
        await withTaskGroup(of: Result<WsModel.VaultActivity?, WsError>.self) { group in
            var next = asked.makeIterator()
            func start() {
                guard let vault = next.next() else { return }
                group.addTask {
                    do throws(WsError) {
                        let response = try await transport.send(Ws.Stats.Vault.Activity.self, payload: .init(vaultID: vault.id))
                        return .success(response.stats)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for _ in 0..<4 { start() }
            for await result in group {
                switch result {
                case .success(let stats): if let stats { answers.append(stats) }
                case .failure(let error): errors.append(error)
                }
                start()
            }
        }
        if answers.isEmpty, let error = errors.first, errors.count == asked.count {
            // Every vault refused the same way: say why, but keep an earlier rollup through a lost connection.
            let part = NodeDigest.Part<NodeDigest.Activity>(error)
            if case .failed = part, activity.value != nil { return }
            activity = part
            return
        }
        activity = .value(NodeDigest.Activity(answers, names: names, asked: vaults.count))
    }

    /// The vaults to ask: those `stats.system.storage` lists, or for an account without stats access, the vaults it
    /// can reach (`storage.vault.accessible.list`). nil while neither has answered; the part then says why.
    private func vaultsForActivity() async -> [NodeDigest.Storage.VaultRef]? {
        if storage.value == nil, storage.error == nil { await storage.refresh() }
        if let stats = storage.value?.stats {
            return NodeDigest.Storage(stats).vaults
        }
        let accessible = queries.query(Ws.Storage.Vault.Accessible.List.self)
        if accessible.value == nil { await accessible.refresh() }
        if let vaults = accessible.value?.vaults {
            return vaults.map { NodeDigest.Storage.VaultRef(id: $0.id, name: $0.name) }
        }
        if let error = accessible.error ?? storage.error {
            if case .value = activity, case .failed = NodeDigest.Part<NodeDigest.Activity>(error) { return nil }
            activity = .init(error)
        }
        return nil
    }
}
