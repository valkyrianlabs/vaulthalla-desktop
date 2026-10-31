import Foundation

/// Adaptive part size and part concurrency for resumable uploads (docs/architecture.md §3, "Resumable uploads and
/// tuning"). Pure: it is fed measurements with explicit times and answers what the next part should look like, so
/// `swift test` drives it through simulated links.
///
/// - **Estimates.** Aggregate upload throughput (bytes/s, an EWMA of each finished part's rate times the parts that
///   ran beside it) and round-trip time (EWMA of the wait between a part's last byte and its answer, less the
///   server's own `sync` from `Server-Timing`), with the lowest RTT seen as the uncongested baseline.
/// - **Part size** = per-stream throughput × ``Configuration/targetPartDuration``, rounded to MiB, held inside soft
///   bounds by the link's speed (slow links 8–32 MiB, typical 32–128 MiB, fast LANs 128–512 MiB), the client's
///   bounds, the server's `part.min_bytes`/`max_bytes` and the memory budget. It starts at 64 MiB, changes only by
///   ≥ 25 % and only after two measured parts, and is never chosen from latency alone. Only parts not yet started
///   take a new size: committed parts are never touched.
/// - **Concurrency** is AIMD within `[1, min(4, part.max_in_flight)]`, starting at 2: one more part after a steady
///   epoch, kept when the epoch after an increase moved ≥ 10 % more bytes, else reverted (a plateau held for a while).
///   It halves on 429/503 (busy) and on bursts of timeouts or dropped connections, steps down when the RTT rises well
///   above its baseline (queues filling), and never rises while `Server-Timing` shows the server's write and sync
///   taking most of each part (adding parts can't help a server-bound transfer).
/// - **Memory**: parts in flight never add up past ``Configuration/memoryBudget`` (default 1 GiB).
/// - **Off**: a fixed 64 MiB × 2 within the server's limits.
public struct TransferTuner: Sendable {
    public struct Configuration: Sendable, Hashable, Codable {
        /// Tune at all; off is ``fixedPartBytes`` × ``fixedConcurrency``.
        public var enabled = true
        /// How long one part should take on the wire.
        public var targetPartDuration: Double = 2
        public var minPartBytes: Int64 = 8 * mib
        public var maxPartBytes: Int64 = 512 * mib
        /// The first part's size without an estimate.
        public var initialPartBytes: Int64 = 64 * mib
        public var initialConcurrency = 2
        /// The client's own ceiling; the server's `max_in_flight` may lower it.
        public var maxConcurrency = 4
        public var fixedPartBytes: Int64 = 64 * mib
        public var fixedConcurrency = 2
        /// Bytes of parts in flight at once, at most (one part always may run).
        public var memoryBudget: Int64 = 1024 * mib
        /// Weight of a new sample in the moving averages.
        public var smoothing: Double = 0.3
        /// The gain an added part must bring to stay.
        public var rampGain: Double = 0.10
        /// The RTT, as a multiple of its baseline (plus 10 ms), past which queues are filling.
        public var rttRise: Double = 2
        /// Parts smaller than this inform the RTT but not the throughput (their time is mostly latency).
        public var minSampleBytes: Int64 = 2 * mib
        /// How long a reverted increase or a back-off holds concurrency down.
        public var holdDown: Double = 30

        public init() {}

        public static let mib: Int64 = 1 << 20
    }

    /// What the server allows per session (`part` in the session's answers).
    public struct Limits: Sendable, Hashable, Codable {
        public var minBytes: Int64
        public var maxBytes: Int64
        public var defaultBytes: Int64
        public var maxInFlight: Int

        public init(minBytes: Int64, maxBytes: Int64, defaultBytes: Int64, maxInFlight: Int) {
            self.minBytes = max(1, minBytes)
            self.maxBytes = max(self.minBytes, maxBytes)
            self.defaultBytes = defaultBytes
            self.maxInFlight = max(1, maxInFlight)
        }

        /// The protocol's defaults (transfer-protocol.md §5), until a session answered.
        public static let protocolDefaults = Limits(minBytes: 1 << 20, maxBytes: 512 << 20, defaultBytes: 64 << 20,
                                                    maxInFlight: 4)
    }

    /// Where the server spent a part's time (`Server-Timing: recv;dur=…, write;dur=…, sync;dur=…`, milliseconds).
    public struct ServerTiming: Sendable, Hashable {
        public var recv: Double
        public var write: Double
        public var sync: Double

