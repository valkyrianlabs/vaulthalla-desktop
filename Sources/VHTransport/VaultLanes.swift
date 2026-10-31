public import Foundation
public import VHCore
import Synchronization

/// A vault's files over the device listener's HTTP lanes, as the device's user (docs/architecture.md §2): thumbnail
/// readiness and images (`/preview/batch`, `/preview`), original bytes (`/download/content`, resumable), folder ZIPs
/// (`/download`), and the upload session flow (`/upload/session` → `PUT /upload/<id>/files/<file>` →
/// `/upload/<id>/finish`, or `DELETE /upload/<id>` when it fails). The same requests the web console makes
/// (web/src/features/files/{source,transfers,thumbnails}.ts), with the device certificate instead of a cookie.
public struct VaultLanes: Sendable {
    public let transfers: DeviceTransferClient
    public var policy: Policy
    /// What the node announced beyond the base lanes; the owner sets it from `meta.hello` before each use.
    public var features = Features()
    /// The node's transfer tuning and stats, shared by every lanes value made for it (nil: a private one per call).
    public var monitor: TransferMonitor?
    /// Where resumable uploads persist their progress (nil: in memory only, nothing survives a relaunch).
    public var store: ResumableStore?
    /// Lanes on a new route after a dropped connection (``LaneReroute``): resumable uploads move there and resume.
    public var reroute: LaneReroute?

    /// Optional lanes the node serves, each gated on its `meta.hello` capability.
    public struct Features: Sendable, Hashable {
        /// `http.upload.resumable`: `/upload/sessions` (resumable parts). Off, uploads use `/upload/session` and
        /// `PUT /upload/content` exactly as before.
        public var resumableUploads = false
        /// `device.lanes.transfer`: `/transfer/probe|sink|source` for calibration and Test Connection.
        public var transferLanes = false

        public init(resumableUploads: Bool = false, transferLanes: Bool = false) {
            self.resumableUploads = resumableUploads
            self.transferLanes = transferLanes
        }
    }

    public struct Policy: Sendable {
        /// Files per upload session and bytes per session: a large drop becomes several sessions, as on the web.
        public var sessionMaxFiles = 500
        public var sessionMaxBytes: Int64 = 4 * 1024 * 1024 * 1024
        /// Files sent at once within a session.
        public var concurrency = 3
        /// Attempts after the first for a transfer that failed for a reason worth retrying.
        public var retries = 3
        /// The first retry's delay; each later one doubles it.
        public var backoff: Duration = .milliseconds(800)
        /// Resumable uploads (``Features/resumableUploads``).
        public var resumable = ResumableUploader.Policy()
        /// A conditional write (``putContent(vaultID:path:from:precondition:mimeType:progress:)``) at most this large
        /// stays one `PUT /upload/content` even on a node with resumable uploads: there is nothing to resume, and one
        /// request beats three.
        public var resumableThreshold: Int64 = 8 << 20

        public init() {}
    }

    public init(transfers: DeviceTransferClient, policy: Policy = Policy()) {
        self.transfers = transfers
        self.policy = policy
    }

    public init(configuration: DeviceHTTPClient.Configuration) throws(DeviceHTTPError) {
        self.init(transfers: try DeviceTransferClient(configuration: configuration))
    }

    private var http: DeviceHTTPClient { transfers.http }

    /// The endpoint these lanes reach.
    public var endpoint: NodeEndpoint { transfers.http.configuration.endpoint }

    public func invalidate() {
        transfers.invalidate()
    }

    // MARK: - Thumbnails

    /// What `/preview/batch` says about one file's thumbnail.
    public enum ThumbnailStatus: String, Sendable, Hashable {
        case ready, queued, missing, unsupported, failed, error

        /// Asking again later may change the answer (the node is still rendering it).
        public var isPending: Bool { self == .queued }
    }

    public struct ThumbnailItem: Sendable, Hashable {
        /// Echoed back by the node to match answers to requests.
        public var key: String
        public var path: String

        public init(key: String, path: String) {
            self.key = key
            self.path = path
        }
    }

