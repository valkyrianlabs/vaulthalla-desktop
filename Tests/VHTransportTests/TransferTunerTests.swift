import Foundation
import Synchronization
import Testing
@testable import VHTransport

/// ``TransferTuner`` driven through simulated links: rounds of parallel parts whose durations follow a link model
/// (an aggregate capacity, a per-connection ceiling, a round trip, optionally a server write rate).
@Suite struct TransferTunerTests {
    static let mib = Int64(1 << 20)

    struct Link {
        /// Aggregate bytes/s.
        var capacity: Double
        /// One connection's ceiling (window / RTT).
        var perStream: Double
        var rtt: Double
        /// The server's write rate (bytes/s, all parts); nil: never the bottleneck.
        var serverRate: Double?
        /// Extra RTT per part beyond the first in flight (queues filling).
        var queueing: Double = 0

        func perPart(_ parallel: Int) -> Double {
            min(perStream, capacity / Double(parallel), (serverRate ?? .infinity) / Double(parallel))
        }
    }

    /// Runs `rounds` rounds of `tuner.concurrency` parts of `tuner.partBytes` from time `start`; returns the end time
    /// and the highest concurrency used.
    @discardableResult
    static func drive(_ tuner: inout TransferTuner, _ link: Link, rounds: Int, from start: Double = 0,
                      timing: Bool = false) -> (end: Double, peak: Int) {
        let (end, used) = trace(&tuner, link, rounds: rounds, from: start, timing: timing)
        return (end, used.max() ?? 0)
    }

    /// ``drive(_:_:rounds:from:timing:)``, returning each round's concurrency.
    static func trace(_ tuner: inout TransferTuner, _ link: Link, rounds: Int, from start: Double = 0,
                      timing: Bool = false) -> (end: Double, used: [Int]) {
        var now = start
        var used: [Int] = []
        for _ in 0..<rounds {
            let parallel = tuner.concurrency
            used.append(parallel)
            let bytes = tuner.partBytes
            let rate = link.perPart(parallel)
            let rtt = link.rtt + link.queueing * Double(parallel - 1)
            let duration = Double(bytes) / rate + rtt
            var serverTiming: TransferTuner.ServerTiming?
            if timing {
                // Server-bound: the disk takes as long as the part; otherwise writes keep up with the wire.
                let write = link.serverRate.map { Double(bytes) / ($0 / Double(parallel)) } ?? 0
                serverTiming = .init(recv: duration * 1000, write: min(write, duration) * 1000, sync: 5)
            }
            for _ in 0..<parallel {
                tuner.record(.init(bytes: bytes, start: now, end: now + duration, parallel: parallel,
                                   ackLatency: rtt + 0.005, serverTiming: serverTiming))
            }
            now += duration
        }
        return (now, used)
    }

    static let slow = Link(capacity: 2.5e6, perStream: 50e6, rtt: 0.080)          // 20 Mbit/s, 80 ms
    static let lan = Link(capacity: 117e6, perStream: 80e6, rtt: 0.001)           // 1 Gbit/s, one stream ~80 MB/s
    static let wide = Link(capacity: 400e6, perStream: 40e6, rtt: 0.010)          // parallel parts pay

    @Test func aSlowHighLatencyLinkGetsSmallPartsAndNoExtraConcurrency() {
        var tuner = TransferTuner()
        #expect(tuner.partBytes == 64 * Self.mib && tuner.concurrency == 2)
        let (_, used) = Self.trace(&tuner, Self.slow, rounds: 60)
        #expect(tuner.partBytes == 8 * Self.mib)
        // A third part never pays on a saturated link: probed rarely (each failed probe holds longer), never kept.
        #expect(used.max() ?? 0 <= 3)
        #expect(used.filter { $0 > 2 }.count <= 4)
        #expect(used.suffix(10).filter { $0 > 2 }.count <= 1)
        #expect(abs((tuner.throughput ?? 0) - 2.5e6) / 2.5e6 < 0.1)
        #expect(tuner.rtt.map { abs($0 - 0.085) < 0.01 } == true)
    }

