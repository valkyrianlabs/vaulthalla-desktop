import Foundation
import Synchronization
import Testing
import VHCore
@testable import VHTransport

/// Resumable uploads (the server's transfer-protocol.md §3) against ``FakeUploadServer`` on the loopback mutual-TLS
/// server: parts, retries, lost answers, re-syncs, integrity, resume after a suspension, finish polling, cancel, the
/// File Provider's conditional single-file session, and calibration (§4).
@Suite struct ResumableUploadTests {
    static let mib = 1 << 20

    struct Fixture {
        let server: HTTPTestServer
        let fake: FakeUploadServer
        let folder: URL

        func stop() {
            server.stop()
            try? FileManager.default.removeItem(at: folder)
        }

        /// A local file of `count` patterned bytes.
        func file(_ name: String, count: Int, seed: Int = 1) throws -> URL {
            let url = folder.appending(path: name)
            try Self.pattern(count, seed: seed).write(to: url)
            return url
        }

        static func pattern(_ count: Int, seed: Int) -> Data {
            Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ seed &* 7) % 251) })
        }

        func requests(_ method: String, prefix: String) -> [HTTPTestServer.Request] {
            server.requests.filter { $0.method == method && $0.path.hasPrefix(prefix) }
        }
    }

    static func start(options: HTTPTestServer.Options = HTTPTestServer.Options(),
                      configure: (inout FakeUploadServer.State) -> Void = { _ in }) async throws -> Fixture {
        let fake = FakeUploadServer()
        fake.state.withLock { state in configure(&state) }
        let server = try await HTTPTestServer.start(
            tls: try WsClientTLSTests.serverTLS(clientSPKI: Recorded()), options: options,
            router: { request in FakeUploadServer.serves(request) ? fake.route(request) : .buffer },
            handler: { request in
                FakeUploadServer.serves(request) ? fake.handle(request) : .init(status: 404)
            })
        let folder = FileManager.default.temporaryDirectory.appending(path: "vh-resumable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Fixture(server: server, fake: fake, folder: folder)
    }

    /// Fixed 1 MiB parts, two at a time: deterministic part boundaries.
    static var smallParts: TransferTuner.Configuration {
        var configuration = TransferTuner.Configuration()
        configuration.enabled = false
        configuration.fixedPartBytes = 1 << 20
        configuration.fixedConcurrency = 2
        return configuration
    }

    static func lanes(port: UInt16, tuning: TransferTuner.Configuration = smallParts, store: ResumableStore? = nil,
                      configure: (inout VaultLanes.Policy) -> Void = { _ in }) throws -> VaultLanes {
        let configuration = DeviceHTTPClient.Configuration(
            endpoint: NodeEndpoint(host: "127.0.0.1", port: port),
            identity: try WsClientTLSTests.identity(WsClientTLSTests.clientP12),
            serverSPKIPin: WsClientTLSTests.data(hex: WsClientTLSTests.serverSPKI), timeout: .seconds(5))
        var policy = VaultLanesTests.fastPolicy
        policy.resumable.backoff = .milliseconds(20)
        policy.resumable.persistInterval = .zero
        configure(&policy)
        var lanes = VaultLanes(transfers: try DeviceTransferClient(configuration: configuration), policy: policy)
        lanes.features = .init(resumableUploads: true, transferLanes: true)
        lanes.monitor = TransferMonitor(node: "node-a", configuration: tuning)
        lanes.store = store
        return lanes
    }

    // MARK: Parts

    @Test func uploadsFilesInPartsAndCommitsThem() async throws {
        let fixture = try await Self.start()
        defer { fixture.stop() }
        let lanes = try Self.lanes(port: fixture.server.port)
        defer { lanes.invalidate() }

        let big = try fixture.file("big.bin", count: 3 * Self.mib + Self.mib / 2)
        let small = try fixture.file("small.txt", count: 1000, seed: 2)
        let empty = try fixture.file("empty", count: 0)
        let seen = Mutex<[VaultLanes.UploadProgress]>([])
        let touched = try await lanes.upload([
            .init(source: big, relativePath: "media/big.bin", size: 3 * Int64(Self.mib) + Int64(Self.mib / 2)),
            .init(source: small, relativePath: "small.txt", size: 1000, mimeType: "text/plain"),
            .init(source: empty, relativePath: "empty", size: 0),
        ], vaultID: 4, into: "/Inbox") { progress in seen.withLock { $0.append(progress) } }

        #expect(touched == ["/Inbox", "/Inbox/media"])
        #expect(fixture.fake.data("/Inbox/media/big.bin") == (try Data(contentsOf: big)))
        #expect(fixture.fake.data("/Inbox/small.txt") == (try Data(contentsOf: small)))
        #expect(fixture.fake.data("/Inbox/empty") == Data())
        // 1 MiB parts; the last one is the rest; nothing went to the legacy lanes.
        let parts = fixture.fake.partRequests.filter { $0.file == "f0" }.map(\.length).sorted()
        #expect(parts == [Int64(Self.mib / 2), Int64(Self.mib), Int64(Self.mib), Int64(Self.mib)])
        #expect(fixture.server.requests.allSatisfy { !$0.path.hasPrefix("/upload/session/") && $0.path != "/upload/session" })
        #expect(fixture.fake.state.withLock { $0.peakInFlight } <= 2)
        let last = try #require(seen.withLock { $0.last })
        #expect(last.bytes == 3 * Int64(Self.mib) + Int64(Self.mib / 2) + 1000)
        #expect(last.files == 3)
        // The create named each file's precondition.
        let create = try #require(fixture.requests("POST", prefix: "/upload/sessions").first)
        let body = try #require(try JSONSerialization.jsonObject(with: create.body) as? [String: Any])
        let files = try #require(body["files"] as? [[String: Any]])
        #expect(files.map { $0["duplicate_policy"] as? String } == ["reject", "reject", "reject"])
        #expect(files.map { $0["path"] as? String } == ["/Inbox/media/big.bin", "/Inbox/small.txt", "/Inbox/empty"])
    }

    @Test func withoutTheCapabilityTheSessionFlowStaysAsItWas() async throws {
        let server = try await HTTPTestServer.start(tls: try WsClientTLSTests.serverTLS(clientSPKI: Recorded())) { request in
            switch (request.method, request.path) {
            case ("POST", "/upload/session"):
                return .init(status: 200, headers: ["Content-Type": "application/json"],
                             body: Data(#"{"upload_id":"legacy1"}"#.utf8))
            default:
                return .init(status: 200)
            }
        }
        defer { server.stop() }
        var lanes = try Self.lanes(port: server.port)
        lanes.features = .init()
        defer { lanes.invalidate() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "vh-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "a")
        try Data(repeating: 1, count: 5000).write(to: file)

        try await lanes.upload([.init(source: file, relativePath: "a", size: 5000)], vaultID: 1, into: "/") { _ in }
        #expect(server.requests.map(\.path) == ["/upload/session", "/upload/legacy1/files/f0", "/upload/legacy1/finish"])
    }

    @Test func busyPartsWaitForRetryAfterAndGoAgain() async throws {
        let fixture = try await Self.start { state in
            state.fault = { info in
                info.offset == Int64(1 << 20) && info.attempt == 0 ? .busy(status: 503, retryAfter: "0.2") : nil
            }
        }
        defer { fixture.stop() }
        let lanes = try Self.lanes(port: fixture.server.port)
        defer { lanes.invalidate() }
        let source = try fixture.file("a.bin", count: 2 * Self.mib + 10)

        let started = ContinuousClock.now
        try await lanes.upload([.init(source: source, relativePath: "a.bin", size: Int64(2 * Self.mib + 10))],
                               vaultID: 1, into: "/") { _ in }
        #expect(ContinuousClock.now - started >= .milliseconds(200))
        #expect(fixture.fake.data("/a.bin") == (try Data(contentsOf: source)))
        let atOffset = fixture.fake.partRequests.filter { $0.offset == Int64(Self.mib) }.map(\.status)
        #expect(atOffset == [503, 200])
        // A busy server halved the concurrency.
        #expect(lanes.monitor?.tuner.concurrency == 2)  // fixed when tuning is off
    }

    /// The node stored the part but the answer never arrived: the same range goes again and is acknowledged (200 for
    /// identical bytes), nothing is duplicated.
    @Test func aLostAnswerResendsTheSameRange() async throws {
        let fixture = try await Self.start { state in
            state.fault = { info in info.offset == 0 && info.attempt == 0 ? .loseAnswer : nil }
        }
        defer { fixture.stop() }
        // One part at a time, so the resend comes before the file is complete (after that it would be file_state).
        var oneAtATime = Self.smallParts
        oneAtATime.fixedConcurrency = 1
        let lanes = try Self.lanes(port: fixture.server.port, tuning: oneAtATime)
        defer { lanes.invalidate() }
        let source = try fixture.file("a.bin", count: 2 * Self.mib)

        try await lanes.upload([.init(source: source, relativePath: "a.bin", size: Int64(2 * Self.mib))],
                               vaultID: 1, into: "/") { _ in }
        #expect(fixture.fake.data("/a.bin") == (try Data(contentsOf: source)))
        let first = fixture.fake.partRequests.filter { $0.offset == 0 }
        #expect(first.count == 2 && first.allSatisfy { $0.length == Int64(Self.mib) && $0.status == 200 })
        // The resend carried the digest of the bytes sent the first time.
        let resent = fixture.requests("PUT", prefix: "/upload/sessions/").filter { $0.query["offset"] == "0" }
        #expect(resent.count == 2)
        #expect(resent.last?.header("Content-Digest")?.hasPrefix("sha-256=:") == true)
    }

    @Test func aDroppedConnectionMidBodySendsThePartAgain() async throws {
        let fixture = try await Self.start { state in
            state.fault = { info in info.offset == 0 && info.attempt == 0 ? .dropAfter(300_000) : nil }
        }
        defer { fixture.stop() }
        let lanes = try Self.lanes(port: fixture.server.port)
        defer { lanes.invalidate() }
        let source = try fixture.file("a.bin", count: 3 * Self.mib)

        try await lanes.upload([.init(source: source, relativePath: "a.bin", size: Int64(3 * Self.mib))],
                               vaultID: 1, into: "/") { _ in }
        #expect(fixture.fake.data("/a.bin") == (try Data(contentsOf: source)))
        #expect(fixture.fake.partRequests.filter { $0.offset == 0 }.map(\.status) == [200])
    }

    @Test func anOverlapResyncsFromTheStatus() async throws {
        let fixture = try await Self.start { state in
            state.fault = { info in info.offset == Int64(1 << 20) && info.attempt == 0 ? .refuse(status: 409, code: "part_overlap") : nil }
        }
        defer { fixture.stop() }
        let lanes = try Self.lanes(port: fixture.server.port)
        defer { lanes.invalidate() }
        let source = try fixture.file("a.bin", count: 2 * Self.mib + 1)

        try await lanes.upload([.init(source: source, relativePath: "a.bin", size: Int64(2 * Self.mib + 1))],
                               vaultID: 1, into: "/") { _ in }
        #expect(fixture.fake.data("/a.bin") == (try Data(contentsOf: source)))
        #expect(fixture.requests("GET", prefix: "/upload/sessions/").count >= 1)
    }

    /// The node's hash of a part differs from the bytes sent: the file isn't kept from that session (it is deleted)
    /// and starts over in a new one.
    @Test func aDigestMismatchStartsTheFileOverInANewSession() async throws {
        let fixture = try await Self.start { state in
            state.fault = { info in info.uploadID == "up1" && info.offset == 0 ? .wrongDigest : nil }
        }
        defer { fixture.stop() }
        let lanes = try Self.lanes(port: fixture.server.port)
        defer { lanes.invalidate() }
        let source = try fixture.file("a.bin", count: 2 * Self.mib + 5)

        try await lanes.upload([.init(source: source, relativePath: "a.bin", size: Int64(2 * Self.mib + 5))],
                               vaultID: 1, into: "/") { _ in }
        #expect(fixture.fake.data("/a.bin") == (try Data(contentsOf: source)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.fake.state.withLock { $0.deleted } == ["up1"])
        #expect(fixture.fake.state.withLock { $0.sessions["up2"]?.files.first?.state } == "committed")
    }

    @Test func aDigestMismatchWithoutRestartsIsAnIntegrityError() async throws {
        let fixture = try await Self.start { state in
            state.fault = { info in info.fileID == "f0" && info.offset == 0 ? .wrongDigest : nil }
        }
        defer { fixture.stop() }
        let lanes = try Self.lanes(port: fixture.server.port) { $0.resumable.fileRestarts = 0 }
        defer { lanes.invalidate() }
        let source = try fixture.file("a.bin", count: 2 * Self.mib)
        let other = try fixture.file("b.bin", count: 10)

        await #expect(throws: TransferError.integrity("a.bin")) {
            try await lanes.upload([.init(source: source, relativePath: "a.bin", size: Int64(2 * Self.mib)),
                                    .init(source: other, relativePath: "b.bin", size: 10)],
                                   vaultID: 1, into: "/") { _ in }
        }
        // The other file still committed.
        #expect(fixture.fake.data("/b.bin") == (try Data(contentsOf: other)))
        #expect(TransferError.integrity("a.bin").message.contains("a.bin"))
    }

    @Test func finishWaitsWhileTheNodeCommits() async throws {
        let fixture = try await Self.start { state in state.finishPending = 3 }
        defer { fixture.stop() }
        let lanes = try Self.lanes(port: fixture.server.port)
        defer { lanes.invalidate() }
        let source = try fixture.file("a.bin", count: 1234)

        try await lanes.upload([.init(source: source, relativePath: "a.bin", size: 1234)], vaultID: 1, into: "/") { _ in }
        #expect(fixture.fake.state.withLock { $0.finishes } >= 4)
        #expect(fixture.fake.data("/a.bin") == (try Data(contentsOf: source)))
    }

    @Test func aFileTheNodeFailsIsReportedAndTheOthersStand() async throws {
        let fixture = try await Self.start { state in
            state.commit = { request in
                request.path == "/taken.txt" ? .failed(code: "already_exists", message: "exists", etag: nil) : .committed(nil)
            }
        }
        defer { fixture.stop() }
        let lanes = try Self.lanes(port: fixture.server.port)
        defer { lanes.invalidate() }
        let a = try fixture.file("taken.txt", count: 100)
        let b = try fixture.file("fresh.txt", count: 200)

        let outcome = try await lanes.resumableUploader.upload(ResumableUploader.plan([
            .init(source: a, relativePath: "taken.txt", size: 100), .init(source: b, relativePath: "fresh.txt", size: 200),
        ], vaultID: 1, into: "/"))
        #expect(outcome.failed.map(\.path) == ["/taken.txt"])
        #expect(outcome.failed.first?.error == .alreadyExists)
        #expect(outcome.committed.keys.sorted() == ["/fresh.txt"])
    }

    // MARK: Resume, cancel

    /// The app quits mid-upload (suspended): the session and the record stay; the next run asks the node what it holds
    /// and sends only the gaps.
    @Test func resumesAfterASuspensionSendingOnlyTheGaps() async throws {
        var options = HTTPTestServer.Options()
        options.bandwidth = 8_000_000
        let fixture = try await Self.start(options: options)
        defer { fixture.stop() }
        let store = ResumableStore(directory: fixture.folder.appending(path: "store"))
        let size = 12 * Self.mib
        let source = try fixture.file("movie.mov", count: size)
        let record = ResumableUploader.plan([.init(source: source, relativePath: "movie.mov", size: Int64(size))],
                                            vaultID: 2, into: "/Films")

        let first = try Self.lanes(port: fixture.server.port, store: store)
        let control = UploadControl()
        let task = Task { try await first.uploadResumable(record, control: control) { _ in } }
        // Wait until a few parts are durable, then quit.
        while (fixture.fake.state.withLock { $0.sessions["up1"]?.files.first?.stored.byteCount ?? 0 }) < Int64(3 * Self.mib) {
            try await Task.sleep(for: .milliseconds(20))
        }
        control.suspend()
        task.cancel()
        await #expect(throws: TransferError.cancelled) { try await task.value }
        first.invalidate()

        let saved = try #require(store.all().first)
        #expect(saved.id == record.id)
        #expect(saved.files[0].uploadID == "up1")
        #expect(saved.files[0].stored.byteCount >= Int64(3 * Self.mib))
        #expect(fixture.fake.state.withLock { $0.deleted }.isEmpty)
        let held = fixture.fake.state.withLock { $0.sessions["up1"]!.files[0].stored }
        let sentBefore = fixture.fake.partRequests.count

        let second = try Self.lanes(port: fixture.server.port, store: store)
        defer { second.invalidate() }
        try await second.uploadResumable(saved) { _ in }
        #expect(fixture.fake.data("/Films/movie.mov") == (try Data(contentsOf: source)))
        let resent = fixture.fake.partRequests.dropFirst(sentBefore).filter { $0.status == 200 }
        #expect(resent.allSatisfy { !held.overlaps($0.offset..<($0.offset + $0.length)) })
        #expect(fixture.fake.state.withLock { $0.sessions.count } == 1)
        #expect(store.all().isEmpty)
    }

    /// The file changed while the upload was suspended: it starts over in a new session with what is there now.
    @Test func aChangedSourceStartsOverOnResume() async throws {
        var options = HTTPTestServer.Options()
        options.bandwidth = 8_000_000
        let fixture = try await Self.start(options: options)
        defer { fixture.stop() }
        let store = ResumableStore(directory: fixture.folder.appending(path: "store"))
        let source = try fixture.file("doc.bin", count: 8 * Self.mib)
        let record = ResumableUploader.plan([.init(source: source, relativePath: "doc.bin", size: Int64(8 * Self.mib))],
                                            vaultID: 2, into: "/")
        let first = try Self.lanes(port: fixture.server.port, store: store)
        let control = UploadControl()
        let task = Task { try await first.uploadResumable(record, control: control) { _ in } }
        while (fixture.fake.state.withLock { $0.sessions["up1"]?.files.first?.stored.byteCount ?? 0 }) < Int64(Self.mib) {
            try await Task.sleep(for: .milliseconds(20))
        }
        control.suspend()
        task.cancel()
        _ = try? await task.value
        first.invalidate()

        // Edited: other bytes, another size.
        let edited = Fixture.pattern(5 * Self.mib + 3, seed: 9)
        try await Task.sleep(for: .milliseconds(20))
        try edited.write(to: source)

        let saved = try #require(store.load(record.id))
        let second = try Self.lanes(port: fixture.server.port, store: store)
        defer { second.invalidate() }
        try await second.uploadResumable(saved) { _ in }
        #expect(fixture.fake.data("/doc.bin") == edited)
        #expect(fixture.fake.state.withLock { $0.sessions["up2"]?.files.first?.size } == Int64(edited.count))
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.fake.state.withLock { $0.deleted }.contains("up1"))
    }

    @Test func cancellingDeletesTheSessionAndTheRecord() async throws {
        var options = HTTPTestServer.Options()
        options.bandwidth = 4_000_000
        let fixture = try await Self.start(options: options)
        defer { fixture.stop() }
        let store = ResumableStore(directory: fixture.folder.appending(path: "store"))
        let source = try fixture.file("a.bin", count: 8 * Self.mib)
        let lanes = try Self.lanes(port: fixture.server.port, store: store)
        defer { lanes.invalidate() }
        let task = Task {
            try await lanes.upload([.init(source: source, relativePath: "a.bin", size: Int64(8 * Self.mib))],
                                   vaultID: 1, into: "/") { _ in }
        }
        while (fixture.fake.state.withLock { $0.sessions["up1"]?.files.first?.stored.byteCount ?? 0 }) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        await #expect(throws: TransferError.cancelled) { try await task.value }
        let deadline = ContinuousClock.now + .seconds(3)
        while fixture.fake.state.withLock({ $0.deleted }).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.fake.state.withLock { $0.deleted } == ["up1"])
        #expect(store.all().isEmpty)
    }

    /// The node is unreachable past every retry: the session and record stay for a retry, which resumes.
    @Test func anUnreachableNodeKeepsTheUploadForARetry() async throws {
        let fixture = try await Self.start { state in
            state.fault = { info in info.uploadID == "up1" && info.offset >= Int64(1 << 20) ? .dropAfter(1) : nil }
        }
        defer { fixture.stop() }
        let store = ResumableStore(directory: fixture.folder.appending(path: "store"))
        let source = try fixture.file("a.bin", count: 3 * Self.mib)
        let lanes = try Self.lanes(port: fixture.server.port, store: store) { policy in
            policy.resumable.partRetries = 1
            policy.resumable.sessionRetries = 1
        }
        defer { lanes.invalidate() }
        let record = ResumableUploader.plan([.init(source: source, relativePath: "a.bin", size: Int64(3 * Self.mib))],
                                            vaultID: 1, into: "/")
        await #expect(throws: TransferError.self) { try await lanes.uploadResumable(record) { _ in } }
        let saved = try #require(store.load(record.id))
        #expect(saved.files[0].uploadID == "up1")
        #expect(fixture.fake.state.withLock { $0.deleted }.isEmpty)

        fixture.fake.state.withLock { $0.fault = nil }
        try await lanes.uploadResumable(saved) { _ in }
        #expect(fixture.fake.data("/a.bin") == (try Data(contentsOf: source)))
        #expect(fixture.fake.partRequests.filter { $0.offset == 0 && $0.status == 200 }.count == 1)
    }

    // MARK: File Provider writes

    @Test func aConditionalWriteGoesAsASingleFileSession() async throws {
        let fixture = try await Self.start { state in
            state.commit = { request in
                if request.ifMatch == "\"g7-1\"" {
                    return .committed(Data(#"{"entry":{"id":7,"name":"a.bin","path":"/a.bin","abs_path":"/v/a.bin","size_bytes":5,"is_hidden":false,"is_system":false,"created_at":"2026-10-31T00:00:00Z","updated_at":"2026-10-31T00:00:00Z","metadata_version":"m7-2","content_version":"\"g7-2\""}}"#.utf8))
                }
                return .failed(code: "precondition_failed", message: "changed", etag: "\"g7-9\"")
            }
        }
        defer { fixture.stop() }
        let lanes = try Self.lanes(port: fixture.server.port) { $0.resumableThreshold = 0 }
        defer { lanes.invalidate() }
        let source = try fixture.file("a.bin", count: Self.mib + 77)

        let written = try await lanes.putContent(vaultID: 3, path: "/a.bin", from: source,
                                                 precondition: .replace(contentVersion: "\"g7-1\""))
        guard case .committed(let created, let entry, let etag) = written else {
            Issue.record("expected a commit, got \(written)")
            return
        }
        #expect(!created)
        #expect(entry?.id == 7)
        #expect(etag == "\"g7-2\"")
        let create = try #require(fixture.requests("POST", prefix: "/upload/sessions").first)
        let files = try #require((try JSONSerialization.jsonObject(with: create.body) as? [String: Any])?["files"] as? [[String: Any]])
        #expect(files.first?["if_match"] as? String == "\"g7-1\"")
        #expect(files.first?["duplicate_policy"] == nil)

        // A stale base: the commit's precondition fails, which is a conflict, as on PUT /upload/content.
        let stale = try await lanes.putContent(vaultID: 3, path: "/a.bin", from: source,
                                               precondition: .replace(contentVersion: "\"g7-0\""))
        #expect(stale == .conflict(currentVersion: "\"g7-9\""))
    }

    @Test func createOnlyRefusedAtCreateIsAConflict() async throws {
        let fixture = try await Self.start { state in
            state.createCheck = { files in files.first?.ifNoneMatch == "*" ? (412, "precondition_failed", "\"g1-3\"") : nil }
        }
        defer { fixture.stop() }
        let lanes = try Self.lanes(port: fixture.server.port) { $0.resumableThreshold = 0 }
        defer { lanes.invalidate() }
        let source = try fixture.file("n.bin", count: 2048)
        let written = try await lanes.putContent(vaultID: 3, path: "/n.bin", from: source, precondition: .create)
        #expect(written == .conflict(currentVersion: "\"g1-3\""))
    }

    @Test func smallConditionalWritesStayOnePut() async throws {
        let fixture = try await Self.start()
        defer { fixture.stop() }
        let lanes = try Self.lanes(port: fixture.server.port)
        defer { lanes.invalidate() }
        let source = try fixture.file("tiny", count: 10)
        _ = try? await lanes.putContent(vaultID: 3, path: "/tiny", from: source, precondition: .create)
        #expect(fixture.server.requests.map(\.path) == ["/upload/content"])
    }

    // MARK: Calibration

    @Test func testConnectionMeasuresWithinItsBudget() async throws {
        let fixture = try await Self.start()
        defer { fixture.stop() }
        var lanes = try Self.lanes(port: fixture.server.port, tuning: TransferTuner.Configuration())
        defer { lanes.invalidate() }
        let result = try await lanes.testConnection()
        #expect(result.rtt != nil)
        #expect((result.uploadBytesPerSecond ?? 0) > 0)
        #expect((result.downloadBytesPerSecond ?? 0) > 0)
        #expect(result.bytesSent <= 16 << 20 && result.bytesReceived <= 16 << 20)
        #expect(result.suggestedConcurrency >= 1 && result.suggestedPartBytes >= 8 << 20)
        let calibration = fixture.fake.state.withLock { $0.calibration }
        #expect(calibration.probes == 3)
        #expect(calibration.sunk == result.bytesSent)
        #expect(lanes.monitor?.snapshot.source == .calibrated)
        // Nothing was written: no session was opened.
        #expect(fixture.fake.state.withLock { $0.sessions.isEmpty })

        lanes.features.transferLanes = false
        await #expect(throws: TransferError.laneUnavailable(.transfer)) { try await lanes.testConnection() }
    }

    @Test func calibrationRunsOnlyForLargeUploadsWithoutAnEstimate() async throws {
        let fixture = try await Self.start()
        defer { fixture.stop() }
        let lanes = try Self.lanes(port: fixture.server.port, tuning: TransferTuner.Configuration())
        defer { lanes.invalidate() }
        #expect(await lanes.calibrateIfNeeded(totalBytes: 10 << 20) == false)
        #expect(await lanes.calibrateIfNeeded(totalBytes: 1 << 30) == true)
        // Fresh now: never again until the estimate expires or the route changes.
        #expect(await lanes.calibrateIfNeeded(totalBytes: 1 << 30) == false)
        #expect(fixture.fake.state.withLock { $0.calibration.probes } == 3)
    }

    // MARK: Pieces

    @Test func errorCodesMapWithoutReadingWords() {
        func body(_ code: String) -> Data { Data(#"{"error":{"code":"\#(code)","message":"already exists"}}"#.utf8) }
        #expect(TransferError.coded(status: 409, body: body("part_overlap")) == .status(409, "already exists"))
        #expect(TransferError.coded(status: 412, body: body("precondition_failed"), etag: "\"e\"")
                == .preconditionFailed(currentVersion: "\"e\""))
        #expect(TransferError.coded(status: 413, body: body("file_too_large")) == .fileTooLarge)
        #expect(TransferError.coded(status: 507, body: body("insufficient_storage")) == .quotaExceeded)
        #expect(TransferError.coded(status: 429, body: body("too_many_parts_in_flight")) == .busy)
        #expect(TransferError.coded(status: 404, body: body("not_found")) == .uploadExpired)
        #expect(TransferError.coded(status: 403, body: Data()) == .forbidden)
        #expect(TransferError.coded(status: nil, code: "key_rotated", message: nil) == .keyRotated)
        #expect(TransferError.coded(status: nil, code: "quota_exceeded", message: nil) == .quotaExceeded)
        #expect(TransferError.keyRotated.message.contains("key changed"))
    }

    @Test func byteRangesCoalesceAndFindGaps() {
        var ranges = ByteRanges(wire: [[10, 20], [0, 5], [5, 8], [30, 40]])
        #expect(ranges.wire == [[0, 8], [10, 20], [30, 40]])
        #expect(ranges.gaps(upTo: 50) == [8..<10, 20..<30, 40..<50])
        ranges.insert(8..<30)
        #expect(ranges.wire == [[0, 40]])
        #expect(ranges.byteCount == 40)
        #expect(ranges.contains(3..<39) && !ranges.contains(39..<41))
        #expect(ByteRanges(wire: [[5, 5], [9, 3], [1]]).isEmpty)
    }

    /// Parts never leave a sliver below the node's minimum in front of a stored range.
    @Test func partsAreCarvedWithinTheNodesLimits() {
        let mib = Int64(Self.mib)
        let limits = TransferTuner.Limits(minBytes: mib, maxBytes: 8 * mib, defaultBytes: 4 * mib, maxInFlight: 4)
        let file = FileRun(index: 0, fileID: "f0", name: "a", source: URL(filePath: "/dev/null"), size: 20 * mib,
                           identity: nil, stored: ByteRanges([(4 * mib + mib / 2)..<(10 * mib)]))
        let run = SessionRun(uploadID: "u", limits: limits, files: [file])
        // The gap before the stored range is 4.5 MiB: a 4 MiB part would leave 0.5 MiB, so it takes all of it.
        #expect(run.carve(file, partBytes: 4 * mib) == 0..<(4 * mib + mib / 2))
        var second = file
        second.inFlight = [0..<(4 * mib + mib / 2)]
        #expect(run.carve(second, partBytes: 4 * mib) == (10 * mib)..<(14 * mib))
        // The file's last part may be short.
        var third = second
        third.inFlight.append((10 * mib)..<(19 * mib + 1))
        #expect(run.carve(third, partBytes: 64 * mib) == (19 * mib + 1)..<(20 * mib))
        // Larger than the node's maximum: clamped.
        #expect(run.carve(second, partBytes: 64 * mib)?.count == Int(8 * mib))
        // A stranded sliver can't be sent: empty.
        let stranded = FileRun(index: 0, fileID: "f0", name: "a", source: URL(filePath: "/dev/null"), size: 20 * mib,
                               identity: nil, stored: ByteRanges([0..<(4 * mib), (4 * mib + 10)..<(20 * mib)]))
        #expect(run.carve(stranded, partBytes: 4 * mib)?.isEmpty == true)
    }

    @Test func retryAfterAndDigestHeaders() {
        #expect(ResumableUploader.retryAfter("2") == .seconds(2))
        #expect(ResumableUploader.retryAfter("0.05") == .milliseconds(50))
        #expect(ResumableUploader.retryAfter("Wed, 21 Oct 2026 07:28:00 GMT") == .seconds(1))
        #expect(ResumableUploader.retryAfter(nil) == nil)
        let hex = String(repeating: "00", count: 32)
        #expect(ResumableUploader.contentDigest(hex: hex) == "sha-256=:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=:")
        #expect(ResumableUploader.isToken("up_1-A") && !ResumableUploader.isToken("../x") && !ResumableUploader.isToken(""))
    }
}
