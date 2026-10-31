public import Foundation

/// Measures a node's link with the device listener's calibration routes (the server's transfer-protocol.md §4,
/// capability `device.lanes.transfer`): RTT from `GET /transfer/probe`, upload throughput from `POST /transfer/sink`,
/// download throughput from `GET /transfer/source`. Nothing is written on the node and no user file is read.
///
/// Strict budgets: at most ``Budget/maxBytes`` each way (default 16 MiB) and ``Budget/maxDuration`` each way
/// (default 3 s), growing from 1 MiB only while the previous transfer was quick. Real transfers are preferred: the
/// uploader calibrates only before a large upload with no fresh estimate (``VaultLanes/calibrateIfNeeded(totalBytes:)``),
/// never on a reconnect, and its first measured parts replace what calibration guessed.
public struct TransferCalibrator: Sendable {
    public struct Budget: Sendable, Hashable {
        public var maxBytes: Int64 = 16 << 20
        public var maxDuration: Duration = .seconds(3)
        public var probes = 3

        public init() {}
    }

    /// What a calibration found: the "Test Connection" summary.
    public struct Result: Sendable, Hashable {
        /// Seconds; nil when no probe answered.
        public var rtt: Double?
        /// Bytes/s each way; nil when that direction wasn't measured.
        public var uploadBytesPerSecond: Double?
        public var downloadBytesPerSecond: Double?
        /// What the tuner would start uploads with.
        public var suggestedPartBytes: Int64
        public var suggestedConcurrency: Int
        /// Bytes moved by the test itself.
        public var bytesSent: Int64
        public var bytesReceived: Int64
        public var measuredAt: Date

        public init(rtt: Double?, uploadBytesPerSecond: Double?, downloadBytesPerSecond: Double?,
                    suggestedPartBytes: Int64, suggestedConcurrency: Int, bytesSent: Int64 = 0, bytesReceived: Int64 = 0,
                    measuredAt: Date = .now) {
            self.rtt = rtt
            self.uploadBytesPerSecond = uploadBytesPerSecond
            self.downloadBytesPerSecond = downloadBytesPerSecond
            self.suggestedPartBytes = suggestedPartBytes
            self.suggestedConcurrency = suggestedConcurrency
            self.bytesSent = bytesSent
            self.bytesReceived = bytesReceived
            self.measuredAt = measuredAt
        }

        /// MB/s (10^6 bytes) for display.
        public var uploadMegabytesPerSecond: Double? { uploadBytesPerSecond.map { $0 / 1e6 } }
        public var downloadMegabytesPerSecond: Double? { downloadBytesPerSecond.map { $0 / 1e6 } }
    }

    public let http: DeviceHTTPClient
    public var budget: Budget

    public init(http: DeviceHTTPClient, budget: Budget = Budget()) {
        self.http = http
        self.budget = budget
    }

    /// Runs the probes and both directions within the budget. `tuning` supplies the configuration the suggestion is
    /// computed with.
    public func run(tuning: TransferTuner.Configuration = TransferTuner.Configuration())
        async throws(TransferError) -> Result
    {
        let rtt = try await probe()
        let (up, sent) = try await sink(rtt: rtt)
        let (down, received) = try await source(rtt: rtt)
        var tuner = TransferTuner(configuration: tuning)
        if let up {
            tuner.seed(.init(throughput: up, rtt: rtt, concurrency: tuning.initialConcurrency,
                             partBytes: tuning.initialPartBytes, source: .calibrated))
        } else if let rtt {
            tuner.recordRTT(rtt)
        }
        return Result(rtt: rtt, uploadBytesPerSecond: up, downloadBytesPerSecond: down,
                      suggestedPartBytes: tuner.partBytes, suggestedConcurrency: tuner.concurrency,
                      bytesSent: sent, bytesReceived: received, measuredAt: Date())
    }

    /// The lowest round trip of a few probes (the first may carry the TLS handshake).
    func probe() async throws(TransferError) -> Double? {
        var best: Double?
        for _ in 0..<max(1, budget.probes) {
            let request = URLRequest(url: try url("/transfer/probe"))
            let start = Self.now()
            let (data, response) = try await send(request)
            guard response.statusCode == 200 else { throw TransferError.coded(status: response.statusCode, body: data) }
            let elapsed = Self.now() - start
            best = min(best ?? elapsed, elapsed)
        }
        return best
    }