        public init(recv: Double, write: Double, sync: Double) {
            self.recv = recv
            self.write = write
            self.sync = sync
        }

        /// Parses the header; nil when it names none of the three.
        public init?(header: String?) {
            guard let header else { return nil }
            var values: [String: Double] = [:]
            for metric in header.split(separator: ",") {
                let fields = metric.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let name = fields.first?.lowercased() else { continue }
                for field in fields.dropFirst() where field.lowercased().hasPrefix("dur=") {
                    values[name] = Double(field.dropFirst(4))
                }
            }
            guard values["recv"] != nil || values["write"] != nil || values["sync"] != nil else { return nil }
            self.init(recv: values["recv"] ?? 0, write: values["write"] ?? 0, sync: values["sync"] ?? 0)
        }
    }

    /// One part that the server acknowledged.
    public struct Sample: Sendable, Hashable {
        public var bytes: Int64
        /// When its request started and when its answer arrived (seconds on any monotonic clock).
        public var start: Double
        public var end: Double
        /// Parts in flight when it started, itself included.
        public var parallel: Int
        /// Seconds from its last body byte to the answer's head, when known.
        public var ackLatency: Double?
        public var serverTiming: ServerTiming?

        public init(bytes: Int64, start: Double, end: Double, parallel: Int, ackLatency: Double? = nil,
                    serverTiming: ServerTiming? = nil) {
            self.bytes = bytes
            self.start = start
            self.end = end
            self.parallel = max(1, parallel)
            self.ackLatency = ackLatency
            self.serverTiming = serverTiming
        }
    }

    /// Trouble a part ran into.
    public enum Signal: Sendable, Hashable {
        /// 429 or 503: the server asked for fewer parts at once.
        case busy
        /// The server stopped answering.
        case timeout
        /// The connection dropped.
        case connection
    }

    /// What is known about a link, for the cache and for seeding a new tuner.
    public struct Estimate: Sendable, Hashable, Codable {
        /// Aggregate bytes/s.
        public var throughput: Double
        /// Seconds.
        public var rtt: Double?
        public var concurrency: Int
        public var partBytes: Int64
        /// Where it came from.
        public var source: Source

        public enum Source: String, Sendable, Hashable, Codable {
            case defaults, cached, calibrated, measured
        }

        public init(throughput: Double, rtt: Double?, concurrency: Int, partBytes: Int64, source: Source) {
            self.throughput = throughput
            self.rtt = rtt
            self.concurrency = concurrency
            self.partBytes = partBytes
            self.source = source
        }
    }

    public private(set) var configuration: Configuration
    public private(set) var limits: Limits
    /// Aggregate bytes/s, nil before a measurement or a seed.
    public private(set) var throughput: Double?
    /// Seconds.
    public private(set) var rtt: Double?
    /// The lowest RTT seen: the link without queues.
    public private(set) var baseRTT: Double?
    public private(set) var partBytes: Int64
    public private(set) var concurrency: Int
    /// The server's write path, not the network, bounds the transfer.
    public private(set) var serverBound = false
    /// Where the current estimate came from.
    public private(set) var source: Estimate.Source = .defaults

    /// The smoothed share of a part's time the server spent writing and syncing.
    private var serverShare: Double?
    private var measuredParts = 0
    private var epoch = Epoch(start: 0, concurrency: 0, increased: false)
    /// The aggregate rate of the last evaluated epoch.
    private var lastEpochRate: Double?
    /// No increase before this time.
    private var holdUntil: Double = -.infinity
    private var failures: [Double] = []
    private var lastDecrease: Double = -.infinity
    private var recentRTTs: [Double] = []
    /// Increases that didn't pay in a row: each doubles the next hold-down.
    private var failedProbes = 0

    private struct Epoch {
        var start: Double
        var concurrency: Int
        /// It began with an increase that has to prove itself.
        var increased: Bool
        var rates: [Double] = []
        var trouble = false
    }

    public init(configuration: Configuration = Configuration(), limits: Limits = .protocolDefaults) {
        self.configuration = configuration
        self.limits = limits
        partBytes = configuration.initialPartBytes
        concurrency = configuration.initialConcurrency
        normalize()
    }

    // MARK: - Settings

    /// The server's limits for the session about to run.
    public mutating func apply(_ limits: Limits) {
        self.limits = limits
        normalize()
    }

    public mutating func setEnabled(_ enabled: Bool, at now: Double = 0) {
        guard enabled != configuration.enabled else { return }
        configuration.enabled = enabled
        if enabled {
            partBytes = sizeFromThroughput() ?? configuration.initialPartBytes
            concurrency = configuration.initialConcurrency
        }
        normalize()
        startEpoch(at: now, increased: false)
    }

