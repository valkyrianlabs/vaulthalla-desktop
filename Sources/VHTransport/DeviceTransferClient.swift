public import Foundation
import Synchronization

/// Streams bytes over the device listener's HTTP lanes with the device's trust (``DeviceHTTPClient``'s TLS, identity
/// and pins): a download is written to disk as it arrives and can resume with a `Range`; an upload is read from disk.
/// Both report progress. Bytes never pass through ws, and never sit in memory whole.
///
/// Small requests (JSON, thumbnails) go through ``http``. Call ``invalidate()`` when done.
public final class DeviceTransferClient: Sendable {
    /// The same node's request/response client (URLs, JSON calls, thumbnails).
    public let http: DeviceHTTPClient
    private let session: URLSession
    private let delegate: StreamingDelegate

    public init(configuration: DeviceHTTPClient.Configuration) throws(DeviceHTTPError) {
        http = try DeviceHTTPClient(configuration: configuration)
        let settings = URLSessionConfiguration.ephemeral
        settings.tlsMinimumSupportedProtocolVersion = .TLSv13
        settings.urlCache = nil
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.urlCredentialStorage = nil
        // Silence between two chunks, not the length of the transfer.
        settings.timeoutIntervalForRequest = Double(configuration.timeout.components.seconds) * 2
        settings.timeoutIntervalForResource = 7 * 24 * 3600
        settings.waitsForConnectivity = false
        settings.httpMaximumConnectionsPerHost = 6
        settings.httpAdditionalHeaders = ["User-Agent": "Vaulthalla Desktop"]
        delegate = StreamingDelegate(trust: TrustDelegate(identity: configuration.identityBox,
                                                          pins: configuration.serverSPKIPins))
        session = URLSession(configuration: settings, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func invalidate() {
        session.invalidateAndCancel()
        http.invalidate()
    }

    // MARK: - Download

    /// Where an interrupted download stands: the bytes already on disk and the validator they belong to.
    public struct Resume: Hashable, Sendable {
        public var offset: Int64
        /// The strong ETag of the first answer; the node sends the rest only while it still matches (`If-Range`).
        public var etag: String

        public init(offset: Int64, etag: String) {
            self.offset = offset
            self.etag = etag
        }
    }

    public struct Downloaded: Sendable {
        /// The file's length on disk once done.
        public var length: Int64
        /// The strong validator, for a later resume.
        public var etag: String?
        /// Whether the node sent only the missing part (206).
        public var resumed: Bool
    }

    /// GETs `request` into `file`. With `resume`, asks for the bytes after `resume.offset` (`Range` + `If-Range`): a
    /// 206 appends, a 200 (the file changed, or ranges aren't served) starts the file over. `progress` gets the bytes
    /// on disk and the expected total when the node said. A failure leaves what arrived in `file` for a resume
    /// (``resumeState(of:etag:)``, with the validator `validator` reported when the answer began); the caller deletes
    /// it when giving up.
    public func download(_ request: URLRequest, to file: URL, resume: Resume? = nil, isDirectory: Bool = false,
                         validator: @escaping @Sendable (String?) -> Void = { _ in },
                         progress: @escaping @Sendable (_ done: Int64, _ total: Int64?) -> Void)
        async throws(TransferError) -> Downloaded
    {
        var request = request
        if let resume, resume.offset > 0 {
            request.setValue("bytes=\(resume.offset)-", forHTTPHeaderField: "Range")
            request.setValue(resume.etag, forHTTPHeaderField: "If-Range")
        }
        let sink = DownloadSink(file: file, resumeOffset: resume?.offset ?? 0, validator: validator, progress: progress)
        let result = await run(session.dataTask(with: request), handler: StreamingDelegate.Handler(
            response: { sink.begin($0) },
            data: { sink.write($0) },
            sent: { _, _ in },
            complete: { _ in }))
        sink.close()
        switch result {
        case .failure(let error):
            throw sink.failure ?? error
        case .success(let response):
            if let failure = sink.failure { throw failure }
            switch response.statusCode {
            case 200, 206:
                return Downloaded(length: sink.written, etag: sink.etag, resumed: response.statusCode == 206)
            case 416 where resume != nil:
                // Nothing after the offset: complete when the node's length is what's on disk.
                if let total = Self.totalLength(contentRange: response.value(forHTTPHeaderField: "Content-Range")),
                   total == resume?.offset {
                    return Downloaded(length: total, etag: resume?.etag, resumed: true)
                }
                throw .status(416, "The download couldn't be resumed. Try again.")
            default:
                throw TransferError.answer(status: response.statusCode, body: sink.errorBody, isDirectory: isDirectory)
            }
        }
    }

    /// The resume point of a partial download: its length on disk, with the validator of the answer it came from.
    public static func resumeState(of file: URL, etag: String?) -> Resume? {
        guard let etag, !etag.isEmpty, !etag.hasPrefix("W/"),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false)))?[.size]
                as? Int64, size > 0
        else { return nil }
        return Resume(offset: size, etag: etag)
    }

    static func totalLength(contentRange: String?) -> Int64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Ranges

    /// What a ranged GET (``fetchRange(_:range:ifRange:into:acceptWhole:progress:)``) got.
    public enum RangeAnswer: Hashable, Sendable {
        /// 206: `length` bytes written at `offset` of the file; `total` is the representation's length
        /// (`Content-Range`), `etag` its validator.
        case partial(offset: Int64, length: Int64, total: Int64?, etag: String?)
        /// 200 accepted (`acceptWhole`): the whole representation, written from offset 0.
        case whole(length: Int64, etag: String?)
        /// 200 refused: the validator didn't match (`If-Range`), so the node sent the whole representation, and only
        /// the asked-for version would do. Nothing was written; the transfer was stopped at its first byte.
        case changed(etag: String?)
        /// 416: nothing at that offset any more (the file shrank).
        case unsatisfiable(total: Int64?)
    }

    /// GETs `range` of `request`'s representation into `file` at the same offset (creating it, sparse, when missing),
    /// with `If-Range: ifRange` when given, so a changed file never mixes into the bytes already there. A 200 (the
    /// validator didn't match, or the node ignored the range) is written from offset 0 when `acceptWhole`, and
    /// stopped otherwise. Other answers outside 2xx throw.
    public func fetchRange(_ request: URLRequest, range: ClosedRange<Int64>, ifRange: String?, into file: URL,
                           acceptWhole: Bool,
                           progress: @escaping @Sendable (_ done: Int64, _ total: Int64?) -> Void = { _, _ in })
        async throws(TransferError) -> RangeAnswer
    {
        var request = request
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        if let ifRange { request.setValue(ifRange, forHTTPHeaderField: "If-Range") }
        let sink = RangeSink(file: file, offset: range.lowerBound, acceptWhole: acceptWhole, progress: progress)
        let result = await run(session.dataTask(with: request), handler: StreamingDelegate.Handler(
            response: { sink.begin($0) },
            data: { sink.write($0) },
            sent: { _, _ in },
            complete: { _ in },
            admit: { sink.admits($0) }))
        sink.close()
        if sink.refusedWhole { return .changed(etag: sink.etag) }
        switch result {
        case .failure(let error):
            throw sink.failure ?? error
        case .success(let response):
            if let failure = sink.failure { throw failure }
            switch response.statusCode {
            case 206:
                return .partial(offset: range.lowerBound, length: sink.written, total: sink.total, etag: sink.etag)
            case 200:
                return .whole(length: sink.written, etag: sink.etag)
            case 416:
                return .unsatisfiable(total: Self.totalLength(contentRange: response.value(forHTTPHeaderField: "Content-Range")))
            default:
                throw TransferError.answer(status: response.statusCode, body: sink.errorBody)
            }
        }
    }

    // MARK: - Upload

    /// Sends `file` as the body of `request` (a PUT), reporting the bytes sent. Returns the answer's body and response,
    /// whatever its status.
    public func upload(_ request: URLRequest, fromFile file: URL,
                       progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void)
        async throws(TransferError) -> (Data, HTTPURLResponse)
    {
        let body = Mutex(Data())
        let result = await run(session.uploadTask(with: request, fromFile: file), handler: StreamingDelegate.Handler(
            response: { _ in },
            data: { chunk in body.withLock { if $0.count < 65536 { $0.append(chunk) } } },
            sent: progress,
            complete: { _ in }))
        switch result {
        case .success(let response): return (body.withLock { $0 }, response)
        case .failure(let error):
            if case .connection = error,
               !FileManager.default.isReadableFile(atPath: file.path(percentEncoded: false)) {
                throw .disk("\(file.lastPathComponent) can't be read")
            }
            throw error
        }
    }

    // MARK: - Running tasks

    private func run(_ task: URLSessionTask, handler: StreamingDelegate.Handler)
        async -> Result<HTTPURLResponse, TransferError>
    {
        let box = TaskBox(task)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<HTTPURLResponse, TransferError>, Never>) in
                var handler = handler
                let inner = handler.complete
                handler.complete = { [delegate, box] error in
                    inner(error)
                    if let error {
                        continuation.resume(returning: .failure(delegate.classify(error)))
                    } else if let response = box.task.response as? HTTPURLResponse {
                        continuation.resume(returning: .success(response))
                    } else {
                        continuation.resume(returning: .failure(.unexpectedAnswer("not HTTP")))
                    }
                }
                delegate.register(box.task.taskIdentifier, handler)
                if Task.isCancelled { box.task.cancel() }
                box.task.resume()
            }
        } onCancel: {
            box.task.cancel()
        }
    }
}

