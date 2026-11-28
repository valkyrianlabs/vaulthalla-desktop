import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
import VHIdentity
@testable import VHNodes
import VHTransport

/// Health findings by push against a live daemon with `health.subscribe` (the server's design/health/findings.md §6;
/// docs/interop-testing.md): this Mac pairs as the instance's super admin, and Desktop's own `NodePulse` and
/// `HealthFindings` read the findings, subscribe, and follow `health.changed` while the finding is acknowledged from the
/// CLI (another session) and from Desktop. Skipped unless `VH_LIVE_NODE` is set. The finding it acts on is
/// `VH_LIVE_HEALTH_CLASS`, else the first active one; with none active it says so and acts on nothing.
@Suite(.enabled(if: LiveNode.isConfigured, "set VH_LIVE_NODE=<host:port> to run against a live daemon"),
       .serialized, .timeLimit(.minutes(5)))
struct LiveHealthPushTests {
    @Test func followsHealthByPushAndActsOnAFinding() async throws {
        let endpoint = try LiveNode.requireEndpoint()
        try await LiveKeychain.withKeys { keys in
            let paired = try await LiveLink.pair(keys, tag: "live-health", name: "health", endpoint: endpoint,
                                                 run: LiveNode.runDirectory)
            var settings = NodeSession.Configuration()
            settings.reconnect = ReconnectPolicy(base: .milliseconds(200), cap: .seconds(2))
            let session = NodeSession(node: paired.node, keys: keys, configuration: settings)
            let events = Recorder(session.events)
            await session.start()
            try #require(await events.first(within: .seconds(20)) { $0.status == .online } != nil,
                         "the session never came online: \(events.all)")
            #expect(await session.supports(command: .healthSubscribe) == .yes)
            #expect(await session.supports(capability: "health.push") == .yes)

            let counting = CountingTransport(session)
            let pulse = await Self.pulse(on: counting, protocol: await session.nodeProtocol)
            let forwarding = Task { await Self.forward(events, to: pulse) }

            // 1. The findings with the catalog, as the paired super admin: it may act on them.
            let catalog = await MainActor.run { pulse.queries.healthFindings(includeCatalog: true) }
            await catalog.refresh()
            let failure = await MainActor.run { catalog.error }
            let listed = try #require(await MainActor.run { catalog.value.map { HealthFindings($0.health) } },
                                      "health.findings.list: \(String(describing: failure))")
            #expect(listed.canManage)
            #expect(!listed.classTitles.isEmpty)
            print("[live] findings: \(listed.findings.map { "\($0.findingClass) \($0.severity) \($0.state)" }), "
                + "\(listed.classTitles.count) classes, can_manage \(listed.canManage)")

            // 2. Subscribed on connect; the background check then rests on the push.
            await MainActor.run { pulse.connectionChanged(online: true) }
            try await Self.waitFor { await MainActor.run { pulse.isFollowingPush } }
            #expect(counting.count(of: "health.subscribe") == 1)
            await pulse.checkHealth()
            let checked = counting.count(of: "health.findings.list")
            await pulse.checkHealth()
            #expect(counting.count(of: "health.findings.list") == checked, "a check while subscribed asked again")