    /// Starts from what is known about the link (a fresh cache entry or a calibration). Real measurements replace it
    /// as they arrive.
    public mutating func seed(_ estimate: Estimate, at now: Double = 0) {
        throughput = estimate.throughput > 0 ? estimate.throughput : throughput
        if let rtt = estimate.rtt, rtt > 0 {
            self.rtt = nil
            recordRTT(rtt)
        }
        source = estimate.source
        if configuration.enabled {
            if estimate.source == .cached { concurrency = estimate.concurrency }
            partBytes = sizeFromThroughput() ?? estimate.partBytes
        }
        normalize()
        startEpoch(at: now, increased: false)
    }

    /// The estimate to cache: nil until something was measured or seeded.
    public var estimate: Estimate? {
        guard let throughput else { return nil }
        return Estimate(throughput: throughput, rtt: rtt, concurrency: concurrency, partBytes: partBytes,
                        source: source)
    }

    /// A round-trip measurement from elsewhere (a calibration probe).
    public mutating func recordRTT(_ seconds: Double) {
        guard seconds > 0 else { return }
        rtt = rtt.map { $0 + configuration.smoothing * (seconds - $0) } ?? seconds
        // The baseline is the lowest of the recent samples, so a route whose RTT really changed is relearned.
        recentRTTs.append(seconds)
        if recentRTTs.count > 64 { recentRTTs.removeFirst(recentRTTs.count - 64) }
        baseRTT = recentRTTs.min()
    }

    // MARK: - Admission

    /// The most parts in flight at once now.
    public var concurrencyCap: Int { max(1, min(configuration.maxConcurrency, limits.maxInFlight)) }

    /// Whether another part of `nextPart` bytes may start beside `inFlightParts` parts holding `inFlightBytes`.
    public func admits(inFlightParts: Int, inFlightBytes: Int64, nextPart: Int64) -> Bool {
        guard inFlightParts < concurrency else { return false }
        return inFlightParts == 0 || inFlightBytes + nextPart <= configuration.memoryBudget
    }

    // MARK: - Measurements

    /// A part the server acknowledged.
    public mutating func record(_ sample: Sample) {
        let duration = max(sample.end - sample.start, 0.001)
        if let latency = sample.ackLatency {
            let serverMs = sample.serverTiming?.sync ?? 0
            let network = latency - serverMs / 1000
            if network > 0 { recordRTT(network) }
        }
        if let timing = sample.serverTiming {
            let share = min(1, (timing.write + timing.sync) / (duration * 1000))
            serverShare = serverShare.map { $0 + configuration.smoothing * (share - $0) } ?? share
            serverBound = (serverShare ?? 0) >= 0.5
        }
        guard sample.bytes >= configuration.minSampleBytes else { return }
        let rate = Double(sample.bytes) / duration * Double(sample.parallel)
        // Real transfers win over a cached or calibrated guess: the first one replaces it.
        throughput = source == .measured ? throughput.map { $0 + configuration.smoothing * (rate - $0) } ?? rate : rate
        measuredParts += 1
        source = .measured
        guard configuration.enabled else { return }
        if sample.start >= epoch.start { epoch.rates.append(rate) }
        resize()
        evaluate(at: sample.end)
    }

    /// A part that failed.
    public mutating func record(_ signal: Signal, at now: Double) {
        guard configuration.enabled else { return }
        epoch.trouble = true
        switch signal {
        case .busy:
            decrease(at: now, halve: true)
        case .timeout, .connection:
            failures = failures.filter { now - $0 < 10 } + [now]
            // One drop is noise; a burst is a lossy or saturated link.
            if failures.count >= 2 { decrease(at: now, halve: true) }
        }
    }

    // MARK: - Decisions

