public import Foundation
public import Observation
public import VHContract
import VHTransport

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
    public let storage: NodeQuery<Ws.Stats.System.Storage>
    public let budget: NodeQuery<Ws.Stats.Pricing.Budget>
    public let conflicts: NodeQuery<Ws.Sync.Conflicts.Summary>

    public private(set) var activity: NodeDigest.Part<NodeDigest.Activity> = .loading
    public private(set) var isFetchingActivity = false
    @ObservationIgnored private var activityTask: Task<Void, Never>?

    public init(queries: NodeQueries, intervals: Intervals = Intervals(), activityVaultLimit: Int = 24) {
        self.queries = queries
        self.intervals = intervals
        self.activityVaultLimit = activityVaultLimit
        overview = queries.query(Ws.Stats.Dashboard.Overview.self, .init())
        storage = queries.query(Ws.Stats.System.Storage.self)
        budget = queries.query(Ws.Stats.Pricing.Budget.self, .init())
        conflicts = queries.query(Ws.Sync.Conflicts.Summary.self)
    }

    /// The node's figures as they stand.
    public var digest: NodeDigest {
        NodeDigest(
            health: .init(overview.value.map { NodeDigest.Health($0.stats) }, error: overview.error),
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
        }
    }

    /// Fetches every part now (⌘R), each on its own: returns once all have settled.
    public func refresh() async {
        async let health: Void = overview.refresh()
        async let figures: Void = storage.refresh()
        async let spend: Void = budget.refresh()
        async let open: Void = conflicts.refresh()
        _ = await (health, figures, spend, open)
        await refreshActivity()
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