    @Test func aFastLANGetsLargePartsAndKeepsTwoStreams() {
        var tuner = TransferTuner()
        Self.drive(&tuner, Self.lan, rounds: 40)
        #expect(tuner.partBytes >= 128 * Self.mib && tuner.partBytes <= 512 * Self.mib)
        #expect(tuner.concurrency == 2)
    }

    @Test func concurrencyRampsUpWhileItPays() {
        var tuner = TransferTuner()
        Self.drive(&tuner, Self.wide, rounds: 40)
        #expect(tuner.concurrency == 4)
        // The server's max_in_flight caps it.
        var capped = TransferTuner(limits: .init(minBytes: Self.mib, maxBytes: 512 * Self.mib, defaultBytes: 64 * Self.mib,
                                                 maxInFlight: 3))
        Self.drive(&capped, Self.wide, rounds: 40)
        #expect(capped.concurrency == 3)
    }

    @Test func retryBurstsHalveConcurrencyAndHoldItDown() {
        var tuner = TransferTuner()
        let (end, _) = Self.drive(&tuner, Self.wide, rounds: 40)
        #expect(tuner.concurrency == 4)
        // One drop is noise.
        tuner.record(.connection, at: end + 1)
        #expect(tuner.concurrency == 4)
        // A burst is not.
        tuner.record(.timeout, at: end + 2)
        #expect(tuner.concurrency == 2)
        // The rest of the burst (same round of parts) doesn't cascade.
        tuner.record(.connection, at: end + 2.1)
        #expect(tuner.concurrency == 2)
        // Held down for a while, even on a link where more would pay...
        let (later, peak) = Self.drive(&tuner, Self.wide, rounds: 3, from: end + 3)
        #expect(peak == 2 && later - end < 30)
        // ...then allowed to climb again.
        Self.drive(&tuner, Self.wide, rounds: 40, from: end + 40)
        #expect(tuner.concurrency == 4)
    }

    @Test func busyAnswersHalveConcurrency() {
        var tuner = TransferTuner()
        let (end, _) = Self.drive(&tuner, Self.wide, rounds: 40)
        tuner.record(.busy, at: end)
        #expect(tuner.concurrency == 2)
        tuner.record(.busy, at: end + 5)
        #expect(tuner.concurrency == 1)
    }

    /// `Server-Timing` shows the server's write taking each part's whole time: adding parts can't help.
    @Test func aServerBottleneckNeverAddsConcurrency() {
        var tuner = TransferTuner()
        let link = Link(capacity: 1e9, perStream: 40e6, rtt: 0.002, serverRate: 60e6)
        let (_, peak) = Self.drive(&tuner, link, rounds: 40, timing: true)
        #expect(tuner.serverBound)
        #expect(peak == 2)
        #expect(tuner.concurrency == 2)
        // The same link without the server's word: it tries a third part, sees no gain, and goes back.
        var blind = TransferTuner()
        let (_, blindPeak) = Self.drive(&blind, link, rounds: 40)
        #expect(!blind.serverBound && blindPeak == 3 && blind.concurrency == 2)
    }

    @Test func risingRTTStepsConcurrencyDown() {
        var tuner = TransferTuner()
        let (end, _) = Self.drive(&tuner, Self.wide, rounds: 40)
        #expect(tuner.concurrency == 4)
        // Queues fill (RTT 10 ms → 300 ms) without any more throughput: one part fewer per round of parts.
        var bloated = Self.wide
        bloated.rtt = 0.3
        bloated.capacity = 160e6
        let (_, used) = Self.trace(&tuner, bloated, rounds: 6, from: end)
        #expect(tuner.concurrency < 4)
        #expect(used.last ?? 4 < 4)
        // Once the higher RTT is the new normal (the baseline window rolled over), it may climb again.
        Self.drive(&tuner, bloated, rounds: 120, from: end + 1000)
        #expect(!tuner.rttRising)
    }

