import AppKit
import Foundation
import Network
import Observation
import os
import VHCore
import VHNodes

/// Watches every paired node with or without a window (docs/mac-experience.md §3): the state the menu bar item
/// shows, the background health check, and what gets notified.
///
/// With no window open nothing polls on its own (`NodeQueries.isActive`), so the monitor asks. Once a minute each
/// online node is asked for its four headline numbers (`NodePulse.checkHealth()`), which fetches the whole overview
/// only when they changed; the slow figures every five minutes. The answers land in the same query cache the views
/// read, so opening the window shows them at once.
@Observable
final class FleetMonitor {
    static let checkInterval: Duration = .seconds(60)
    static let evaluateInterval: Duration = .seconds(30)
    /// The slow figures (storage, spend, conflicts) every this many checks.
    static let figuresEvery = 5
    static let settingsKey = "notifications.fleet"
    private static let log = Logger(subsystem: "sh.vaulthalla.app", category: "fleet")

    @ObservationIgnored weak var app: AppModel?
    let preferences: NodePreferences
    /// Which notices are on (Settings ▸ Notifications).
    var settings: FleetNoticeSettings {
        didSet { if settings != oldValue { saveSettings() } }
    }

    /// What was already said, and since when each node has been unreachable. Read by the item's state too, so the
    /// icon and the notifications judge a node by the same clock.
    private(set) var memory: FleetNoticeMemory
    /// When the state was last judged: moves on every evaluation, so time-based state redraws.
    private(set) var judgedAt = Date.now
    /// When the nodes were last asked.
    private(set) var checkedAt: Date?
    private(set) var isChecking = false

    @ObservationIgnored private let notifier = FleetNotifier()
    @ObservationIgnored private let memoryURL: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pendingEvaluation: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var networkAvailable = true
    @ObservationIgnored private var wokeAt: Date?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var checks = 0
    /// Where a notification goes when clicked. The app sets it.
    @ObservationIgnored var post: (FleetNotification) -> Void = { _ in }

    /// `memoryURL`: where what was already notified is kept (nil in previews: nothing is saved).
    init(preferences: NodePreferences, memoryURL: URL?, defaults: UserDefaults = .standard) {
        self.preferences = preferences
        self.memoryURL = memoryURL
        self.defaults = defaults
        settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(FleetNoticeSettings.self, from: $0) } ?? FleetNoticeSettings()
        memory = memoryURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(FleetNoticeMemory.self, from: $0) } ?? FleetNoticeMemory()
    }

    // MARK: - What the item shows

    /// Every node with its figures, judged by the grace period: a node that just dropped is still "connecting".
    var members: [FleetSummary.Member] {
        guard let app else { return [] }
        return app.nodes.map { node in
            FleetSummary.Member(id: node.id, name: node.displayName, reachability: judgedReachability(of: node),
                                digest: app.pulse(for: node)?.digest ?? NodeDigest())
        }
    }

    var summary: FleetSummary { FleetSummary(members) }

    var status: FleetStatus { FleetStatus(members, muted: preferences.muted) }

    /// The node's reachability as the item judges it: unreachable only once the grace period has passed (and never
    /// while this Mac has no network or just woke, when the clock isn't running).
    func judgedReachability(of node: Node) -> FleetSummary.Reachability {
        guard let app else { return .notPaired }
        let raw = app.status(for: node).reachability
        guard raw == .offline || raw == .connecting else { return raw }
        guard let since = memory.nodes[node.id.rawValue]?.offlineSince,
              judgedAt.timeIntervalSince(since) >= notifier.policy.unreachableGrace else { return .connecting }
        return .offline
    }

    // MARK: - Running

    /// Starts watching. Idempotent.
    func start() {
        guard loop == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(available) }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.wokeAt = .now
                self?.evaluateSoon()
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow()
                // Two evaluations per check, so the grace period is noticed within half a minute.
                try? await Task.sleep(for: Self.evaluateInterval)
                guard !Task.isCancelled else { return }
                self?.evaluate()
                try? await Task.sleep(for: Self.checkInterval - Self.evaluateInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        pendingEvaluation?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Asks every online node now, then judges. Joins nothing: a second call while one runs returns at once.
    func checkNow(figures: Bool? = nil) async {
        guard !isChecking, let app else { return }
        isChecking = true
        defer { isChecking = false }
        checks += 1
        let withFigures = figures ?? (checks % Self.figuresEvery == 1)
        let pulses = app.nodes.compactMap { app.status(for: $0) == .online ? app.pulse(for: $0) : nil }
        await withTaskGroup(of: Void.self) { group in
            for pulse in pulses {
                group.addTask {
                    await pulse.checkHealth()
                    if withFigures { await pulse.refreshFigures() }
                }
            }
        }
        checkedAt = .now
        evaluate()
    }

    /// A node's connection changed: a node that just came online is asked at once, and the state is judged again.
    func connectionChanged(_ id: NodeID, online: Bool) {
        guard loop != nil else { return }
        if online, let app, let node = app.node(withID: id) {
            Task { [weak self] in
                // The pulse exists once the node has a query store, which `pulse(for:)` makes on first use.
                guard let pulse = app.pulse(for: node) else { return }
                await pulse.checkHealth()
                await pulse.refreshFigures()
                self?.evaluate()
            }
        }
        evaluateSoon()
    }

    private func networkChanged(_ available: Bool) {
        guard available != networkAvailable else { return }
        networkAvailable = available
        evaluateSoon()
    }

    /// Judges shortly, once, however many things changed in the same moment.
    func evaluateSoon() {
        pendingEvaluation?.cancel()
        pendingEvaluation = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    // MARK: - Judging

    /// One check of the rules: updates what is remembered and posts what is new.
    func evaluate() {
        guard let app else { return }
        let now = Date.now
        let onScreen = Self.nodeOnScreen(app)
        let observations = app.nodes.map { node -> FleetObservation in
            let pulse = app.pulse(for: node)
            return FleetObservation(
                id: node.id, name: node.displayName, reachability: app.status(for: node).reachability,
                needsPairing: app.needsPairingAgain(node.id),
                incompatibility: app.incompatibility(for: node)?.message,
                findings: pulse?.digest.health.value?.alerts,
                conflicts: pulse?.conflicts.value?.total,
                muted: preferences.isMuted(node.id),
                onScreen: onScreen == node.id)
        }
        var next = memory
        let posts = notifier.evaluate(observations, memory: &next, settings: settings,
                                      at: .init(now: now, networkAvailable: networkAvailable, wokeAt: wokeAt))
        if next != memory {
            memory = next
            saveMemory()
        }
        judgedAt = now
        for notification in posts {
            Self.log.notice("notify \(notification.notice.rawValue, privacy: .public)")
            post(notification)
        }
    }

    /// The node the frontmost window is showing, if the app is frontmost: the screen already says what happens there.
    private static func nodeOnScreen(_ app: AppModel) -> NodeID? {
        guard NSApp.isActive, !app.showsAllNodes, MainWindow.isVisible else { return nil }
        return app.selectedNodeID
    }

    // MARK: - Saving

    private func saveSettings() {
        if settings == FleetNoticeSettings() {
            defaults.removeObject(forKey: Self.settingsKey)
        } else if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    private func saveMemory() {
        guard let memoryURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: memoryURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(memory).write(to: memoryURL, options: .atomic)
        } catch {
            Self.log.error("saving what was notified: \(error.localizedDescription, privacy: .public)")
        }
    }
}
