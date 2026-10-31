import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Upload and download benchmarks against a live daemon over the real network between this Mac and the instance's box
/// (docs/interop-testing.md). Opt-in twice: `VH_LIVE_NODE` and `VH_LIVE_BENCH=1`. Each mode runs `VH_LIVE_BENCH_REPS`
/// times (default 2), interleaved, on a 1 GiB file (`VH_LIVE_BENCH_MIB`); every upload is checked with `vh fs get`.
///
/// Per run: wall time and throughput, the time from the last byte sent to the commit (finalize), this process's peak
/// resident set and footprint, the daemon's CPU and peak RSS (sampled on the box), and the HTTP requests the daemon saw
/// (its `http` logger and console sink at debug level; see the doc). Rows go to stdout and, with `VH_LIVE_BENCH_OUT`, as JSON lines to that
/// file.
@Suite(.enabled(if: LiveNode.isConfigured && ProcessInfo.processInfo.environment["VH_LIVE_BENCH"] == "1",
                "set VH_LIVE_NODE and VH_LIVE_BENCH=1 to benchmark against a live daemon"),
       .serialized, .timeLimit(.minutes(60)))
struct LiveTransferBenchmarks {
    static let environment = ProcessInfo.processInfo.environment
    static let repetitions = Int(environment["VH_LIVE_BENCH_REPS"] ?? "") ?? 2
    static let size = (Int64(environment["VH_LIVE_BENCH_MIB"] ?? "") ?? 1024) * mib

    struct Row: Codable, Sendable {
        var mode: String
        var repetition: Int
        var bytes: Int64
        var seconds: Double
        var megabytesPerSecond: Double
        var finalizeSeconds: Double?
        var clientPeakResidentMiB: Double
        var clientPeakFootprintMiB: Double
        var clientBaselineResidentMiB: Double
        var serverCPUSeconds: Double
        var serverAverageCPUPercent: Double
        var serverPeakCPUPercent: Double
        var serverPeakRSSMiB: Double
        var requests: Int?
        var partRequests: Int?
        var note: String?
    }

    @Test func benchmarks() async throws {
        try await LiveDevice.with { device in
            let files = try LiveFiles()
            var rows: [Row] = []
            var download: (path: String, sha256: String)?
            for repetition in 1...Self.repetitions {
                let (source, digest) = try files.random("bench-\(repetition).bin", size: Self.size,
                                                        seed: 0xBE7C_0000 + UInt64(repetition))
                let cache = files.folder.appending(path: "estimates-\(repetition).json")

                rows.append(try await Self.measure("legacy whole-file /upload/session", repetition, device, source, digest,
                                                   mode: .legacy))
                rows.append(try await Self.measure("resumable fixed 64 MiB x 2", repetition, device, source, digest,
                                                   mode: .fixed))
                rows.append(try await Self.measure("resumable automatic (cold)", repetition, device, source, digest,
                                                   mode: .automatic(cache)))
                let warm = try await Self.measure("resumable automatic (warm)", repetition, device, source, digest,
                                                  mode: .automatic(cache))
                rows.append(warm)
                download = (warm.note ?? "", digest)
                if let download {
                    rows.append(try await Self.download(repetition, device, path: download.path, digest: download.sha256,
                                                        into: files.folder))
                }
                try? FileManager.default.removeItem(at: source)
            }
            // The link last (its 256 MiB bodies sit in this process's memory): the calibration lanes, each way.
            for repetition in 1...Self.repetitions {
                rows.append(contentsOf: try await Self.lanes(device, repetition: repetition))
            }
            Self.report(rows)
        }
    }

    // MARK: - Modes

    enum Mode {
        case legacy
        case fixed
        case automatic(URL)
    }

