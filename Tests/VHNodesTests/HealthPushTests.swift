import Foundation
import Testing
import VHContract
import VHCore
@testable import VHTransport
@testable import VHNodes

/// Health by push (the server's design/health/findings.md §6): a node with `health.subscribe` is subscribed once per
/// connection, each `health.changed` refetches the findings (coalesced), and the poll slows to a safety net while
/// subscribed. Without the command, after `"subscribed": false`, a refusal or a disconnect, health is polled as before.
@Suite struct HealthPushTests {
    typealias H = HealthFindingsTests

    /// A negotiated node with every command, or without the push commands (a node from before them).
    static func negotiated(withPush: Bool) -> NodeProtocol {
        let push: Set<String> = [WsCommand.healthSubscribe.rawValue, WsCommand.healthUnsubscribe.rawValue]
        let commands = Set(WsCommand.allCases.map(\.rawValue)).filter { withPush || !push.contains($0) }
        return NodeProtocol(state: .negotiated, version: 1, serverRange: 1...1, capabilities: [], commands: commands)
    }

    /// A node with one warning whose state the test changes; it answers the subscription with revision 3.
    @MainActor
    static func pushingNode(listDelay: Duration? = nil, subscribe: ScriptedNode.Reply = .ok(["revision": 3]))
        -> (ScriptedNode, Shared<String>)
    {
        let node = FleetSamples.scriptedNode(status: "warning")
        let state = Shared("active")
        node.answer("health.findings.list", after: listDelay) { _ in
            .ok(["health": FleetSamples.json(H.findings([H.finding("system.fuse.error_rate_elevated", "warning",
                                                                   state: state.value)]))])
        }
        node.answer("health.subscribe") { _ in subscribe }
        return (node, state)
    }

    @MainActor
    static func pulse(_ node: ScriptedNode, withPush: Bool = true, intervals: NodePulse.Intervals = fast())
        -> NodePulse
    {
        let queries = NodeQueries(transport: node)
        queries.protocolChanged(negotiated(withPush: withPush))
        return NodePulse(queries: queries, intervals: intervals)
    }

    static func fast() -> NodePulse.Intervals {
        var intervals = NodePulse.Intervals()
        intervals.pushRefetchFloor = .milliseconds(1)
        return intervals
    }

