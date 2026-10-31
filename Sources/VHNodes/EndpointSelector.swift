public import Foundation
public import VHCore
public import VHTransport

/// One address the selector may try for a node, with where it came from (the server's transfer protocol §2,
/// "Candidate sources").
public struct EndpointCandidate: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        /// `127.0.0.1` / `::1` at the node's port: tried for every node, the pin decides whether it is this one.
        case loopback
        /// The address the operator entered (`Node.endpoint`).
        case configured
        /// The node's last `device.endpoints` answer (`Node.endpoints`).
        case advertised
        /// The endpoint the last Device session came up on (`Node.lastGood`).
        case lastGood
        /// A Bonjour `_vaulthalla._tcp` result whose TXT `node_id` is the node's (only after the others failed).
        case bonjour
        /// A `vaulthalla://pair` link's list (before pairing).
        case link
    }

    public var endpoint: NodeEndpoint
    /// Every source that named it, in the order they were merged.
    public var sources: [Source]
    /// The server's `kind` for it, when it advertised one.
    public var advertisedKind: EndpointClass?
    /// The server's interface name for it, when advertised.
    public var interface: String?
    /// The class the address had when it last connected (``Source/lastGood``).
    public var lastGoodClass: EndpointClass?
    /// Merge order: "server order" within a class.
    public var order: Int

    public init(endpoint: NodeEndpoint, sources: [Source], advertisedKind: EndpointClass? = nil, interface: String? = nil,
                lastGoodClass: EndpointClass? = nil, order: Int = 0) {
        self.endpoint = endpoint
        self.sources = sources
        self.advertisedKind = advertisedKind
        self.interface = interface
        self.lastGoodClass = lastGoodClass
        self.order = order
    }

    public var isConfigured: Bool { sources.contains(.configured) }
    public var isLastGood: Bool { sources.contains(.lastGood) }

    /// The de-duplication key: host lowercased, and port.
    public var key: String { "\(endpoint.host.lowercased())|\(endpoint.port)" }

    /// The class it is expected to have before it is probed, which orders the probes. A passthrough the server
    /// declared stays one; an IP literal is what its range says; a name is what it last connected as, else what its
    /// suffix suggests (`.local` is lan), else what the server said, else wan.
    public var estimatedClass: EndpointClass {
        if advertisedKind == .passthrough { return .passthrough }
        if let literal = EndpointClassifier.classify(address: endpoint.host) { return literal }
        return lastGoodClass ?? EndpointClassifier.estimate(host: endpoint.host) ?? advertisedKind ?? .wan
    }

    /// The class of the address a probe actually reached.
    func actualClass(remoteAddress: String?, interfaceName: String?) -> EndpointClass {
        if advertisedKind == .passthrough { return .passthrough }
        if let remoteAddress, let resolved = EndpointClassifier.classify(address: remoteAddress,
                                                                         interfaceName: interfaceName) {
            return resolved
        }
        return estimatedClass
    }

    /// The candidates for `node`, merged and de-duplicated by (host lowercased, port): loopback, the configured
    /// endpoint, the node's advertised endpoints (server order), and the last good endpoint. Bonjour comes later
    /// (``EndpointSelector/select(_:prober:bonjour:)``).
    public static func candidates(for node: Node) -> [EndpointCandidate] {
        var merger = Merger()
        let port = node.endpoints.first { $0.kind == .loopback }?.port ?? node.endpoint.port
        merger.add(NodeEndpoint(host: "127.0.0.1", port: port), .loopback)
        merger.add(NodeEndpoint(host: "::1", port: port), .loopback)
        merger.add(node.endpoint, .configured)
        for advertised in node.endpoints {
            merger.add(advertised.endpoint, .advertised, kind: advertised.kind, interface: advertised.interface)
        }
        if let lastGood = node.lastGood {
            merger.add(lastGood.endpoint, .lastGood, lastGoodClass: lastGood.transportClass)
        }
        return merger.candidates
    }

    /// Candidates from a list of endpoints of one source (a pairing link, Bonjour), de-duplicated.
    public static func candidates(_ endpoints: [NodeEndpoint], source: Source) -> [EndpointCandidate] {
        var merger = Merger()
        for endpoint in endpoints { merger.add(endpoint, source) }
        return merger.candidates
    }

    struct Merger {
        private(set) var candidates: [EndpointCandidate] = []

        mutating func add(_ endpoint: NodeEndpoint, _ source: Source, kind: EndpointClass? = nil,
                          interface: String? = nil, lastGoodClass: EndpointClass? = nil, orderOffset: Int = 0) {
            let host = endpoint.host.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, endpoint.port > 0 else { return }
            let probe = EndpointCandidate(endpoint: NodeEndpoint(host: host, port: endpoint.port), sources: [source])
            if let index = candidates.firstIndex(where: { $0.key == probe.key }) {
                if !candidates[index].sources.contains(source) { candidates[index].sources.append(source) }
                candidates[index].advertisedKind = candidates[index].advertisedKind ?? kind
                candidates[index].interface = candidates[index].interface ?? interface
                candidates[index].lastGoodClass = candidates[index].lastGoodClass ?? lastGoodClass
                return
            }
            candidates.append(EndpointCandidate(endpoint: probe.endpoint, sources: [source], advertisedKind: kind,
                                                interface: interface, lastGoodClass: lastGoodClass,
                                                order: orderOffset + candidates.count))
        }
    }
}