    /// The node's thumbnail readiness for up to 200 files of one vault, by key. Never renders or fetches anything.
    public func thumbnailStatus(vaultID: Int64, items: [ThumbnailItem], size: Int)
        async throws(TransferError) -> [String: ThumbnailStatus]
    {
        struct Body: Encodable {
            struct Item: Encodable {
                var key: String
                var path: String
                var vault_id: Int64
            }
            var size: Int
            var vault_id: Int64
            var items: [Item]
        }
        struct Answer: Decodable {
            struct Item: Decodable {
                var key: String?
                var status: String
            }
            var items: [Item]?
        }
        var request = URLRequest(url: try url("/preview/batch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encode(Body(size: size, vault_id: vaultID, items: items.prefix(200).map {
            .init(key: $0.key, path: $0.path, vault_id: vaultID)
        }))
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw TransferError.answer(status: response.statusCode, body: data) }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw .unexpectedAnswer("preview batch")
        }
        var statuses: [String: ThumbnailStatus] = [:]
        for item in answer.items ?? [] {
            guard let key = item.key else { continue }
            statuses[key] = ThumbnailStatus(rawValue: item.status) ?? .error
        }
        return statuses
    }

    /// A thumbnail (JPEG) of a file whose plan says it has one, `size` px on its long side.
    public func thumbnail(vaultID: Int64, path: String, size: Int) async throws(TransferError) -> Data {
        let request = URLRequest(url: try url("/preview", [
            .init(name: "vault_id", value: String(vaultID)), .init(name: "path", value: path),
            .init(name: "size", value: String(size)),
        ]))
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw TransferError.answer(status: response.statusCode, body: data) }
        return data
    }

    // MARK: - Downloads

    /// Downloads a file's original bytes (`/download/content`) or a folder as the node's ZIP (`/download`) into
    /// `destination`, replacing what is there once complete. The bytes go to a hidden partial file next to it first;
    /// a file download that drops resumes where it stopped (`Range`, while the ETag still matches), a ZIP starts over.
    /// Returns the length written.
    @discardableResult
    public func download(vaultID: Int64, path: String, isDirectory: Bool, to destination: URL,
                         progress: @escaping @Sendable (_ done: Int64, _ total: Int64?) -> Void)
        async throws(TransferError) -> Int64
    {
        try await fetch(vaultID: vaultID, path: path, isDirectory: isDirectory, to: destination, progress: progress)
            .length
    }

    /// ``download(vaultID:path:isDirectory:to:progress:)`` of a file, also returning the strong validator (the
    /// file's `content_version`) of the bytes it placed.
    public func downloadContent(vaultID: Int64, path: String, to destination: URL,
                                progress: @escaping @Sendable (_ done: Int64, _ total: Int64?) -> Void = { _, _ in })
        async throws(TransferError) -> DeviceTransferClient.Downloaded
    {
        try await fetch(vaultID: vaultID, path: path, isDirectory: false, to: destination, progress: progress)
    }

    private func fetch(vaultID: Int64, path: String, isDirectory: Bool, to destination: URL,
                       progress: @escaping @Sendable (_ done: Int64, _ total: Int64?) -> Void)
        async throws(TransferError) -> DeviceTransferClient.Downloaded
    {
        let query: [URLQueryItem] = [
            .init(name: "vault_id", value: String(vaultID)), .init(name: "path", value: path),
            .init(name: "disposition", value: "attachment"),
        ]
        let request = URLRequest(url: try url(isDirectory ? "/download" : "/download/content", query))
        let partial = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).vhdownload", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: partial) }

        // The validator of what is on disk, so the next attempt asks for the rest of the same file.
        let etag = Mutex<String?>(nil)
        let progress = metered(progress)
        var attempt = 0
        while true {
            let resume = isDirectory ? nil : DeviceTransferClient.resumeState(of: partial, etag: etag.withLock { $0 })
            do {
                let done = try await transfers.download(
                    request, to: partial, resume: resume, isDirectory: isDirectory,
                    validator: { value in etag.withLock { $0 = value } }, progress: progress)
                try place(partial, at: destination)
                return done
            } catch {
                if case .disk = error { throw error }
                try await retry(after: error, attempt: &attempt)
            }
        }
    }

    /// The length the node will send, from a HEAD (a folder's ZIP length is computed from its listing).
    public func downloadLength(vaultID: Int64, path: String, isDirectory: Bool) async throws(TransferError) -> Int64? {
        var request = URLRequest(url: try url(isDirectory ? "/download" : "/download/content", [
            .init(name: "vault_id", value: String(vaultID)), .init(name: "path", value: path),
        ]))
        request.httpMethod = "HEAD"
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw TransferError.answer(status: response.statusCode, body: data, isDirectory: isDirectory)
        }
        return response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    }

    private func place(_ partial: URL, at destination: URL) throws(TransferError) {
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try manager.replaceItemAt(destination, withItemAt: partial)
            } else {
                try manager.moveItem(at: partial, to: destination)
            }
        } catch {
            throw .disk(error.localizedDescription)
        }
    }

    // MARK: - Uploads

    /// One local file to upload, and where it goes relative to the target folder ("photos/2024/a.jpg").
    public struct UploadFile: Sendable, Hashable {
        public var source: URL
        public var relativePath: String
        public var size: Int64
        public var mimeType: String?

        public init(source: URL, relativePath: String, size: Int64, mimeType: String? = nil) {
            self.source = source
            self.relativePath = relativePath
            self.size = size
            self.mimeType = mimeType
        }
    }

    /// Progress of an upload: bytes acknowledged by the transport and files the node holds complete.
    public struct UploadProgress: Sendable, Hashable {
        public var bytes: Int64
        public var files: Int

        public init(bytes: Int64, files: Int) {
            self.bytes = bytes
            self.files = files
        }
    }

    /// Splits `files` into sessions of at most `maxFiles` files and `maxBytes` bytes (a file larger than that goes
    /// alone), in order.
    public static func sessions(_ files: [UploadFile], maxFiles: Int, maxBytes: Int64) -> [[UploadFile]] {
        var sessions: [[UploadFile]] = []
        var current: [UploadFile] = []
        var bytes: Int64 = 0
        for file in files {
            if !current.isEmpty, current.count >= maxFiles || bytes + file.size > maxBytes {
                sessions.append(current)
                current = []
                bytes = 0
            }
            current.append(file)
            bytes += file.size
        }
        if !current.isEmpty { sessions.append(current) }
        return sessions
    }

    /// Uploads `files` into `directory`: in resumable parts when the node announced them
    /// (``Features/resumableUploads``, ``uploadResumable(_:control:progress:)``), else the session flow below, unchanged.
    @discardableResult
    public func upload(_ files: [UploadFile], vaultID: Int64, into directory: String, control: UploadControl? = nil,
                       progress: @escaping @Sendable (UploadProgress) -> Void)
        async throws(TransferError) -> Set<String>
    {
        guard features.resumableUploads else {
            return try await uploadSessions(files, vaultID: vaultID, into: directory, progress: progress)
        }
        let record = ResumableUploader.plan(files, vaultID: vaultID, into: directory)
        return try await uploadResumable(record, control: control, progress: progress)
    }

    /// Uploads `files` into `directory` of the vault. Each session is opened, filled (``Policy/concurrency`` files at
    /// a time) and finished; nothing is committed until its finish. A session that fails is discarded on the node
    /// (`DELETE`), and opened again from the start when the failure is worth a retry (a file the node saw fail can't be
    /// sent again within its session). Cancelling discards the open session too. Returns the folders that changed.
    @discardableResult
    public func uploadSessions(_ files: [UploadFile], vaultID: Int64, into directory: String,
                               progress: @escaping @Sendable (UploadProgress) -> Void)
        async throws(TransferError) -> Set<String>
    {
        let target = VaultPathString.normalize(directory)
        let tally = Tally()
        var touched: Set<String> = [target]
        for batch in Self.sessions(files, maxFiles: policy.sessionMaxFiles, maxBytes: policy.sessionMaxBytes) {
            let planned = batch.enumerated().map { index, file in
                let path = VaultPathString.join(target, file.relativePath)
                return PlannedFile(file: file, id: "f\(index)", path: path)
            }
            for file in planned { touched.insert(VaultPathString.parent(of: file.path)) }
            var attempt = 0
            while true {
                let before = tally.state.withLock { $0 }
                do {
                    try await uploadSession(planned, vaultID: vaultID, tally: tally, progress: progress)
                    break
                } catch {
                    // Roll back this attempt's progress, so a retry doesn't count twice.
                    tally.state.withLock { $0 = before }
                    progress(before)
                    try await retry(after: error, attempt: &attempt)
                }
            }
        }
        return touched
    }

    private final class Tally: Sendable {
        let state = Mutex(UploadProgress(bytes: 0, files: 0))
    }

    private struct PlannedFile: Sendable {
        var file: UploadFile
        var id: String
        var path: String
    }

    private func uploadSession(_ planned: [PlannedFile], vaultID: Int64, tally: Tally,
                               progress: @escaping @Sendable (UploadProgress) -> Void) async throws(TransferError) {
        struct Body: Encodable {
            struct File: Encodable {
                var file_id: String
                var mime_type: String?
                var duplicate_policy = "reject"
                var path: String
                var size: Int64
            }
            var vault_id: Int64
            var files: [File]
        }
        struct Opened: Decodable { var upload_id: String? }

        var open = URLRequest(url: try url("/upload/session"))
        open.httpMethod = "POST"
        open.setValue("application/json", forHTTPHeaderField: "Content-Type")
        open.httpBody = try encode(Body(vault_id: vaultID, files: planned.map {
            .init(file_id: $0.id, mime_type: $0.file.mimeType, path: $0.path, size: $0.file.size)
        }))
        let (opened, openResponse) = try await send(open)
        guard openResponse.statusCode == 200 else {
            throw TransferError.answer(status: openResponse.statusCode, body: opened)
        }
        guard let uploadID = (try? JSONDecoder().decode(Opened.self, from: opened))?.upload_id, !uploadID.isEmpty,
              uploadID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { throw .unexpectedAnswer("the server did not open an upload session") }

        do throws(TransferError) {
            try await sendFiles(planned, uploadID: uploadID, tally: tally, progress: progress)
            var finish = URLRequest(url: try url("/upload/\(uploadID)/finish"))
            finish.httpMethod = "POST"
            let (finished, finishResponse) = try await send(finish)
            guard finishResponse.statusCode == 200 else {
                throw TransferError.answer(status: finishResponse.statusCode, body: finished)
            }
        } catch {
            discard(uploadID)
            throw error
        }
    }

    private func sendFiles(_ planned: [PlannedFile], uploadID: String, tally: Tally,
                           progress: @escaping @Sendable (UploadProgress) -> Void) async throws(TransferError) {
        let limit = max(1, policy.concurrency)
        let result: Result<Void, TransferError> = await withTaskGroup(of: Result<Void, TransferError>.self) { group in
            var next = 0
            var failure: TransferError?
            func add() {
                let file = planned[next]
                next += 1
                group.addTask { await self.put(file, uploadID: uploadID, tally: tally, progress: progress) }
            }
            while next < planned.count, next < limit { add() }
            for await outcome in group {
                if case .failure(let error) = outcome, failure == nil {
                    failure = error
                    group.cancelAll()
                }
                if failure == nil, next < planned.count, !Task.isCancelled { add() }
            }
            if let failure { return .failure(failure) }
            return Task.isCancelled ? .failure(.cancelled) : .success(())
        }
        try result.get()
    }

    private func put(_ planned: PlannedFile, uploadID: String, tally: Tally,
                     progress: @escaping @Sendable (UploadProgress) -> Void) async -> Result<Void, TransferError> {
        // An empty file is complete as soon as the session opens: the node refuses a body for it.
        guard planned.file.size > 0 else {
            progress(tally.state.withLock { $0.files += 1; return $0 })
            return .success(())
        }
        do {
            var request = URLRequest(url: try url("/upload/\(uploadID)/files/\(planned.id)"))
            request.httpMethod = "PUT"
            request.setValue(planned.file.mimeType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
            let seen = Mutex<Int64>(0)
            let (body, response) = try await transfers.upload(request, fromFile: planned.file.source) { sent, _ in
                let delta = seen.withLock { last in
                    let delta = sent - last
                    last = max(last, sent)
                    return delta
                }
                guard delta > 0 else { return }
                progress(tally.state.withLock { $0.bytes += delta; return $0 })
            }
            guard (200..<300).contains(response.statusCode) else {
                return .failure(TransferError.answer(status: response.statusCode, body: body))
            }
            let rest = planned.file.size - seen.withLock { $0 }
            progress(tally.state.withLock { $0.bytes += max(0, rest); $0.files += 1; return $0 })
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Discards an upload session on the node, outside the caller's task so a cancellation still reaches the node.
    private func discard(_ uploadID: String) {
        guard let url = try? url("/upload/\(uploadID)") else { return }
        let http = http
        Task.detached {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            _ = try? await http.data(for: request)
        }
    }

    // MARK: - Resumable uploads

    /// The resumable uploader on these lanes (its tuning is ``monitor``, or a private one).
    public var resumableUploader: ResumableUploader {
        var uploader = ResumableUploader(transfers: transfers, monitor: monitor ?? TransferMonitor(node: "unshared"),
                                         store: store, policy: policy.resumable)
        uploader.reroute = reroute
        return uploader
    }

    /// Runs or resumes a resumable upload (``ResumableUploader``). Throws the first file's failure when any failed,
    /// after the others finished; returns the folders that changed.
    @discardableResult
    public func uploadResumable(_ record: ResumableUploadRecord, control: UploadControl? = nil,
                                progress: @escaping @Sendable (UploadProgress) -> Void)
        async throws(TransferError) -> Set<String>
    {
        await calibrateIfNeeded(totalBytes: record.totalBytes - record.storedBytes)
        let outcome = try await resumableUploader.upload(record, control: control, progress: progress)
        if let first = outcome.failed.first { throw first.error }
        return outcome.folders
    }

    /// Wraps a download's progress so its bytes reach the monitor's meter.
    private func metered(_ progress: @escaping @Sendable (Int64, Int64?) -> Void) -> @Sendable (Int64, Int64?) -> Void {
        guard let monitor else { return progress }
        let seen = Mutex<Int64>(0)
        return { done, total in
            let delta = seen.withLock { last in
                defer { last = done }
                return done > last ? done - last : 0
            }
            if delta > 0 { monitor.downloaded(delta) }
            progress(done, total)
        }
    }

    // MARK: - Plumbing

    func url(_ path: String, _ query: [URLQueryItem] = []) throws(TransferError) -> URL {
        do {
            return try http.url(path: path, query: query)
        } catch {
            throw TransferError(error)
        }
    }

    func send(_ request: URLRequest) async throws(TransferError) -> (Data, HTTPURLResponse) {
        do {
            return try await http.data(for: request)
        } catch {
            throw TransferError(error)
        }
    }

    private func encode(_ value: some Encodable) throws(TransferError) -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw .unexpectedAnswer("the request could not be encoded")
        }
    }

    /// Waits before the next attempt when `error` is worth retrying and attempts remain; rethrows it otherwise.
    func retry(after error: TransferError, attempt: inout Int) async throws(TransferError) {
        guard error.isRetryable, attempt < policy.retries, !Task.isCancelled else { throw error }
        let delay = policy.backoff * (1 << attempt)
        attempt += 1
        do {
            try await Task.sleep(for: delay)
        } catch {
            throw .cancelled
        }
    }
}

/// Vault path arithmetic for the lanes (the web's paths.ts). VHNodes' `VaultPath` is the view-facing type.
enum VaultPathString {
    static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." && $0 != ".." }
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    static func join(_ base: String, _ relative: String) -> String {
        normalize(normalize(base) + "/" + relative)
    }

    static func parent(of path: String) -> String {
        var parts = normalize(path).split(separator: "/")
        _ = parts.popLast()
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }
}
