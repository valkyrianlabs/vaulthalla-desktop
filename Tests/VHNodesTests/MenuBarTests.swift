import Foundation
import Testing
import VHContract
import VHCore
@testable import VHTransport
@testable import VHNodes

/// The menu bar's client logic (docs/mac-experience.md): the one state the item shows, what notifies and what never
/// repeats, favourites, the login item's default, and the background health check.
@Suite struct MenuBarTests {
    static let a = NodeID(rawValue: "a")
    static let b = NodeID(rawValue: "b")
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func member(_ id: NodeID, _ reach: FleetSummary.Reachability, health: String? = nil,
                       attention: [(code: String, severity: String, card: String)] = []) -> FleetSummary.Member {
        var digest = NodeDigest()
        if let health {
            digest.health = .value(NodeDigest.Health(FleetSamples.overview(status: health, attention: attention)))
        }
        return .init(id: id, name: id.rawValue.uppercased(), reachability: reach, digest: digest)
    }

    static func alert(_ code: String, _ severity: String, card: String = "system.fuse") -> NodeDigest.Alert {
        NodeDigest.Alert(code: code, severity: severity, cardID: card, title: "Title \(code)", message: "Message \(code)")
    }

    // MARK: The item's state

    @Test func nothingPairedOrAnsweredIsNotReportingNeverQuiet() {
        #expect(FleetStatus([]).level == .notReporting)
        #expect(FleetStatus([]).headline == "No nodes yet")
        #expect(FleetStatus([Self.member(Self.a, .notPaired)]).level == .notReporting)
        // Online, but health hasn't answered: not quiet yet.
        let loading = FleetStatus([Self.member(Self.a, .online)])
        #expect(loading.level == .notReporting)
        #expect(loading.detail == "Checking health…")
        // Still connecting at launch: neither quiet nor an alarm.
        let connecting = FleetStatus([Self.member(Self.a, .connecting), Self.member(Self.b, .connecting)])
        #expect(connecting.level == .notReporting)
        #expect(connecting.headline == "Connecting to 2 nodes…")
    }

    @Test func quietNeedsEveryPairedNodeOnlineWithoutFindings() {
        let quiet = FleetStatus([Self.member(Self.a, .online, health: "healthy"),
                                 Self.member(Self.b, .online, health: "healthy")])
        #expect(quiet.level == .quiet)
        #expect(quiet.headline == "2 nodes, all healthy")

        // An account that may not read health is online, not "healthy".
        var denied = Self.member(Self.b, .online)
        denied.digest.health = .denied
        let partly = FleetStatus([Self.member(Self.a, .online, health: "healthy"), denied])
        #expect(partly.level == .quiet)
        #expect(partly.headline == "2 nodes online")
    }

    @Test func errorsUnreachableAndRevokedNeedAttentionWarningsDoNot() {
        let warned = FleetStatus([
            Self.member(Self.a, .online, health: "warning", attention: [("system.db.warning", "warning", "system.db")]),
            Self.member(Self.b, .online, health: "healthy"),
        ])
        #expect(warned.level == .warnings)
        #expect(warned.attention == [Self.a])

        let failing = FleetStatus([
            Self.member(Self.a, .online, health: "error", attention: [("system.db.disconnected", "error", "system.db")]),
            Self.member(Self.b, .offline, health: "healthy"),
        ])
        #expect(failing.level == .attention)
        #expect(failing.headline == "2 nodes need attention")
        #expect(failing.detail == "B is unreachable · A reports errors")

        #expect(FleetStatus([Self.member(Self.a, .revoked)]).detail == "A revoked this Mac")
        // An offline node's last answer is not counted as current health.
        let stale = FleetStatus([Self.member(Self.a, .connecting, health: "error",
                                             attention: [("system.db.disconnected", "error", "system.db")])])
        #expect(stale.level == .notReporting)
    }

    @Test func aMutedNodeStaysOutOfTheState() {
        let members = [Self.member(Self.a, .offline), Self.member(Self.b, .online, health: "healthy")]
        #expect(FleetStatus(members).level == .attention)
        let muted = FleetStatus(members, muted: [Self.a])
        #expect(muted.level == .quiet)
        #expect(muted.headline == "B is healthy")
    }

    // MARK: Notifications