/// What one selection found: every candidate's outcome, in priority order, and the one chosen.
public struct EndpointSelection: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case ok
        case refused
        case timeout
        /// A different server's key answered there.
        case identityMismatch
        case tlsError(String)
        case unresolved
        /// Not probed: a better route won first, or the time ran out before its turn.
        case notTried

        init(_ outcome: EndpointProbeResult.Outcome) {
            switch outcome {
            case .ok: self = .ok
            case .refused: self = .refused
            case .timeout: self = .timeout
            case .identityMismatch: self = .identityMismatch
            case .tlsError(let text): self = .tlsError(text)
            case .unresolved: self = .unresolved
            }
        }

        /// Whether a TLS server answered at all (the address is reachable).
        public var reachedServer: Bool {
            switch self {
            case .ok, .identityMismatch, .tlsError: true
            case .refused, .timeout, .unresolved, .notTried: false
            }
        }
    }

    public struct Report: Hashable, Sendable {
        public var candidate: EndpointCandidate
        public var outcome: Outcome
        /// The class of the address reached (`ok`), else the estimate.
        public var transportClass: EndpointClass
        public var rtt: Duration?
        /// The address actually connected to.
        public var remoteAddress: String?
        public var interfaceName: String?
        /// The pin the server presented (`ok` only): the current one or the announced next one.
        public var matchedPin: Data?

        public init(candidate: EndpointCandidate, outcome: Outcome, transportClass: EndpointClass, rtt: Duration? = nil,
                    remoteAddress: String? = nil, interfaceName: String? = nil, matchedPin: Data? = nil) {
            self.candidate = candidate
            self.outcome = outcome
            self.transportClass = transportClass
            self.rtt = rtt
            self.remoteAddress = remoteAddress
            self.interfaceName = interfaceName
            self.matchedPin = matchedPin
        }

        /// (class, last good first, server order): lower is better.
        var priority: Priority {
            Priority(rank: transportClass.rank, lastGood: candidate.isLastGood ? 0 : 1, order: candidate.order)
        }
    }

    public var reports: [Report]
    public var chosen: Report?
    public var startedAt: Date
    /// Whether Bonjour was browsed (only when no other candidate proved the pin).
    public var usedBonjour: Bool

    public init(reports: [Report], chosen: Report?, startedAt: Date, usedBonjour: Bool = false) {
        self.reports = reports
        self.chosen = chosen
        self.startedAt = startedAt
        self.usedBonjour = usedBonjour
    }

    /// No candidate proved the pin and the configured endpoint presented another key: today's pin-mismatch flow
    /// (try the announced next key, then pair again). A mismatch anywhere else only marks that candidate.
    public var configuredEndpointMismatched: Bool {
        chosen == nil && reports.contains { $0.candidate.isConfigured && $0.outcome == .identityMismatch }
    }

    /// The report for `endpoint`, if it was a candidate.
    public func report(for endpoint: NodeEndpoint) -> Report? {
        let key = EndpointCandidate(endpoint: endpoint, sources: []).key
        return reports.first { $0.candidate.key == key }
    }

    /// Candidates of a better class than the chosen one (or every candidate, with none chosen) that didn't work: why
    /// a better route wasn't used.
    public var betterRoutesNotUsed: [Report] {
        let limit = chosen?.transportClass.rank ?? Int.max
        return reports.filter { $0.outcome != .ok && $0.transportClass.rank < limit && $0.outcome != .notTried }
    }
}

struct Priority: Comparable, Hashable {
    var rank: Int
    var lastGood: Int
    var order: Int