    @Test func aBandwidthChangeMidTransferResizesFutureParts() {
        var tuner = TransferTuner()
        let (end, _) = Self.drive(&tuner, Self.lan, rounds: 30)
        #expect(tuner.partBytes >= 128 * Self.mib)
        Self.drive(&tuner, Link(capacity: 2e6, perStream: 50e6, rtt: 0.05), rounds: 30, from: end)
        #expect(tuner.partBytes <= 32 * Self.mib)
        // And back up.
        Self.drive(&tuner, Self.lan, rounds: 30, from: end + 10_000)
        #expect(tuner.partBytes >= 128 * Self.mib)
    }

    @Test func tuningOffIsFixed64MiBTimesTwoWithinTheServersLimits() {
        var configuration = TransferTuner.Configuration()
        configuration.enabled = false
        var tuner = TransferTuner(configuration: configuration)
        Self.drive(&tuner, Self.wide, rounds: 40)
        tuner.record(.busy, at: 1)
        #expect(tuner.partBytes == 64 * Self.mib && tuner.concurrency == 2)
        tuner.apply(.init(minBytes: Self.mib, maxBytes: 32 * Self.mib, defaultBytes: 32 * Self.mib, maxInFlight: 1))
        #expect(tuner.partBytes == 32 * Self.mib && tuner.concurrency == 1)
        // Switching on starts from what was measured.
        tuner.apply(.protocolDefaults)
        tuner.setEnabled(true, at: 100)
        #expect(tuner.partBytes >= 128 * Self.mib)
    }

    @Test func everyBoundHolds() {
        let limits = TransferTuner.Limits(minBytes: 16 * Self.mib, maxBytes: 48 * Self.mib, defaultBytes: 32 * Self.mib,
                                          maxInFlight: 4)
        var slow = TransferTuner(limits: limits)
        Self.drive(&slow, Self.slow, rounds: 30)
        #expect(slow.partBytes == 16 * Self.mib)
        var fast = TransferTuner(limits: limits)
        Self.drive(&fast, Self.lan, rounds: 30)
        #expect(fast.partBytes == 48 * Self.mib)

        var configuration = TransferTuner.Configuration()
        configuration.memoryBudget = 128 * Self.mib
        var tight = TransferTuner(configuration: configuration)
        let (_, _) = Self.drive(&tight, Self.wide, rounds: 40)
        #expect(tight.partBytes * Int64(tight.concurrency) <= 128 * Self.mib)
        #expect(tight.admits(inFlightParts: 0, inFlightBytes: 0, nextPart: 512 * Self.mib))
        #expect(!tight.admits(inFlightParts: 1, inFlightBytes: 100 * Self.mib, nextPart: 32 * Self.mib))
        #expect(!tight.admits(inFlightParts: tight.concurrency, inFlightBytes: 0, nextPart: Self.mib))
    }

    @Test func latencyAloneNeverSizesParts() {
        var tuner = TransferTuner()
        for rtt in stride(from: 0.001, through: 0.5, by: 0.01) { tuner.recordRTT(rtt) }
        // Small parts carry latency, not throughput.
        tuner.record(.init(bytes: Self.mib, start: 0, end: 2, parallel: 1, ackLatency: 1.9))
        #expect(tuner.partBytes == 64 * Self.mib)
        #expect(tuner.throughput == nil)
    }

    @Test func aSeedStartsFromWhatIsKnownAndRealPartsReplaceIt() {
        var tuner = TransferTuner()
        tuner.seed(.init(throughput: 2.5e6, rtt: 0.08, concurrency: 2, partBytes: 64 * Self.mib, source: .calibrated))
        #expect(tuner.partBytes == 8 * Self.mib)
        #expect(tuner.source == .calibrated)
        // The link is really a LAN: the first real part replaces the guess.
        tuner.record(.init(bytes: 8 * Self.mib, start: 0, end: 0.14, parallel: 2))
        #expect(tuner.source == .measured)
        #expect((tuner.throughput ?? 0) > 100e6)
        // A cached estimate brings its concurrency.
        var cached = TransferTuner()
        cached.seed(.init(throughput: 400e6, rtt: 0.01, concurrency: 4, partBytes: 128 * Self.mib, source: .cached))
        #expect(cached.concurrency == 4 && cached.partBytes >= 128 * Self.mib)
    }

