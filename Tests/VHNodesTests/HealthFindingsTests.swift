import Foundation
import Testing
import VHContract
import VHCore
@testable import VHTransport
@testable import VHNodes

/// Acting on findings (docs/mac-experience.md §7): the state is the server's, acknowledged and silenced findings no
/// longer raise the item or notify, the health figures stay the truth, and a node without the commands is unchanged.
@Suite struct HealthFindingsTests {
    static let a = NodeID(rawValue: "a")
    static let now = FleetSamples.now

    static func finding(_ code: String, _ severity: String, card: String = "system.fuse", state: String = "active",
                        notifies: Bool = true, by: String = "cooper", until: Int64? = nil) -> WsModel.HealthFinding {
        let mark = state == "active" ? nil : WsModel.HealthFindingMark(
            class: code, subject: "", state: state, severity: severity, setBy: 1, setByName: by, setAt: now - 600,
            expiresAt: until)
        return WsModel.HealthFinding(
            class: code, subject: "", cardID: card, severity: severity, title: card, classTitle: "Class \(code)",
            message: code, href: "/health/filesystem#fuse", notifies: notifies, state: state, mark: mark,
            remedies: [.init(id: "open", label: "Open the filesystem", kind: "open", href: "/health/filesystem#fuse")])
    }

    static func findings(_ items: [WsModel.HealthFinding], canManage: Bool = true,
                         silences: [WsModel.HealthFindingMark] = []) -> WsModel.HealthFindings {
        let errors = items.filter { $0.severity == "error" }
        let warnings = items.filter { $0.severity == "warning" }
        return WsModel.HealthFindings(
            overallStatus: !errors.isEmpty ? "error" : !warnings.isEmpty ? "warning" : "healthy",
            errorCount: Int64(errors.count), warningCount: Int64(warnings.count),
            unattendedErrorCount: Int64(errors.filter { $0.state == "active" }.count),
            unattendedWarningCount: Int64(warnings.filter { $0.state == "active" }.count),
            checkedAt: now, findings: items, silences: silences, canManage: canManage)
    }

    static func health(_ items: [WsModel.HealthFinding], canManage: Bool = true) -> NodeDigest.Health {
        let overview = FleetSamples.overview(
            status: items.contains { $0.severity == "error" } ? "error" : items.isEmpty ? "healthy" : "warning",
            attention: items.map { ($0.class, $0.severity, $0.cardID) })
        return NodeDigest.Health(overview, findings: HealthFindings(findings(items, canManage: canManage)))
    }

    static func member(_ items: [WsModel.HealthFinding]) -> FleetSummary.Member {
        .init(id: a, name: "A", reachability: .online, digest: NodeDigest(health: .value(health(items))))
    }

    // MARK: The state the item shows

    @Test func attendedFindingsNoLongerRaiseTheItemButStayOnTheHealthFigures() {
        let acknowledged = [Self.finding("system.db.disconnected", "error", card: "system.db", state: "acknowledged")]
        let status = FleetStatus([Self.member(acknowledged)])
        #expect(status.level == .quiet)
        #expect(status.headline == "A: nothing needs attention")
        #expect(status.detail == "1 finding acknowledged or silenced")
        // The health is still the truth.
        let health = Self.health(acknowledged)
        #expect(health.hasErrors && !health.needsErrorAttention)
        #expect(health.alerts.first?.state == .acknowledged)
        #expect(health.alerts.first?.mark?.setByName == "cooper")

        // An unattended warning next to a silenced error: warnings, not attention.
        let mixed = [Self.finding("system.db.disconnected", "error", card: "system.db", state: "silenced",
                                  until: Self.now + 3_600),
                     Self.finding("system.fuse.error_rate_elevated", "warning")]
        #expect(FleetStatus([Self.member(mixed)]).level == .warnings)
        let summary = FleetSummary([Self.member(mixed)])
        #expect(summary.alerts.map(\.alert.code) == ["system.fuse.error_rate_elevated"])
        #expect(summary.silenced.map(\.alert.code) == ["system.db.disconnected"])
        #expect(summary.nodesWithErrors == [Self.a])
    }

