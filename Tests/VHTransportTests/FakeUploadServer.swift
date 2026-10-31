import CryptoKit
import Foundation
import Synchronization
import VHTransport

/// The daemon's resumable uploads (`/upload/sessions`, the server's docs/reference/transfer-protocol.md §3) and
/// calibration lanes (`/transfer/*`, §4) for an ``HTTPTestServer``, written from the spec: part rules checked before
/// the body is read, bodies streamed and hashed (kept only when ``State/keepBodies``), idempotent resubmits, 409
/// overlap/conflict, `max_in_flight` with 429, `Server-Timing`, files committing on their own after their last gap,
/// finish answering 409/202/200, cancel. Faults are injected per part (``Fault``).
///
/// VHNodesTests links this file (a symlink), as it does ``HTTPTestServer``.
final class FakeUploadServer: Sendable {
    /// Something to do to one part request.
    enum Fault: Sendable {
        /// Refuse before the body: 429 or 503 with `Retry-After` (seconds, fractional: the fake's own speed).
        case busy(status: Int, retryAfter: String)
        /// Read this many body bytes, then drop the connection (nothing recorded).
        case dropAfter(Int)
        /// Record the part, then close without answering (a lost answer).
        case loseAnswer
        /// Answer with another `sha256` than the bytes'.
        case wrongDigest
        /// Answer this status and error code before the body.
        case refuse(status: Int, code: String)
    }

    struct PartInfo: Sendable {
        var uploadID: String
        var fileID: String
        var offset: Int64
        var length: Int64
        /// How many requests this exact range got before this one.
        var attempt: Int
    }

    struct CommitRequest: Sendable {
        var vaultID: Int64
        var path: String
        var data: Data?
        var ifMatch: String?
        var ifNoneMatch: String?
        var duplicatePolicy: String?
    }

    enum CommitResult: Sendable {
        /// The entry as JSON (nil: `entry: null`).
        case committed(Data?)
        case failed(code: String, message: String, etag: String?)
    }

    struct File: Sendable {
        var id: String
        var path: String
        var size: Int64
        var ifMatch: String?
        var ifNoneMatch: String?
        var duplicatePolicy: String?
        var stored = ByteRanges()
        var parts: [Int64: (length: Int64, sha: String)] = [:]
        var inFlight: [Range<Int64>] = []
        var data: Data?
        var state = "receiving"
        var error: (code: String, message: String, etag: String?)?
        var entry: Data?
    }

    struct Session: Sendable {
        var id: String
        var vaultID: Int64
        var state = "open"
        var files: [File]
        var inFlight = 0
    }

    struct State: Sendable {
        var minBytes: Int64 = 1 << 20
        var maxBytes: Int64 = 512 << 20
        var defaultBytes: Int64 = 64 << 20
        var maxInFlight = 4
        var sessions: [String: Session] = [:]
        var nextID = 1
        /// Keep each file's bytes (small tests) or only hash them (benchmarks).
        var keepBodies = true
        /// How long sealing and committing take after a file's last gap.
        var commitDelay: Double = 0.02
        /// 202 answers to give before a finish may answer 200.
        var finishPending = 0
        /// Delay of every part answer, reported as `sync` in `Server-Timing` (a slow disk).
        var syncDelay: Double = 0
        /// Bytes/s the server can write; parts queue behind each other (reported as `write`). nil: unlimited.
        var diskRate: Double?
        var diskFree: UInt64 = 0
        var fault: (@Sendable (PartInfo) -> Fault?)?
        /// Run at create: a refusal of the whole session (status, code, etag).
        var createCheck: (@Sendable ([File]) -> (Int, String, String?)?)?
        var commit: @Sendable (CommitRequest) -> CommitResult = { _ in .committed(nil) }
        /// Every part request: (file, offset, length, status).
        var parts: [(file: String, offset: Int64, length: Int64, status: Int)] = []
        var attempts: [String: Int] = [:]
        var peakInFlight = 0
        var deleted: [String] = []
        var finishes = 0
        var calibration = (probes: 0, sunk: Int64(0), sourced: Int64(0))
    }

    let state = Mutex(State())
    private let queue = DispatchQueue(label: "vh.test.fake-upload")

    // MARK: Inspection