    static func observe(_ id: NodeID = a, _ reach: FleetSummary.Reachability = .online,
                        findings: [NodeDigest.Alert]? = nil, conflicts: Int64? = nil, muted: Bool = false,
                        onScreen: Bool = false, needsPairing: Bool = false,
                        incompatibility: String? = nil) -> FleetObservation {
        FleetObservation(id: id, name: id.rawValue.uppercased(), reachability: reach, needsPairing: needsPairing,
                         incompatibility: incompatibility, findings: findings, conflicts: conflicts, muted: muted,
                         onScreen: onScreen)
    }

    struct Run {
        var notifier = FleetNotifier()
        var memory = FleetNoticeMemory()
        var settings = FleetNoticeSettings()
        var clock = MenuBarTests.start

        mutating func check(_ observations: FleetObservation..., after seconds: TimeInterval = 0, network: Bool = true,
                            wokeAt: Date? = nil) -> [FleetNotification] {
            clock += seconds
            return notifier.evaluate(observations, memory: &memory, settings: settings,
                                     at: .init(now: clock, networkAvailable: network, wokeAt: wokeAt))
        }
    }

    @Test func anErrorNotifiesOncePerOccurrence() {
        var run = Run()
        let error = Self.alert("system.fuse.error_rate_high", "error")
        let first = run.check(Self.observe(findings: [error]))
        #expect(first.map(\.notice) == [.healthError])
        #expect(first.first?.title == "A: Title system.fuse.error_rate_high")
        #expect(first.first?.sound == true)
        #expect(first.first?.target == .finding(Self.a, error))
        // Still active a minute later: not said again.
        #expect(run.check(Self.observe(findings: [error]), after: 60).isEmpty)
        // Cleared: one "no longer reporting errors".
        #expect(run.check(Self.observe(findings: []), after: 60).map(\.notice) == [.healthCleared])
        #expect(run.check(Self.observe(findings: []), after: 60).isEmpty)
    }

    @Test func aFindingThatFlapsIsOneOccurrenceAndOneThatReturnsLateIsNews() {
        var run = Run()
        let error = Self.alert("system.operations.stalled", "error", card: "system.operations")
        #expect(run.check(Self.observe(findings: [error])).count == 1)
        _ = run.check(Self.observe(findings: []), after: 60)
        // Back within the flap window: the same occurrence.
        #expect(run.check(Self.observe(findings: [error]), after: 600).isEmpty)
        _ = run.check(Self.observe(findings: []), after: 60)
        // Back after staying away longer than the window: news.
        #expect(run.check(Self.observe(findings: [error]), after: 31 * 60).map(\.notice) == [.healthError])
    }

    @Test func warningsAreOffByDefaultAndAWarningThatBecomesAnErrorIsNews() {
        var run = Run()
        let warning = Self.alert("system.fuse.error_rate", "warning")
        #expect(run.check(Self.observe(findings: [warning])).isEmpty)
        // The same finding, now an error.
        let worse = Self.alert("system.fuse.error_rate", "error")
        #expect(run.check(Self.observe(findings: [worse]), after: 60).map(\.notice) == [.healthError])

        var loud = Run()
        loud.settings.set(.healthWarning, on: true)
        let told = loud.check(Self.observe(findings: [warning]))
        #expect(told.map(\.notice) == [.healthWarning])
        #expect(told.first?.sound == false)
        // Turning warnings on later doesn't replay the ones already known.
        run.settings.set(.healthWarning, on: true)
        #expect(run.check(Self.observe(findings: [worse]), after: 60).isEmpty)
    }

    @Test func aBurstBecomesOneNotification() {
        var run = Run()
        let many = (1...5).map { Self.alert("system.x.e\($0)", "error", card: "system.x\($0)") }
        let posts = run.check(Self.observe(findings: many))
        #expect(posts.count == 1)
        #expect(posts.first?.title == "5 new problems on A")
        #expect(posts.first?.body == "Title system.x.e1, Title system.x.e2, Title system.x.e3, and 2 more.")
        // Three or fewer are told one by one.
        var few = Run()
        #expect(few.check(Self.observe(findings: Array(many.prefix(3)))).count == 3)
    }