    @Test func aNodeWithoutFindingsIsJudgedAsBefore() {
        let overview = FleetSamples.overview(status: "error", attention: [("system.db.disconnected", "error", "system.db")])
        let health = NodeDigest.Health(overview)
        #expect(health.unattendedErrorCount == nil)
        #expect(health.needsErrorAttention)
        #expect(!health.canManageFindings)
        #expect(health.alerts.allSatisfy { !$0.canManage && $0.state == .active && $0.notifies == nil })
        let member = FleetSummary.Member(id: Self.a, name: "A", reachability: .online,
                                         digest: NodeDigest(health: .value(health)))
        #expect(FleetStatus([member]).level == .attention)
    }

    @Test func anOverviewThatCarriesTheUnattendedCountsIsFollowedToo() {
        var overview = FleetSamples.overview(status: "error", attention: [("system.db.disconnected", "error", "system.db")])
        overview.unattendedErrorCount = 0
        overview.unattendedWarningCount = 0
        overview.attention[0].state = "acknowledged"
        let health = NodeDigest.Health(overview)
        #expect(!health.needsErrorAttention && health.hasErrors)
        #expect(health.alerts.first?.state == .acknowledged)
        // Without the findings list nothing can be done from here.
        #expect(health.alerts.first?.canManage == false)
    }

    // MARK: Notifications

    static func observe(_ items: [WsModel.HealthFinding]) -> FleetObservation {
        FleetObservation(id: a, name: "A", reachability: .online, findings: health(items).alerts)
    }

    @Test func acknowledgedAndSilencedFindingsAreNotToldAndAnAcknowledgedErrorIsNotCleared() {
        var run = MenuBarTests.Run()
        let error = Self.finding("system.db.disconnected", "error", card: "system.db")
        #expect(run.check(Self.observe([error])).map(\.notice) == [.healthError])
        // Someone acknowledged it: nothing to say, and certainly not "no longer reporting errors".
        let acknowledged = Self.finding("system.db.disconnected", "error", card: "system.db", state: "acknowledged")
        #expect(run.check(Self.observe([acknowledged]), after: 60).isEmpty)
        // It clears for real: now it is over.
        #expect(run.check(Self.observe([]), after: 60).map(\.notice) == [.healthCleared])

        // A finding silenced before it was ever seen is never told.
        var quiet = MenuBarTests.Run()
        let silenced = Self.finding("system.retention.overdue", "error", card: "system.retention", state: "silenced",
                                    until: Self.now + 3_600)
        #expect(quiet.check(Self.observe([silenced])).isEmpty)
        // Its silence ends an hour later, still active: it speaks again.
        let back = Self.finding("system.retention.overdue", "error", card: "system.retention")
        #expect(quiet.check(Self.observe([back]), after: 3_600).map(\.notice) == [.healthError])
    }

    @Test func warningsFollowTheServersHint() {
        var run = MenuBarTests.Run()
        let busy = Self.finding("system.operations.active_work", "warning", card: "system.operations", notifies: false)
        let degraded = Self.finding("system.storage.degraded_vaults", "warning", card: "system.storage")
        let told = run.check(Self.observe([busy, degraded]))
        // On by default for a warning the node says is worth it; never for one it says isn't.
        #expect(told.map(\.notice) == [.healthNotableWarning])
        #expect(told.first?.title == "A: system.storage")
        #expect(told.first?.sound == false)

        // Even with every warning switched on, a class the node says isn't worth it stays quiet.
        var loud = MenuBarTests.Run()
        loud.settings.set(.healthWarning, on: true)
        #expect(loud.check(Self.observe([busy])).isEmpty)
        // And the hinted warnings can be switched off on their own.
        var off = MenuBarTests.Run()
        off.settings.set(.healthNotableWarning, on: false)
        #expect(off.check(Self.observe([degraded])).isEmpty)
    }

    @Test func aFindingsNotificationCanBeTakenBack() {
        let alert = Self.health([Self.finding("system.db.disconnected", "error", card: "system.db")]).alerts[0]
        var run = MenuBarTests.Run()
        let posted = run.check(FleetObservation(id: Self.a, name: "A", reachability: .online, findings: [alert]))
        #expect(FleetNotifier.notificationIDs(for: alert, on: Self.a).contains(posted[0].id))
        #expect(alert.canManage)
    }