    static func measure(_ title: String, _ repetition: Int, _ device: LiveDevice, _ source: URL, _ digest: String,
                        mode: Mode) async throws -> Row {
        let path = "/bench/\(UUID().uuidString.prefix(8)).bin"
        let directory = "/bench"
        let name = String(path.dropFirst(directory.count + 1))
        var tuning = TransferTuner.Configuration()
        var cache: TransferEstimateCache?
        switch mode {
        case .legacy: break
        case .fixed:
            tuning.enabled = false
            tuning.fixedPartBytes = 64 * mib
            tuning.fixedConcurrency = 2
        case .automatic(let file):
            cache = TransferEstimateCache(file: file)
        }
        let lanes: VaultLanes
        if case .legacy = mode {
            lanes = try device.lanes(tuning: tuning, cache: cache, resumable: false)
        } else {
            lanes = try device.lanes(tuning: tuning, cache: cache)
        }
        defer { lanes.invalidate() }
        let cachedBefore = cache?.estimate(node: device.serverNodeID, endpointClass: .lan)

        let lastByte = Mutex<Double?>(nil)
        let size = size
        let progress: @Sendable (VaultLanes.UploadProgress) -> Void = { report in
            if report.bytes >= size { lastByte.withLock { $0 = $0 ?? liveNow() } }
        }
        let counters = try await requestCounters()
        let baseline = ClientMemory.current()
        let client = ClientSampler()
        let server = try await DaemonSampler.start()
        let started = liveNow()
        let file = VaultLanes.UploadFile(source: source, relativePath: name, size: size)
        switch mode {
        case .legacy:
            try await lanes.uploadSessions([file], vaultID: device.vault, into: directory, progress: progress)
        case .fixed:
            let record = ResumableUploader.plan([file], vaultID: device.vault, into: directory)
            let outcome = try await lanes.resumableUploader.upload(record, progress: progress)
            #expect(outcome.failed.isEmpty)
        case .automatic:
            // The app's path: calibrates first when no estimate is cached.
            let record = ResumableUploader.plan([file], vaultID: device.vault, into: directory)
            try await lanes.uploadResumable(record, progress: progress)
        }
        let ended = liveNow()
        let memory = client.stop()
        let daemon = try await server.stop()
        let requests = try await requestCounters()
        #expect(try await LiveNode.sha256(vault: device.vault, path: path) == digest, "\(title): bytes differ")
        let snapshot = lanes.monitor?.snapshot
        var note = path
        if case .automatic = mode {
            let estimate = lanes.monitor?.tuner
            note += String(format: " | cached before: %@; ended at %d MiB x %d (%@)",
                           cachedBefore.map { String(format: "%.0f MB/s", $0.throughput / 1e6) } ?? "none",
                           Int((estimate?.partBytes ?? 0) / mib), estimate?.concurrency ?? 0,
                           snapshot?.source.rawValue ?? "?")
        }
        let seconds = ended - started
        return Row(mode: title, repetition: repetition, bytes: size, seconds: seconds,
                   megabytesPerSecond: Double(size) / seconds / 1e6,
                   finalizeSeconds: lastByte.withLock { $0 }.map { ended - $0 },
                   clientPeakResidentMiB: Double(memory.resident) / Double(mib),
                   clientPeakFootprintMiB: Double(memory.footprint) / Double(mib),
                   clientBaselineResidentMiB: Double(baseline.resident) / Double(mib),
                   serverCPUSeconds: daemon.cpuSeconds, serverAverageCPUPercent: daemon.averageCPUPercent,
                   serverPeakCPUPercent: daemon.peakCPUPercent, serverPeakRSSMiB: daemon.peakRSSMiB,
                   requests: requests.map { $0.all - (counters?.all ?? 0) },
                   partRequests: requests.map { $0.parts - (counters?.parts ?? 0) }, note: note)
    }

    static func download(_ repetition: Int, _ device: LiveDevice, path: String, digest: String, into folder: URL)
        async throws -> Row
    {
        let vaultPath = String(path.split(separator: " ").first ?? "")
        let lanes = try device.lanes()
        defer { lanes.invalidate() }
        let target = folder.appending(path: "download-\(repetition).bin")
        let baseline = ClientMemory.current()
        let client = ClientSampler()
        let server = try await DaemonSampler.start()
        let started = liveNow()
        let length = try await lanes.download(vaultID: device.vault, path: vaultPath, isDirectory: false, to: target) { _, _ in }
        let ended = liveNow()
        let memory = client.stop()
        let daemon = try await server.stop()
        #expect(length == size)
        #expect(try LiveFiles.sha256(of: target) == digest, "the download differs")
        try? FileManager.default.removeItem(at: target)
        let seconds = ended - started
        return Row(mode: "download (/download, device lane)", repetition: repetition, bytes: length, seconds: seconds,
                   megabytesPerSecond: Double(length) / seconds / 1e6, finalizeSeconds: nil,
                   clientPeakResidentMiB: Double(memory.resident) / Double(mib),
                   clientPeakFootprintMiB: Double(memory.footprint) / Double(mib),
                   clientBaselineResidentMiB: Double(baseline.resident) / Double(mib),
                   serverCPUSeconds: daemon.cpuSeconds, serverAverageCPUPercent: daemon.averageCPUPercent,
                   serverPeakCPUPercent: daemon.peakCPUPercent, serverPeakRSSMiB: daemon.peakRSSMiB,
                   requests: 1, partRequests: nil, note: vaultPath)
    }