    @Test func unreachableWaitsForTheGracePeriodAndIsAnsweredByReachableAgain() {
        var run = Run()
        #expect(run.check(Self.observe(Self.a, .online)).isEmpty)
        #expect(run.check(Self.observe(Self.a, .offline), after: 10).isEmpty)
        #expect(run.check(Self.observe(Self.a, .connecting), after: 60).isEmpty)
        let down = run.check(Self.observe(Self.a, .offline), after: 60)
        #expect(down.map(\.notice) == [.nodeUnreachable])
        #expect(down.first?.body == "This Mac hasn't been able to reach it for 2 minutes.")
        #expect(run.check(Self.observe(Self.a, .offline), after: 600).isEmpty)
        #expect(run.check(Self.observe(Self.a, .online), after: 60).map(\.notice) == [.nodeReachable])
        // A blip shorter than the grace period says nothing, in either direction.
        #expect(run.check(Self.observe(Self.a, .offline), after: 60).isEmpty)
        #expect(run.check(Self.observe(Self.a, .online), after: 30).isEmpty)
    }

    @Test func withoutANetworkOrJustAfterWakingNothingIsJudged() {
        var run = Run()
        _ = run.check(Self.observe(Self.a, .offline))
        // This Mac is offline for ten minutes: the node isn't blamed, and the clock starts when the network is back.
        #expect(run.check(Self.observe(Self.a, .offline), after: 600, network: false).isEmpty)
        #expect(run.check(Self.observe(Self.a, .offline), after: 60).isEmpty)
        #expect(run.check(Self.observe(Self.a, .offline), after: 60).isEmpty)
        #expect(run.check(Self.observe(Self.a, .offline), after: 60).map(\.notice) == [.nodeUnreachable])

        var woke = Run()
        _ = woke.check(Self.observe(Self.a, .offline))
        let wake = woke.clock + 3600
        #expect(woke.check(Self.observe(Self.a, .offline), after: 3610, wokeAt: wake).isEmpty)
        // The grace period counts from after the wake hold, not from before the sleep.
        #expect(woke.check(Self.observe(Self.a, .offline), after: 60, wokeAt: wake).isEmpty)
        #expect(woke.check(Self.observe(Self.a, .offline), after: 120, wokeAt: wake).map(\.notice) == [.nodeUnreachable])
    }

    @Test func aRelaunchIsNotNews() throws {
        var run = Run()
        let error = Self.alert("system.db.disconnected", "error", card: "system.db")
        #expect(run.check(Self.observe(findings: [error], conflicts: 2)).count == 1)
        // The memory as the app saves it, read back by the next launch.
        let saved = try JSONEncoder().encode(run.memory)
        var next = Run()
        next.memory = try JSONDecoder().decode(FleetNoticeMemory.self, from: saved)
        next.clock = run.clock + 300
        #expect(next.check(Self.observe(findings: [error], conflicts: 2)).isEmpty)
        // And the "cleared" for the error told before the relaunch still arrives.
        #expect(next.check(Self.observe(findings: [], conflicts: 2), after: 60).map(\.notice) == [.healthCleared])
    }

    @Test func mutedOnScreenAndSwitchedOffAreRememberedButNotTold() {
        let error = Self.alert("system.db.disconnected", "error", card: "system.db")
        var muted = Run()
        #expect(muted.check(Self.observe(findings: [error], muted: true)).isEmpty)
        // Unmuting doesn't replay what happened meanwhile.
        #expect(muted.check(Self.observe(findings: [error]), after: 60).isEmpty)

        var visible = Run()
        #expect(visible.check(Self.observe(findings: [error], onScreen: true)).isEmpty)

        var off = Run()
        off.settings.enabled = false
        #expect(off.check(Self.observe(findings: [error])).isEmpty)
        var single = Run()
        single.settings.set(.healthError, on: false)
        #expect(single.check(Self.observe(findings: [error])).isEmpty)
        #expect(single.settings.overrides == ["health.error": false])
        single.settings.set(.healthError, on: true)
        #expect(single.settings.overrides.isEmpty)
    }

    @Test func unknownHealthIsNeitherNewsNorCleared() {
        var run = Run()
        let error = Self.alert("system.db.disconnected", "error", card: "system.db")
        _ = run.check(Self.observe(findings: [error]))
        // No answer (nil), or the node went offline: nothing is concluded from silence.
        #expect(run.check(Self.observe(findings: nil), after: 60).isEmpty)
        #expect(run.check(Self.observe(Self.a, .connecting, findings: []), after: 10).isEmpty)
        #expect(run.memory.nodes["a"]?.errorsNotified == true)
    }