    /// Judges the epoch once it has enough parts.
    private mutating func evaluate(at now: Double) {
        guard epoch.rates.count >= max(3, epoch.concurrency) else { return }
        let rate = epoch.rates.reduce(0, +) / Double(epoch.rates.count)
        let previous = lastEpochRate
        if let previous, !epoch.increased, abs(rate - previous) / previous > 0.3 {
            // The link changed under us: what held concurrency down may not hold any more.
            holdUntil = -.infinity
            failedProbes = 0
        }
        if epoch.increased, let previous, rate < previous * (1 + configuration.rampGain) {
            // The added part didn't pay: back to where it was, and stay there a while (longer each time).
            concurrency = max(1, concurrency - 1)
            holdUntil = now + configuration.holdDown * Double(1 << min(failedProbes, 4))
            failedProbes += 1
            normalize()
            startEpoch(at: now, increased: false)
            return
        }
        if epoch.increased { failedProbes = 0 }
        lastEpochRate = rate
        if rttRising, concurrency > 1 {
            // Queues are filling: one part fewer.
            decrease(at: now, halve: false)
            return
        }
        if canIncrease(at: now) {
            concurrency += 1
            normalize()
            resize()
            startEpoch(at: now, increased: true)
        } else {
            startEpoch(at: now, increased: false)
        }
    }

    private func canIncrease(at now: Double) -> Bool {
        guard concurrency < concurrencyCap, !serverBound, !epoch.trouble, now >= holdUntil, !rttRising else {
            return false
        }
        // One more part must fit the memory budget.
        return Int64(concurrency + 1) * partBytes <= configuration.memoryBudget
    }

    /// The RTT is well above its baseline: queues are filling somewhere.
    var rttRising: Bool {
        guard let rtt, let baseRTT else { return false }
        return rtt > baseRTT * configuration.rttRise + 0.010
    }

    private mutating func decrease(at now: Double, halve: Bool) {
        holdUntil = now + configuration.holdDown
        // Once per round of parts: the parts already in flight report the same trouble.
        guard now - lastDecrease > max(rtt ?? 0, 0.5) else { return }
        lastDecrease = now
        concurrency = halve ? max(1, concurrency / 2) : max(1, concurrency - 1)
        normalize()
        startEpoch(at: now, increased: false)
    }

    private mutating func startEpoch(at now: Double, increased: Bool) {
        epoch = Epoch(start: now, concurrency: concurrency, increased: increased)
        if rttRising, configuration.enabled, concurrency > 1, !increased {
            // Rising RTT counts as trouble for the next epoch, so it doesn't climb.
            epoch.trouble = true
        }
    }

    /// Recomputes the part size from the throughput, with hysteresis.
    private mutating func resize() {
        guard configuration.enabled, measuredParts >= 2 || source == .calibrated || source == .cached,
              let wanted = sizeFromThroughput()
        else { return }
        if abs(Double(wanted - partBytes)) / Double(partBytes) >= 0.25 { partBytes = wanted }
        normalize()
    }

    /// The part size the throughput asks for, inside every bound; nil without a throughput.
    func sizeFromThroughput() -> Int64? {
        guard let throughput, throughput > 0 else { return nil }
        let mib = Double(Configuration.mib)
        let perStream = throughput / Double(max(1, concurrency))
        let raw = (perStream * configuration.targetPartDuration / mib).rounded() * mib
        // Soft bounds by the link's speed: heuristics that keep a noisy estimate from extremes.
        let (low, high): (Double, Double) = switch throughput {
        case ..<(5e6): (8 * mib, 32 * mib)
        case ..<(50e6): (32 * mib, 128 * mib)
        default: (128 * mib, 512 * mib)
        }
        return clampPart(Int64(min(max(raw, low), high)))
    }

    /// Inside the client's bounds, the server's, and the memory budget at the current concurrency.
    private func clampPart(_ bytes: Int64) -> Int64 {
        let mib = Configuration.mib
        var value = min(max(bytes, configuration.minPartBytes), configuration.maxPartBytes)
        value = min(value, configuration.memoryBudget / Int64(max(1, concurrency)))
        value = max(mib, value / mib * mib)
        return min(max(value, limits.minBytes), limits.maxBytes)
    }

    private mutating func normalize() {
        if !configuration.enabled {
            concurrency = max(1, min(configuration.fixedConcurrency, limits.maxInFlight))
            partBytes = min(max(configuration.fixedPartBytes, limits.minBytes), limits.maxBytes)
            return
        }
        concurrency = max(1, min(concurrency, concurrencyCap))
        partBytes = clampPart(partBytes)
    }
}

extension TransferTuner.Limits {
    /// A session answer's `part` object.
    init(_ wire: WireUpload.Parts?) {
        let defaults = Self.protocolDefaults
        self.init(minBytes: wire?.min_bytes ?? defaults.minBytes, maxBytes: wire?.max_bytes ?? defaults.maxBytes,
                  defaultBytes: wire?.default_bytes ?? defaults.defaultBytes,
                  maxInFlight: wire?.max_in_flight ?? defaults.maxInFlight)
    }
}