            let named = ProcessInfo.processInfo.environment["VH_LIVE_HEALTH_CLASS"]
            guard let target = listed.findings.first(where: { named == nil ? $0.state == .active : $0.findingClass == named })
            else {
                // Nothing active to acknowledge: silence a class that is not active instead (the true counts are
                // untouched either way), and turn it back on.
                let quiet = try #require(listed.classTitles.keys.sorted().first { cls in
                    !listed.findings.contains { $0.findingClass == cls }
                })
                print("[live] no active finding; silencing the inactive class \(quiet) instead")
                let seen = events.all.count
                #expect(await pulse.perform(.silence(.hour), findingClass: quiet) == nil)
                let pushed = await events.first(after: seen, within: .seconds(30)) { $0.healthChange != nil }
                print("[live] pushed after the silence: \(String(describing: pushed?.healthChange))")
                try await Self.waitFor { await MainActor.run { pulse.healthFindings?.silences.contains { $0.findingClass == quiet } == true } }
                #expect(await pulse.perform(.turnBackOn, findingClass: quiet) == nil)
                forwarding.cancel()
                await session.stop()
                try await LiveNode.vh(["device", "revoke", paired.deviceID], admin: true)
                return
            }
            let unattendedBefore = listed.unattendedErrorCount + listed.unattendedWarningCount
            print("[live] acting on \(target.findingClass) (\(target.severity)); unattended \(unattendedBefore), "
                + "errors \(listed.errorCount), warnings \(listed.warningCount)")

            // 3. Acknowledged from the CLI (another session): the push arrives and the pulse refetches on its own.
            let listsBefore = counting.count(of: "health.findings.list")
            let seen = events.all.count
            try await LiveNode.vh(["health", "ack", target.findingClass], admin: true)
            let pushed = try #require(await events.first(after: seen, within: .seconds(30)) { $0.healthChange != nil },
                                      "no health.changed after the CLI's acknowledge")
            print("[live] pushed after the CLI's ack: \(String(describing: pushed.healthChange))")
            try await Self.waitFor { await Self.state(of: target, in: pulse) == .acknowledged }
            #expect(counting.count(of: "health.findings.list") > listsBefore, "the pulse refetched on the event")
            let after = try #require(await MainActor.run { pulse.healthFindings })
            #expect(after.errorCount == listed.errorCount && after.warningCount == listed.warningCount)
            #expect(after.unattendedErrorCount + after.unattendedWarningCount < unattendedBefore)
            print("[live] after the ack: errors \(after.errorCount), warnings \(after.warningCount), unattended "
                + "\(after.unattendedErrorCount)/\(after.unattendedWarningCount)")

            // `vh health` over the unix socket lists the same state.
            let cli = try await LiveNode.vhJSON(["health", "list"], admin: true)
            let cliState = cli["health"]?["findings"]?.arrayValue?
                .first { $0["class"]?.stringValue == target.findingClass }?["state"]?.stringValue
            #expect(cliState == "acknowledged")
            #expect(cli["health"]?["unattended_error_count"]?.integerValue == after.unattendedErrorCount)
            #expect(cli["health"]?["unattended_warning_count"]?.integerValue == after.unattendedWarningCount)

            // 4. Turned back on from Desktop: pushed too, and the counts come back.
            let beforeOn = events.all.count
            #expect(await pulse.perform(.turnBackOn, findingClass: target.findingClass) == nil)
            #expect(await events.first(after: beforeOn, within: .seconds(30)) { $0.healthChange != nil } != nil)
            try await Self.waitFor { await Self.state(of: target, in: pulse) == .active }
            let back = try #require(await MainActor.run { pulse.healthFindings })
            #expect(back.unattendedErrorCount + back.unattendedWarningCount == unattendedBefore)

            // 5. Acknowledged from Desktop (HealthFindings' action), pushed; then once more with a note, which the
            //    audit trail records as present without its text.
            let beforeAck = events.all.count
            #expect(await pulse.perform(.acknowledge, findingClass: target.findingClass) == nil)
            #expect(await events.first(after: beforeAck, within: .seconds(30)) { $0.healthChange != nil } != nil)
            #expect(await Self.state(of: target, in: pulse) == .acknowledged)
            #expect(await pulse.perform(.turnBackOn, findingClass: target.findingClass) == nil)
            let note = "live-proof-note-\(UUID().uuidString.prefix(8))"
            _ = try await session.send(Ws.Health.Finding.Acknowledge.self,
                                       payload: .init(class: target.findingClass, note: .value(note)))
            let trail = try await session.send(Ws.Audit.List.self, payload: .init(action: .value("health."), limit: 20))
            let text = String(decoding: try JSONEncoder().encode(trail), as: UTF8.self)
            let actions = trail.events.map(\.action)
            #expect(actions.contains("health.finding.acknowledge") && actions.contains("health.finding.unsilence"))
            #expect(!text.contains(note), "the audit trail carries the note's text")
            print("[live] audit: \(actions.prefix(6)); note text absent: \(!text.contains(note))")
            #expect(await pulse.perform(.turnBackOn, findingClass: target.findingClass) == nil)
            try await Self.waitFor { await Self.state(of: target, in: pulse) == .active }
            let restored = try #require(await MainActor.run { pulse.healthFindings })
            #expect(restored.unattendedErrorCount + restored.unattendedWarningCount == unattendedBefore)
            print("[live] list \(counting.count(of: "health.findings.list")), subscribe "
                + "\(counting.count(of: "health.subscribe")), events "
                + "\(events.all.filter { $0.healthChange != nil }.count)")

            forwarding.cancel()
            await session.stop()
            try await LiveNode.vh(["device", "revoke", paired.deviceID], admin: true)
        }
    }

    /// The seeded user (no admin.stats.manage) may not acknowledge, on its own Device session.
    @Test func anAccountWithoutManageIsRefused() async throws {
        let endpoint = try LiveNode.requireEndpoint()
        try await LiveKeychain.withKeys { keys in
            let identity = try await keys.identityForPairing(nodeTag: "live-node", deviceName: LiveInteropTests.deviceName,
                                                             replacingExisting: true)
            let final = try await LiveInteropTests.pair(identity, endpoint: endpoint) { code, _ in code.digits }
            try await LiveNode.vh(["device", "pair", "--close"])
            guard case .approved(let serverNodeID, let nodeName, let deviceID, let serverSPKI) = final else {
                Issue.record("pairing ended \(final)")
                return
            }
            let node = Node(id: NodeID(rawValue: "live-node"), displayName: nodeName, endpoint: endpoint,
                            pairing: .paired(serverSPKISHA256: serverSPKI, deviceID: deviceID, since: .now),
                            serverNodeID: serverNodeID)
            let session = NodeSession(node: node, keys: keys)
            let events = Recorder(session.events)
            await session.start()
            try #require(await events.first(within: .seconds(20)) { $0.status == .online } != nil)
            let listed = try? await session.send(Ws.Health.Findings.List.self, payload: .init())
            print("[live] the seeded user's list: \(listed.map { "can_manage \($0.health.canManage)" } ?? "refused")")
            if let listed { #expect(!listed.health.canManage) }
            do throws(WsError) {
                _ = try await session.send(Ws.Health.Finding.Acknowledge.self, payload: .init(class: "system.db.warning"))
                Issue.record("the acknowledge was accepted")
            } catch {
                print("[live] the seeded user's acknowledge: \(error.message)")
                if case .denied = error {} else { Issue.record("expected denied, got \(error)") }
            }
            await session.stop()
            try await LiveNode.vh(["device", "revoke", deviceID])
        }
    }

    @MainActor
    static func pulse(on transport: CountingTransport, protocol settled: NodeProtocol?) -> NodePulse {
        let queries = NodeQueries(transport: transport)
        queries.protocolChanged(settled)
        return NodePulse(queries: queries)
    }

    /// Hands the session's `health.changed` events to the pulse, as the app does.
    static func forward(_ events: Recorder<NodeSession.Event>, to pulse: NodePulse) async {
        var next = 0
        while !Task.isCancelled {
            let all = events.all
            for event in all.dropFirst(next) {
                if let change = event.healthChange { await MainActor.run { pulse.healthChanged(change) } }
            }
            next = all.count
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    static func state(of finding: HealthFindings.Finding, in pulse: NodePulse) async -> HealthFindings.State? {
        await MainActor.run { pulse.healthFindings?.findings.first { $0.id == finding.id }?.state }
    }

    static func waitFor(within timeout: Duration = .seconds(30), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw LiveFailure("condition not met within \(timeout)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// A session that counts the commands sent through it.
final class CountingTransport: NodeTransport {
    let session: NodeSession
    private let sent = Mutex<[String]>([])

    init(_ session: NodeSession) { self.session = session }

    func count(of command: String) -> Int { sent.withLock { $0.filter { $0 == command }.count } }

    func send<R: WsRequest>(_ request: R.Type, payload: R.Payload) async throws(WsError) -> R.Response {
        sent.withLock { $0.append(R.command.rawValue) }
        return try await session.send(request, payload: payload)
    }

    func commandSupport(_ command: WsCommand) async -> ProtocolSupport { await session.supports(command: command) }

    func capabilitySupport(_ capability: WsCapability) async -> ProtocolSupport {
        await session.supports(capability: capability)
    }
}

extension NodeSession.Event {
    var healthChange: HealthChange? {
        if case .healthChanged(let change) = self { return change }
        return nil
    }
}