    @Test func conflictsNotifyWhenTheCountRises() {
        var run = Run()
        // The first count is where this Mac starts from.
        #expect(run.check(Self.observe(conflicts: 3)).isEmpty)
        let more = run.check(Self.observe(conflicts: 5), after: 60)
        #expect(more.map(\.notice) == [.syncConflicts])
        #expect(more.first?.title == "2 new sync conflicts on A")
        #expect(more.first?.body == "5 are open in all.")
        #expect(more.first?.target == .syncConflicts(Self.a))
        #expect(run.check(Self.observe(conflicts: 1), after: 60).isEmpty)
        #expect(run.check(Self.observe(conflicts: 2), after: 60).first?.title == "1 new sync conflict on A")
    }

    @Test func revokedAndIncompatibleAreToldOnce() {
        var run = Run()
        let revoked = run.check(Self.observe(Self.a, .revoked))
        #expect(revoked.map(\.notice) == [.nodeRevoked])
        #expect(revoked.first?.target == .pairAgain(Self.a))
        #expect(run.check(Self.observe(Self.a, .revoked), after: 600).isEmpty)
        #expect(run.check(Self.observe(Self.a, .offline, needsPairing: true), after: 600).isEmpty)

        var old = Run()
        let why = "This node needs Vaulthalla Desktop 0.9 or newer."
        #expect(old.check(Self.observe(incompatibility: why)).map(\.notice) == [.nodeIncompatible])
        #expect(old.check(Self.observe(incompatibility: why), after: 60).isEmpty)
        #expect(old.check(Self.observe(), after: 60).isEmpty)
        #expect(old.check(Self.observe(incompatibility: why), after: 60).count == 1)
    }

    @Test func aRemovedNodeTakesItsMemoryWithIt() {
        var run = Run()
        _ = run.check(Self.observe(Self.a, findings: []), Self.observe(Self.b, findings: []))
        #expect(Set(run.memory.nodes.keys) == ["a", "b"])
        _ = run.check(Self.observe(Self.b, findings: []))
        #expect(Set(run.memory.nodes.keys) == ["b"])
    }

    // MARK: Favourites

    @MainActor @Test func favouritesAndMutesPersistAndGoWithTheNode() throws {
        let suite = "sh.vaulthalla.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let nodes = ["a", "b", "c"].map { Node(id: NodeID(rawValue: $0), displayName: $0, endpoint: .init(host: $0)) }

        let preferences = NodePreferences(defaults: defaults)
        preferences.toggleFavorite(NodeID(rawValue: "c"))
        preferences.setMuted(true, for: Self.b)
        #expect(preferences.favoritesFirst(nodes).map(\.displayName) == ["c", "a", "b"])

        let reread = NodePreferences(defaults: defaults)
        #expect(reread.isFavorite(NodeID(rawValue: "c")))
        #expect(reread.isMuted(Self.b))
        reread.forget(NodeID(rawValue: "c"))
        reread.forget(Self.b)
        #expect(defaults.object(forKey: NodePreferences.favoritesKey) == nil)
        #expect(defaults.object(forKey: NodePreferences.mutedKey) == nil)
    }

    // MARK: Open at login

    final class FakeLoginItems: LoginItemService, @unchecked Sendable {
        var status: LoginItemStatus = .disabled
        var registrations = 0
        var failure: (any Error)?

        func register() throws {
            if let failure { throw failure }
            registrations += 1
            status = .enabled
        }

        func unregister() throws {
            status = .disabled
        }
    }

    @MainActor @Test func openAtLoginIsRegisteredOnceAndNeverAgain() throws {
        let suite = "sh.vaulthalla.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeLoginItems()

        let first = LoginItemController(service: service, defaults: defaults, appliesDefault: true)
        first.applyDefaultIfNeeded()
        #expect(first.isEnabled)
        #expect(service.registrations == 1)

        // The person removes it in System Settings: the next launch sees that and leaves it alone.
        service.status = .disabled
        let second = LoginItemController(service: service, defaults: defaults, appliesDefault: true)
        second.applyDefaultIfNeeded()
        #expect(!second.isEnabled)
        #expect(service.registrations == 1)

        // Turning it on is theirs to do; the switch follows the system.
        second.setEnabled(true)
        #expect(second.isEnabled)
        service.status = .requiresApproval
        second.refresh()
        #expect(second.status == .requiresApproval)
    }

