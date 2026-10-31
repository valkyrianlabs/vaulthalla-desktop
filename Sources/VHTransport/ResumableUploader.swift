public import Foundation
public import VHContract
import Synchronization
import os

/// Lets the owner of an upload stop it in one of two ways before cancelling its task: a plain cancel discards the
/// node's session and the persisted state; ``suspend()`` first (an app quitting) keeps both, so the upload resumes
/// on the next launch.
public final class UploadControl: Sendable {
    private let suspended = Mutex(false)

    public init() {}

    public func suspend() {
        suspended.withLock { $0 = true }
    }

    public var isSuspended: Bool { suspended.withLock { $0 } }
}

/// Lanes on a new route after a connection-class failure (the server's transfer-protocol.md §2: "requests in flight
/// are retried on the new endpoint"): the owner asks its session to select again and answers the transfer client for
/// the endpoint the lanes moved to, or nil when they stayed where they were.
public typealias LaneReroute = @Sendable () async -> DeviceTransferClient?

/// Resumable uploads in parts over the device listener (the server's docs/reference/transfer-protocol.md §3,
/// capability `http.upload.resumable`; docs/architecture.md §3 "Resumable uploads and tuning").
///
/// - A session is created for up to ``Policy/sessionMaxFiles`` files (`POST /upload/sessions`). Each file is sent as
///   byte ranges (`PUT /upload/sessions/<id>/files/<f>?offset=n`), streamed from disk with bounded memory and hashed on
///   the way; the hash must equal the answer's `sha256` (else ``TransferError/integrity(_:)`` for that file). Parts run
///   in parallel within the ``TransferMonitor``'s tuner and the server's `part.max_in_flight`, and a part that fails
///   is retried with backoff (honouring `Retry-After` on 429/503) as exactly the same range, so a lost answer is
///   harmless (the node answers 200 for identical bytes). A 409 `part_overlap`/`file_state` re-syncs from the
///   session's status; `part_conflict` means the local file isn't what was sent before (it starts over).
/// - After a dropped connection the session's status (`GET`) says what the node holds durably, and only the gaps go.
///   Progress is persisted in a ``ResumableStore``, so an upload survives an app restart: the source must be
///   unchanged (path, size, mtime, inode), else that file starts over in a new session.
/// - With a ``reroute`` hook, a dropped connection asks for another route at once instead of backing off: once the
///   lanes moved to a new endpoint, the same session resumes there from its status (session ids are the node's, not
///   the endpoint's). Without another route the usual retries and backoff apply.
/// - `POST …/finish` is polled while it answers 202. Files commit on their own; a file that failed (a precondition, a
///   rotated key) is reported per file and the others stand. Cancelling deletes the session (`DELETE`), unless the
///   ``UploadControl`` was suspended first.
public struct ResumableUploader: Sendable {
    public struct Policy: Sendable {
        /// Attempts after the first for one part (dropped connections, timeouts, busy answers).
        public var partRetries = 5
        /// Session-level attempts after a part ran out of retries (each resumes from the node's status); progress
        /// in between resets the count.
        public var sessionRetries = 5
        /// The first retry's delay; each later one doubles it, up to ``maxBackoff``.
        public var backoff: Duration = .milliseconds(800)
        public var maxBackoff: Duration = .seconds(30)
        /// How long finishing may wait for the node to commit.
        public var finishTimeout: Duration = .seconds(600)
        /// Files per session (the node allows up to `transfer.max_session_files`, 4096 by default).
        public var sessionMaxFiles = 500
        /// How often one file may start over (its source changed, the vault key rotated, the session expired).
        public var fileRestarts = 2
        /// Persist progress at most this often (and on every state change).
        public var persistInterval: Duration = .seconds(1)
        /// Moves to a new endpoint (``ResumableUploader/reroute``) one upload may make.
        public var reroutes = 3

        public init() {}
    }

    /// What became of an upload's files.
    public struct Outcome: Sendable {
        /// Vault path → the committed file's entry, when the node said.
        public var committed: [String: WsModel.FsEntryBase?]
        /// Files that failed, with why, in the upload's order.
        public var failed: [(path: String, error: TransferError)]
        /// The vault folders that may have changed.
        public var folders: Set<String>
    }

    /// The lanes' transfer client; replaced when ``reroute`` moved the upload to another endpoint.
    public private(set) var transfers: DeviceTransferClient
    public let monitor: TransferMonitor
    public let store: ResumableStore?
    public var policy: Policy
    /// Asked after a connection-class failure for lanes on a new route; nil: retry on the same endpoint.
    public var reroute: LaneReroute?
    private let log = Logger(subsystem: "sh.vaulthalla.app", category: "resumable-upload")

    public init(transfers: DeviceTransferClient, monitor: TransferMonitor, store: ResumableStore? = nil,
                policy: Policy = Policy()) {
        self.transfers = transfers
        self.monitor = monitor
        self.store = store
        self.policy = policy
    }

