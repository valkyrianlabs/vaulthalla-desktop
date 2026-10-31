public import Foundation
import Synchronization

/// The class of the address a lane connects to (the server's transfer-protocol.md §2): estimates are kept per node and
/// class, since a LAN and a WAN route to the same node are different links.
public enum TransferEndpointClass: String, Sendable, Hashable, Codable, CaseIterable {
    case loopback, lan, vpn, wan, passthrough, unknown

    /// Classifies a literal address the way the server's advertisement does (`127/8` and `::1` loopback; RFC 1918,
    /// `fc00::/7` and `.local` names lan; `100.64/10` vpn; other addresses wan). A host name is `unknown`: the
    /// endpoint selector knows what it resolved to and passes the class instead.
    public init(host: String) {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") {
            self = .loopback
            return
        }
        if host.hasSuffix(".local") || host.hasSuffix(".home.arpa") {
            self = .lan
            return
        }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168): self = .lan
            case (172, 16...31): self = .lan
            case (100, 64...127): self = .vpn
            case (169, 254): self = .unknown
            default: self = .wan
            }
            return
        }
        if host.contains(":") {
            if host.hasPrefix("fc") || host.hasPrefix("fd") { self = .lan }
            else if host.hasPrefix("fe80") { self = .unknown }
            else { self = .wan }
            return
        }
        self = .unknown
    }
}

/// The last link estimate per node, with an expiry (default 24 h), so a new upload starts from what the previous one
/// learned instead of probing. An entry is for one endpoint class: asking for another class drops it (the route
/// changed). Persisted as JSON when given a file (Application Support), in memory otherwise.
public final class TransferEstimateCache: Sendable {
    public struct Entry: Codable, Sendable, Hashable {
        public var endpointClass: TransferEndpointClass
        public var estimate: TransferTuner.Estimate
        public var savedAt: Date
    }

    private let file: URL?
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date
    private let entries: Mutex<[String: Entry]>

    public init(file: URL? = nil, lifetime: TimeInterval = 24 * 3600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.lifetime = lifetime
        self.now = now
        var loaded: [String: Entry] = [:]
        if let file, let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            loaded = decoded
        }
        entries = Mutex(loaded)
    }

    /// A fresh estimate for `node` over `endpointClass`, or nil (none, expired, or for another class: dropped).
    public func estimate(node: String, endpointClass: TransferEndpointClass) -> TransferTuner.Estimate? {
        let now = now()
        let (found, changed) = entries.withLock { entries -> (TransferTuner.Estimate?, Bool) in
            guard let entry = entries[node] else { return (nil, false) }
            guard entry.endpointClass == endpointClass, now.timeIntervalSince(entry.savedAt) < lifetime,
                  now >= entry.savedAt
            else {
                entries[node] = nil
                return (nil, true)
            }
            var estimate = entry.estimate
            estimate.source = .cached
            return (estimate, false)
        }
        if changed { persist() }
        return found
    }

    public func save(_ estimate: TransferTuner.Estimate, node: String, endpointClass: TransferEndpointClass) {
        let entry = Entry(endpointClass: endpointClass, estimate: estimate, savedAt: now())
        entries.withLock { $0[node] = entry }
        persist()
    }

    public func remove(node: String) {
        entries.withLock { $0[node] = nil }
        persist()
    }

    private func persist() {
        guard let file else { return }
        let snapshot = entries.withLock { $0 }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
    }
}

/// What the transfer engine is doing now, for the connection status view (a snapshot; ``TransferMonitor/updates()``
/// streams them).
public struct TransferTuningSnapshot: Sendable, Hashable {
    /// Bytes/s over the last few seconds.
    public var uploadBytesPerSecond: Double
    public var downloadBytesPerSecond: Double
    /// The size the next part takes.
    public var partBytes: Int64
    /// Parts the tuner allows in flight, and those in flight now.
    public var concurrency: Int
    public var partsInFlight: Int
    public var tuningEnabled: Bool
    /// The smoothed aggregate upload estimate (bytes/s) and RTT (seconds) the tuner works from.
    public var estimatedThroughput: Double?
    public var rtt: Double?
    /// Where the estimate came from.
    public var source: TransferTuner.Estimate.Source
    /// `Server-Timing` says the server's write path, not the network, bounds uploads.
    public var serverBound: Bool
    public var endpointClass: TransferEndpointClass

    public static let idle = TransferTuningSnapshot(
        uploadBytesPerSecond: 0, downloadBytesPerSecond: 0, partBytes: 64 << 20, concurrency: 2, partsInFlight: 0,
        tuningEnabled: true, estimatedThroughput: nil, rtt: nil, source: .defaults, serverBound: false,
        endpointClass: .unknown)
}