    /// Upload throughput from bodies of growing size, stopping at the byte or time budget.
    func sink(rtt: Double?) async throws(TransferError) -> (Double?, Int64) {
        struct Answer: Decodable {
            var bytes: Int64?
            var server_ms: Double?
        }
        var size: Int64 = 1 << 20
        var total: Int64 = 0
        var best: Double?
        let deadline = Self.now() + Self.seconds(budget.maxDuration)
        while total + size <= budget.maxBytes {
            var request = URLRequest(url: try url("/transfer/sink"))
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.payload(Int(size))
            let start = Self.now()
            let (data, response) = try await send(request)
            let elapsed = Self.now() - start
            if response.statusCode == 429 { break }
            guard response.statusCode == 200 else { throw TransferError.coded(status: response.statusCode, body: data) }
            total += size
            let answer = try? JSONDecoder().decode(Answer.self, from: data)
            let serverSeconds = TransferTuner.ServerTiming(header: response.value(forHTTPHeaderField: "Server-Timing"))
                .map { $0.recv / 1000 } ?? answer?.server_ms.map { $0 / 1000 }
            let wire = max(serverSeconds ?? 0, elapsed - (rtt ?? 0), 0.001)
            best = Double(size) / wire
            // Grow while there is time for a transfer four times as long.
            let remaining = deadline - Self.now()
            guard remaining > elapsed * 4, let next = Self.nextSize(after: size, used: total, budget: budget.maxBytes)
            else { break }
            size = next
        }
        return (best, total)
    }

    /// The next body: four times the last, or what is left of the byte budget when that is smaller (so the largest
    /// sample uses the budget instead of stopping at a quarter of it); nil below 1 MiB.
    static func nextSize(after size: Int64, used: Int64, budget: Int64) -> Int64? {
        let next = min(size * 4, budget - used)
        return next >= 1 << 20 ? next : nil
    }

    /// Download throughput the same way.
    func source(rtt: Double?) async throws(TransferError) -> (Double?, Int64) {
        var size: Int64 = 1 << 20
        var total: Int64 = 0
        var best: Double?
        let deadline = Self.now() + Self.seconds(budget.maxDuration)
        while total + size <= budget.maxBytes {
            let request = URLRequest(url: try url("/transfer/source", [.init(name: "bytes", value: String(size))]))
            let start = Self.now()
            let (data, response) = try await send(request)
            let elapsed = Self.now() - start
            if response.statusCode == 429 { break }
            guard response.statusCode == 200 else { throw TransferError.coded(status: response.statusCode, body: data) }
            total += Int64(data.count)
            best = Double(data.count) / max(elapsed - (rtt ?? 0), 0.001)
            let remaining = deadline - Self.now()
            guard remaining > elapsed * 4, let next = Self.nextSize(after: size, used: total, budget: budget.maxBytes)
            else { break }
            size = next
        }
        return (best, total)
    }

    // MARK: Plumbing

    private func url(_ path: String, _ query: [URLQueryItem] = []) throws(TransferError) -> URL {
        do {
            return try http.url(path: path, query: query)
        } catch {
            throw TransferError(error)
        }
    }

    private func send(_ request: URLRequest) async throws(TransferError) -> (Data, HTTPURLResponse) {
        do {
            return try await http.data(for: request)
        } catch {
            throw TransferError(error)
        }
    }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Bytes that don't compress. Filled by the system's generator at memory speed: a byte-at-a-time loop here ran
    /// for seconds on the cooperative pool in debug builds (megabytes per sample) and stalled every other task.
    static func payload(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, buffer.count) }
        }
        return data
    }
}

extension VaultLanes {
    /// Measures the link now ("Test Connection"): RTT, both directions, and what uploads would start with. Feeds the
    /// result to ``monitor`` (and through it the estimate cache). Needs ``Features/transferLanes``.
    public func testConnection(budget: TransferCalibrator.Budget = TransferCalibrator.Budget())
        async throws(TransferError) -> TransferCalibrator.Result
    {
        guard features.transferLanes else { throw .laneUnavailable(.transfer) }
        let configuration = monitor?.tuner.configuration ?? TransferTuner.Configuration()
        let result = try await TransferCalibrator(http: transfers.http, budget: budget).run(tuning: configuration)
        if let monitor {
            if let rtt = result.rtt { monitor.recordRTT(rtt) }
            if let up = result.uploadBytesPerSecond {
                monitor.seed(.init(throughput: up, rtt: result.rtt, concurrency: result.suggestedConcurrency,
                                   partBytes: result.suggestedPartBytes, source: .calibrated))
            }
        }
        return result
    }

    /// Calibrates before an upload of `totalBytes` only when it is worth it: the node serves the calibration lanes,
    /// the upload is large (≥ 256 MiB), and the monitor has no fresh estimate (cached or measured). A failure is
    /// ignored: the upload learns from its own parts. Returns whether it calibrated.
    @discardableResult
    public func calibrateIfNeeded(totalBytes: Int64) async -> Bool {
        guard features.transferLanes, totalBytes >= 256 << 20, let monitor else { return false }
        monitor.seedFromCache()
        guard !monitor.hasEstimate else { return false }
        return (try? await testConnection()) != nil
    }
}