    // MARK: - Planning

    /// A new upload of `files` into `directory`, each refusing an existing target (the session flow's rule).
    public static func plan(_ files: [VaultLanes.UploadFile], vaultID: Int64, into directory: String,
                            id: UUID = UUID()) -> ResumableUploadRecord {
        let target = VaultPathString.normalize(directory)
        return ResumableUploadRecord(id: id, vaultID: vaultID, directory: target, files: files.map {
            .init(source: $0.source, relativePath: $0.relativePath, path: VaultPathString.join(target, $0.relativePath),
                  size: $0.size, mimeType: $0.mimeType, precondition: .reject)
        })
    }

    // MARK: - Running

    /// Runs (or resumes) `record` until every file committed or failed. Throws when the upload as a whole can't go
    /// on (refused, out of room, unreachable after every retry, cancelled); per-file failures are in the outcome.
    public func upload(_ record: ResumableUploadRecord, control: UploadControl? = nil,
                       progress: @escaping @Sendable (VaultLanes.UploadProgress) -> Void = { _ in })
        async throws(TransferError) -> Outcome
    {
        var running = self
        return try await running.run(record, control: control, progress: progress)
    }

    private mutating func run(_ record: ResumableUploadRecord, control: UploadControl?,
                              progress: @escaping @Sendable (VaultLanes.UploadProgress) -> Void)
        async throws(TransferError) -> Outcome
    {
        var job = Job(record: record, store: store, persistInterval: policy.persistInterval)
        job.escalatesDrops = reroute != nil
        var reroutes = 0
        job.persist(force: true)
        monitor.seedFromCache()
        monitor.beginTransfer()
        let tally = Tally(record: job.record)
        progress(tally.report())
        var failures = 0
        do throws(TransferError) {
            while true {
                if Task.isCancelled { throw .cancelled }
                let open = job.record.files.indices.filter { job.record.files[$0].state == .pending }
                if open.isEmpty { break }
                let resuming = open.first { job.record.files[$0].uploadID != nil }
                let batch: [Int]
                if let resuming, let uploadID = job.record.files[resuming].uploadID {
                    batch = open.filter { job.record.files[$0].uploadID == uploadID }
                } else {
                    batch = Array(open.filter { job.record.files[$0].uploadID == nil }.prefix(max(1, policy.sessionMaxFiles)))
                }
                let before = job.record.storedBytes
                do throws(TransferError) {
                    try await runSession(batch, job: &job, tally: tally, progress: progress)
                    failures = 0
                } catch {
                    if Task.isCancelled { throw .cancelled }
                    // Not this task's cancellation: the lanes' session was invalidated under the upload (its route
                    // was replaced). The node still holds what it acknowledged.
                    let error = error == .cancelled ? TransferError.connection("the connection was closed") : error
                    if error == .uploadExpired {
                        // The node forgot the session: its files start over in a new one.
                        for index in batch where job.record.files[index].state == .pending {
                            job.record.files[index].uploadID = nil
                            job.record.files[index].fileID = nil
                            job.record.files[index].stored = ByteRanges()
                        }
                        job.persist(force: true)
                        tally.reset(job.record)
                    }
                    if Self.reroutable(error), reroutes < policy.reroutes, let reroute {
                        if let moved = await reroute() {
                            // Another endpoint: the same session resumes there from its status, at once.
                            reroutes += 1
                            transfers = moved
                            job.escalatesDrops = true
                            log.notice("upload \(record.id, privacy: .public) resumes on a new route")
                            continue
                        }
                        // No other route: drops take the usual part retries from here on.
                        job.escalatesDrops = false
                    }
                    guard Self.resumable(error) else { throw error }
                    if job.record.storedBytes > before { failures = 0 }
                    failures += 1
                    guard failures <= policy.sessionRetries else { throw error }
                    log.notice("upload \(record.id, privacy: .public) resumes after: \(error.message, privacy: .private)")
                    try await sleep(backoff(failures - 1))
                }
            }
        } catch {
            if error == .cancelled || Task.isCancelled {
                if control?.isSuspended == true {
                    job.persist(force: true)
                } else {
                    discard(job.record)
                }
                throw .cancelled
            }
            if Self.resumable(error) {
                // Unreachable for now: keep the session and the record, so a retry (or the next launch) resumes.
                job.persist(force: true)
            } else {
                discard(job.record)
            }
            throw error
        }
        store?.remove(job.record.id)
        monitor.saveEstimate()
        var outcome = Outcome(committed: [:], failed: [], folders: job.record.folders)
        for file in job.record.files {
            switch file.state {
            case .committed: outcome.committed[file.path] = job.entries[file.path] ?? nil
            case .failed: outcome.failed.append((file.path, job.errors[file.path] ?? .status(500, file.failure ?? "")))
            case .pending: break
            }
        }
        return outcome
    }

