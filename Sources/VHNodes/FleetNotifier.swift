public import Foundation
public import VHCore

/// What Vaulthalla tells the person about without being asked (docs/mac-experience.md §6): the classes, their
/// defaults, and the rules that keep them from repeating. Pure: it turns what the app observes into the notifications
/// to post, and remembers what it already said. The app posts them and saves the memory.
public enum FleetNotice: String, Sendable, Hashable, Codable, CaseIterable {
    case nodeUnreachable = "node.unreachable"
    case nodeReachable = "node.reachable"
    case nodeRevoked = "node.revoked"
    case nodeIncompatible = "node.incompatible"
    case healthError = "health.error"
    case healthWarning = "health.warning"
    case healthCleared = "health.cleared"
    case syncConflicts = "sync.conflicts"

    /// Warnings are off until the server says which ones are worth it: one of them fires during every upload.
    public var enabledByDefault: Bool { self != .healthWarning }

    public var playsSound: Bool {
        switch self {
        case .nodeUnreachable, .nodeRevoked, .healthError: true
        case .nodeReachable, .nodeIncompatible, .healthWarning, .healthCleared, .syncConflicts: false
        }
    }

    public var title: String {
        switch self {
        case .nodeUnreachable: "A server becomes unreachable"
        case .nodeReachable: "A server is reachable again"
        case .nodeRevoked: "A server revokes this Mac"
        case .nodeIncompatible: "A server needs a different version"
        case .healthError: "A server reports an error"
        case .healthWarning: "A server reports a warning"
        case .healthCleared: "A server's errors have cleared"
        case .syncConflicts: "New sync conflicts"
        }
    }
}

/// Which notices are on. Stored by the app; absent entries take the notice's default.
public struct FleetNoticeSettings: Sendable, Hashable, Codable {
    /// The master switch.
    public var enabled: Bool
    public var overrides: [String: Bool]

    public init(enabled: Bool = true, overrides: [String: Bool] = [:]) {
        self.enabled = enabled
        self.overrides = overrides
    }

    public func allows(_ notice: FleetNotice) -> Bool {
        enabled && (overrides[notice.rawValue] ?? notice.enabledByDefault)
    }

    public func isOn(_ notice: FleetNotice) -> Bool {
        overrides[notice.rawValue] ?? notice.enabledByDefault
    }

    public mutating func set(_ notice: FleetNotice, on: Bool) {
        overrides[notice.rawValue] = on == notice.enabledByDefault ? nil : on
    }
}

/// One notification to post. `id` is stable per thing, so posting it again replaces the earlier one.
public struct FleetNotification: Sendable, Hashable {
    /// Where a click goes.
    public enum Target: Sendable, Hashable {
        case node(NodeID)
        case pairAgain(NodeID)
        case finding(NodeID, NodeDigest.Alert)
        case syncConflicts(NodeID)
    }

    public var id: String
    public var notice: FleetNotice
    public var node: NodeID
    public var title: String
    public var body: String
    public var sound: Bool
    public var target: Target

    public init(id: String, notice: FleetNotice, node: NodeID, title: String, body: String, sound: Bool, target: Target) {
        self.id = id
        self.notice = notice
        self.node = node
        self.title = title
        self.body = body
        self.sound = sound
        self.target = target
    }
}

/// What the app sees of one node at one moment.
public struct FleetObservation: Sendable, Hashable {
    public var id: NodeID
    public var name: String
    public var reachability: FleetSummary.Reachability
    /// The session gave up for good: only pairing again helps.
    public var needsPairing: Bool
    /// Why this build and the node can't talk, when their protocol ranges don't overlap.
    public var incompatibility: String?
    /// The node's findings as it last reported them; nil while unknown (no answer, or no access).
    public var findings: [NodeDigest.Alert]?
    /// Open sync conflicts; nil while unknown.
    public var conflicts: Int64?
    public var muted: Bool
    /// The window is frontmost and showing this node: the screen already says it.
    public var onScreen: Bool

    public init(id: NodeID, name: String, reachability: FleetSummary.Reachability, needsPairing: Bool = false,
                incompatibility: String? = nil, findings: [NodeDigest.Alert]? = nil, conflicts: Int64? = nil,
                muted: Bool = false, onScreen: Bool = false) {
        self.id = id
        self.name = name
        self.reachability = reachability
        self.needsPairing = needsPairing
        self.incompatibility = incompatibility
        self.findings = findings
        self.conflicts = conflicts
        self.muted = muted
        self.onScreen = onScreen
    }
}

/// What has been said already, so nothing is said twice and a relaunch isn't news. Node ids and finding codes only.
public struct FleetNoticeMemory: Sendable, Hashable, Codable {
    public struct Finding: Sendable, Hashable, Codable {
        /// ``SeverityRank`` when last seen (0 error, 1 warning).
        public var rank: Int
        /// When it stopped being reported; nil while active.
        public var clearedAt: Date?
    }

