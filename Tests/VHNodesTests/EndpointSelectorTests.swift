import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
@testable import VHNodes
import VHTransport

/// A prober that answers from a script, after a scripted delay, and records when each probe started.
final class FakeProber: EndpointProbing {
    struct Step: Sendable {
        var delay: Duration
        var result: EndpointProbeResult
    }

    private let script: [String: Step]
    private let clock = ContinuousClock()
    let origin = ContinuousClock.now
    private let started = Mutex<[(host: String, at: Duration)]>([])

    init(_ script: [String: Step]) {
        self.script = script
    }

    /// The hosts probed, in the order they started, with when (since the prober was made).
    var starts: [(host: String, at: Duration)] { started.withLock { $0 } }
    var order: [String] { starts.map(\.host) }

    func probe(_ endpoint: NodeEndpoint, timeout: Duration) async -> EndpointProbeResult {
        started.withLock { $0.append((endpoint.host, clock.now - origin)) }
        let step = script[endpoint.host] ?? Step(delay: .milliseconds(5), result: .init(outcome: .refused))
        do {
            try await Task.sleep(for: min(step.delay, timeout))
        } catch {
            return EndpointProbeResult(outcome: .timeout)
        }
        return step.delay > timeout ? EndpointProbeResult(outcome: .timeout) : step.result
    }

    static func ok(after delay: Duration = .milliseconds(5), address: String? = nil, interface: String? = nil,
                   pin: Data = Data([1])) -> Step {
        Step(delay: delay, result: EndpointProbeResult(outcome: .ok, rtt: .milliseconds(2), remoteAddress: address,
                                                       interfaceName: interface, matchedPin: pin))
    }

    static func fail(_ outcome: EndpointProbeResult.Outcome, after delay: Duration = .milliseconds(5)) -> Step {
        Step(delay: delay, result: EndpointProbeResult(outcome: outcome))
    }
}

@Suite struct EndpointSelectorTests {
    private func node(_ host: String = "vh.example.com", port: UInt16 = 36972, advertised: [AdvertisedEndpoint] = [],
                      lastGood: LastGoodEndpoint? = nil) -> Node {
        Node(id: NodeID(rawValue: "n"), displayName: "vh", endpoint: NodeEndpoint(host: host, port: port),
             pairing: .paired(serverSPKISHA256: Data([1]), deviceID: "d", since: .now),
             serverNodeID: "node-1", endpoints: advertised, lastGood: lastGood)
    }

    private func fast() -> EndpointSelector {
        var configuration = EndpointSelector.Configuration()
        configuration.stagger = .milliseconds(60)
        configuration.probeTimeout = .milliseconds(600)
        configuration.overallTimeout = .milliseconds(1200)
        configuration.grace = .milliseconds(150)
        configuration.bonjourBrowse = .milliseconds(50)
        return EndpointSelector(configuration: configuration)
    }

    // MARK: Candidates