    /// A failure that may mean the route is gone (worth asking ``reroute``).
    static func reroutable(_ error: TransferError) -> Bool {
        switch error {
        case .connection, .timeout: true
        default: false
        }
    }

    /// A session-level failure worth resuming from the node's status.
    static func resumable(_ error: TransferError) -> Bool {
        switch error {
        case .connection, .timeout, .busy, .uploadExpired: true
        case .status(let code, _): code >= 500 || code == 408
        default: false
        }
    }

    /// Gives an upload up: deletes the sessions it holds on the node (outside the caller's task, so a cancellation
    /// still reaches the node) and its persisted record. Committed files stay.
    public func discard(_ record: ResumableUploadRecord) {
        let ids = Set(record.files.compactMap { $0.state == .pending ? $0.uploadID : nil })
        for id in ids { discardSession(id) }
        store?.remove(record.id)
    }

    func discardSession(_ uploadID: String) {
        guard let url = try? url("/upload/sessions/\(uploadID)") else { return }
        let http = transfers.http
        Task.detached {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            _ = try? await http.data(for: request)
        }
    }

    // MARK: - One session

    private func runSession(_ batch: [Int], job: inout Job, tally: Tally,
                            progress: @escaping @Sendable (VaultLanes.UploadProgress) -> Void)
        async throws(TransferError)
    {
        var run: SessionRun
        if let uploadID = job.record.files[batch[0]].uploadID {
            // Resume: the node's status is the truth about what it holds.
            let (status, http) = try await sessionStatus(uploadID)
            if http == 404 { throw .uploadExpired }
            run = SessionRun(uploadID: uploadID, limits: TransferTuner.Limits(status?.part), files: [])
            for index in batch {
                let file = job.record.files[index]
                var entry = FileRun(index: index, fileID: file.fileID ?? "", name: file.source.lastPathComponent,
                                    source: file.source, size: file.size, identity: file.identity,
                                    stored: file.stored)
                if let identity = file.identity, SourceIdentity.of(file.source) != identity {
                    entry.abandoned = .sourceChanged(file.source.lastPathComponent)
                }
                run.files.append(entry)
            }
            run.apply(status, overwrite: true)
            // A cancelled session takes no parts: its unfinished files start over.
            if status?.state == "cancelled" { throw .uploadExpired }
        } else {
            run = try await createSession(batch, job: &job)
        }
        monitor.apply(run.limits)
        try await transfer(&run, job: &job, tally: tally, progress: progress)
    }

    private func createSession(_ batch: [Int], job: inout Job) async throws(TransferError) -> SessionRun {
        struct Body: Encodable {
            struct File: Encodable {
                var file_id: String
                var path: String
                var size: Int64
                var mime_type: String?
                var duplicate_policy: String?
                var if_none_match: String?
                var if_match: String?
            }
            var vault_id: Int64
            var files: [File]
        }
        var files: [Body.File] = []
        for index in batch {
            var file = job.record.files[index]
            file.identity = SourceIdentity.of(file.source)
            guard let identity = file.identity else {
                throw .disk("\(file.source.lastPathComponent) can't be read")
            }
            if identity.size != file.size {
                // It changed since it was chosen: send what is there now.
                file.size = identity.size
            }
            file.fileID = "f\(index)"
            file.stored = ByteRanges()
            job.record.files[index] = file
            var wire = Body.File(file_id: "f\(index)", path: file.path, size: file.size, mime_type: file.mimeType)
            switch file.precondition {
            case .reject: wire.duplicate_policy = "reject"
            case .createOnly: wire.if_none_match = "*"
            case .replace(let version): wire.if_match = version
            }
            files.append(wire)
        }
        var request = URLRequest(url: try url("/upload/sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(Body(vault_id: job.record.vaultID, files: files))
        } catch {
            throw .unexpectedAnswer("the request could not be encoded")
        }
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw TransferError.coded(status: response.statusCode, body: data,
                                      etag: response.value(forHTTPHeaderField: "ETag"))
        }
        guard let answer = WireUpload.decode(WireUpload.Session.self, data), let uploadID = answer.upload_id,
              Self.isToken(uploadID)
        else { throw .unexpectedAnswer("the server did not open an upload session") }
        var run = SessionRun(uploadID: uploadID, limits: TransferTuner.Limits(answer.part), files: [])
        for index in batch {
            let file = job.record.files[index]
            job.record.files[index].uploadID = uploadID
            run.files.append(FileRun(index: index, fileID: file.fileID ?? "f\(index)", name: file.source.lastPathComponent,
                                     source: file.source, size: file.size, identity: file.identity, stored: ByteRanges()))
        }
        run.apply(answer, overwrite: true)
        job.persist(force: true)
        return run
    }