    public struct Node: Sendable, Hashable, Codable {
        /// Since when the node has not been online; nil while it is, or while that can't be judged.
        public var offlineSince: Date?
        public var unreachableNotified = false
        public var revokedNotified = false
        /// The incompatibility already announced.
        public var incompatibleNotified: String?
        /// Findings seen, by ``NodeDigest/Alert/id``.
        public var findings: [String: Finding] = [:]
        /// An error notification went out and its "cleared" has not.
        public var errorsNotified = false
        /// The open conflict count already known.
        public var conflicts: Int64?

        public init() {}
    }

    public var nodes: [String: Node]

    public init(nodes: [String: Node] = [:]) {
        self.nodes = nodes
    }
}

public struct FleetNotifier: Sendable {
    public struct Policy: Sendable {
        /// How long a paired node may be offline before anyone is told.
        public var unreachableGrace: TimeInterval = 120
        /// A finding that returns this soon after clearing is the same occurrence.
        public var flapWindow: TimeInterval = 30 * 60
        /// Nothing about reachability is judged this soon after the Mac woke.
        public var wakeHold: TimeInterval = 30
        /// More new findings than this on one node in one check become a single notification.
        public var groupAbove = 3

        public init() {}
    }

    /// The moment of a check.
    public struct Moment: Sendable {
        public var now: Date
        /// Whether this Mac has a network at all: without one, an unreachable node says nothing about the node.
        public var networkAvailable: Bool
        public var wokeAt: Date?

        public init(now: Date, networkAvailable: Bool = true, wokeAt: Date? = nil) {
            self.now = now
            self.networkAvailable = networkAvailable
            self.wokeAt = wokeAt
        }
    }

    public var policy: Policy

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// One check: updates `memory` and returns what to post, in node order.
    public func evaluate(_ observations: [FleetObservation], memory: inout FleetNoticeMemory,
                         settings: FleetNoticeSettings, at moment: Moment) -> [FleetNotification] {
        var out: [FleetNotification] = []
        let known = Set(observations.map(\.id.rawValue))
        // A node that is gone takes its memory with it.
        memory.nodes = memory.nodes.filter { known.contains($0.key) }

        for node in observations {
            var state = memory.nodes[node.id.rawValue] ?? FleetNoticeMemory.Node()
            var posts: [FleetNotification] = []
            reachability(node, &state, moment, &posts)
            pairing(node, &state, &posts)
            findings(node, &state, moment, &posts)
            conflicts(node, &state, &posts)
            memory.nodes[node.id.rawValue] = state
            // What was learned is remembered either way; only the telling is held back.
            guard !node.muted, !node.onScreen else { continue }
            out += posts.filter { settings.allows($0.notice) }
        }
        return out
    }

    // MARK: Reachability

    private func reachability(_ node: FleetObservation, _ state: inout FleetNoticeMemory.Node, _ moment: Moment,
                              _ posts: inout [FleetNotification]) {
        switch node.reachability {
        case .online:
            state.offlineSince = nil
            if state.unreachableNotified {
                state.unreachableNotified = false
                posts.append(FleetNotification(
                    id: "\(node.id.rawValue)|reachability", notice: .nodeReachable, node: node.id,
                    title: "\(node.name) is reachable again", body: "This Mac is connected to it.",
                    sound: FleetNotice.nodeReachable.playsSound, target: .node(node.id)))
            }
        case .offline, .connecting:
            // Without a network, or just after waking, an unreachable node says nothing about the node: the clock
            // starts once that can be judged.
            let justWoke = moment.wokeAt.map { moment.now.timeIntervalSince($0) < policy.wakeHold } ?? false
            guard moment.networkAvailable, !justWoke else {
                state.offlineSince = nil
                return
            }
            guard let since = state.offlineSince else {
                state.offlineSince = moment.now
                return
            }
            guard !state.unreachableNotified, moment.now.timeIntervalSince(since) >= policy.unreachableGrace else { return }
            state.unreachableNotified = true
            posts.append(FleetNotification(
                id: "\(node.id.rawValue)|reachability", notice: .nodeUnreachable, node: node.id,
                title: "\(node.name) is unreachable",
                body: "This Mac hasn't been able to reach it for \(Self.minutes(policy.unreachableGrace)).",
                sound: FleetNotice.nodeUnreachable.playsSound, target: .node(node.id)))
        case .revoked, .notPaired:
            state.offlineSince = nil
            state.unreachableNotified = false
        }
    }

    private func pairing(_ node: FleetObservation, _ state: inout FleetNoticeMemory.Node,
                         _ posts: inout [FleetNotification]) {
        let lost = node.reachability == .revoked || node.needsPairing
        if lost, !state.revokedNotified {
            state.revokedNotified = true
            posts.append(FleetNotification(
                id: "\(node.id.rawValue)|pairing", notice: .nodeRevoked, node: node.id,
                title: node.reachability == .revoked ? "\(node.name) revoked this Mac" : "\(node.name) needs pairing again",
                body: "Pair this Mac again in Vaulthalla to use it.",
                sound: FleetNotice.nodeRevoked.playsSound, target: .pairAgain(node.id)))
        } else if !lost, node.reachability == .online {
            state.revokedNotified = false
        }

        if let why = node.incompatibility {
            if state.incompatibleNotified != why {
                state.incompatibleNotified = why
                posts.append(FleetNotification(
                    id: "\(node.id.rawValue)|protocol", notice: .nodeIncompatible, node: node.id,
                    title: "\(node.name) can't be used with this version", body: why,
                    sound: FleetNotice.nodeIncompatible.playsSound, target: .node(node.id)))
            }
        } else if node.reachability == .online {
            state.incompatibleNotified = nil
        }
    }

