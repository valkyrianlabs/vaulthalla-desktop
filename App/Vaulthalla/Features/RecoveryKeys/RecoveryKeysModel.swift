import AppKit
import Foundation
import Observation
import VHContract
import VHCore
import VHKeyBackup
import VHNodes
import VHOnePassword
import VHTransport

/// Recovery Keys across every paired node (docs/architecture.md §6): each node's `vault.keys.status`, 1Password's
/// item metadata (never keys), the rows the screens show, sync runs, change detection and its notification.
///
/// - Node statuses are polled every 5 minutes while the app is active, when it becomes active, when a screen opens
///   and after a sync. Polling is cheap and never touches 1Password.
/// - 1Password is read (account check, vault, `items.list`) when Recovery Keys is opened or synced, not in the
///   background: reading it may ask for Touch ID. Until then each vault's status rests on the node's own record of
///   confirmed backups. Only item metadata is kept, in memory.
/// - Keys exist only inside a sync or restore call (`VHKeyBackup`), never here.
@MainActor
@Observable
final class RecoveryKeysModel {
    /// One node's answer to `vault.keys.status`.
    enum NodeKeys {
        case loading
        case loaded([WsModel.VaultKeyStatus], at: Date)
        /// The latest poll failed; `last` is what it said before, shown as unknown.
        case failed(WsError, last: [WsModel.VaultKeyStatus]?)
    }

    /// Why a node has no rows to show.
    enum NodeProblem: Equatable {
        /// The daemon predates key backup (no `vault.keys.status`).
        case unsupported
        /// The account this Mac acts for may not inspect vault keys there.
        case denied(String)
        case offline
        case failed(String)
    }

    enum OnePasswordState {
        /// No account set in Settings → 1Password.
        case notConfigured
        /// Configured; not read since launch (statuses come from the nodes' records).
        case notChecked
        case checking
        case ready(vault: OnePasswordVault, items: [BackupItem], at: Date)
        case failed(message: String)
    }

    // MARK: State

    private(set) var nodeKeys: [NodeID: NodeKeys] = [:]
    private(set) var onePassword: OnePasswordState = .notConfigured
    /// The sync in progress or last finished, shown in the progress sheet.
    var run: KeySyncRun?
    private(set) var lastPoll: Date?

    var settings: OnePasswordSettings {
        didSet {
            guard settings != oldValue, persists else { return }
            Self.defaults.set(settings.account, forKey: Keys.account)
            Self.defaults.set(settings.vaultTitle, forKey: Keys.vaultTitle)
            onePassword = settings.isConfigured ? .notChecked : .notConfigured
        }
    }

    /// The user opted in to "N vault keys need backup" notifications.
    var notificationsEnabled: Bool {
        didSet { if persists { Self.defaults.set(notificationsEnabled, forKey: Keys.notify) } }
    }

    @ObservationIgnored weak var app: AppModel?
    /// False for PREVIEW DATA: settings changes aren't saved.
    @ObservationIgnored private var persists = true
    @ObservationIgnored private var storeOverride: (any KeyBackupStore)?
    @ObservationIgnored private var helper: OnePasswordHelper?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var appActive = true
    @ObservationIgnored let notifier = RecoveryKeysNotifier()

    static let pollInterval: Duration = .seconds(300)

    private enum Keys {
        static let account = "recoveryKeys.onePasswordAccount"
        static let vaultTitle = "recoveryKeys.onePasswordVault"
        static let notify = "recoveryKeys.notify"
    }

    private static var defaults: UserDefaults { .standard }

    init(store: (any KeyBackupStore)? = nil) {
        let defaults = Self.defaults
        settings = OnePasswordSettings(
            account: defaults.string(forKey: Keys.account) ?? "",
            vaultTitle: defaults.string(forKey: Keys.vaultTitle) ?? OnePasswordSettings.defaultVaultTitle)
        notificationsEnabled = defaults.bool(forKey: Keys.notify)
        storeOverride = store
        onePassword = settings.isConfigured ? .notChecked : .notConfigured
    }