    /// `[A-Za-z0-9_-]`, as the node's ids are.
    static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    private func sessionStatus(_ uploadID: String) async throws(TransferError) -> (WireUpload.Session?, Int) {
        let (data, response) = try await send(URLRequest(url: try url("/upload/sessions/\(uploadID)")))
        if response.statusCode == 404 { return (nil, 404) }
        guard response.statusCode == 200 else { throw TransferError.coded(status: response.statusCode, body: data) }
        guard let status = WireUpload.decode(WireUpload.Session.self, data) else {
            throw .unexpectedAnswer("the upload session's status")
        }
        return (status, 200)
    }

    /// Sends every gap of the session's files, then finishes it.
    private func transfer(_ run: inout SessionRun, job: inout Job, tally: Tally,
                          progress: @escaping @Sendable (VaultLanes.UploadProgress) -> Void)
        async throws(TransferError)
    {
        var resends = 0
        do throws(TransferError) {
            while true {
                try await sendParts(&run, job: &job, tally: tally, progress: progress)
                if try await finish(&run, job: &job, tally: tally, progress: progress) { break }
                resends += 1
                guard resends <= 5 else { throw .status(409, "The server kept reporting the upload incomplete.") }
            }
        } catch where run.cancelled {
            discardSession(run.uploadID)
        }
        settle(run, job: &job)
        tally.reset(job.record)
        progress(tally.report())
    }

    /// Records what became of each file of a finished session, starting over the ones that may.
    private func settle(_ run: SessionRun, job: inout Job) {
        for file in run.files {
            var record = job.record.files[file.index]
            let path = record.path
            if file.state == "committed" {
                record.state = .committed
                record.stored = ByteRanges([0..<record.size])
                job.entries[path] = file.entry
            } else if run.cancelled, file.abandoned == nil, file.error == nil {
                // Its session was cancelled under it: it starts over, through no fault of its own.
                record.uploadID = nil
                record.fileID = nil
                record.stored = ByteRanges()
                record.identity = nil
            } else {
                let error = file.abandoned ?? file.error ?? .status(500, "The server didn't commit the file.")
                let restartable = switch error {
                case .sourceChanged, .integrity, .keyRotated, .uploadExpired: true
                default: false
                }
                if restartable, record.restarts < policy.fileRestarts {
                    record.restarts += 1
                    record.uploadID = nil
                    record.fileID = nil
                    record.stored = ByteRanges()
                    record.identity = nil
                    record.size = SourceIdentity.of(record.source)?.size ?? record.size
                    log.notice("a file starts over: \(error.message, privacy: .private)")
                } else {
                    record.state = .failed
                    record.failure = error.message
                    job.errors[path] = error
                }
            }
            job.record.files[file.index] = record
        }
        job.persist(force: true)
    }

    // MARK: Parts

    private struct PartResult: Sendable {
        var job: PartRequest
        var answer: Result<DeviceTransferClient.PartAnswer, TransferError>
        var start: Double
        var end: Double
        var parallel: Double
        /// The hash of the bytes sent, when all of them were (also on a failure: the answer may be what was lost).
        var digest: String?
    }

    private func sendParts(_ run: inout SessionRun, job: inout Job, tally: Tally,
                           progress: @escaping @Sendable (VaultLanes.UploadProgress) -> Void)
        async throws(TransferError)
    {
        let uploadID = run.uploadID
        let result: Result<Void, TransferError> = await withTaskGroup(of: PartResult.self) { group in
            var inFlight = 0
            var failure: TransferError?
            func launch(_ part: PartRequest, file: FileRun) {
                inFlight += 1
                let url = try? self.url("/upload/sessions/\(uploadID)/files/\(file.fileID)",
                                        [.init(name: "offset", value: String(part.range.lowerBound))])
                let monitor = monitor
                let transfers = transfers
                let source = file.source
                let identity = file.identity
                let key = "\(part.file):\(part.range.lowerBound)"
                let length = Int64(part.range.count)
                // Counted now, not when the task runs, so the next admission sees it.
                let ticket = monitor.partStarted(bytes: length)
                group.addTask {
                    defer {
                        monitor.partEnded(bytes: length)
                        tally.endPart(key)
                    }
                    if part.delay > .zero {
                        try? await Task.sleep(for: part.delay)
                    }
                    guard let url, !Task.isCancelled else {
                        return PartResult(job: part, answer: .failure(url == nil ? .connection("bad URL") : .cancelled),
                                          start: monitor.now, end: monitor.now, parallel: 1)
                    }
                    var request = URLRequest(url: url)
                    if let digest = part.digest, let header = Self.contentDigest(hex: digest) {
                        request.setValue(header, forHTTPHeaderField: "Content-Digest")
                    }
                    let start = monitor.now
                    let digest = Mutex<String?>(nil)
                    do throws(TransferError) {
                        let answer = try await transfers.uploadPart(
                            request, file: source, range: part.range,
                            unchanged: { identity == nil || SourceIdentity.of(source) == identity },
                            hashed: { hex in digest.withLock { $0 = hex } },
                            progress: { sent in
                                let delta = tally.partProgress(key, sent: sent)
                                if delta > 0 { monitor.uploaded(delta) }
                                if tally.allow() { progress(tally.report()) }
                            })
                        return PartResult(job: part, answer: .success(answer), start: start, end: monitor.now,
                                          parallel: monitor.parallelism(since: ticket))
                    } catch {
                        return PartResult(job: part, answer: .failure(error), start: start, end: monitor.now,
                                          parallel: 1, digest: digest.withLock { $0 })
                    }
                }
            }
            func fill() {
                // The tuner's limits count every upload to the node; a session with nothing in flight always sends one
                // part, so uploads running side by side each make progress.
                while failure == nil, !Task.isCancelled, inFlight < run.limits.maxInFlight,
                      let (part, file) = run.next(partBytes: monitor.partBytes,
                                                  admit: { inFlight == 0 || monitor.admit(nextPart: $0) }) {
                    launch(part, file: file)
                }
            }
            fill()
            while inFlight > 0 {
                guard let result = await group.next() else { break }
                inFlight -= 1
                if failure == nil {
                    do throws(TransferError) {
                        try await handle(result, run: &run, job: &job, tally: tally)
                    } catch {
                        failure = error
                        group.cancelAll()
                    }
                }
                if failure == nil {
                    if Task.isCancelled {
                        failure = .cancelled
                        group.cancelAll()
                    } else {
                        fill()
                    }
                }
                job.persist(force: false)
            }
            if let failure { return .failure(failure) }
            return Task.isCancelled ? .failure(.cancelled) : .success(())
        }
        run.clearInFlight()
        tally.reset(job.record, run: run)
        progress(tally.report())
        try result.get()
    }