/// A `URLSessionTask` handed to a cancellation handler (URLSession's tasks are thread-safe).
private final class TaskBox: @unchecked Sendable {
    let task: URLSessionTask
    init(_ task: URLSessionTask) { self.task = task }
}

/// Writes a download's body to disk as it arrives. Called on the session's serial delegate queue.
private final class DownloadSink: @unchecked Sendable {
    private let file: URL
    private let resumeOffset: Int64
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let validator: @Sendable (String?) -> Void
    private var handle: FileHandle?
    private(set) var written: Int64 = 0
    private(set) var etag: String?
    private(set) var failure: TransferError?
    private(set) var errorBody = Data()
    private var total: Int64?
    private var isError = false
    private var lastReport = ContinuousClock.now

    init(file: URL, resumeOffset: Int64, validator: @escaping @Sendable (String?) -> Void,
         progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.file = file
        self.resumeOffset = resumeOffset
        self.validator = validator
        self.progress = progress
    }

    func begin(_ response: HTTPURLResponse) {
        guard (200..<300).contains(response.statusCode) else {
            isError = true
            return
        }
        etag = response.value(forHTTPHeaderField: "ETag")
        validator(etag)
        let length = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        let manager = FileManager.default
        let path = file.path(percentEncoded: false)
        do {
            if response.statusCode == 206, resumeOffset > 0 {
                guard manager.fileExists(atPath: path) else { throw CocoaError(.fileNoSuchFile) }
                let opened = try FileHandle(forWritingTo: file)
                try opened.truncate(atOffset: UInt64(resumeOffset))
                try opened.seekToEnd()
                handle = opened
                written = resumeOffset
                total = length.map { $0 + resumeOffset }
                    ?? DeviceTransferClient.totalLength(contentRange: response.value(forHTTPHeaderField: "Content-Range"))
            } else {
                // A whole answer: start the file over (the content changed, or the node ignored the range).
                guard manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                handle = try FileHandle(forWritingTo: file)
                written = 0
                total = length
            }
            progress(written, total)
        } catch {
            failure = .disk(error.localizedDescription)
        }
    }