    @Test func mergesSourcesAndDeduplicatesByHostAndPort() {
        let node = node("VH.Example.com", advertised: [
            AdvertisedEndpoint(host: "127.0.0.1", port: 36972, kind: .loopback, source: "interface", interface: "lo"),
            AdvertisedEndpoint(host: "10.0.0.11", port: 36972, kind: .lan, source: "interface", interface: "enp3s0"),
            AdvertisedEndpoint(host: "vh.example.com", port: 36972, kind: .wan, source: "config"),
            AdvertisedEndpoint(host: "vh.example.com", port: 443, kind: .passthrough, source: "config"),
        ], lastGood: LastGoodEndpoint(endpoint: NodeEndpoint(host: "10.0.0.11"), at: .now, transportClass: .lan))
        let candidates = EndpointCandidate.candidates(for: node)
        #expect(candidates.map(\.endpoint.description) == [
            "127.0.0.1:36972", "[::1]:36972", "VH.Example.com:36972", "10.0.0.11:36972", "vh.example.com:443",
        ])
        #expect(candidates[0].sources == [.loopback, .advertised])
        #expect(candidates[2].sources == [.configured, .advertised])
        #expect(candidates[2].advertisedKind == .wan)
        #expect(candidates[3].sources == [.advertised, .lastGood])
        #expect(candidates[3].interface == "enp3s0")
        #expect(candidates[4].estimatedClass == .passthrough)
    }

    @Test func loopbackIsAlwaysACandidateAtTheListenerPort() {
        let passthrough = node("vh.example.com", port: 443, advertised: [
            AdvertisedEndpoint(host: "::1", port: 36972, kind: .loopback),
        ])
        let hosts = EndpointCandidate.candidates(for: passthrough).map(\.endpoint.description)
        #expect(hosts.prefix(2) == ["127.0.0.1:36972", "[::1]:36972"])
        // Without an advertisement, the configured port.
        #expect(EndpointCandidate.candidates(for: node(port: 4443)).first?.endpoint.port == 4443)
    }

    // MARK: Ordering and choice

    @Test func picksTheBestClassActuallyReached() async {
        // The configured name resolves to a LAN address (split horizon): it beats the advertised WAN one even
        // though its name alone says nothing.
        let node = node("vh.example.com", advertised: [
            AdvertisedEndpoint(host: "203.0.113.7", port: 36972, kind: .wan),
        ])
        let prober = FakeProber([
            "vh.example.com": FakeProber.ok(after: .milliseconds(40), address: "10.0.0.11"),
            "203.0.113.7": FakeProber.ok(after: .milliseconds(10), address: "203.0.113.7"),
        ])
        let selection = await fast().select(EndpointCandidate.candidates(for: node), prober: prober)
        #expect(selection.chosen?.candidate.endpoint.host == "vh.example.com")
        #expect(selection.chosen?.transportClass == .lan)
        #expect(selection.report(for: NodeEndpoint(host: "127.0.0.1"))?.outcome == .refused)
    }

    @Test func probesInPriorityOrderStaggered() async {
        let node = node("vh.example.com", advertised: [
            AdvertisedEndpoint(host: "203.0.113.7", port: 36972, kind: .wan),
            AdvertisedEndpoint(host: "100.101.1.2", port: 36972, kind: .vpn),
            AdvertisedEndpoint(host: "10.0.0.11", port: 36972, kind: .lan),
        ])
        // Every probe hangs, so only the stagger spaces the starts.
        let hang = FakeProber.fail(.timeout, after: .seconds(5))
        let prober = FakeProber(["127.0.0.1": hang, "::1": hang, "10.0.0.11": hang, "100.101.1.2": hang,
                                 "203.0.113.7": hang, "vh.example.com": hang])
        let selection = await fast().select(EndpointCandidate.candidates(for: node), prober: prober)
        #expect(selection.chosen == nil)
        // loopback, lan, vpn, then wan (the configured name first: server order within the class).
        #expect(prober.order == ["127.0.0.1", "::1", "10.0.0.11", "100.101.1.2", "vh.example.com", "203.0.113.7"])
        let starts = prober.starts.map(\.at)
        for (earlier, later) in zip(starts.prefix(4), starts.dropFirst().prefix(3)) {
            #expect(later - earlier >= .milliseconds(50))
        }
        // At most four in flight: the fifth starts only when the first probe's 600 ms ran out.
        #expect(starts[4] >= .milliseconds(580))
        #expect(selection.reports.allSatisfy { $0.outcome == .timeout })
    }

    @Test func aFailureStartsTheNextProbeAtOnce() async {
        let node = node("vh.example.com")
        let prober = FakeProber([
            "127.0.0.1": FakeProber.fail(.refused, after: .milliseconds(1)),
            "::1": FakeProber.fail(.refused, after: .milliseconds(1)),
            "vh.example.com": FakeProber.ok(address: "203.0.113.7"),
        ])
        var configuration = EndpointSelector.Configuration()
        configuration.stagger = .milliseconds(400)
        let selection = await EndpointSelector(configuration: configuration)
            .select(EndpointCandidate.candidates(for: node), prober: prober)
        #expect(selection.chosen?.candidate.endpoint.host == "vh.example.com")
        // Without the early start the third probe would begin at 800 ms.
        #expect(try! #require(prober.starts.last).at < .milliseconds(300))
    }

    @Test func waitsBrieflyForABetterProbeStillInFlight() async {
        let node = node("vh.example.com", advertised: [AdvertisedEndpoint(host: "10.0.0.11", port: 36972, kind: .lan)])
        // LAN answers 80 ms after the WAN name: within the grace window, so it wins.
        let prober = FakeProber([
            "10.0.0.11": FakeProber.ok(after: .milliseconds(140), address: "10.0.0.11"),
            "vh.example.com": FakeProber.ok(after: .milliseconds(5), address: "203.0.113.7"),
        ])
        var configuration = EndpointSelector.Configuration()
        configuration.stagger = .milliseconds(10)
        configuration.grace = .milliseconds(250)
        let selection = await EndpointSelector(configuration: configuration)
            .select(EndpointCandidate.candidates(for: node), prober: prober)
        #expect(selection.chosen?.candidate.endpoint.host == "10.0.0.11")
    }

    @Test func theGraceWindowIsBounded() async {
        let node = node("vh.example.com", advertised: [AdvertisedEndpoint(host: "10.0.0.11", port: 36972, kind: .lan)])
        let prober = FakeProber([
            "10.0.0.11": FakeProber.ok(after: .milliseconds(900), address: "10.0.0.11"),
            "vh.example.com": FakeProber.ok(after: .milliseconds(5), address: "203.0.113.7"),
        ])
        var configuration = EndpointSelector.Configuration()
        configuration.stagger = .milliseconds(10)
        configuration.grace = .milliseconds(100)
        let clock = ContinuousClock()
        let started = clock.now
        let selection = await EndpointSelector(configuration: configuration)
            .select(EndpointCandidate.candidates(for: node), prober: prober)
        #expect(clock.now - started < .milliseconds(600))
        #expect(selection.chosen?.candidate.endpoint.host == "vh.example.com")
        #expect(selection.chosen?.transportClass == .wan)
        #expect(selection.report(for: NodeEndpoint(host: "10.0.0.11"))?.outcome == .timeout)
    }

    @Test func lastGoodGoesFirstWithinItsClass() async {
        let node = node("vh.example.com", advertised: [
            AdvertisedEndpoint(host: "10.0.0.11", port: 36972, kind: .lan),
            AdvertisedEndpoint(host: "192.168.1.5", port: 36972, kind: .lan),
        ], lastGood: LastGoodEndpoint(endpoint: NodeEndpoint(host: "192.168.1.5"), at: .now, transportClass: .lan))
        let prober = FakeProber([
            "10.0.0.11": FakeProber.ok(address: "10.0.0.11"),
            "192.168.1.5": FakeProber.ok(address: "192.168.1.5"),
        ])
        let selection = await fast().select(EndpointCandidate.candidates(for: node), prober: prober)
        #expect(prober.order.prefix(3) == ["127.0.0.1", "::1", "192.168.1.5"])
        #expect(selection.chosen?.candidate.endpoint.host == "192.168.1.5")
    }

    @Test func tunnelInterfacesCountAsVPN() async {
        let node = node("10.8.0.1")
        let prober = FakeProber(["10.8.0.1": FakeProber.ok(address: "10.8.0.1", interface: "utun3")])
        let selection = await fast().select(EndpointCandidate.candidates(for: node), prober: prober)
        #expect(selection.chosen?.transportClass == .vpn)
    }

    // MARK: Pins

    @Test func aMismatchElsewhereOnlyMarksThatCandidate() async {
        // Another Vaulthalla on this Mac answers on loopback with its own key.
        let node = node("vh.example.com")
        let prober = FakeProber([
            "127.0.0.1": FakeProber.fail(.identityMismatch),
            "vh.example.com": FakeProber.ok(address: "203.0.113.7", pin: Data([2])),
        ])
        let selection = await fast().select(EndpointCandidate.candidates(for: node), prober: prober)
        #expect(selection.chosen?.candidate.isConfigured == true)
        #expect(selection.chosen?.matchedPin == Data([2]))
        #expect(selection.report(for: NodeEndpoint(host: "127.0.0.1"))?.outcome == .identityMismatch)
        #expect(!selection.configuredEndpointMismatched)
        // Loopback is tried for every node: its failures aren't "a better route wasn't used".
        #expect(selection.betterRoutesNotUsed.isEmpty)
    }

    @Test func explainsAdvertisedBetterRoutesThatFailed() async {
        let node = node("vh.example.com", advertised: [
            AdvertisedEndpoint(host: "10.0.0.11", port: 36972, kind: .lan),
            AdvertisedEndpoint(host: "127.0.0.1", port: 36972, kind: .loopback),
        ])
        let prober = FakeProber([
            "10.0.0.11": FakeProber.fail(.timeout, after: .milliseconds(20)),
            "vh.example.com": FakeProber.ok(address: "203.0.113.7"),
        ])
        let selection = await fast().select(EndpointCandidate.candidates(for: node), prober: prober)
        #expect(selection.chosen?.transportClass == .wan)
        #expect(selection.betterRoutesNotUsed.map(\.candidate.endpoint.host) == ["127.0.0.1", "10.0.0.11"])
    }

    @Test func aMismatchOnTheConfiguredEndpointWithNoSuccessIsTheOldPinFailure() async {
        let node = node("vh.example.com")
        let prober = FakeProber([
            "127.0.0.1": FakeProber.fail(.identityMismatch),
            "vh.example.com": FakeProber.fail(.identityMismatch),
        ])
        let selection = await fast().select(EndpointCandidate.candidates(for: node), prober: prober)
        #expect(selection.chosen == nil)
        #expect(selection.configuredEndpointMismatched)
        // Only loopback mismatched and the configured one is unreachable: offline, not a pin failure.
        let away = FakeProber(["127.0.0.1": FakeProber.fail(.identityMismatch),
                               "vh.example.com": FakeProber.fail(.timeout)])
        #expect(!(await fast().select(EndpointCandidate.candidates(for: node), prober: away)).configuredEndpointMismatched)
    }

    // MARK: Bonjour

    @Test func bonjourIsTheLastSource() async {
        let node = node("vh-old.local")
        let browsed = Mutex(0)
        let prober = FakeProber(["vh-storage.local": FakeProber.ok(address: "10.0.0.20")])
        let selection = await fast().select(EndpointCandidate.candidates(for: node), prober: prober) { _ in
            browsed.withLock { $0 += 1 }
            return [NodeEndpoint(host: "vh-old.local"), NodeEndpoint(host: "vh-storage.local")]
        }
        #expect(browsed.withLock { $0 } == 1)
        #expect(selection.usedBonjour)
        #expect(selection.chosen?.candidate.sources == [.bonjour])
        // An address already probed isn't probed again.
        #expect(prober.order.filter { $0 == "vh-old.local" }.count == 1)

        // Not browsed when something else worked.
        let reachable = FakeProber(["vh-old.local": FakeProber.ok(address: "10.0.0.20")])
        let direct = await fast().select(EndpointCandidate.candidates(for: node), prober: reachable) { _ in
            browsed.withLock { $0 += 1 }
            return []
        }
        #expect(!direct.usedBonjour && browsed.withLock { $0 } == 1)
    }

    // MARK: Schedule

    @Test func neverMoreOftenThanEveryFiveSeconds() {
        var schedule = RouteSchedule()
        let now = ContinuousClock.now
        #expect(schedule.earliest(for: .connect, activeClass: nil, now: now) == now)
        schedule.recordSelection(at: now)
        #expect(schedule.isFresh(now: now + .seconds(2)))
        #expect(!schedule.isFresh(now: now + .seconds(5)))
        #expect(schedule.earliest(for: .pathChanged, activeClass: .lan, now: now + .seconds(1)) == now + .seconds(5))
        #expect(schedule.earliest(for: .laneFailure, activeClass: .lan, now: now + .seconds(9)) == now + .seconds(9))
        #expect(schedule.earliest(for: .manual, activeClass: .lan, now: now + .seconds(3)) == now + .seconds(5))
    }

    @Test func dropsReselectOnlyFromTheSecondInARow() {
        let schedule = RouteSchedule()
        let now = ContinuousClock.now
        #expect(schedule.earliest(for: .dropped(consecutive: 1), activeClass: .lan, now: now) == nil)
        #expect(schedule.earliest(for: .dropped(consecutive: 2), activeClass: .lan, now: now) == now)
        #expect(schedule.earliest(for: .dropped(consecutive: 5), activeClass: nil, now: now) == now)
    }

    @Test func upgradesEveryThirtyMinutesOnlyBelowLAN() {
        var schedule = RouteSchedule()
        let now = ContinuousClock.now
        schedule.recordSelection(at: now)
        #expect(schedule.nextUpgrade(activeClass: .lan) == nil)
        #expect(schedule.nextUpgrade(activeClass: .loopback) == nil)
        #expect(schedule.nextUpgrade(activeClass: .vpn) == now + .seconds(1800))
        #expect(schedule.nextUpgrade(activeClass: .passthrough) == now + .seconds(1800))
        #expect(schedule.earliest(for: .upgrade, activeClass: .lan, now: now + .seconds(1800)) == nil)
        #expect(schedule.earliest(for: .upgrade, activeClass: .wan, now: now + .seconds(1800)) == now + .seconds(1800))
    }

    // MARK: Advertisement

    @Test func decodesTheSpecExampleDefensively() throws {
        let json: JSONValue = [
            "node_id": "node-1", "port": 36972, "remote": true, "listening": true, "generated_at": 1_793_453_809,
            "candidates": [
                ["host": "127.0.0.1", "port": 36972, "kind": "loopback", "source": "interface", "interface": "lo"],
                ["host": "fd00::11", "port": 36972, "kind": "lan", "source": "interface", "interface": "enp3s0"],
                ["host": "vh-storage.local", "port": 36972, "kind": "lan", "source": "mdns"],
                ["host": "device.example.com", "port": 443, "kind": "passthrough", "source": "config"],
                ["host": "device.example.com", "port": 443, "kind": "wan"],
                ["host": "evil.example.com/ws?x=", "port": 36972],
                ["host": "a b", "port": 36972],
                ["host": "x:y", "port": 1],
                ["host": "ok.example", "port": 0],
                ["host": "ok.example", "port": 70000],
                ["host": "new.example", "port": 36972, "kind": "satellite"],
                ["port": 36972],
                "nonsense",
            ],
        ]
        let advertisement = EndpointAdvertisement(json: json)
        #expect(advertisement.nodeID == "node-1" && advertisement.port == 36972 && advertisement.remote == true)
        #expect(advertisement.generatedAt == Date(timeIntervalSince1970: 1_793_453_809))
        #expect(advertisement.candidates.map(\.endpoint.description) == [
            "127.0.0.1:36972", "[fd00::11]:36972", "vh-storage.local:36972", "device.example.com:443",
            "new.example:36972",
        ])
        #expect(advertisement.candidates[3].kind == .passthrough)
        #expect(advertisement.candidates[4].kind == nil)

        let many = JSONValue.array((0..<100).map { ["host": .string("10.0.0.\($0)"), "port": 36972] })
        #expect(EndpointAdvertisement(json: ["candidates": many]).candidates.count == EndpointAdvertisement.maxCandidates)
    }
}