    /// One part's answer.
    private func handle(_ result: PartResult, run: inout SessionRun, job: inout Job, tally: Tally)
        async throws(TransferError)
    {
        let part = result.job
        guard let position = run.files.firstIndex(where: { $0.index == part.file }) else { return }
        run.files[position].finished(part.range)
        guard run.files[position].abandoned == nil else { return }
        let name = run.files[position].name
        switch result.answer {
        case .failure(let error):
            switch error {
            case .sourceChanged, .disk:
                run.files[position].abandoned = error
            case .connection, .timeout:
                monitor.record(error == .timeout ? .timeout : .connection)
                // A dropped connection with another route possible: stop here and move (``reroute``); the session's
                // status says afterwards what the node kept.
                if job.escalatesDrops, error != .timeout { throw error }
                // The node may hold the part already: the resend carries the bytes' digest.
                if let digest = result.digest { run.files[position].digests[part.range.lowerBound] = digest }
                try retry(part, in: &run.files[position], after: nil, error: error)
            case .cancelled:
                // A part this task didn't cancel: the lanes' session was invalidated (a replaced route).
                if Task.isCancelled { throw .cancelled }
                throw .connection("the connection was closed")
            default:
                throw error
            }
        case .success(let answer):
            let status = answer.response.statusCode
            let detail = ServerErrorBody.decode(answer.body)
            let retryAfter = Self.retryAfter(answer.response.value(forHTTPHeaderField: "Retry-After"))
            switch (status, detail?.code) {
            case (200, _), (201, _):
                guard let ack = WireUpload.decode(WireUpload.Ack.self, answer.body),
                      ack.offset == part.range.lowerBound, ack.length == Int64(part.range.count)
                else {
                    // An answer for another range than was sent: ask the node what it holds.
                    run.files[position].attempt(part.range.lowerBound)
                    guard run.files[position].attempts[part.range.lowerBound, default: 0] <= policy.partRetries else {
                        throw .unexpectedAnswer("the server acknowledged another part than was sent")
                    }
                    try await resync(&run)
                    return
                }
                if let ours = answer.sha256, let theirs = ack.sha256, ours != theirs.lowercased() {
                    // The node holds other bytes than were sent. Stop the session at once, before the file's last
                    // gap closes and it commits; the session's other files start over in a new one.
                    log.error("part sha256 mismatch at offset \(part.range.lowerBound, privacy: .public)")
                    run.files[position].abandoned = .integrity(name)
                    run.cancelled = true
                    throw .integrity(name)
                }
                run.files[position].stored.insert(part.range)
                run.files[position].stored.formUnion(ByteRanges(wire: ack.ranges))
                if let state = ack.state { run.files[position].state = state }
                if let digest = answer.sha256 { run.files[position].digests[part.range.lowerBound] = digest }
                job.record.files[part.file].stored = run.files[position].stored
                tally.stored(part.file, bytes: run.files[position].stored.byteCount)
                monitor.record(TransferTuner.Sample(
                    bytes: Int64(part.range.count), start: result.start, end: result.end, parallel: result.parallel,
                    ackLatency: answer.ackLatency,
                    serverTiming: TransferTuner.ServerTiming(header: answer.response.value(forHTTPHeaderField: "Server-Timing"))))
            case (400, "digest_mismatch"):
                // The node read other bytes than were hashed: send the range again.
                try retry(part, in: &run.files[position], after: nil, error: .integrity(name))
            case (409, "part_conflict"):
                // The node holds this range with other bytes: the local file isn't what was sent before.
                run.files[position].abandoned = .sourceChanged(name)
            case (409, _):
                // part_overlap, file_state: the node's view and ours differ; ask it. A part of a connection that died
                // may still count as in flight there for a while, so the range waits before it goes again.
                try await resync(&run)
                guard let again = run.files.firstIndex(where: { $0.index == part.file }) else { return }
                if run.files[again].stored.overlaps(part.range) || !run.files[again].accepting { return }
                try retry(part, in: &run.files[again], after: nil,
                          error: .status(409, "The server and this Mac disagree about what was uploaded."))
            case (429, _), (503, _):
                monitor.record(.busy)
                try retry(part, in: &run.files[position], after: retryAfter, error: .busy)
            case (404, _):
                throw .uploadExpired
            case (413, "part_too_large"), (400, "bad_request"):
                // Our idea of the limits is stale.
                run.files[position].attempt(part.range.lowerBound)
                guard run.files[position].attempts[part.range.lowerBound, default: 0] <= policy.partRetries else {
                    throw TransferError.coded(status: status, body: answer.body)
                }
                try await resync(&run)
                monitor.apply(run.limits)
            case (413, _):
                run.files[position].abandoned = .fileTooLarge
            case (500..., _), (408, _):
                try retry(part, in: &run.files[position], after: retryAfter,
                          error: TransferError.coded(status: status, body: answer.body))
            default:
                throw TransferError.coded(status: status, body: answer.body,
                                          etag: answer.response.value(forHTTPHeaderField: "ETag"))
            }
        }
    }

