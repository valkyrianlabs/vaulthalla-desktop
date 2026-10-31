import Darwin
import Foundation
import Synchronization
import Testing
import VHCore
@testable import VHTransport

/// FAKE-SERVER BENCHMARK (opt-in: `VH_BENCH=1`, or tools/bench/transfer-bench.sh). Uploads one file through the
/// in-process ``FakeUploadServer`` behind an emulated link (a shared bandwidth cap on request bodies and a fixed delay
/// before every answer) and compares the legacy whole-file PUT, fixed 64 MiB × 2 parts, and tuned parts (a cold
/// start, then a warm one that starts from the cold run's estimate). It prints throughput, the process's peak memory
/// footprint above its baseline (client and fake server share the process), and the requests and time spent beyond
/// the ideal transfer. Loopback TLS with a token-bucket throttle is not a real network (no TCP slow start, loss or
/// queueing): the numbers compare the client's strategies against each other, nothing more.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VH_BENCH"] == "1"))
struct TransferBenchmark {
    struct Link: Sendable {
        var name: String
        var bytesPerSecond: Double
        var latency: Duration
        var fileBytes: Int
    }

    struct Row: Sendable {
        var link: String
        var mode: String
        var seconds: Double
        var requests: Int
        var peakFootprint: Int64
        var partBytes: Int64?
        var concurrency: Int?
        var ideal: Double
    }

    static let links = [
        Link(name: "20 Mbit/s + 80 ms", bytesPerSecond: 2.5e6, latency: .milliseconds(80),
             fileBytes: Int(ProcessInfo.processInfo.environment["VH_BENCH_SLOW_MIB"].flatMap(Int.init) ?? 40) << 20),
        Link(name: "1 Gbit/s + 1 ms", bytesPerSecond: 125e6, latency: .milliseconds(1),
             fileBytes: Int(ProcessInfo.processInfo.environment["VH_BENCH_FAST_MIB"].flatMap(Int.init) ?? 1024) << 20),
    ]

