import CryptoKit
import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
import VHIdentity
import VHNodes
import VHTransport

/// Direct transport against a real daemon (docs/interop-testing.md, the server's docs/reference/transfer-protocol.md):
/// endpoint advertisement and selection, resumable uploads over the device lane (large files, a dropped route, a
/// daemon restart, resubmissions), the File Provider's conditional single-file writes, and the calibration lanes.
/// Skipped unless `VH_LIVE_NODE` is set; each test pairs its own key and revokes it at the end.
@Suite(.enabled(if: LiveNode.isConfigured, "set VH_LIVE_NODE=<host:port> to run against a live daemon"),
       .serialized, .timeLimit(.minutes(10)))
struct LiveTransferTests {
    static let environment = ProcessInfo.processInfo.environment
    /// A port on the instance's box for a throwaway TLS server with its own key (the identity-mismatch candidate).
    static let decoyPort = UInt16(environment["VH_LIVE_DECOY_PORT"] ?? "") ?? 36990

    static func fixedParts(_ bytes: Int64, concurrency: Int = 2) -> TransferTuner.Configuration {
        var configuration = TransferTuner.Configuration()
        configuration.enabled = false
        configuration.fixedPartBytes = bytes
        configuration.fixedConcurrency = concurrency
        return configuration
    }

    static func session(_ node: Node, keys: DeviceKeys) -> NodeSession {
        var settings = NodeSession.Configuration()
        settings.reconnect = ReconnectPolicy(base: .milliseconds(200), cap: .seconds(2))
        return NodeSession(node: node, keys: keys, configuration: settings)
    }

    // MARK: - a. Endpoints