    /// Queues exactly `part`'s range again after a delay, or gives up with `error` once its retries are spent.
    private func retry(_ part: PartRequest, in file: inout FileRun, after: Duration?, error: TransferError)
        throws(TransferError)
    {
        file.attempt(part.range.lowerBound)
        let attempt = file.attempts[part.range.lowerBound, default: 1]
        guard attempt <= policy.partRetries else {
            if case .integrity = error {
                file.abandoned = error
                return
            }
            throw error
        }
        file.retry.append(Retry(range: part.range, delay: after ?? backoff(attempt - 1)))
    }

    private func backoff(_ attempt: Int) -> Duration {
        let delay = policy.backoff * (1 << min(attempt, 16))
        return min(delay, policy.maxBackoff)
    }

    private func resync(_ run: inout SessionRun) async throws(TransferError) {
        let (status, http) = try await sessionStatus(run.uploadID)
        if http == 404 { throw .uploadExpired }
        run.apply(status, overwrite: true)
    }

    // MARK: Finishing

    /// Finishes the session; false when the node still lacks bytes this Mac should send.
    private func finish(_ run: inout SessionRun, job: inout Job, tally: Tally,
                        progress: @escaping @Sendable (VaultLanes.UploadProgress) -> Void)
        async throws(TransferError) -> Bool
    {
        let deadline = ContinuousClock.now + policy.finishTimeout
        // Every file abandoned: nothing to finish.
        if run.files.allSatisfy({ $0.abandoned != nil || $0.terminal }) && run.files.contains(where: { $0.abandoned != nil }) {
            try await waitForTerminal(&run, deadline: deadline)
            discardSession(run.uploadID)
            return true
        }
        while true {
            var request = URLRequest(url: try url("/upload/sessions/\(run.uploadID)/finish"))
            request.httpMethod = "POST"
            let (data, response) = try await send(request)
            let status = WireUpload.decode(WireUpload.Session.self, data)
            switch response.statusCode {
            case 200:
                run.apply(status, overwrite: false)
                return true
            case 202:
                run.apply(status, overwrite: false)
                tally.reset(job.record, run: run)
                progress(tally.report())
                guard ContinuousClock.now < deadline else { throw .timeout }
                try await sleep(Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")) ?? .seconds(1))
            case 409:
                // incomplete: the status says what is missing.
                if let status, status.files != nil { run.apply(status, overwrite: true) } else { try await resync(&run) }
                if run.files.contains(where: { $0.abandoned == nil && $0.hasGaps }) { return false }
                // Only abandoned files lack bytes: let the others commit, then end the session.
                try await waitForTerminal(&run, deadline: deadline)
                discardSession(run.uploadID)
                return true
            case 404:
                throw .uploadExpired
            default:
                throw TransferError.coded(status: response.statusCode, body: data)
            }
        }
    }

    /// Polls the status until every file not abandoned is committed or failed.
    private func waitForTerminal(_ run: inout SessionRun, deadline: ContinuousClock.Instant) async throws(TransferError) {
        while !run.files.allSatisfy({ $0.abandoned != nil || $0.terminal }) {
            guard ContinuousClock.now < deadline else { throw .timeout }
            try await sleep(.seconds(1))
            try await resync(&run)
        }
    }

    // MARK: Plumbing

    func url(_ path: String, _ query: [URLQueryItem] = []) throws(TransferError) -> URL {
        do {
            return try transfers.http.url(path: path, query: query)
        } catch {
            throw TransferError(error)
        }
    }

    func send(_ request: URLRequest) async throws(TransferError) -> (Data, HTTPURLResponse) {
        do {
            return try await transfers.http.data(for: request)
        } catch {
            throw TransferError(error)
        }
    }

    private func sleep(_ duration: Duration) async throws(TransferError) {
        do {
            try await Task.sleep(for: duration)
        } catch {
            throw .cancelled
        }
    }

    /// `Retry-After` in seconds (an HTTP date is read as one second).
    static func retryAfter(_ value: String?) -> Duration? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds >= 0 { return .milliseconds(Int64(min(seconds, 300) * 1000)) }
        return .seconds(1)
    }