    /// `/transfer/sink` and `/transfer/source` with 256 MiB bodies: the link as the device listener sees it.
    static func lanes(_ device: LiveDevice, repetition: Int) async throws -> [Row] {
        let http = try device.http()
        defer { http.invalidate() }
        let bytes = 256 * mib
        var rows: [Row] = []
        var sink = URLRequest(url: try http.url(path: "/transfer/sink"))
        sink.httpMethod = "POST"
        sink.httpBody = Data(count: Int(bytes))
        var started = liveNow()
        let (sinkBody, sinkResponse) = try await http.data(for: sink)
        var seconds = liveNow() - started
        #expect(sinkResponse.statusCode == 200)
        let serverMS = (try? JSONDecoder().decode(JSONValue.self, from: sinkBody))?["server_ms"]?.doubleValue
        rows.append(Row(mode: "link: /transfer/sink 256 MiB", repetition: repetition, bytes: bytes, seconds: seconds,
                        megabytesPerSecond: Double(bytes) / seconds / 1e6, finalizeSeconds: nil,
                        clientPeakResidentMiB: 0, clientPeakFootprintMiB: 0, clientBaselineResidentMiB: 0,
                        serverCPUSeconds: 0, serverAverageCPUPercent: 0, serverPeakCPUPercent: 0, serverPeakRSSMiB: 0,
                        requests: 1, partRequests: nil,
                        note: serverMS.map { String(format: "server-side body %.1f MB/s", Double(bytes) / ($0 / 1000) / 1e6) }))
        started = liveNow()
        let (data, sourceResponse) = try await http.data(for: URLRequest(url: try http.url(
            path: "/transfer/source", query: [.init(name: "bytes", value: String(bytes))])))
        seconds = liveNow() - started
        #expect(sourceResponse.statusCode == 200 && Int64(data.count) == bytes)
        rows.append(Row(mode: "link: /transfer/source 256 MiB", repetition: repetition, bytes: bytes, seconds: seconds,
                        megabytesPerSecond: Double(bytes) / seconds / 1e6, finalizeSeconds: nil,
                        clientPeakResidentMiB: 0, clientPeakFootprintMiB: 0, clientBaselineResidentMiB: 0,
                        serverCPUSeconds: 0, serverAverageCPUPercent: 0, serverPeakCPUPercent: 0, serverPeakRSSMiB: 0,
                        requests: 1, partRequests: nil, note: nil))
        return rows
    }

    /// HTTP requests the daemon logged so far (its `http` logger and console at debug, so daemon.log gets one
    /// "Request headers:" line per request):
    /// all upload requests, and resumable parts. nil when the log has none (debug logging off).
    static func requestCounters() async throws -> (all: Int, parts: Int)? {
        let log = "\(LiveNode.runDirectory)/log/daemon.log"
        let text = try await LiveNode.shell(
            "sudo grep -c 'Request headers: /upload' \(log) || true; "
                + "sudo grep -cE 'Request headers: /upload/sessions/[^/ ]+/files/' \(log) || true")
        let numbers = text.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 2, numbers[0] > 0 else { return nil }
        return (numbers[0], numbers[1])
    }

    static func report(_ rows: [Row]) {
        print("[bench] mode | rep | MB/s | s | finalize s | client peak RSS / footprint MiB (baseline) | daemon CPU s, avg %, "
              + "peak % | daemon peak RSS MiB | requests (parts)")
        for row in rows {
            print(String(format: "[bench] %@ | %d | %.1f | %.2f | %@ | %.0f / %.0f (%.0f) | %.1f, %.0f, %.0f | %.0f | %@ | %@",
                         row.mode, row.repetition, row.megabytesPerSecond, row.seconds,
                         row.finalizeSeconds.map { String(format: "%.2f", $0) } ?? "-",
                         row.clientPeakResidentMiB, row.clientPeakFootprintMiB, row.clientBaselineResidentMiB,
                         row.serverCPUSeconds, row.serverAverageCPUPercent, row.serverPeakCPUPercent, row.serverPeakRSSMiB,
                         row.requests.map { "\($0) (\(row.partRequests.map(String.init) ?? "-"))" } ?? "-", row.note ?? ""))
        }
        guard let out = environment["VH_LIVE_BENCH_OUT"] else { return }
        let encoder = JSONEncoder()
        let lines = rows.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
}