    func data(_ path: String) -> Data? {
        state.withLock { state in
            state.sessions.values.flatMap(\.files).first { $0.path == path && $0.state == "committed" }?.data
        }
    }

    var partRequests: [(file: String, offset: Int64, length: Int64, status: Int)] { state.withLock { $0.parts } }

    // MARK: Routing

    /// Streams part bodies and the calibration sink; everything else is buffered (``handle(_:)``).
    func route(_ request: HTTPTestServer.Request) -> HTTPTestServer.Plan {
        let path = request.path.split(separator: "/").map(String.init)
        if request.method == "PUT", path.count == 5, path[0] == "upload", path[1] == "sessions", path[3] == "files" {
            return part(request, uploadID: path[2], fileID: path[4])
        }
        if request.method == "POST", request.path == "/transfer/sink" {
            let length = Int64(request.header("Content-Length") ?? "") ?? 0
            let started = Mutex<UInt64?>(nil)
            return .stream(.init(chunk: { _ in
                started.withLock { $0 = $0 ?? DispatchTime.now().uptimeNanoseconds }
                return .proceed
            }, end: { [self] in
                let ms = started.withLock { $0 }.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1e6 } ?? 0
                state.withLock { $0.calibration.sunk += length }
                return Self.json(200, ["bytes": length, "server_ms": Int(ms)],
                                 headers: ["Server-Timing": String(format: "recv;dur=%.3f", ms)])
            }))
        }
        return .buffer
    }

    /// Whether this server answers `request`.
    static func serves(_ request: HTTPTestServer.Request) -> Bool {
        request.path.hasPrefix("/upload/sessions") || request.path.hasPrefix("/transfer/")
    }

    func handle(_ request: HTTPTestServer.Request) -> HTTPTestServer.Response {
        let path = request.path.split(separator: "/").map(String.init)
        switch (request.method, path.count) {
        case ("POST", 2) where request.path == "/upload/sessions": return create(request)
        case ("GET", 3) where path[1] == "sessions": return status(path[2])
        case ("POST", 4) where path[1] == "sessions" && path[3] == "finish": return finish(path[2])
        case ("DELETE", 3) where path[1] == "sessions": return cancel(path[2])
        case ("GET", 2) where request.path == "/transfer/probe":
            state.withLock { $0.calibration.probes += 1 }
            return Self.json(200, ["node_id": "fake-node", "server_time_ms": Int(Date().timeIntervalSince1970 * 1000),
                                   "capabilities": ["device.lanes.transfer", "http.upload.resumable"]])
        case ("GET", 2) where request.path == "/transfer/source":
            guard let count = Int(request.query["bytes"] ?? ""), count >= 0, count <= 256 << 20 else {
                return Self.error(400, "bad_request", "bytes")
            }
            state.withLock { $0.calibration.sourced += Int64(count) }
            return .init(status: 200, headers: ["Content-Type": "application/octet-stream"],
                         body: Data(repeating: 0x5A, count: count))
        default:
            return Self.error(404, "not_found", "Not found")
        }
    }

    // MARK: Sessions

    private func create(_ request: HTTPTestServer.Request) -> HTTPTestServer.Response {
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let vaultID = (body["vault_id"] as? NSNumber)?.int64Value,
              let files = body["files"] as? [[String: Any]], !files.isEmpty
        else { return Self.error(400, "bad_request", "Malformed session") }
        var made: [File] = []
        for file in files {
            guard let id = file["file_id"] as? String, let path = file["path"] as? String,
                  let size = (file["size"] as? NSNumber)?.int64Value
            else { return Self.error(400, "bad_request", "Malformed file") }
            let conditions = [file["duplicate_policy"], file["if_none_match"], file["if_match"]].compactMap { $0 }
            guard conditions.count <= 1 else { return Self.error(400, "bad_request", "One precondition per file") }
            if size > 68_719_476_704 { return Self.error(413, "file_too_large", "Too large") }
            made.append(File(id: id, path: path, size: size, ifMatch: file["if_match"] as? String,
                             ifNoneMatch: file["if_none_match"] as? String,
                             duplicatePolicy: file["duplicate_policy"] as? String ?? (conditions.isEmpty ? "reject" : nil)))
        }
        let (session, refusal) = state.withLock { state -> (Session?, (Int, String, String?)?) in
            if let refusal = state.createCheck?(made) { return (nil, refusal) }
            let id = "up\(state.nextID)"
            state.nextID += 1
            var session = Session(id: id, vaultID: vaultID, files: made)
            if state.keepBodies {
                for index in session.files.indices { session.files[index].data = Data(count: Int(session.files[index].size)) }
            }
            state.sessions[id] = session
            return (session, nil)
        }
        if let refusal {
            let (status, code, etag) = refusal
            var response = Self.error(status, code, code == "precondition_failed" ? "Precondition failed" : code,
                                      etag: etag)
            if let etag { response.headers["ETag"] = etag }
            return response
        }
        guard let session else { return Self.error(500, "internal", "") }
        // Empty files are complete at once.
        for file in session.files where file.size == 0 { seal(session.id, file.id) }
        return Self.json(201, state.withLock { state in Self.status(of: state.sessions[session.id]!, in: state) })
    }

    private func status(_ id: String) -> HTTPTestServer.Response {
        state.withLock { state in
            guard let session = state.sessions[id] else { return Self.error(404, "not_found", "No such upload") }
            return Self.json(200, Self.status(of: session, in: state))
        }
    }

    private func finish(_ id: String) -> HTTPTestServer.Response {
        state.withLock { state in
            state.finishes += 1
            guard let session = state.sessions[id], session.state != "cancelled" else {
                return Self.error(404, "not_found", "No such upload")
            }
            var status = Self.status(of: session, in: state)
            if session.files.contains(where: { $0.state == "receiving" }) {
                status["error"] = ["code": "incomplete", "message": "Some files are incomplete"]
                return Self.json(409, status)
            }
            if state.finishPending > 0 || session.files.contains(where: { $0.state == "sealing" || $0.state == "committing" }) {
                state.finishPending = max(0, state.finishPending - 1)
                status["state"] = "finalizing"
                return Self.json(202, status, headers: ["Retry-After": "0.05"])
            }
            let failed = session.files.contains { $0.state == "failed" }
            state.sessions[id]!.state = failed ? "failed" : "complete"
            status["state"] = failed ? "failed" : "complete"
            return Self.json(200, status)
        }
    }

    private func cancel(_ id: String) -> HTTPTestServer.Response {
        state.withLock { state in
            state.deleted.append(id)
            guard state.sessions[id] != nil else { return Self.error(404, "not_found", "No such upload") }
            state.sessions[id]!.state = "cancelled"
            return .init(status: 204)
        }
    }

    // MARK: Parts

    private func part(_ request: HTTPTestServer.Request, uploadID: String, fileID: String) -> HTTPTestServer.Plan {
        guard let lengthText = request.header("Content-Length"), let length = Int64(lengthText) else {
            return .refuse(Self.error(411, "bad_request", "Content-Length required"))
        }
        guard let offset = Int64(request.query["offset"] ?? "") else {
            return .refuse(Self.error(400, "bad_request", "offset"))
        }
        let digest = request.header("Content-Digest")
        enum Admission {
            case refuse(HTTPTestServer.Response)
            case accept(resubmit: String?, fault: Fault?)
        }
        let admission = state.withLock { state -> Admission in
            let key = "\(uploadID)/\(fileID)/\(offset)/\(length)"
            let attempt = state.attempts[key, default: 0]
            state.attempts[key] = attempt + 1
            func refuse(_ response: HTTPTestServer.Response) -> Admission {
                state.parts.append((fileID, offset, length, response.status))
                return .refuse(response)
            }
            guard var session = state.sessions[uploadID], session.state == "open",
                  let index = session.files.firstIndex(where: { $0.id == fileID })
            else { return refuse(Self.error(404, "not_found", "No such upload")) }
            let file = session.files[index]
            guard length > 0, offset >= 0, offset + length <= file.size else {
                return refuse(Self.error(400, "bad_request", "Range outside the file"))
            }
            guard length <= state.maxBytes else { return refuse(Self.error(413, "part_too_large", "Part too large")) }
            guard length >= state.minBytes || offset + length == file.size else {
                return refuse(Self.error(400, "bad_request", "Part below the minimum"))
            }
            guard file.state == "receiving" else { return refuse(Self.error(409, "file_state", file.state)) }
            guard session.inFlight < state.maxInFlight else {
                var response = Self.error(429, "too_many_parts_in_flight", "Too many parts")
                response.headers["Retry-After"] = "0.05"
                return refuse(response)
            }
            let fault = state.fault?(PartInfo(uploadID: uploadID, fileID: fileID, offset: offset, length: length,
                                              attempt: attempt))
            switch fault {
            case .busy(let status, let after)?:
                var response = Self.error(status, status == 429 ? "too_many_parts_in_flight" : "busy", "Busy")
                response.headers["Retry-After"] = after
                return refuse(response)
            case .refuse(let status, let code)?:
                return refuse(Self.error(status, code, code))
            default:
                break
            }
            let range = offset..<(offset + length)
            var resubmit: String?
            if let stored = file.parts[offset], stored.length == length {
                resubmit = stored.sha
            } else if file.stored.overlaps(range) || file.inFlight.contains(where: { $0.overlaps(range) }) {
                return refuse(Self.error(409, "part_overlap", "Overlaps another part"))
            }
            session.inFlight += 1
            session.files[index].inFlight.append(range)
            state.peakInFlight = max(state.peakInFlight, session.inFlight)
            state.sessions[uploadID] = session
            return .accept(resubmit: resubmit, fault: fault)
        }
        guard case .accept(let resubmit, let fault) = admission else {
            if case .refuse(let response) = admission { return .refuse(response) }
            return .buffer
        }
        let range = offset..<(offset + length)
        let hasher = Mutex(SHA256())
        let received = Mutex<Int64>(0)
        let started = DispatchTime.now().uptimeNanoseconds
        let keep = state.withLock { $0.keepBodies } && resubmit == nil
        let buffer = Mutex(keep ? Data(capacity: Int(length)) : Data())
        let release: @Sendable () -> Void = { [self] in
            state.withLock { state in
                guard state.sessions[uploadID] != nil else { return }
                state.sessions[uploadID]!.inFlight -= 1
                if let index = state.sessions[uploadID]!.files.firstIndex(where: { $0.id == fileID }),
                   let at = state.sessions[uploadID]!.files[index].inFlight.firstIndex(of: range) {
                    state.sessions[uploadID]!.files[index].inFlight.remove(at: at)
                }
            }
        }
        return .stream(.init(chunk: { chunk in
            hasher.withLock { $0.update(data: chunk) }
            if keep { buffer.withLock { $0.append(chunk) } }
            let total = received.withLock { $0 += Int64(chunk.count); return $0 }
            if case .dropAfter(let limit)? = fault, total >= Int64(limit) { return .drop }
            return .proceed
        }, end: { [self] in
            release()
            let recvMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            let digestBytes = Data(hasher.withLock { $0.finalize() })
            let sha = digestBytes.map { String(format: "%02x", $0) }.joined()
            if let digest, digest != "sha-256=:\(digestBytes.base64EncodedString()):" {
                state.withLock { $0.parts.append((fileID, offset, length, 400)) }
                return Self.error(400, "digest_mismatch", "Content-Digest doesn't match")
            }
            if let resubmit {
                let status = resubmit == sha ? 200 : 409
                let response = state.withLock { state -> HTTPTestServer.Response in
                    state.parts.append((fileID, offset, length, status))
                    guard status == 200, let file = state.sessions[uploadID]?.files.first(where: { $0.id == fileID }) else {
                        return Self.error(409, "part_conflict", "Different bytes")
                    }
                    return Self.json(200, Self.ack(file, offset: offset, length: length, sha: sha))
                }
                return response
            }
            let (answer, complete, write, sync) = state.withLock { state -> ([String: Any], Bool, Double, Double) in
                guard var session = state.sessions[uploadID],
                      let index = session.files.firstIndex(where: { $0.id == fileID })
                else { return ([:], false, 0, 0) }
                session.files[index].stored.insert(range)
                session.files[index].parts[offset] = (length, sha)
                if keep, session.files[index].data != nil {
                    let bytes = buffer.withLock { $0 }
                    session.files[index].data!.replaceSubrange(Int(offset)..<Int(offset + length), with: bytes)
                }
                let complete = session.files[index].stored.contains(0..<session.files[index].size)
                if complete { session.files[index].state = "sealing" }
                state.sessions[uploadID] = session
                var write = 0.0
                if let rate = state.diskRate {
                    let now = DispatchTime.now().uptimeNanoseconds
                    state.diskFree = max(state.diskFree, now) + UInt64(Double(length) / rate * 1e9)
                    write = Double(state.diskFree - now) / 1e9
                }
                state.parts.append((fileID, offset, length, 200))
                let shown = fault.map { if case .wrongDigest = $0 { String(repeating: "0", count: 64) } else { sha } } ?? sha
                return (Self.ack(session.files[index], offset: offset, length: length, sha: shown), complete, write,
                        state.syncDelay)
            }
            if complete { schedule(uploadID, fileID) }
            var response = Self.json(200, answer, headers: [
                "Server-Timing": String(format: "recv;dur=%.3f, write;dur=%.3f, sync;dur=%.3f", recvMs, write * 1000,
                                        sync * 1000),
            ])
            let wait = write + sync
            if wait > 0 { response.delay = .milliseconds(Int64(wait * 1000)) }
            if case .loseAnswer? = fault { response.dropInsteadOfAnswering = true }
            return response
        }, abort: release))
    }

    private func schedule(_ uploadID: String, _ fileID: String) {
        let delay = state.withLock { $0.commitDelay }
        queue.asyncAfter(deadline: .now() + delay) { [self] in seal(uploadID, fileID) }
    }

    /// Sealing, then the commit with the file's precondition.
    private func seal(_ uploadID: String, _ fileID: String) {
        let (request, commit) = state.withLock { state -> (CommitRequest?, @Sendable (CommitRequest) -> CommitResult) in
            guard let session = state.sessions[uploadID],
                  let file = session.files.first(where: { $0.id == fileID })
            else { return (nil, state.commit) }
            return (CommitRequest(vaultID: session.vaultID, path: file.path, data: file.data, ifMatch: file.ifMatch,
                                  ifNoneMatch: file.ifNoneMatch, duplicatePolicy: file.duplicatePolicy), state.commit)
        }
        guard let request else { return }
        let result = commit(request)
        state.withLock { state in
            guard let index = state.sessions[uploadID]?.files.firstIndex(where: { $0.id == fileID }) else { return }
            switch result {
            case .committed(let entry):
                state.sessions[uploadID]!.files[index].state = "committed"
                state.sessions[uploadID]!.files[index].entry = entry
            case .failed(let code, let message, let etag):
                state.sessions[uploadID]!.files[index].state = "failed"
                state.sessions[uploadID]!.files[index].error = (code, message, etag)
            }
        }
    }

    // MARK: JSON

    private static func ack(_ file: File, offset: Int64, length: Int64, sha: String) -> [String: Any] {
        ["file_id": file.id, "offset": offset, "length": length, "sha256": sha,
         "received_bytes": file.stored.byteCount, "ranges": file.stored.wire, "state": file.state]
    }

    private static func status(of session: Session, in state: State) -> [String: Any] {
        [
            "upload_id": session.id, "state": session.state, "resumable": true, "expires_at": 1_893_456_000,
            "part": ["default_bytes": state.defaultBytes, "min_bytes": state.minBytes, "max_bytes": state.maxBytes,
                     "max_in_flight": state.maxInFlight],
            "files": session.files.map { file -> [String: Any] in
                var object: [String: Any] = [
                    "file_id": file.id, "path": file.path, "size": file.size, "state": file.state,
                    "received_bytes": file.stored.byteCount, "ranges": file.stored.wire,
                    "error": NSNull(), "entry": NSNull(),
                ]
                if let error = file.error {
                    var detail: [String: Any] = ["code": error.code, "message": error.message]
                    if let etag = error.etag { detail["etag"] = etag }
                    object["error"] = detail
                }
                if let entry = file.entry, let value = try? JSONSerialization.jsonObject(with: entry) {
                    object["entry"] = value
                }
                return object
            },
        ]
    }

    static func json(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> HTTPTestServer.Response {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return .init(status: status, headers: headers, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    static func error(_ status: Int, _ code: String, _ message: String, etag: String? = nil) -> HTTPTestServer.Response {
        var detail: [String: Any] = ["code": code, "message": message]
        if let etag { detail["etag"] = etag }
        return json(status, ["error": detail])
    }
}