    @MainActor
    func waitFor(within timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestFailure("condition not met within \(timeout)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Subscribing

    @MainActor @Test func subscribesOncePerConnectionAndTheBackgroundCheckRestsWhileSubscribed() async throws {
        let (node, _) = Self.pushingNode()
        let pulse = Self.pulse(node)
        pulse.connectionChanged(online: true)
        try await waitFor { pulse.isFollowingPush }
        #expect(node.count(of: "health.subscribe") == 1)

        // The first check fetches; the next ones rest on the push while the answer is fresher than the safety net.
        await pulse.checkHealth()
        await pulse.checkHealth()
        await pulse.checkHealth()
        #expect(node.count(of: "health.findings.list") == 1)
        #expect(node.count(of: "stats.dashboard.severity") == 0)

        // A new connection subscribes again: the server's subscription ended with the old one.
        pulse.connectionChanged(online: false)
        #expect(!pulse.isFollowingPush)
        pulse.connectionChanged(online: true)
        try await waitFor { pulse.isFollowingPush }
        #expect(node.count(of: "health.subscribe") == 2)
    }

    @MainActor @Test func anEventRefetchesTheFindingsAndTheOverview() async throws {
        let (node, state) = Self.pushingNode()
        let pulse = Self.pulse(node)
        pulse.connectionChanged(online: true)
        try await waitFor { pulse.isFollowingPush }
        await pulse.checkHealth()
        #expect(pulse.digest.health.value?.alerts.first?.state == .active)
        let overviews = node.count(of: "stats.dashboard.overview")

        // Someone acknowledged it in the console: the node says so, and the pulse asks.
        state.value = "acknowledged"
        pulse.healthChanged(HealthChange(revision: 4, overallStatus: "warning", errorCount: 0, warningCount: 1,
                                         unattendedErrorCount: 0, unattendedWarningCount: 0))
        try await waitFor { pulse.digest.health.value?.alerts.first?.state == .acknowledged }
        #expect(node.count(of: "health.findings.list") == 2)
        try await waitFor { node.count(of: "stats.dashboard.overview") == overviews + 1 }

        // An event no newer than one already seen asks nothing; neither does one older than the subscription.
        pulse.healthChanged(HealthChange(revision: 4))
        pulse.healthChanged(HealthChange(revision: 2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(node.count(of: "health.findings.list") == 2)
    }

    @MainActor @Test func eventsDuringARefetchFoldIntoOneMoreAndTheNewestWins() async throws {
        let (node, state) = Self.pushingNode(listDelay: .milliseconds(300))
        let pulse = Self.pulse(node)
        pulse.connectionChanged(online: true)
        try await waitFor { pulse.isFollowingPush }

        pulse.healthChanged(HealthChange(revision: 4))
        try await waitFor { node.count(of: "health.findings.list") == 1 }
        // Three more while the first is in flight: one more refetch, after it, sees the latest state.
        state.value = "silenced"
        pulse.healthChanged(HealthChange(revision: 5))
        pulse.healthChanged(HealthChange(revision: 6))
        pulse.healthChanged(HealthChange(revision: 7))
        try await waitFor { pulse.digest.health.value?.alerts.first?.state == .silenced }
        try await Task.sleep(for: .milliseconds(500))
        #expect(node.count(of: "health.findings.list") == 2)
    }

    @MainActor @Test func aFetchUnderWayWhenTheEventArrivesIsFollowedByAFreshOne() async throws {
        let (node, state) = Self.pushingNode(listDelay: .milliseconds(200))
        let pulse = Self.pulse(node)
        pulse.connectionChanged(online: true)
        try await waitFor { pulse.isFollowingPush }
        // A poll asked just before the change: its answer may predate it.
        let poll = Task { await pulse.findings.refresh() }
        try await waitFor { node.count(of: "health.findings.list") == 1 }
        state.value = "acknowledged"
        pulse.healthChanged(HealthChange(revision: 4))
        await poll.value
        try await waitFor { node.count(of: "health.findings.list") == 2 }
        try await waitFor { pulse.digest.health.value?.alerts.first?.state == .acknowledged }
    }

    // MARK: Falling back

    @MainActor @Test func subscribedFalseFallsBackToPolling() async throws {
        let (node, _) = Self.pushingNode()
        let pulse = Self.pulse(node)
        pulse.connectionChanged(online: true)
        try await waitFor { pulse.isFollowingPush }
        await pulse.checkHealth()
        await pulse.checkHealth()
        #expect(node.count(of: "health.findings.list") == 1)

        // The account lost admin.stats.view: the last event says so, and every check asks again.
        pulse.healthChanged(HealthChange(revision: 9, subscribed: false))
        #expect(!pulse.isFollowingPush)
        await pulse.checkHealth()
        await pulse.checkHealth()
        #expect(node.count(of: "health.findings.list") == 3)
    }

    @MainActor @Test func anOlderNodeOrARefusedSubscriptionKeepsPolling() async throws {
        // A node from before the push: nothing is sent, every check asks as before.
        let (older, _) = Self.pushingNode()
        let pulse = Self.pulse(older, withPush: false)
        pulse.connectionChanged(online: true)
        await pulse.checkHealth()
        await pulse.checkHealth()
        #expect(older.count(of: "health.subscribe") == 0)
        #expect(!pulse.isFollowingPush)
        #expect(older.count(of: "health.findings.list") == 2)

        // An account without admin.stats.view is refused: polling as before.
        let (refusing, _) = Self.pushingNode(subscribe: .refuse("Needs admin.stats.view.", code: "denied"))
        let refused = Self.pulse(refusing)
        refused.connectionChanged(online: true)
        try await waitFor { refusing.count(of: "health.subscribe") == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!refused.isFollowingPush)
        await refused.checkHealth()
        await refused.checkHealth()
        #expect(refusing.count(of: "health.findings.list") == 2)
    }

    @MainActor @Test func anAnswerToAnEarlierConnectionsSubscriptionIsIgnored() async throws {
        let node = FleetSamples.scriptedNode(status: "warning")
        node.answer("health.subscribe", after: .milliseconds(200)) { _ in .ok(["revision": 1]) }
        let pulse = Self.pulse(node)
        pulse.connectionChanged(online: true)
        try await waitFor { node.count(of: "health.subscribe") == 1 }
        pulse.connectionChanged(online: false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!pulse.isFollowingPush)
    }

    @MainActor @Test func theWindowsHealthPollSlowsWhileSubscribed() async throws {
        let (node, _) = Self.pushingNode()
        var intervals = Self.fast()
        intervals.health = .milliseconds(100)
        let pulse = Self.pulse(node, intervals: intervals)
        let watching = Task { await pulse.observe() }
        defer { watching.cancel() }

        // Polled at the normal interval while not subscribed.
        try await waitFor { node.count(of: "health.findings.list") >= 3 }
        pulse.connectionChanged(online: true)
        try await waitFor { pulse.isFollowingPush }
        try await Task.sleep(for: .milliseconds(150))
        let settled = node.count(of: "health.findings.list")
        try await Task.sleep(for: .milliseconds(500))
        #expect(node.count(of: "health.findings.list") == settled)

        // The subscription ends: the normal interval again.
        pulse.healthChanged(HealthChange(revision: 9, subscribed: false))
        try await waitFor { node.count(of: "health.findings.list") >= settled + 2 }
    }

    // MARK: The event

    @Test func theEventIsReadFromItsFrame() {
        func frame(_ command: String, _ data: JSONValue?, requestId: String? = nil) -> UnsolicitedMessage {
            UnsolicitedMessage(command: command, status: nil, requestId: requestId, data: data, message: nil,
                               frame: .null)
        }
        let full = HealthChange(frame("health.changed", [
            "revision": 12, "overall_status": "error", "error_count": 1, "warning_count": 2,
            "unattended_error_count": 0, "unattended_warning_count": 2,
        ]))
        #expect(full == HealthChange(revision: 12, overallStatus: "error", errorCount: 1, warningCount: 2,
                                     unattendedErrorCount: 0, unattendedWarningCount: 2))
        #expect(HealthChange(frame("health.changed", ["revision": 13, "subscribed": false]))?.subscribed == false)
        #expect(HealthChange(frame("fs.changed", ["vault_id": 1, "revision": 3])) == nil)
        #expect(HealthChange(frame("health.changed", ["overall_status": "ok"])) == nil)
        #expect(HealthChange(frame("health.changed", ["revision": 1], requestId: "r1")) == nil)
    }
}