    /// `sha-256=:<base64>:` (RFC 9530) from a hex digest.
    static func contentDigest(hex: String) -> String? {
        guard hex.count == 64 else { return nil }
        var bytes = Data(capacity: 32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return "sha-256=:\(bytes.base64EncodedString()):"
    }
}

// MARK: - Session state

/// A part to send again, and how long to wait first.
struct Retry: Sendable, Hashable {
    var range: Range<Int64>
    var delay: Duration
}

/// One file of the session being sent.
struct FileRun: Sendable {
    let index: Int
    let fileID: String
    let name: String
    let source: URL
    let size: Int64
    let identity: SourceIdentity?
    var stored: ByteRanges
    var state = "receiving"
    var inFlight: [Range<Int64>] = []
    var retry: [Retry] = []
    var attempts: [Int64: Int] = [:]
    /// Hashes of ranges sent before, by offset (for `Content-Digest` on a resend).
    var digests: [Int64: String] = [:]
    /// This Mac stopped sending it (the source changed, an integrity failure).
    var abandoned: TransferError?
    /// The node failed it.
    var error: TransferError?
    var entry: WsModel.FsEntryBase?

    var terminal: Bool { state == "committed" || state == "failed" }
    var hasGaps: Bool { !stored.contains(0..<size) }
    var accepting: Bool { abandoned == nil && error == nil && (state == "receiving" || state.isEmpty) }

    mutating func attempt(_ offset: Int64) {
        attempts[offset, default: 0] += 1
    }

    mutating func finished(_ range: Range<Int64>) {
        if let at = inFlight.firstIndex(of: range) { inFlight.remove(at: at) }
    }
}

struct SessionRun: Sendable {
    let uploadID: String
    var limits: TransferTuner.Limits
    var files: [FileRun]
    /// This Mac cancelled the session (an integrity failure): its unfinished files start over in another.
    var cancelled = false

    /// The next part to send, if any may start now: a retried range first, else the start of the first gap nobody is
    /// sending, sized so no piece smaller than the node's minimum is left before a stored range.
    mutating func next(partBytes: Int64, admit: (Int64) -> Bool) -> (PartRequest, FileRun)? {
        for position in files.indices where files[position].accepting {
            // A retried range the node now holds (even partly) is dropped: carving sends what is still missing.
            let stored = files[position].stored
            files[position].retry.removeAll { stored.overlaps($0.range) }
            if let retry = files[position].retry.first {
                guard admit(Int64(retry.range.count)) else { return nil }
                files[position].retry.removeFirst()
                files[position].inFlight.append(retry.range)
                let file = files[position]
                return (.init(file: file.index, range: retry.range, delay: retry.delay,
                              digest: file.digests[retry.range.lowerBound]), file)
            }
            guard let range = carve(files[position], partBytes: partBytes) else { continue }
            if range.isEmpty {
                // A gap the node's minimum part size can't fill: this file can't resume in this session.
                files[position].abandoned = .uploadExpired
                continue
            }
            guard admit(Int64(range.count)) else { return nil }
            files[position].inFlight.append(range)
            let file = files[position]
            return (.init(file: file.index, range: range, delay: .zero, digest: file.digests[range.lowerBound]), file)
        }
        return nil
    }

    /// The next new range of `file`, nil when everything is stored or assigned, empty when its first gap can't be sent.
    func carve(_ file: FileRun, partBytes: Int64) -> Range<Int64>? {
        var assigned = file.stored
        for range in file.inFlight { assigned.insert(range) }
        for retry in file.retry { assigned.insert(retry.range) }
        guard let gap = assigned.gaps(upTo: file.size).first else { return nil }
        let size = min(max(partBytes, limits.minBytes), limits.maxBytes)
        let span = gap.upperBound - gap.lowerBound
        var length = min(size, span)
        let rest = span - length
        if rest > 0, rest < limits.minBytes, gap.upperBound < file.size {
            // Don't leave a sliver the node would refuse before a stored range.
            length = span <= limits.maxBytes ? span : span - limits.minBytes
        }
        if length < limits.minBytes, gap.lowerBound + length != file.size { return gap.lowerBound..<gap.lowerBound }
        return gap.lowerBound..<(gap.lowerBound + length)
    }