    func write(_ data: Data) {
        if isError {
            if errorBody.count < 65536 { errorBody.append(data) }
            return
        }
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            let now = ContinuousClock.now
            if now - lastReport >= .milliseconds(100) {
                lastReport = now
                progress(written, total)
            }
        } catch {
            failure = .disk(error.localizedDescription)
        }
    }

    func close() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        if failure == nil, !isError { progress(written, total) }
    }
}

/// Writes a ranged answer's body at its offset of a file (``DeviceTransferClient/fetchRange``). Called on the
/// session's serial delegate queue.
private final class RangeSink: @unchecked Sendable {
    private let file: URL
    private let offset: Int64
    private let acceptWhole: Bool
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var handle: FileHandle?
    private var isError = false
    private(set) var written: Int64 = 0
    private(set) var total: Int64?
    private(set) var etag: String?
    private(set) var failure: TransferError?
    private(set) var errorBody = Data()
    private(set) var refusedWhole = false

    init(file: URL, offset: Int64, acceptWhole: Bool, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.file = file
        self.offset = offset
        self.acceptWhole = acceptWhole
        self.progress = progress
    }

    func admits(_ response: HTTPURLResponse) -> Bool {
        !(response.statusCode == 200 && !acceptWhole)
    }

    func begin(_ response: HTTPURLResponse) {
        etag = response.value(forHTTPHeaderField: "ETag")
        switch response.statusCode {
        case 206:
            total = DeviceTransferClient.totalLength(contentRange: response.value(forHTTPHeaderField: "Content-Range"))
            open(at: offset, truncate: false)
        case 200 where acceptWhole:
            total = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            open(at: 0, truncate: true)
        case 200:
            refusedWhole = true
        default:
            isError = true
        }
    }