    // MARK: Findings

    private func findings(_ node: FleetObservation, _ state: inout FleetNoticeMemory.Node, _ moment: Moment,
                          _ posts: inout [FleetNotification]) {
        // Only an online node's answer is current, and only an answer says anything: unknown is not "cleared".
        guard node.reachability == .online, let reported = node.findings else { return }
        let active = reported.filter { SeverityRank.of($0.severity) <= 1 }
        var fresh: [NodeDigest.Alert] = []
        for alert in active {
            let rank = SeverityRank.of(alert.severity)
            if let seen = state.findings[alert.id] {
                let returnedLate = seen.clearedAt.map { moment.now.timeIntervalSince($0) >= policy.flapWindow } ?? false
                // News again when it got worse, or came back after staying away long enough.
                if rank < seen.rank || returnedLate { fresh.append(alert) }
            } else {
                fresh.append(alert)
            }
            state.findings[alert.id] = .init(rank: rank, clearedAt: nil)
        }
        let activeIDs = Set(active.map(\.id))
        for (id, seen) in state.findings where !activeIDs.contains(id) {
            if let clearedAt = seen.clearedAt {
                if moment.now.timeIntervalSince(clearedAt) >= policy.flapWindow { state.findings[id] = nil }
            } else {
                state.findings[id]?.clearedAt = moment.now
            }
        }

        let errors = fresh.filter { SeverityRank.of($0.severity) == 0 }
        let warnings = fresh.filter { SeverityRank.of($0.severity) == 1 }
        post(errors, as: .healthError, node, &posts)
        post(warnings, as: .healthWarning, node, &posts)
        if !errors.isEmpty { state.errorsNotified = true }

        let stillErrors = active.contains { SeverityRank.of($0.severity) == 0 }
        if state.errorsNotified, !stillErrors {
            state.errorsNotified = false
            posts.append(FleetNotification(
                id: "\(node.id.rawValue)|health.cleared", notice: .healthCleared, node: node.id,
                title: "\(node.name) is no longer reporting errors",
                body: active.isEmpty ? "Nothing needs attention." : "\(Self.count(active.count, "warning")) remain.",
                sound: FleetNotice.healthCleared.playsSound, target: .node(node.id)))
        }
    }

    private func post(_ alerts: [NodeDigest.Alert], as notice: FleetNotice, _ node: FleetObservation,
                      _ posts: inout [FleetNotification]) {
        guard let first = alerts.first else { return }
        if alerts.count > policy.groupAbove {
            let noun = notice == .healthError ? "new problem" : "new warning"
            let titles = alerts.prefix(3).map(\.title).joined(separator: ", ")
            posts.append(FleetNotification(
                id: "\(node.id.rawValue)|\(notice.rawValue)|group", notice: notice, node: node.id,
                title: "\(Self.count(alerts.count, noun)) on \(node.name)",
                body: "\(titles), and \(alerts.count - 3) more.",
                sound: notice.playsSound, target: .finding(node.id, first)))
            return
        }
        for alert in alerts {
            posts.append(FleetNotification(
                id: "\(node.id.rawValue)|\(notice.rawValue)|\(alert.id)", notice: notice, node: node.id,
                title: "\(node.name): \(alert.title)", body: alert.message,
                sound: notice.playsSound, target: .finding(node.id, alert)))
        }
    }

    // MARK: Conflicts

    private func conflicts(_ node: FleetObservation, _ state: inout FleetNoticeMemory.Node,
                           _ posts: inout [FleetNotification]) {
        guard node.reachability == .online, let open = node.conflicts else { return }
        defer { state.conflicts = open }
        // The first count seen is where this Mac starts from: conflicts that were already there are not news.
        guard let known = state.conflicts, open > known else { return }
        let added = open - known
        posts.append(FleetNotification(
            id: "\(node.id.rawValue)|conflicts", notice: .syncConflicts, node: node.id,
            title: "\(Self.count(Int(added), "new sync conflict")) on \(node.name)",
            body: open == added ? "Open Sync Conflicts to resolve \(added == 1 ? "it" : "them")."
                : "\(open) are open in all.",
            sound: FleetNotice.syncConflicts.playsSound, target: .syncConflicts(node.id)))
    }

    // MARK: Wording

    private static func count(_ number: Int, _ noun: String) -> String {
        number == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }

    private static func minutes(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes == 1 ? "a minute" : "\(minutes) minutes"
    }
}