    static func < (lhs: Priority, rhs: Priority) -> Bool {
        (lhs.rank, lhs.lastGood, lhs.order) < (rhs.rank, rhs.lastGood, rhs.order)
    }
}

/// Picks the endpoint to connect to (the server's transfer protocol §2): probes the candidates with a TLS handshake
/// against the pins, at most ``Configuration/maxInFlight`` at once, started in priority order
/// ``Configuration/stagger`` apart (or at once when the previous one failed), each bounded by
/// ``Configuration/probeTimeout`` and all by ``Configuration/overallTimeout``. After the first success it waits up to
/// ``Configuration/grace`` for a higher-priority probe still in flight, then picks the best success by the class of
/// the address actually reached (loopback, lan, vpn, wan, passthrough), last good first, then server order.
///
/// Bonjour is the last source: it is browsed (briefly) only when nothing else proved the pin.
public struct EndpointSelector: Sendable {
    public struct Configuration: Sendable {
        public var maxInFlight = 4
        public var stagger: Duration = .milliseconds(150)
        public var probeTimeout: Duration = .seconds(3)
        public var overallTimeout: Duration = .seconds(6)
        public var grace: Duration = .milliseconds(250)
        /// The Bonjour phase's own bound: browsing, then probing what it found.
        public var bonjourBrowse: Duration = .milliseconds(1500)

        public init() {}
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Probes `candidates` and picks the best verified one. `bonjour` browses for this node's Bonjour endpoints
    /// within the time it is given; it is called only when no candidate succeeded.
    public func select(_ candidates: [EndpointCandidate], prober: any EndpointProbing,
                       bonjour: (@Sendable (Duration) async -> [NodeEndpoint])? = nil) async -> EndpointSelection {
        let startedAt = Date.now
        var reports = await probe(candidates, prober: prober, budget: configuration.overallTimeout)
        var usedBonjour = false
        if reports.allSatisfy({ $0.outcome != .ok }), let bonjour, !Task.isCancelled {
            usedBonjour = true
            let known = Set(candidates.map(\.key))
            let found = await bonjour(configuration.bonjourBrowse)
            var merger = EndpointCandidate.Merger()
            for endpoint in found { merger.add(endpoint, .bonjour, orderOffset: candidates.count) }
            let fresh = merger.candidates.filter { !known.contains($0.key) }
            if !fresh.isEmpty {
                reports += await probe(fresh, prober: prober, budget: configuration.probeTimeout)
            }
        }
        reports.sort { $0.priority < $1.priority }
        let chosen = reports.filter { $0.outcome == .ok }.min { $0.priority < $1.priority }
        return EndpointSelection(reports: reports, chosen: chosen, startedAt: startedAt, usedBonjour: usedBonjour)
    }

    private enum Event: Sendable {
        case result(Int, EndpointProbeResult)
        case tick
    }