    @Test func compareStrategies() async throws {
        var rows: [Row] = []
        for link in Self.links {
            let folder = FileManager.default.temporaryDirectory.appending(path: "vh-bench-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appending(path: "payload.bin")
            try Self.writePayload(file, bytes: link.fileBytes)
            let ideal = Double(link.fileBytes) / link.bytesPerSecond

            rows.append(try await Self.legacy(link, file: file, ideal: ideal))
            var fixed = TransferTuner.Configuration()
            fixed.enabled = false
            rows.append(try await Self.resumable(link, file: file, ideal: ideal, mode: "fixed 64 MiB x 2",
                                                 monitor: TransferMonitor(node: "bench", configuration: fixed),
                                                 calibrate: false))
            let tuned = TransferMonitor(node: "bench", configuration: TransferTuner.Configuration())
            rows.append(try await Self.resumable(link, file: file, ideal: ideal, mode: "tuned (cold)", monitor: tuned,
                                                 calibrate: true))
            rows.append(try await Self.resumable(link, file: file, ideal: ideal, mode: "tuned (warm)", monitor: tuned,
                                                 calibrate: true))
        }
        print(Self.table(rows))
        #expect(rows.allSatisfy { $0.seconds > 0 })
    }

    // MARK: Runs

    static func server(_ link: Link, fake: FakeUploadServer, legacy: Bool) async throws -> HTTPTestServer {
        var options = HTTPTestServer.Options()
        options.bandwidth = link.bytesPerSecond
        options.latency = link.latency
        return try await HTTPTestServer.start(
            tls: try WsClientTLSTests.serverTLS(clientSPKI: Recorded()), options: options,
            router: { request in
                if FakeUploadServer.serves(request) { return fake.route(request) }
                if legacy, request.method == "PUT", request.path.hasPrefix("/upload/") {
                    // The session flow's whole-file PUT, streamed and discarded.
                    return .stream(.init(chunk: { _ in .proceed }, end: { .init(status: 200) }))
                }
                return .buffer
            },
            handler: { request in
                if FakeUploadServer.serves(request) { return fake.handle(request) }
                if request.method == "POST", request.path == "/upload/session" {
                    return .init(status: 200, headers: ["Content-Type": "application/json"],
                                 body: Data(#"{"upload_id":"legacy1"}"#.utf8))
                }
                return .init(status: 200)
            })
    }

    static func lanes(port: UInt16, monitor: TransferMonitor?, resumable: Bool) throws -> VaultLanes {
        let configuration = DeviceHTTPClient.Configuration(
            endpoint: NodeEndpoint(host: "127.0.0.1", port: port),
            identity: try WsClientTLSTests.identity(WsClientTLSTests.clientP12),
            serverSPKIPin: WsClientTLSTests.data(hex: WsClientTLSTests.serverSPKI), timeout: .seconds(30))
        var lanes = VaultLanes(transfers: try DeviceTransferClient(configuration: configuration))
        lanes.features = .init(resumableUploads: resumable, transferLanes: resumable)
        lanes.monitor = monitor
        return lanes
    }

    static func legacy(_ link: Link, file: URL, ideal: Double) async throws -> Row {
        let fake = FakeUploadServer()
        let server = try await server(link, fake: fake, legacy: true)
        defer { server.stop() }
        let lanes = try lanes(port: server.port, monitor: nil, resumable: false)
        defer { lanes.invalidate() }
        let (seconds, peak) = try await measure {
            try await lanes.uploadSessions([.init(source: file, relativePath: "payload.bin", size: Int64(link.fileBytes))],
                                           vaultID: 1, into: "/") { _ in }
        }
        return Row(link: link.name, mode: "legacy whole-file PUT", seconds: seconds,
                   requests: server.requests.count, peakFootprint: peak, partBytes: Int64(link.fileBytes),
                   concurrency: 1, ideal: ideal)
    }

    static func resumable(_ link: Link, file: URL, ideal: Double, mode: String, monitor: TransferMonitor,
                          calibrate: Bool) async throws -> Row {
        let fake = FakeUploadServer()
        fake.state.withLock { $0.keepBodies = false }
        let server = try await server(link, fake: fake, legacy: false)
        defer { server.stop() }
        var lanes = try lanes(port: server.port, monitor: monitor, resumable: true)
        lanes.features.transferLanes = calibrate
        defer { lanes.invalidate() }
        let record = ResumableUploader.plan([.init(source: file, relativePath: "payload.bin", size: Int64(link.fileBytes))],
                                            vaultID: 1, into: "/")
        let (seconds, peak) = try await measure { try await lanes.uploadResumable(record) { _ in } }
        let parts = fake.partRequests.filter { $0.status == 200 }
        let sizes = Set(parts.map(\.length))
        return Row(link: link.name, mode: mode, seconds: seconds, requests: server.requests.count, peakFootprint: peak,
                   partBytes: sizes.max(), concurrency: fake.state.withLock { $0.peakInFlight }, ideal: ideal)
    }

    // MARK: Measuring

    /// Wall time of `body`, and the peak physical footprint above the one before it (sampled every 10 ms).
    static func measure(_ body: () async throws -> some Sendable) async throws -> (Double, Int64) {
        let baseline = footprint()
        let peak = Mutex(baseline)
        let sampler = Task.detached {
            while !Task.isCancelled {
                let now = footprint()
                peak.withLock { $0 = max($0, now) }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let start = ContinuousClock.now
        _ = try await body()
        let elapsed = ContinuousClock.now - start
        sampler.cancel()
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (seconds, max(0, peak.withLock { $0 } - baseline))
    }

    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    static func writePayload(_ url: URL, bytes: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = TransferCalibrator.payload(8 << 20)
        var left = bytes
        while left > 0 {
            let take = min(left, chunk.count)
            try handle.write(contentsOf: chunk.prefix(take))
            left -= take
        }
    }

    static func table(_ rows: [Row]) -> String {
        func mib(_ value: Int64?) -> String { value.map { String(format: "%.0f MiB", Double($0) / 1048576) } ?? "-" }
        func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
            let fill = String(repeating: " ", count: max(0, width - text.count))
            return left ? text + fill : fill + text
        }
        func line(_ cells: [String]) -> String {
            let widths = [20, 22, 9, 9, 9, 9, 10, 10]
            return cells.enumerated().map { pad($1, widths[$0], left: $0 < 2) }.joined(separator: " ")
        }
        var lines = ["", "FAKE-SERVER BENCHMARK (in-process loopback TLS, token-bucket link; not a real network)",
                     line(["link", "mode", "seconds", "MB/s", "requests", "part", "in flight", "peak RSS+"])]
        for row in rows {
            let rate = Double(rowBytes(row)) / row.seconds / 1e6
            lines.append(line([row.link, row.mode, String(format: "%.2f", row.seconds), String(format: "%.2f", rate),
                               String(row.requests), mib(row.partBytes), row.concurrency.map(String.init) ?? "-",
                               mib(row.peakFootprint)]))
        }
        lines.append("ideal (bytes / link rate): " + Dictionary(grouping: rows, by: \.link).map { link, rows in
            String(format: "%.2f s", rows[0].ideal) + " for " + link
        }.sorted().joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    static func rowBytes(_ row: Row) -> Int {
        links.first { $0.name == row.link }?.fileBytes ?? 0
    }
}