    /// The store backups go to: the bundled helper, launched on first use (or PREVIEW DATA's stand-in).
    var store: any KeyBackupStore {
        if let storeOverride { return storeOverride }
        if let helper { return helper }
        let made = OnePasswordHelper(configuration: .bundled())
        helper = made
        return made
    }

    // MARK: Lifecycle

    /// Starts change detection: a poll now and every 5 minutes while the app is active.
    func start() {
        guard pollTask == nil else { return }
        notifier.onOpen = { [weak self] in self?.app?.showAllRecoveryKeys() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.appActive { await self.pollNodes() }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func appActivityChanged(_ active: Bool) {
        let wasActive = appActive
        appActive = active
        // On activation: poll again unless a poll just ran.
        if active, !wasActive, (lastPoll.map { Date.now.timeIntervalSince($0) > 30 } ?? true) {
            Task { await pollNodes() }
        }
    }

    // MARK: Nodes

    /// Paired nodes with a live (or preview) connection, as key backup addresses them.
    var connectedNodes: [KeyBackupNode] {
        guard let app else { return [] }
        return app.nodes.compactMap { node in
            guard app.status(for: node) == .online, let transport = app.keyTransport(for: node.id) else { return nil }
            return KeyBackupNode(node: node, transport: transport)
        }
    }

    /// Every paired node, connected or not (offline ones show their last known vaults as unknown).
    var pairedNodes: [Node] {
        app?.nodes.filter { $0.pairing.isPaired } ?? []
    }

    /// Asks every connected node for its key status.
    func pollNodes() async {
        lastPoll = .now
        await withTaskGroup(of: (NodeID, Result<[WsModel.VaultKeyStatus], WsError>).self) { group in
            for node in connectedNodes {
                if nodeKeys[node.id] == nil { nodeKeys[node.id] = .loading }
                let transport = node.transport
                let id = node.id
                group.addTask {
                    do throws(WsError) {
                        return (id, .success(try await VaultKeyCommands(transport).status()))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let statuses): nodeKeys[id] = .loaded(statuses, at: .now)
                case .failure(let error): nodeKeys[id] = .failed(error, last: lastStatuses(id))
                }
            }
        }
        await notifyIfNeeded()
    }

    private func lastStatuses(_ id: NodeID) -> [WsModel.VaultKeyStatus]? {
        switch nodeKeys[id] {
        case .loaded(let statuses, _): statuses
        case .failed(_, let last): last
        default: nil
        }
    }

    func problem(for node: Node) -> NodeProblem? {
        guard let app else { return nil }
        if app.status(for: node) != .online {
            return lastStatuses(node.id) == nil ? .offline : nil
        }
        guard case .failed(let error, _) = nodeKeys[node.id] else { return nil }
        if KeyBackupWords.unsupported(error) { return .unsupported }
        switch error {
        case .denied(let message): return .denied(message)
        case .disconnected, .cancelled: return .offline
        default: return .failed(KeyBackupWords.node(error))
        }
    }

    func isLoading(_ node: Node) -> Bool {
        if case .loading = nodeKeys[node.id] { return true }
        return false
    }

    // MARK: Rows

    var items: [BackupItem]? {
        if case .ready(_, let items, _) = onePassword { return items }
        return nil
    }

    /// The table: every vault of `nodes` (all paired nodes when nil). Nodes that are offline, or whose latest poll
    /// failed, show their last known vaults as unknown, never as backed up.
    func rows(for nodes: [Node]? = nil) -> [VaultKeyRow] {
        guard let app else { return [] }
        let items = items
        return (nodes ?? pairedNodes).flatMap { node -> [VaultKeyRow] in
            let target = KeyBackupNode(node: node, transport: app.keyTransport(for: node.id) ?? OfflineTransport())
            switch nodeKeys[node.id] {
            case .loaded(let statuses, _) where app.status(for: node) == .online:
                return VaultKeyRows.rows(node: target, statuses: statuses, items: items)
            case .loaded(let statuses, _), .failed(_, .some(let statuses)):
                return VaultKeyRows.rows(node: target, statuses: statuses, items: items).map(\.asUnknown)
            default:
                return []
            }
        }
    }

    func attentionCount(for node: Node? = nil) -> Int {
        rows(for: node.map { [$0] }).filter(\.needsAttention).count
    }

    // MARK: 1Password

    /// Connects to the account, finds or creates the vault, and reads every item's metadata.
    @discardableResult
    func refreshOnePassword() async -> Bool {
        guard settings.isConfigured else {
            onePassword = .notConfigured
            return false
        }
        if case .checking = onePassword { return false }
        onePassword = .checking
        let sync = KeyBackupSync(store: store, settings: settings)
        do {
            let vault = try await sync.prepare()
            let items = try await sync.items(in: vault)
            onePassword = .ready(vault: vault, items: items, at: .now)
            return true
        } catch {
            onePassword = .failed(message: KeyBackupWords.onePassword(error))
            return false
        }
    }

    var onePasswordVault: OnePasswordVault? {
        if case .ready(let vault, _, _) = onePassword { return vault }
        return nil
    }

    /// Settings → 1Password's "Check": connects to `account` (Touch ID may be asked) without changing anything.
    func checkAccount(_ account: String) async -> AccountCheck {
        do {
            let status = try await store.checkAccount(account)
            return .connected(vaultCount: status.vaultCount)
        } catch let error as OnePasswordHelperError {
            if case .refused(let code, let message, let hint, _) = error {
                return .failed(code: code.rawValue, message: message.capitalizedFirst, hint: hint)
            }
            return .failed(code: nil, message: KeyBackupWords.onePassword(error), hint: nil)
        } catch {
            return .failed(code: nil, message: error.localizedDescription, hint: nil)
        }
    }

    enum AccountCheck: Equatable {
        case connected(vaultCount: Int)
        case failed(code: String?, message: String, hint: String?)
    }

    // MARK: Sync

    /// Backs up `rows` (every row that wants it when nil). `force` backs them up again even when they are backed up
    /// (to refresh attestations). Progress goes to ``run``.
    func sync(_ selected: [VaultKeyRow]? = nil, force: Bool = false, title: String = "Back up vault keys") {
        guard run?.isRunning != true else { return }
        let run = KeySyncRun(title: title)
        self.run = run
        guard settings.isConfigured else {
            run.fail("Choose your 1Password account in Settings → 1Password first.")
            return
        }
        Task {
            await pollNodes()
            guard await refreshOnePassword(), let vault = onePasswordVault else {
                if case .failed(let message) = onePassword { run.fail(message) } else { run.fail("1Password isn't ready.") }
                return
            }
            // Fresh rows with what 1Password holds now; only the vaults asked for.
            let wanted = selected.map { Set($0.map(\.id)) }
            let rows = rows().filter { row in
                wanted.map { $0.contains(row.id) } ?? row.status.wantsSync
            }
            run.begin(rows)
            let outcomes = await KeyBackupSync(store: store, settings: settings)
                .run(rows, nodes: connectedNodes, into: vault, force: force) { event in
                    await run.apply(event)
                }
            run.finish(outcomes)
            await refreshOnePassword()
            await pollNodes()
        }
    }

    // MARK: Notifications

    @ObservationIgnored private var notifiedRows: Set<String> = []

    /// "N vault keys need backup", posted when a vault starts needing a backup (or its key became unavailable) and
    /// the user opted in. Not repeated for the same vaults.
    private func notifyIfNeeded() async {
        let needing = rows().filter { $0.needsBackup || $0.isKeyUnavailable }
        let ids = Set(needing.map(\.id))
        defer { notifiedRows = ids }
        guard notificationsEnabled, !ids.subtracting(notifiedRows).isEmpty else { return }
        await notifier.post(needing)
    }

    /// Turning notifications on asks macOS for permission the first time.
    func setNotifications(_ enabled: Bool) async -> Bool {
        guard enabled else {
            notificationsEnabled = false
            return true
        }
        let granted = await notifier.requestPermission()
        notificationsEnabled = granted
        if granted { notifiedRows = [] }
        return granted
    }

    #if DEBUG
    /// PREVIEW DATA: a stand-in 1Password, already read, and settings that aren't saved.
    func usePreview(store: any KeyBackupStore, items: [BackupItem], vault: OnePasswordVault) {
        persists = false
        storeOverride = store
        settings = OnePasswordSettings(account: "Cooper (preview)")
        notificationsEnabled = false
        onePassword = .ready(vault: vault, items: items, at: .now)
    }
    #endif
}

/// A transport for rows of a node that isn't connected: every request fails as disconnected.
private nonisolated struct OfflineTransport: NodeTransport {
    func send<R: WsRequest>(_ request: R.Type, payload: R.Payload) async throws(WsError) -> R.Response {
        throw .disconnected
    }
}

nonisolated extension VaultKeyRow {
    /// The same vault with its status unknown (node offline): never shown as backed up.
    var asUnknown: VaultKeyRow {
        VaultKeyRow(nodeID: nodeID, nodeName: nodeName, backupNodeID: backupNodeID, vaultID: vaultID,
                    vaultName: vaultName, deleted: deleted, daemon: daemon, item: item, status: .unknown,
                    onePasswordChecked: onePasswordChecked, lastSalvage: lastSalvage)
    }

    var isKeyUnavailable: Bool {
        if case .keyUnavailable = status { return true }
        return false
    }
}

/// One sync, vault by vault, for the progress sheet.
@MainActor
@Observable
final class KeySyncRun: Identifiable {
    enum Phase: Equatable {
        case preparing
        case running
        case finished
        case failed(String)
    }

    struct Entry: Identifiable {
        let id: String
        let nodeName: String
        let vaultName: String
        var running = false
        var outcome: VaultSyncOutcome?
    }

    let id = UUID()
    let title: String
    private(set) var phase: Phase = .preparing
    private(set) var entries: [Entry] = []

    init(title: String) {
        self.title = title
    }

    var isRunning: Bool { phase == .preparing || phase == .running }

    func begin(_ rows: [VaultKeyRow]) {
        entries = rows.map { Entry(id: $0.id, nodeName: $0.nodeName, vaultName: $0.vaultName) }
        phase = .running
    }

    func apply(_ event: VaultSyncEvent) {
        switch event {
        case .started(let id):
            if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].running = true }
        case .finished(let id, let outcome):
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].running = false
                entries[i].outcome = outcome
            }
        }
    }

    func finish(_ outcomes: [String: VaultSyncOutcome]) {
        for (id, outcome) in outcomes {
            if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].outcome = outcome }
        }
        phase = .finished
    }

    func fail(_ message: String) {
        phase = .failed(message)
    }

    #if DEBUG
    /// PREVIEW DATA: a finished run with every kind of outcome.
    static func preview() -> KeySyncRun {
        let run = KeySyncRun(title: "Back up vault keys")
        run.entries = [
            Entry(id: "a", nodeName: "Home lab (preview)", vaultName: "Family Photos (preview)",
                  outcome: .backedUp(version: 3, written: true)),
            Entry(id: "b", nodeName: "Home lab (preview)", vaultName: "Documents (preview)",
                  outcome: .backedUp(version: 1, written: false)),
            Entry(id: "c", nodeName: "Home lab (preview)", vaultName: "Offsite Backup (preview)",
                  outcome: .storedNotConfirmed(version: 2, reason: "key version 2 is no longer the current key of vault 'Offsite Backup' (current: 3)")),
            Entry(id: "d", nodeName: "Studio (preview)", vaultName: "Renders (preview)",
                  outcome: .failed(step: .export, message: "This account may not export vault keys on Studio (preview) (it needs the encryption-key Export permission).")),
            Entry(id: "e", nodeName: "Studio (preview)", vaultName: "Archive (preview)", running: true),
        ]
        run.phase = .running
        return run
    }
    #endif
}