    // MARK: The pulse

    static func negotiated(withFindings: Bool) -> NodeProtocol {
        let commands = Set(WsCommand.allCases.map(\.rawValue)).filter { withFindings || !$0.hasPrefix("health.") }
        return NodeProtocol(state: .negotiated, version: 1, serverRange: 1...1, capabilities: [], commands: commands)
    }

    @MainActor @Test func theBackgroundCheckAsksForTheFindingsWhenTheNodeHasThem() async throws {
        let node = FleetSamples.scriptedNode(status: "warning")
        let state = Shared("active")
        node.answer("health.findings.list") { _ in
            .ok(["health": FleetSamples.json(Self.findings([Self.finding("system.fuse.error_rate_elevated", "warning",
                                                                         state: state.value)]))])
        }
        node.answer("health.finding.acknowledge") { _ in
            state.value = "acknowledged"
            return .ok(["health": FleetSamples.json(Self.findings([Self.finding("system.fuse.error_rate_elevated",
                                                                                "warning", state: "acknowledged")]))])
        }
        let queries = NodeQueries(transport: node)
        queries.protocolChanged(Self.negotiated(withFindings: true))
        let pulse = NodePulse(queries: queries)

        await pulse.checkHealth()
        await pulse.checkHealth()
        #expect(node.count(of: "health.findings.list") == 2)
        #expect(node.count(of: "stats.dashboard.severity") == 0)
        #expect(node.count(of: "stats.dashboard.overview") == 1)
        #expect(pulse.digest.health.value?.alerts.first?.state == .active)
        #expect(pulse.digest.health.value?.alerts.first?.remedies.first?.href == "/health/filesystem#fuse")

        // A person acknowledges it: the answer shows at once, without another read.
        let refusal = await pulse.perform(.acknowledge, findingClass: "system.fuse.error_rate_elevated")
        #expect(refusal == nil)
        #expect(node.payloads(of: "health.finding.acknowledge") == [["class": "system.fuse.error_rate_elevated"]])
        #expect(pulse.digest.health.value?.alerts.first?.state == .acknowledged)
        #expect(pulse.digest.health.value?.needsWarningAttention == false)
        #expect(node.count(of: "health.findings.list") == 2)
    }

    @MainActor @Test func silenceSendsHowLongAndARefusalComesBack() async throws {
        let node = FleetSamples.scriptedNode(status: "warning")
        node.answer("health.finding.silence") { _ in .refuse("Needs admin.stats.manage.", code: "denied") }
        let queries = NodeQueries(transport: node)
        queries.protocolChanged(Self.negotiated(withFindings: true))
        let pulse = NodePulse(queries: queries)

        let refusal = await pulse.perform(.silence(.day), findingClass: "system.db.warning")
        #expect(refusal?.message == "Needs admin.stats.manage.")
        _ = await pulse.perform(.silence(.untilTurnedBackOn), findingClass: "system.db.warning")
        #expect(node.payloads(of: "health.finding.silence") == [
            ["class": "system.db.warning", "for_seconds": 86_400], ["class": "system.db.warning"],
        ])
    }

    @MainActor @Test func aNodeWithoutTheCommandsKeepsTheSmallQuestion() async throws {
        let node = FleetSamples.scriptedNode(status: "healthy")
        let healthy = WsModel.DashboardSeverity(overallStatus: "healthy", errorCount: 0, warningCount: 0,
                                                checkedAt: FleetSamples.now)
        node.answer("stats.dashboard.severity") { _ in .ok(["stats": FleetSamples.json(healthy)]) }
        let queries = NodeQueries(transport: node)
        queries.protocolChanged(Self.negotiated(withFindings: false))
        let pulse = NodePulse(queries: queries)

        await pulse.checkHealth()
        await pulse.refresh()
        #expect(node.count(of: "health.findings.list") == 0)
        #expect(node.count(of: "stats.dashboard.severity") == 1)
        #expect(pulse.healthFindings == nil)
        #expect(pulse.digest.health.value?.canManageFindings == false)
    }
}