    /// `device.endpoints` lists the box's LAN address (kind lan, the instance's port), loopback, and no link-local; a
    /// session selects a verified LAN route; a different TLS server at the configured address is only marked
    /// `identity_mismatch` (no re-pairing) while an advertised address proves the pin.
    @Test func endpointsAreAdvertisedAndSelectionVerifiesThem() async throws {
        try await LiveDevice.with { device in
            let box = device.endpoint.host
            let port = UInt16(device.instance.devicePort)
            let decoy = try await Self.startDecoy()
            defer { Task { try? await LiveNode.shell("kill \(decoy) 2>/dev/null; rm -rf /tmp/vhi-live-decoy") } }

            // 1. Configured: the address this Mac reaches the box at.
            let first = Self.session(device.node(), keys: device.keys)
            let events = Recorder(first.events)
            await first.start()
            try #require(await events.first(within: .seconds(20)) { $0.status == .online } != nil,
                         "never online: \(events.all)")
            let ws = try #require(await first.client)
            let answer = try await ws.send(command: "device.endpoints", payload: [:])
            let candidates = answer["candidates"]?.arrayValue ?? []
            print("[live] device.endpoints: " + candidates.map {
                "\($0["host"]?.stringValue ?? "?"):\($0["port"]?.integerValue ?? 0) \($0["kind"]?.stringValue ?? "?")"
                    + "/\($0["source"]?.stringValue ?? "?")"
            }.joined(separator: ", "))
            #expect(answer["node_id"]?.stringValue == device.serverNodeID)
            #expect(answer["remote"] == true && answer["listening"] == true)
            #expect(answer["port"]?.integerValue == Int64(port))
            let lan = candidates.first { $0["host"]?.stringValue == box }
            #expect(lan?["kind"]?.stringValue == "lan", "\(box) is listed as lan: \(candidates)")
            #expect(lan?["port"]?.integerValue == Int64(port))
            #expect(lan?["source"]?.stringValue == "interface")
            for loopback in ["127.0.0.1", "::1"] {
                let entry = candidates.first { $0["host"]?.stringValue == loopback }
                #expect(entry?["kind"]?.stringValue == "loopback", "\(loopback): \(candidates)")
                #expect(entry?["port"]?.integerValue == Int64(port))
            }
            for candidate in candidates {
                let host = candidate["host"]?.stringValue?.lowercased() ?? ""
                #expect(!host.hasPrefix("fe80") && !host.hasPrefix("169.254"), "link-local advertised: \(host)")
                #expect(!host.contains("%"), "a scope id travelled: \(host)")
            }
            // The owner session keeps what was advertised.
            let saved = await events.first(within: .seconds(10)) {
                if case .endpointsChanged(let endpoints, _, _) = $0 { endpoints.contains { $0.host == box } } else { false }
            }
            guard case .endpointsChanged(let advertised, _, _) = saved else {
                Issue.record("no endpointsChanged with \(box): \(events.all)")
                return
            }
            let route = try #require(await first.route)
            #expect(route.endpoint == device.endpoint && route.transportClass == .lan && route.verifiedKey == .current
                    && route.isConnected, "route: \(route)")
            Self.printSelection("configured = \(box)", route.selection)
            #expect(route.selection?.report(for: NodeEndpoint(host: "127.0.0.1", port: port))?.outcome != .ok,
                    "nothing of this node listens on the Mac's loopback")
            await first.stop()

            // 2. Configured: another TLS server (fresh key) at the box. The node's advertised list, plus a name that
            // doesn't resolve, are the other candidates.
            let decoyEndpoint = NodeEndpoint(host: box, port: Self.decoyPort)
            let unresolvable = AdvertisedEndpoint(host: "vh-interop-nowhere.invalid", port: port, kind: .lan, source: "config")
            let node = device.node(endpoint: decoyEndpoint, endpoints: advertised + [unresolvable])
            let second = Self.session(node, keys: device.keys)
            let secondEvents = Recorder(second.events)
            await second.start()
            defer { Task { await second.stop() } }
            try #require(await secondEvents.first(within: .seconds(25)) { $0.status == .online } != nil,
                         "never online with a mismatching configured endpoint: \(secondEvents.all)")
            let moved = try #require(await second.route)
            Self.printSelection("configured = decoy \(decoyEndpoint)", moved.selection)
            #expect(moved.endpoint == NodeEndpoint(host: box, port: port), "route: \(moved.endpoint)")
            #expect(moved.transportClass == .lan && moved.verifiedKey == .current)
            let selection = try #require(moved.selection)
            #expect(selection.report(for: decoyEndpoint)?.outcome == .identityMismatch,
                    "decoy: \(String(describing: selection.report(for: decoyEndpoint)))")
            #expect(selection.configuredEndpointMismatched == false)
            let nowhere = selection.report(for: unresolvable.endpoint)?.outcome
            #expect(nowhere != .ok, "an unresolvable name: \(String(describing: nowhere))")
            #expect(!secondEvents.all.contains { if case .pairingRequired = $0 { true } else { false } },
                    "a mismatch on one candidate must not ask for pairing again")
            #expect(!secondEvents.all.contains { $0.status == .revoked })
            #expect(!secondEvents.all.contains { if case .recordChanged = $0 { true } else { false } },
                    "the pairing record is untouched")

            // 3. Test Connection selects again: the same route.
            let again = try #require(await second.testRoute())
            Self.printSelection("testRoute()", again)
            #expect(again.chosen?.candidate.endpoint == NodeEndpoint(host: box, port: port))
            // The last good route is probed first now; the decoy is either refused again or not tried at all.
            let decoyAgain = again.report(for: decoyEndpoint)?.outcome
            #expect(decoyAgain == .identityMismatch || decoyAgain == .notTried, "decoy: \(String(describing: decoyAgain))")
            #expect(await second.status == .online)
        }
    }

    /// `openssl s_server` on the box with a fresh P-256 key; returns its pid.
    static func startDecoy() async throws -> Int {
        let dir = "/tmp/vhi-live-decoy"
        let text = try await LiveNode.shell(
            "rm -rf \(dir) && mkdir -p \(dir) && cd \(dir) && "
                + "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout key.pem -out cert.pem "
                + "-subj /CN=vh-interop-decoy -days 1 > /dev/null 2>&1 && "
                + "(nohup timeout 900 openssl s_server -quiet -accept \(decoyPort) -cert cert.pem -key key.pem -verify 1 -www "
                + "< /dev/null > /dev/null 2>&1 & echo $!)")
        guard let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LiveFailure("decoy didn't start: \(text)")
        }
        try await Task.sleep(for: .milliseconds(500))
        return pid
    }

    static func printSelection(_ title: String, _ selection: EndpointSelection?) {
        guard let selection else {
            print("[live] \(title): no selection")
            return
        }
        print("[live] selection, \(title): chosen \(selection.chosen.map { "\($0.candidate.endpoint)" } ?? "none")")
        for report in selection.reports {
            let rtt = report.rtt.map { String(format: " %.1f ms", Double($0.components.attoseconds) / 1e15
                                                  + Double($0.components.seconds) * 1000) } ?? ""
            print("[live]   \(report.candidate.endpoint) \(report.candidate.sources.map(\.rawValue)) -> \(report.outcome)"
                  + " (\(report.transportClass.rawValue))\(rtt)")
        }
    }

    // MARK: - b. A large resumable upload

    /// ~300 MB (over Cloudflare's 100 MB body limit) in 64 MiB parts over the device lane; the session's status while it
    /// runs (sorted, coalesced, growing ranges), the commit, and the bytes as `vh fs get` reads them.
    @Test func largeResumableUploadOverTheDeviceLane() async throws {
        try await LiveDevice.with { device in
            let files = try LiveFiles()
            let size: Int64 = 300_000_000
            let (source, digest) = try files.random("big.bin", size: size, seed: 0xB16_F11E)
            let store = ResumableStore(directory: files.folder.appending(path: "store"))
            let lanes = try device.lanes(tuning: Self.fixedParts(64 * mib), store: store)
            defer { lanes.invalidate() }
            let http = try device.http()
            defer { http.invalidate() }
            let name = "big-\(UUID().uuidString.prefix(8)).bin"
            let record = ResumableUploader.plan([.init(source: source, relativePath: name, size: size)],
                                                vaultID: device.vault, into: "/live")
            let path = record.files[0].path

            let watcher = StatusWatcher(http: http, store: store, record: record.id)
            let started = liveNow()
            let outcome = try await lanes.resumableUploader.upload(record)
            let elapsed = liveNow() - started
            let samples = await watcher.stop()
            print(String(format: "[live] 300 MB resumable upload: %.1f s, %.1f MB/s, %d status samples", elapsed,
                         Double(size) / elapsed / 1e6, samples.count))

            #expect(outcome.failed.isEmpty, "failed: \(outcome.failed)")
            let entry = try #require(outcome.committed[path] ?? nil, "no entry for \(path): \(outcome.committed)")
            #expect(entry.sizeBytes == size)
            #expect(store.load(record.id) == nil, "a finished upload leaves no record")

            // Status while running: ranges sorted, disjoint, coalesced, inside the file; received = their sum; growing.
            let receiving = samples.filter { $0.files.first?.state == "receiving" }
            #expect(!receiving.isEmpty, "never saw the session receiving")
            var last: Int64 = 0
            for sample in samples {
                guard let file = sample.files.first else { continue }
                var end: Int64 = -1
                var sum: Int64 = 0
                for range in file.ranges {
                    #expect(range.count == 2 && range[0] < range[1] && range[0] > end && range[1] <= size,
                            "ranges: \(file.ranges)")
                    end = range[1]
                    sum += range[1] - range[0]
                }
                #expect(sum == file.received_bytes)
                #expect(file.received_bytes >= last, "received went back: \(file.received_bytes) < \(last)")
                last = file.received_bytes
                // 64 MiB parts: every range ends on a part boundary, or at the end.
                for range in file.ranges { #expect(range[1] % (64 * mib) == 0 || range[1] == size) }
            }
            print("[live] status samples (received MB): "
                  + samples.compactMap { $0.files.first.map { "\($0.state):\($0.received_bytes / 1_000_000)" } }
                      .joined(separator: " "))

            // The session afterwards, and the bytes as the node serves them.
            if let uploadID = samples.last?.upload_id {
                let (code, after) = try await UploadWire.status(http, upload: uploadID)
                #expect(code == 200 && after?.state == "complete" && after?.files.first?.state == "committed",
                        "after: \(code) \(String(describing: after?.state))")
            }
            #expect(try await LiveNode.sha256(vault: device.vault, path: path) == digest)
        }
    }

    // MARK: - c. Interruptions

    /// The route drops mid-file (every connection cut, new ones refused for 3 s): the upload resumes from the node's
    /// status and sends only the gaps (counted by a relay), and the committed file is exact.
    @Test func aDroppedRouteResumesWithOnlyTheGaps() async throws {
        try await Self.interrupted(name: "drop") { relay in
            relay.setRefusing(true)
            relay.dropAll()
            try await Task.sleep(for: .seconds(3))
            relay.setRefusing(false)
        }
    }

    /// The daemon restarts mid-file (SIGTERM, start again on the same DB and spool): the upload resumes on the restarted
    /// node and sends only the gaps.
    @Test func aDaemonRestartResumesWithOnlyTheGaps() async throws {
        try await Self.interrupted(name: "restart") { _ in
            let before = try await LiveNode.instance()
            let after = try await LiveNode.restartDaemon()
            #expect(after.alive && after.serverSPKISHA256 == before.serverSPKISHA256, "the listener key survives")
        }
    }

    /// The daemon is killed mid-file (SIGKILL: no clean shutdown, part attempts left half written) and started again:
    /// the node keeps only durable parts, and the upload resumes with the gaps.
    @Test func aDaemonCrashResumesWithOnlyTheGaps() async throws {
        try await Self.interrupted(name: "crash") { _ in
            let after = try await LiveNode.restartDaemon(kill: true)
            #expect(after.alive)
        }
    }

    static func interrupted(name: String, interrupt: @escaping @Sendable (LiveRelay) async throws -> Void) async throws {
        try await LiveDevice.with { device in
            let files = try LiveFiles()
            let size: Int64 = 300_000_000
            let part = 16 * mib
            let (source, digest) = try files.random("\(name).bin", size: size, seed: 0xD20B ^ UInt64(name.count))
            let relay = try LiveRelay(to: device.endpoint)
            defer { relay.stop() }
            let store = ResumableStore(directory: files.folder.appending(path: "store"))
            let lanes = try device.lanes(relay.endpoint, tuning: Self.fixedParts(part), store: store)
            defer { lanes.invalidate() }
            // Status straight to the node, not through the relay.
            let http = try device.http()
            defer { http.invalidate() }
            let record = ResumableUploader.plan(
                [.init(source: source, relativePath: "\(name)-\(UUID().uuidString.prefix(8)).bin", size: size)],
                vaultID: device.vault, into: "/live")
            let path = record.files[0].path
            let uploader = lanes.resumableUploader
            let upload = Task { try await uploader.upload(record) }

            // Wait until the node holds 40 % of the file, then interrupt.
            var uploadID: String?
            var held: Int64 = 0
            let deadline = liveNow() + 240
            while held < size * 4 / 10 {
                guard liveNow() < deadline else { throw LiveFailure("the upload never reached 40 %") }
                try await Task.sleep(for: .milliseconds(100))
                uploadID = uploadID ?? store.load(record.id)?.files.first?.uploadID
                guard let uploadID else { continue }
                held = try await UploadWire.status(http, upload: uploadID).1?.files.first?.received_bytes ?? 0
            }
            let id = try #require(uploadID)
            let sentBefore = relay.counts.up
            try await interrupt(relay)
            // What the node kept: the gaps are what must still go.
            let kept = try #require(try await UploadWire.status(http, upload: id).1?.files.first, "the session is gone")
            let keptAt = relay.counts.up
            #expect(kept.received_bytes > 0, "the node kept nothing")

            let outcome = try await upload.value
            let total = relay.counts.up
            let gap = size - kept.received_bytes
            let afterKept = total - keptAt
            let afterInterrupt = total - sentBefore
            print(String(format: "[live] %@: file %.1f MB; sent %.1f MB in all (%.2f× the file) over %d connections; node "
                         + "kept %.1f MB; sent %.1f MB after the interruption, %.1f MB after the node's status, for a gap "
                         + "of %.1f MB", name, Double(size) / 1e6, Double(total) / 1e6, Double(total) / Double(size),
                         relay.counts.connections, Double(kept.received_bytes) / 1e6, Double(afterInterrupt) / 1e6,
                         Double(afterKept) / 1e6, Double(gap) / 1e6))
            #expect(outcome.failed.isEmpty, "failed: \(outcome.failed)")
            #expect(outcome.committed[path] != nil)
            // Only the gaps went again: what went after the interruption is the gap, plus at most the parts that were in
            // flight and might have been stored without their answer (resent with their digest), plus TLS/HTTP framing.
            let slack = Int64(Double(gap) * 0.01) + 2 * part + (1 << 20)
            #expect(afterKept <= gap + slack, "sent \(afterKept) after the node kept \(kept.received_bytes) (gap \(gap))")
            #expect(afterInterrupt >= gap, "the gaps must go")
            #expect(Double(total) <= Double(size) * 1.01 + Double(4 * part), "sent \(total) for a \(size)-byte file")
            #expect(relay.counts.connections > 1, "it reconnected")
            #expect(try await LiveNode.sha256(vault: device.vault, path: path) == digest)
        }
    }

    // MARK: - d. Resubmissions

    /// The same part twice (a lost answer) is 200 both times; different bytes for a stored range are 409 part_conflict
    /// and change nothing; a partial overlap is 409 part_overlap. Then the Swift uploader resumes a record that is
    /// behind the node (it never saw an answer) and commits the exact file.
    @Test func resubmittedPartsAreIdempotentAndConflictsAreRefused() async throws {
        try await LiveDevice.with { device in
            let http = try device.http()
            defer { http.invalidate() }
            let files = try LiveFiles()
            let size = 3 * mib + 100
            let (source, digest) = try files.random("dup.bin", size: size, seed: 0xD0B)
            let bytes = try Data(contentsOf: source)
            let path = "/live/dup-\(UUID().uuidString.prefix(8)).bin"

            let (created, session) = try await UploadWire.create(http, vault: device.vault, files: [
                ["file_id": "f0", "path": .string(path), "size": .integer(size), "duplicate_policy": "reject"],
            ])
            #expect(created == 201, "create: \(created) \(String(describing: session))")
            let upload = try #require(session?["upload_id"]?.stringValue)
            #expect(session?["part"]?["min_bytes"]?.integerValue == mib)

            let first = bytes[0..<Int(mib)]
            let (put, ack) = try await UploadWire.part(http, upload: upload, file: "f0", offset: 0, bytes: first)
            #expect(put == 200, "part 0: \(put) \(String(describing: ack))")
            let localHash = SHA256.hash(data: first).map { String(format: "%02x", $0) }.joined()
            #expect(ack?["sha256"]?.stringValue?.lowercased() == localHash)

            // A lost answer: the client sends exactly the same part again.
            let (again, againAck) = try await UploadWire.part(http, upload: upload, file: "f0", offset: 0, bytes: first)
            #expect(again == 200, "resubmission: \(again) \(String(describing: againAck))")
            #expect(againAck?["received_bytes"]?.integerValue == mib)
            #expect(againAck?["sha256"]?.stringValue?.lowercased() == localHash)

            // Different bytes for the stored range: refused, nothing changes.
            var other = Data(first)
            other[12345] ^= 0xFF
            let (conflict, conflictBody) = try await UploadWire.part(http, upload: upload, file: "f0", offset: 0, bytes: other)
            #expect(conflict == 409 && conflictBody?["error"]?["code"]?.stringValue == "part_conflict",
                    "different bytes: \(conflict) \(String(describing: conflictBody))")
            // A partial overlap, and a short part that isn't the last.
            let (overlap, overlapBody) = try await UploadWire.part(http, upload: upload, file: "f0", offset: mib / 2,
                                                                   bytes: bytes[Int(mib / 2)..<Int(mib / 2 + mib)])
            #expect(overlap == 409 && overlapBody?["error"]?["code"]?.stringValue == "part_overlap",
                    "overlap: \(overlap) \(String(describing: overlapBody))")
            let (short, shortBody) = try await UploadWire.part(http, upload: upload, file: "f0", offset: mib,
                                                               bytes: bytes[Int(mib)..<Int(mib + mib / 2)])
            #expect(short == 400, "short part: \(short) \(String(describing: shortBody))")
            let status = try await UploadWire.status(http, upload: upload).1
            #expect(status?.files.first?.ranges == [[0, mib]], "status: \(String(describing: status?.files.first?.ranges))")

            // The Swift uploader takes over a record that thinks nothing was stored (its answer was lost): it resumes
            // from the node's status and the file commits exactly.
            let lanes = try device.lanes(tuning: Self.fixedParts(mib))
            defer { lanes.invalidate() }
            var file = ResumableUploadRecord.File(source: source, relativePath: "dup.bin", path: path, size: size,
                                                  mimeType: nil, precondition: .reject)
            file.uploadID = upload
            file.fileID = "f0"
            file.identity = SourceIdentity.of(source)
            let record = ResumableUploadRecord(vaultID: device.vault, directory: "/live", files: [file])
            let outcome = try await lanes.resumableUploader.upload(record)
            #expect(outcome.failed.isEmpty && outcome.committed[path] != nil, "outcome: \(outcome.failed)")
            #expect(try await LiveNode.sha256(vault: device.vault, path: path) == digest)

            // After the commit the file takes no more parts.
            let (late, lateBody) = try await UploadWire.part(http, upload: upload, file: "f0", offset: 0, bytes: first)
            print("[live] a part after the commit: \(late) \(lateBody?["error"]?["code"]?.stringValue ?? "")")
            #expect(late == 409 || late == 404, "late part: \(late) \(String(describing: lateBody))")
        }
    }

    // MARK: - e. Conditional single-file sessions

    /// The File Provider's writes through `putContent`: files over the resumable threshold go as single-file sessions
    /// with `if_none_match: "*"` or `if_match`; a stale or violated precondition is a conflict and writes nothing.
    @Test func conditionalSingleFileSessions() async throws {
        try await LiveDevice.with { device in
            let files = try LiveFiles()
            let (a, _) = try files.random("a.bin", size: 12 * mib, seed: 0xA)
            let (b, digestB) = try files.random("b.bin", size: 12 * mib + 3, seed: 0xB)
            let (c, _) = try files.random("c.bin", size: 9 * mib, seed: 0xC)
            let relay = try LiveRelay(to: device.endpoint)
            defer { relay.stop() }
            let lanes = try device.lanes(relay.endpoint, tuning: Self.fixedParts(4 * mib))
            defer { lanes.invalidate() }
            let path = "/live/fp-\(UUID().uuidString.prefix(8)).bin"

            let created = try await lanes.putContent(vaultID: device.vault, path: path, from: a, precondition: .create)
            guard case .committed(true, let entry, let v1?) = created else {
                Issue.record("create: \(created)")
                return
            }
            #expect(entry?.sizeBytes == 12 * mib)
            // Sent in parts (three 4 MiB parts), not one body: the relay saw about the file once.
            #expect(relay.counts.up >= 12 * mib && relay.counts.up < 13 * mib, "sent \(relay.counts.up)")

            let exists = try await lanes.putContent(vaultID: device.vault, path: path, from: b, precondition: .create)
            #expect(exists == .conflict(currentVersion: v1), "create over an existing file: \(exists)")

            let replaced = try await lanes.putContent(vaultID: device.vault, path: path, from: b,
                                                      precondition: .replace(contentVersion: v1))
            guard case .committed(false, _, let v2?) = replaced else {
                Issue.record("replace: \(replaced)")
                return
            }
            #expect(v2 != v1)

            let stale = try await lanes.putContent(vaultID: device.vault, path: path, from: c,
                                                   precondition: .replace(contentVersion: v1))
            #expect(stale == .conflict(currentVersion: v2), "a stale if_match: \(stale)")

            #expect(try await LiveNode.sha256(vault: device.vault, path: path) == digestB, "the replace stands")
            let check = files.folder.appending(path: "check.bin")
            let downloaded = try await lanes.downloadContent(vaultID: device.vault, path: path, to: check)
            #expect(downloaded.etag == v2, "the download's validator is the replace's version")
            #expect(try LiveFiles.sha256(of: check) == digestB)
            print("[live] conditional writes: v1 \(v1.prefix(12)), v2 \(v2.prefix(12)); conflicts as expected")
        }
    }

    // MARK: - f. Calibration lanes

    /// `/transfer/probe`, `/sink`, `/source` directly, then `TransferCalibrator` through `testConnection()` and the
    /// Connection panel's test (`ConnectionTests.calibrating`), with sanity bounds on the numbers.
    @Test func calibrationLanesAndTestConnection() async throws {
        try await LiveDevice.with { device in
            let http = try device.http()
            defer { http.invalidate() }
            let (probeData, probe) = try await http.data(for: URLRequest(url: try http.url(path: "/transfer/probe")))
            let probeBody = try JSONDecoder().decode(JSONValue.self, from: probeData)
            #expect(probe.statusCode == 200)
            #expect(probeBody["node_id"]?.stringValue == device.serverNodeID)
            let capabilities = probeBody["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(capabilities.contains("http.upload.resumable") && capabilities.contains("device.lanes.transfer"),
                    "capabilities: \(capabilities)")
            #expect(probe.value(forHTTPHeaderField: "Cache-Control")?.contains("no-store") == true)

            var sink = URLRequest(url: try http.url(path: "/transfer/sink"))
            sink.httpMethod = "POST"
            sink.httpBody = Data(count: Int(mib))
            let (sinkData, sinkResponse) = try await http.data(for: sink)
            #expect(sinkResponse.statusCode == 200)
            #expect(try JSONDecoder().decode(JSONValue.self, from: sinkData)["bytes"]?.integerValue == mib)
            #expect(sinkResponse.value(forHTTPHeaderField: "Server-Timing")?.contains("recv;dur=") == true)

            let (sourceData, sourceResponse) = try await http.data(for: URLRequest(url: try http.url(
                path: "/transfer/source", query: [.init(name: "bytes", value: "1000")])))
            #expect(sourceResponse.statusCode == 200 && sourceData.count == 1000)
            let (_, tooMuch) = try await http.data(for: URLRequest(url: try http.url(
                path: "/transfer/source", query: [.init(name: "bytes", value: String(256 * mib + 1))])))
            #expect(tooMuch.statusCode == 400)

            let lanes = try device.lanes()
            defer { lanes.invalidate() }
            let result = try await lanes.testConnection()
            print(String(format: "[live] testConnection: RTT %.2f ms, up %.1f MB/s, down %.1f MB/s, parts %d MiB x %d, "
                         + "sent %.1f MiB, received %.1f MiB", (result.rtt ?? 0) * 1000,
                         result.uploadMegabytesPerSecond ?? 0, result.downloadMegabytesPerSecond ?? 0,
                         Int(result.suggestedPartBytes / mib), result.suggestedConcurrency,
                         Double(result.bytesSent) / Double(mib), Double(result.bytesReceived) / Double(mib)))
            let rtt = try #require(result.rtt)
            #expect(rtt > 0 && rtt < 0.2, "RTT \(rtt)")
            for rate in [result.uploadBytesPerSecond, result.downloadBytesPerSecond] {
                let rate = try #require(rate)
                // Between 1 MB/s and 10 GbE: a LAN, whatever its medium.
                #expect(rate > 1e6 && rate < 1.25e9, "rate \(rate)")
            }
            let budget = TransferCalibrator.Budget()
            #expect(result.bytesSent <= budget.maxBytes && result.bytesReceived <= budget.maxBytes)
            #expect((8 * mib...512 * mib).contains(result.suggestedPartBytes))
            #expect((1...4).contains(result.suggestedConcurrency))
            #expect(lanes.monitor?.snapshot.source == .calibrated)

            // The Connection panel's test on a live session: the selection, then the calibration over its route.
            let session = Self.session(device.node(), keys: device.keys)
            let events = Recorder(session.events)
            await session.start()
            defer { Task { await session.stop() } }
            try #require(await events.first(within: .seconds(20)) { $0.status == .online } != nil)
            let test = ConnectionTests.calibrating { session throws(TransferError) in
                guard let configuration = await session.laneConfiguration() else { throw .connection("no lanes") }
                var lanes: VaultLanes
                do { lanes = try VaultLanes(configuration: configuration) } catch { throw .connection("\(error)") }
                defer { lanes.invalidate() }
                lanes.features = .init(resumableUploads: true, transferLanes: true)
                return try await lanes.testConnection()
            }
            let panel = await test(session)
            print("[live] Test Connection: route \(panel.route.map { "\($0.endpoint) \($0.transportClass.rawValue)" } ?? "-"); "
                  + "\(panel.note ?? "")")
            #expect(panel.selection?.chosen != nil)
            #expect(panel.route?.transportClass == .lan)
            #expect(panel.uploadBytesPerSecond != nil && panel.downloadBytesPerSecond != nil)
            #expect(panel.note?.hasPrefix("Uploads would start with") == true, "note: \(panel.note ?? "nil")")
        }
    }
}

/// Polls an upload's session status (straight to the node) while it runs.
final class StatusWatcher: Sendable {
    private final class Samples: Sendable {
        let value = Mutex<[UploadWire.Status]>([])
    }

    private let samples = Samples()
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(http: DeviceHTTPClient, store: ResumableStore, record: UUID) {
        let samples = samples
        let poll = Task.detached {
            var uploadID: String?
            while !Task.isCancelled {
                uploadID = uploadID ?? store.load(record)?.files.first?.uploadID
                if let uploadID, let status = try? await UploadWire.status(http, upload: uploadID).1 {
                    samples.value.withLock { $0.append(status) }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        task.withLock { $0 = poll }
    }

    func stop() async -> [UploadWire.Status] {
        let running = task.withLock { $0 }
        running?.cancel()
        await running?.value
        return samples.value.withLock { $0 }
    }
}