    /// One round of probes within `budget`.
    private func probe(_ candidates: [EndpointCandidate], prober: any EndpointProbing, budget: Duration) async
        -> [EndpointSelection.Report]
    {
        guard !candidates.isEmpty else { return [] }
        let configuration = configuration
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start + budget
        let estimated: [Priority] = candidates.map {
            Priority(rank: $0.estimatedClass.rank, lastGood: $0.isLastGood ? 0 : 1, order: $0.order)
        }
        var pending = candidates.indices.sorted { estimated[$0] < estimated[$1] }
        var inFlight: Set<Int> = []
        var results: [Int: EndpointSelection.Report] = [:]
        var nextLaunch = start
        var firstSuccess: ContinuousClock.Instant?

        func best() -> Priority? {
            results.values.filter { $0.outcome == .ok }.map(\.priority).min()
        }

        await withTaskGroup(of: Event.self) { group in
            while true {
                let now = clock.now
                let bestSoFar = best()
                // Launch what may start now, in priority order. With a success in hand, only what could beat it.
                while inFlight.count < configuration.maxInFlight, now >= nextLaunch, let next = pending.first,
                      bestSoFar.map({ estimated[next] < $0 }) ?? true, now < deadline {
                    pending.removeFirst()
                    inFlight.insert(next)
                    let candidate = candidates[next]
                    let timeout = min(configuration.probeTimeout, deadline - now)
                    group.addTask { .result(next, await prober.probe(candidate.endpoint, timeout: timeout)) }
                    nextLaunch = now + configuration.stagger
                }

                let launchable = pending.first.map { next in bestSoFar.map { estimated[next] < $0 } ?? true } ?? false
                if let bestSoFar {
                    let betterInFlight = inFlight.contains { estimated[$0] < bestSoFar }
                    let graceOver = firstSuccess.map { now >= $0 + configuration.grace } ?? false
                    if graceOver || (!betterInFlight && !launchable) { break }
                }
                if inFlight.isEmpty && !launchable { break }
                if now >= deadline || Task.isCancelled { break }

                // Wake for the next launch slot, the end of the grace window or the deadline.
                var wake = deadline
                if launchable, inFlight.count < configuration.maxInFlight { wake = min(wake, max(nextLaunch, now)) }
                if let firstSuccess { wake = min(wake, firstSuccess + configuration.grace) }
                if wake > now {
                    group.addTask {
                        try? await clock.sleep(until: wake)
                        return .tick
                    }
                }
                guard let event = await group.next() else { break }
                guard case .result(let index, let result) = event else { continue }
                inFlight.remove(index)
                let candidate = candidates[index]
                let outcome = EndpointSelection.Outcome(result.outcome)
                let reached = outcome == .ok
                    ? candidate.actualClass(remoteAddress: result.remoteAddress, interfaceName: result.interfaceName)
                    : candidate.estimatedClass
                results[index] = EndpointSelection.Report(
                    candidate: candidate, outcome: outcome, transportClass: reached,
                    rtt: outcome == .ok ? result.rtt : nil,
                    remoteAddress: result.remoteAddress, interfaceName: result.interfaceName,
                    matchedPin: outcome == .ok ? result.matchedPin : nil)
                if outcome == .ok {
                    if firstSuccess == nil { firstSuccess = clock.now }
                } else {
                    // A failure frees its slot at once: the next candidate needn't wait out the stagger.
                    nextLaunch = clock.now
                }
            }
            group.cancelAll()
        }

        return candidates.indices.map { index in
            if let report = results[index] { return report }
            // Still in flight at the end: it ran out of time. Never started: not tried.
            let outcome: EndpointSelection.Outcome = inFlight.contains(index) ? .timeout : .notTried
            return EndpointSelection.Report(candidate: candidates[index], outcome: outcome,
                                            transportClass: candidates[index].estimatedClass)
        }
    }
}

/// When the selector may run again (the server's transfer protocol §2): on connect, when the network path changes,
/// when the ws connection drops twice in a row, after a lane's connection failure, and every 30 min while connected
/// on a class worse than lan; never more often than every 5 s.
public struct RouteSchedule: Hashable, Sendable {
    public enum Trigger: Hashable, Sendable {
        case connect
        case pathChanged
        /// The ws connection failed `consecutive` times in a row without coming up in between.
        case dropped(consecutive: Int)
        case laneFailure
        /// The periodic check for a better route.
        case upgrade
        /// The operator asked (Test connection).
        case manual
    }

    public var minimumInterval: Duration = .seconds(5)
    public var upgradeInterval: Duration = .seconds(30 * 60)
    public var dropsBeforeReselect = 2
    /// When the last selection ran.
    public private(set) var lastSelection: ContinuousClock.Instant?

    public init() {}

    /// When a selection for `trigger` may run: `now`, a later instant (throttled), or nil (the trigger doesn't call
    /// for one). `activeClass` is the class connected on now, nil when not connected.
    public func earliest(for trigger: Trigger, activeClass: EndpointClass?, now: ContinuousClock.Instant)
        -> ContinuousClock.Instant?
    {
        switch trigger {
        case .dropped(let count):
            guard count >= dropsBeforeReselect else { return nil }
        case .upgrade:
            guard let activeClass, activeClass > .lan else { return nil }
        case .connect, .pathChanged, .laneFailure, .manual:
            break
        }
        guard let lastSelection else { return now }
        return max(now, lastSelection + minimumInterval)
    }

    /// Whether the last selection is recent enough to reuse instead of probing again (within the minimum interval).
    public func isFresh(now: ContinuousClock.Instant) -> Bool {
        lastSelection.map { now < $0 + minimumInterval } ?? false
    }

    /// When the next periodic upgrade check is due, while connected on `activeClass`; nil when it is lan or better.
    public func nextUpgrade(activeClass: EndpointClass?) -> ContinuousClock.Instant? {
        guard let activeClass, activeClass > .lan, let lastSelection else { return nil }
        return lastSelection + upgradeInterval
    }

    public mutating func recordSelection(at instant: ContinuousClock.Instant) {
        lastSelection = instant
    }
}