    mutating func clearInFlight() {
        for position in files.indices { files[position].inFlight.removeAll() }
    }

    /// Takes in a status or finish answer. `overwrite`: its ranges replace ours (they are the node's durable truth).
    mutating func apply(_ status: WireUpload.Session?, overwrite: Bool) {
        guard let status else { return }
        if let part = status.part { limits = TransferTuner.Limits(part) }
        for wire in status.files ?? [] {
            guard let position = files.firstIndex(where: { $0.fileID == wire.file_id }) else { continue }
            if let ranges = wire.ranges {
                let theirs = ByteRanges(wire: ranges)
                if overwrite { files[position].stored = theirs } else { files[position].stored.formUnion(theirs) }
            }
            if let state = wire.state { files[position].state = state }
            if wire.state == "committed" { files[position].stored = ByteRanges([0..<files[position].size]) }
            if let entry = wire.entry?.value { files[position].entry = entry }
            if wire.state == "failed" {
                files[position].error = TransferError.coded(status: nil, code: wire.error?.code,
                                                            message: wire.error?.message, etag: wire.error?.etag)
            }
        }
    }
}

/// One part to send: a range of one file, after a delay (a retry), with the hash of its bytes when they were sent
/// before.
struct PartRequest: Sendable {
    var file: Int
    var range: Range<Int64>
    var delay: Duration
    var digest: String?
}

/// The upload's record as it runs, saved at most every `persistInterval` (and when forced).
private struct Job {
    var record: ResumableUploadRecord
    let store: ResumableStore?
    let persistInterval: Duration
    var lastSaved: ContinuousClock.Instant?
    var entries: [String: WsModel.FsEntryBase?] = [:]
    var errors: [String: TransferError] = [:]
    /// A part's dropped connection ends the session run at once (to try another route) instead of being retried.
    var escalatesDrops = false

    init(record: ResumableUploadRecord, store: ResumableStore?, persistInterval: Duration) {
        self.record = record
        self.store = store
        self.persistInterval = persistInterval
    }

    mutating func persist(force: Bool) {
        guard let store else { return }
        let now = ContinuousClock.now
        if !force, let lastSaved, now - lastSaved < persistInterval { return }
        lastSaved = now
        store.save(record)
    }
}

/// Progress across the whole upload: bytes the node holds plus the parts' bytes on the way, and files complete.
final class Tally: Sendable {
    private struct State {
        var stored: [Int: Int64] = [:]
        var sizes: [Int: Int64] = [:]
        var committedFiles = 0
        var inFlight: [String: Int64] = [:]
        var last: ContinuousClock.Instant?
    }

    private let state: Mutex<State>

    init(record: ResumableUploadRecord) {
        state = Mutex(State())
        reset(record)
    }

    func reset(_ record: ResumableUploadRecord, run: SessionRun? = nil) {
        state.withLock { state in
            state.stored = [:]
            state.sizes = [:]
            state.committedFiles = 0
            for (index, file) in record.files.enumerated() {
                state.sizes[index] = file.size
                state.stored[index] = file.state == .committed ? file.size : min(file.size, file.stored.byteCount)
                if file.state == .committed { state.committedFiles += 1 }
            }
            for file in run?.files ?? [] where file.abandoned == nil {
                state.stored[file.index] = min(file.size, file.stored.byteCount)
            }
        }
    }

    func stored(_ index: Int, bytes: Int64) {
        state.withLock { $0.stored[index] = min($0.sizes[index] ?? bytes, bytes) }
    }

    /// The bytes a part sent since its last report.
    func partProgress(_ key: String, sent: Int64) -> Int64 {
        state.withLock { state in
            let before = state.inFlight[key] ?? 0
            state.inFlight[key] = max(before, sent)
            return max(0, sent - before)
        }
    }

    func endPart(_ key: String) {
        _ = state.withLock { $0.inFlight.removeValue(forKey: key) }
    }

    /// At most every 100 ms.
    func allow() -> Bool {
        let now = ContinuousClock.now
        return state.withLock { state in
            if let last = state.last, now - last < .milliseconds(100) { return false }
            state.last = now
            return true
        }
    }

    func report() -> VaultLanes.UploadProgress {
        state.withLock { state in
            let complete = state.stored.filter { index, bytes in bytes >= (state.sizes[index] ?? 0) }.count
            let bytes = state.stored.values.reduce(0, +) + state.inFlight.values.reduce(0, +)
            return VaultLanes.UploadProgress(bytes: bytes, files: max(complete, state.committedFiles))
        }
    }
}