    @MainActor @Test func aDevelopmentBuildNeverRegistersOrRecordsTheDefault() throws {
        let suite = "sh.vaulthalla.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeLoginItems()

        let debug = LoginItemController(service: service, defaults: defaults, appliesDefault: false)
        debug.applyDefaultIfNeeded()
        debug.setEnabled(true)
        debug.setEnabled(false)
        #expect(service.registrations == 1)
        #expect(defaults.object(forKey: LoginItemController.defaultAppliedKey) == nil)

        // A release build on the same preferences still applies its default afterwards.
        let release = LoginItemController(service: service, defaults: defaults, appliesDefault: true)
        release.applyDefaultIfNeeded()
        #expect(release.isEnabled)
    }

    @MainActor @Test func aFailedRegistrationIsReportedAndNotRetried() throws {
        let suite = "sh.vaulthalla.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeLoginItems()
        service.failure = CocoaError(.fileNoSuchFile)

        let controller = LoginItemController(service: service, defaults: defaults, appliesDefault: true)
        controller.applyDefaultIfNeeded()
        #expect(!controller.isEnabled)
        #expect(controller.problem != nil)
        service.failure = nil
        LoginItemController(service: service, defaults: defaults, appliesDefault: true).applyDefaultIfNeeded()
        #expect(service.registrations == 0)
    }

    // MARK: The background check

    @MainActor @Test func theBackgroundCheckAsksForTheOverviewOnlyWhenTheNumbersChange() async throws {
        let node = FleetSamples.scriptedNode(status: "healthy")
        let healthy = WsModel.DashboardSeverity(overallStatus: "healthy", errorCount: 0, warningCount: 0,
                                                checkedAt: FleetSamples.now)
        node.answer("stats.dashboard.severity") { _ in .ok(["stats": FleetSamples.json(healthy)]) }
        let pulse = NodePulse(queries: NodeQueries(transport: node), fullCheckEvery: 4)

        await pulse.checkHealth()
        #expect(node.count(of: "stats.dashboard.overview") == 1)
        await pulse.checkHealth()
        await pulse.checkHealth()
        #expect(node.count(of: "stats.dashboard.severity") == 3)
        #expect(node.count(of: "stats.dashboard.overview") == 1)

        // The numbers changed: the whole picture is fetched once.
        let failing = WsModel.DashboardSeverity(overallStatus: "error", errorCount: 1, warningCount: 0,
                                                checkedAt: FleetSamples.now)
        node.answer("stats.dashboard.severity") { _ in .ok(["stats": FleetSamples.json(failing)]) }
        await pulse.checkHealth()
        await pulse.checkHealth()
        #expect(node.count(of: "stats.dashboard.overview") == 2)

        // Unchanged numbers can hide changed findings: a full check every few rounds regardless.
        await pulse.checkHealth()
        await pulse.checkHealth()
        await pulse.checkHealth()
        #expect(node.count(of: "stats.dashboard.overview") == 3)
        // The slow figures are fetched only when asked.
        #expect(node.count(of: "stats.system.storage") == 0)
        await pulse.refreshFigures()
        #expect(node.count(of: "stats.system.storage") == 1)
        #expect(node.count(of: "sync.conflicts.summary") == 1)
    }

    @MainActor @Test func aNodeWithoutStatsAccessIsAskedForItsOverviewOnce() async throws {
        let node = FleetSamples.scriptedNode(status: "healthy")
        let refusal = ScriptedNode.Reply.refuse("Permission denied: this account lacks admin.stats.view.", code: "denied")
        node.answer("stats.dashboard.severity") { _ in refusal }
        node.answer("stats.dashboard.overview") { _ in refusal }
        let pulse = NodePulse(queries: NodeQueries(transport: node))

        await pulse.checkHealth()
        await pulse.checkHealth()
        await pulse.checkHealth()
        #expect(pulse.digest.health == .denied)
        #expect(node.count(of: "stats.dashboard.overview") == 1)
    }
}