    private func open(at position: Int64, truncate: Bool) {
        let path = file.path(percentEncoded: false)
        do {
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
                else { throw CocoaError(.fileWriteUnknown) }
            }
            let opened = try FileHandle(forWritingTo: file)
            if truncate { try opened.truncate(atOffset: 0) }
            try opened.seek(toOffset: UInt64(position))
            handle = opened
        } catch {
            failure = .disk(error.localizedDescription)
        }
    }

    func write(_ data: Data) {
        if isError {
            if errorBody.count < 65536 { errorBody.append(data) }
            return
        }
        guard failure == nil, let handle else { return }
        do {
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            progress(written, total)
        } catch {
            failure = .disk(error.localizedDescription)
        }
    }

    func close() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }
}

/// The streaming session's delegate: TLS challenges through ``TrustDelegate``, everything else to the task's
/// handler. URLSession calls it on one serial queue.
final class StreamingDelegate: NSObject, URLSessionDataDelegate, Sendable {
    struct Handler: Sendable {
        var response: @Sendable (HTTPURLResponse) -> Void
        var data: @Sendable (Data) -> Void
        var sent: @Sendable (Int64, Int64) -> Void
        var complete: @Sendable ((any Error)?) -> Void
        /// Whether to take the response's body; false cancels the task (it completes as cancelled).
        var admit: @Sendable (HTTPURLResponse) -> Bool = { _ in true }
    }

    private let trust: TrustDelegate
    private let handlers = Mutex<[Int: Handler]>([:])

    init(trust: TrustDelegate) {
        self.trust = trust
    }

    func register(_ id: Int, _ handler: Handler) {
        handlers.withLock { $0[id] = handler }
    }

    private func handler(_ id: Int) -> Handler? {
        handlers.withLock { $0[id] }
    }

    func classify(_ error: any Error) -> TransferError {
        if let error = error as? URLError { return TransferError(trust.classify(error)) }
        if error is CancellationError { return .cancelled }
        return .connection(error.localizedDescription)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        await trust.urlSession(session, didReceive: challenge)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse)
        async -> URLSession.ResponseDisposition
    {
        guard let http = response as? HTTPURLResponse, let handler = handler(dataTask.taskIdentifier) else { return .allow }
        handler.response(http)
        return handler.admit(http) ? .allow : .cancel
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(dataTask.taskIdentifier)?.data(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        handler(task.taskIdentifier)?.sent(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let handler = handlers.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        handler?.complete(error)
    }
}