/// One node's transfer tuning, shared by every upload to it (``ResumableUploader``) and fed by downloads too: the
/// ``TransferTuner`` behind a lock, rate meters for both directions, the estimate cache, and a stream of
/// ``TransferTuningSnapshot``s for the UI (at most ~4 a second while something moves).
public final class TransferMonitor: Sendable {
    public let node: String
    private let cache: TransferEstimateCache?
    private let state: Mutex<State>
    private let clock: @Sendable () -> Double

    private struct State {
        var tuner: TransferTuner
        var endpointClass: TransferEndpointClass
        var seeded = false
        var inFlightParts = 0
        var inFlightBytes: Int64 = 0
        /// ∫ parts in flight dt, for each part's average parallelism.
        var parallelIntegral: Double = 0
        var integratedAt: Double = 0

        mutating func integrate(to now: Double) {
            if integratedAt > 0 { parallelIntegral += Double(inFlightParts) * max(0, now - integratedAt) }
            integratedAt = now
        }
        var up = RateMeter()
        var down = RateMeter()
        var observers: [UUID: AsyncStream<TransferTuningSnapshot>.Continuation] = [:]
        var lastPublished: Double = -.infinity
        var lastSnapshot: TransferTuningSnapshot?
    }

    /// `node`: the cache key (the node's id). `endpointClass`: the route's class, see ``setEndpointClass(_:)``.
    public init(node: String, endpointClass: TransferEndpointClass = .unknown,
                configuration: TransferTuner.Configuration = TransferTuner.Configuration(),
                cache: TransferEstimateCache? = nil,
                clock: @escaping @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }) {
        self.node = node
        self.cache = cache
        self.clock = clock
        state = Mutex(State(tuner: TransferTuner(configuration: configuration), endpointClass: endpointClass))
    }

    // MARK: - For the UI

    public var snapshot: TransferTuningSnapshot {
        let now = clock()
        return state.withLock { Self.snapshot(&$0, now: now) }
    }

    /// Snapshots as they change, starting with the current one. Each call is its own stream.
    public func updates() -> AsyncStream<TransferTuningSnapshot> {
        let (stream, continuation) = AsyncStream<TransferTuningSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let now = clock()
        let first = state.withLock { state in
            state.observers[id] = continuation
            return Self.snapshot(&state, now: now)
        }
        continuation.yield(first)
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Turns tuning on or off (off: fixed 64 MiB × 2). Parts already sent are never affected.
    public func setTuningEnabled(_ enabled: Bool) {
        let now = clock()
        mutate { $0.tuner.setEnabled(enabled, at: now) }
    }

    public var isTuningEnabled: Bool { state.withLock { $0.tuner.configuration.enabled } }

    /// The route's class changed (endpoint re-selection): what was learned no longer applies.
    public func setEndpointClass(_ endpointClass: TransferEndpointClass) {
        let reset = state.withLock { state -> Bool in
            guard state.endpointClass != endpointClass else { return false }
            let configuration = state.tuner.configuration
            state.tuner = TransferTuner(configuration: configuration, limits: state.tuner.limits)
            state.endpointClass = endpointClass
            state.seeded = false
            return true
        }
        if reset { cache?.remove(node: node); publish(force: true) }
    }

    // MARK: - For the engine

    /// The tuner's state (for tests and the calibration summary).
    public var tuner: TransferTuner { state.withLock { $0.tuner } }

    /// Whether the tuner works from more than defaults (a cached, calibrated or measured estimate).
    public var hasEstimate: Bool { state.withLock { $0.tuner.throughput != nil } }

    /// Seeds the tuner from the cache once per route; true when a fresh estimate was there.
    @discardableResult
    func seedFromCache() -> Bool {
        guard let cache else { return state.withLock { $0.tuner.throughput != nil } }
        let (needed, endpointClass) = state.withLock { ($0.seeded == false && $0.tuner.throughput == nil, $0.endpointClass) }
        guard needed else { return state.withLock { $0.tuner.throughput != nil } }
        let now = clock()
        guard let estimate = cache.estimate(node: node, endpointClass: endpointClass) else {
            state.withLock { $0.seeded = true }
            return false
        }
        mutate { state in
            state.seeded = true
            state.tuner.seed(estimate, at: now)
        }
        return true
    }

    /// An upload starts (``TransferTuner/beginTransfer(at:)``).
    func beginTransfer() {
        let now = clock()
        mutate { $0.tuner.beginTransfer(at: now) }
    }

    /// A calibration's measurement (``TransferCalibrator``).
    func seed(_ estimate: TransferTuner.Estimate) {
        let now = clock()
        mutate { state in
            state.seeded = true
            state.tuner.seed(estimate, at: now)
        }
        saveEstimate()
    }

    func recordRTT(_ seconds: Double) {
        mutate { $0.tuner.recordRTT(seconds) }
    }

    func apply(_ limits: TransferTuner.Limits) {
        mutate { $0.tuner.apply(limits) }
    }

    /// The next part's size, and whether it may start now.
    func admit(nextPart: Int64) -> Bool {
        state.withLock {
            $0.tuner.admits(inFlightParts: $0.inFlightParts, inFlightBytes: $0.inFlightBytes, nextPart: nextPart)
        }
    }

    var partBytes: Int64 { state.withLock { $0.tuner.partBytes } }

    /// Where a part started, for its average parallelism (``parallelism(since:)``).
    struct PartTicket: Sendable {
        var start: Double
        var integral: Double
        var parallel: Int
    }

    /// A part started.
    func partStarted(bytes: Int64) -> PartTicket {
        let now = clock()
        let ticket = state.withLock { state -> PartTicket in
            state.integrate(to: now)
            state.inFlightParts += 1
            state.inFlightBytes += bytes
            return PartTicket(start: now, integral: state.parallelIntegral, parallel: state.inFlightParts)
        }
        publish(force: true)
        return ticket
    }

    /// The parts in flight beside the one `ticket` started, on average over its time so far (itself included).
    func parallelism(since ticket: PartTicket) -> Double {
        let now = clock()
        return state.withLock { state in
            state.integrate(to: now)
            let span = now - ticket.start
            guard span > 0 else { return Double(ticket.parallel) }
            return max(1, (state.parallelIntegral - ticket.integral) / span)
        }
    }

    /// A part ended (acknowledged or not).
    func partEnded(bytes: Int64) {
        let now = clock()
        state.withLock { state in
            state.integrate(to: now)
            state.inFlightParts = max(0, state.inFlightParts - 1)
            state.inFlightBytes = max(0, state.inFlightBytes - bytes)
        }
        publish(force: true)
    }

    func record(_ sample: TransferTuner.Sample) {
        mutate { $0.tuner.record(sample) }
    }

    func record(_ signal: TransferTuner.Signal) {
        let now = clock()
        mutate { $0.tuner.record(signal, at: now) }
    }

    /// Bytes that moved, for the rate meters.
    func uploaded(_ bytes: Int64) {
        let now = clock()
        state.withLock { $0.up.add(bytes, at: now) }
        publish(force: false)
    }

    func downloaded(_ bytes: Int64) {
        let now = clock()
        state.withLock { $0.down.add(bytes, at: now) }
        publish(force: false)
    }

    /// Keeps what was learned for the next transfer to this node over this route.
    func saveEstimate() {
        let (estimate, endpointClass) = state.withLock { ($0.tuner.estimate, $0.endpointClass) }
        guard let cache, let estimate else { return }
        cache.save(estimate, node: node, endpointClass: endpointClass)
    }

    var now: Double { clock() }

    // MARK: - Plumbing

    private func mutate(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
        publish(force: true)
    }

    private func publish(force: Bool) {
        let now = clock()
        let (snapshot, observers) = state.withLock { state -> (TransferTuningSnapshot?, [AsyncStream<TransferTuningSnapshot>.Continuation]) in
            guard !state.observers.isEmpty, force || now - state.lastPublished >= 0.25 else { return (nil, []) }
            let snapshot = Self.snapshot(&state, now: now)
            guard snapshot != state.lastSnapshot else { return (nil, []) }
            state.lastSnapshot = snapshot
            state.lastPublished = now
            return (snapshot, Array(state.observers.values))
        }
        guard let snapshot else { return }
        for observer in observers { observer.yield(snapshot) }
    }

    private static func snapshot(_ state: inout State, now: Double) -> TransferTuningSnapshot {
        TransferTuningSnapshot(
            uploadBytesPerSecond: state.up.rate(at: now), downloadBytesPerSecond: state.down.rate(at: now),
            partBytes: state.tuner.partBytes, concurrency: state.tuner.concurrency, partsInFlight: state.inFlightParts,
            tuningEnabled: state.tuner.configuration.enabled, estimatedThroughput: state.tuner.throughput,
            rtt: state.tuner.rtt, source: state.tuner.source, serverBound: state.tuner.serverBound,
            endpointClass: state.endpointClass)
    }
}

/// Bytes per second over a sliding window of one-second buckets.
struct RateMeter: Sendable {
    private var buckets: [(second: Int64, bytes: Int64)] = []
    static let window: Int64 = 3

    mutating func add(_ bytes: Int64, at now: Double) {
        let second = Int64(now.rounded(.down))
        if let last = buckets.last, last.second == second {
            buckets[buckets.count - 1].bytes += bytes
        } else {
            buckets.append((second, bytes))
        }
        buckets.removeAll { second - $0.second >= Self.window + 1 }
    }

    func rate(at now: Double) -> Double {
        let second = Int64(now.rounded(.down))
        // Whole seconds before this one, plus the part of this one that has passed.
        let recent = buckets.filter { second - $0.second < Self.window }
        guard !recent.isEmpty else { return 0 }
        let span = Double(Self.window - 1) + (now - Double(second))
        return Double(recent.reduce(0) { $0 + $1.bytes }) / max(span, 0.25)
    }
}