    @Test func serverTimingParses() {
        let timing = TransferTuner.ServerTiming(header: "recv;dur=812.5, write;dur=40, sync;dur=12.25")
        #expect(timing == .init(recv: 812.5, write: 40, sync: 12.25))
        #expect(TransferTuner.ServerTiming(header: "cache;desc=hit") == nil)
        #expect(TransferTuner.ServerTiming(header: nil) == nil)
    }

    // MARK: Cache and monitor

    @Test func theEstimateCacheExpiresAndForgetsAnotherRoute() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "vh-estimates-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let cache = TransferEstimateCache(file: file, now: { clock.withLock { $0 } })
        let estimate = TransferTuner.Estimate(throughput: 9e7, rtt: 0.002, concurrency: 3, partBytes: 128 << 20,
                                              source: .measured)
        cache.save(estimate, node: "n1", endpointClass: .lan)
        #expect(cache.estimate(node: "n1", endpointClass: .lan)?.throughput == 9e7)
        #expect(cache.estimate(node: "n1", endpointClass: .lan)?.source == .cached)
        // Persisted.
        let reread = TransferEstimateCache(file: file, now: { clock.withLock { $0 } })
        #expect(reread.estimate(node: "n1", endpointClass: .lan)?.concurrency == 3)
        // Expired after 24 h.
        clock.withLock { $0 += 24 * 3600 + 1 }
        #expect(cache.estimate(node: "n1", endpointClass: .lan) == nil)
        // Another route drops it.
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_800_000_000) }
        cache.save(estimate, node: "n1", endpointClass: .lan)
        #expect(cache.estimate(node: "n1", endpointClass: .wan) == nil)
        #expect(cache.estimate(node: "n1", endpointClass: .lan) == nil)
    }

    @Test func theMonitorStreamsSnapshots() async throws {
        let cache = TransferEstimateCache()
        cache.save(.init(throughput: 2.5e6, rtt: 0.08, concurrency: 1, partBytes: 8 << 20, source: .measured),
                   node: "n1", endpointClass: .wan)
        let monitor = TransferMonitor(node: "n1", endpointClass: .wan, cache: cache)
        var updates = monitor.updates().makeAsyncIterator()
        let first = await updates.next()
        #expect(first?.partBytes == 64 << 20 && first?.tuningEnabled == true && first?.source == .defaults)
        #expect(monitor.seedFromCache())
        let seeded = await updates.next()
        #expect(seeded?.partBytes == 8 << 20 && seeded?.concurrency == 1 && seeded?.source == .cached)
        monitor.setTuningEnabled(false)
        let fixed = await updates.next()
        #expect(fixed?.tuningEnabled == false && fixed?.partBytes == 64 << 20 && fixed?.concurrency == 2)
        // A route change forgets everything learned.
        monitor.setTuningEnabled(true)
        _ = await updates.next()
        monitor.setEndpointClass(.lan)
        let reset = await updates.next()
        #expect(reset?.endpointClass == .lan && reset?.source == .defaults && reset?.estimatedThroughput == nil)
        #expect(cache.estimate(node: "n1", endpointClass: .wan) == nil)
    }

    @Test func endpointClassesFollowTheServersRanges() {
        #expect(TransferEndpointClass(host: "127.0.0.1") == .loopback)
        #expect(TransferEndpointClass(host: "::1") == .loopback)
        #expect(TransferEndpointClass(host: "10.0.0.11") == .lan)
        #expect(TransferEndpointClass(host: "172.20.1.1") == .lan)
        #expect(TransferEndpointClass(host: "192.168.1.4") == .lan)
        #expect(TransferEndpointClass(host: "fd00::11") == .lan)
        #expect(TransferEndpointClass(host: "vh-storage.local") == .lan)
        #expect(TransferEndpointClass(host: "100.101.1.2") == .vpn)
        #expect(TransferEndpointClass(host: "203.0.113.7") == .wan)
        #expect(TransferEndpointClass(host: "2001:db8::1") == .wan)
        #expect(TransferEndpointClass(host: "device.example.com") == .unknown)
    }
}
