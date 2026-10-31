public import Foundation
public import VHContract

/// The lanes a replica needs beyond the browser's (the Finder integration, desktop#4): a byte range of one version of
/// a file (`/download/content` with `Range` and `If-Range`), and the conditional create/replace lane
/// (`PUT /upload/content` with `If-None-Match: *` or `If-Match`, vaulthalla/server#258). The node decides everything:
/// whether the caller may, whether the version still matches, whether there is room. These calls only say what it
/// answered.
extension VaultLanes {
    // MARK: - Ranges

    /// GETs `range` of the file at `path` into `file` at the same offset, only while the file is still the version
    /// `contentVersion` (its strong ETag, sent as `If-Range`). See ``DeviceTransferClient/fetchRange``: a changed file
    /// comes back as `.whole` when `acceptWhole`, else as `.changed` with nothing written.
    public func downloadRange(vaultID: Int64, path: String, range: ClosedRange<Int64>, contentVersion: String?,
                              into file: URL, acceptWhole: Bool,
                              progress: @escaping @Sendable (_ done: Int64, _ total: Int64?) -> Void = { _, _ in })
        async throws(TransferError) -> DeviceTransferClient.RangeAnswer
    {
        let request = URLRequest(url: try url("/download/content", [
            .init(name: "vault_id", value: String(vaultID)), .init(name: "path", value: path),
            .init(name: "disposition", value: "attachment"),
        ]))
        // Only a strong validator can guard a range (the node compares strong ETags only, and so does RFC 9110).
        let validator = contentVersion.flatMap { $0.hasPrefix("\"") ? $0 : nil }
        return try await transfers.fetchRange(request, range: range, ifRange: validator, into: file,
                                              acceptWhole: acceptWhole || validator == nil, progress: progress)
    }

    // MARK: - Conditional writes

    /// What a `PUT /upload/content` may only do.
    public enum ContentPrecondition: Hashable, Sendable {
        /// Create the file; refused when anything is at the path (`If-None-Match: *`).
        case create
        /// Replace the file while it is still this version, its `content_version` (`If-Match`).
        case replace(contentVersion: String)
    }

    /// What the node did with a conditional write.
    public enum ContentWrite: Hashable, Sendable {
        /// Committed (201 created, 200 replaced): the file's entry as the node now has it, and its new ETag.
        case committed(created: Bool, entry: WsModel.FsEntryBase?, etag: String?)
        /// 412: the precondition failed. Another write got there first (a stale `If-Match`, a file already at the path
        /// on create, or the file is open through the node's mounted filesystem). `currentVersion` is the file's
        /// version now, when the node said. Nothing was written.
        case conflict(currentVersion: String?)
    }

    /// Sends `file` as the new content of `path`, only under `precondition`. On a node with resumable uploads
    /// (``VaultLanes/Features/resumableUploads``) a file larger than ``VaultLanes/Policy/resumableThreshold`` goes as a
    /// single-file resumable session carrying the precondition (`if_none_match: "*"` or `if_match`), whose parts are
    /// retried within this call; anything else is one `PUT /upload/content`, never retried here: whether a write whose
    /// answer was lost committed is for the caller to find out. A 409 (something that is not a file is at the path)
    /// throws ``TransferError/alreadyExists``; a 413 for room in the vault ``TransferError/quotaExceeded``; other
    /// refusals ``TransferError/status(_:_:)`` or the shared mappings.
    public func putContent(vaultID: Int64, path: String, from file: URL, precondition: ContentPrecondition,
                           mimeType: String? = nil,
                           progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void = { _, _ in })
        async throws(TransferError) -> ContentWrite
    {
        if features.resumableUploads, let size = SourceIdentity.of(file)?.size, size > policy.resumableThreshold {
            return try await putResumable(vaultID: vaultID, path: path, from: file, size: size,
                                          precondition: precondition, mimeType: mimeType, progress: progress)
        }
        var request = URLRequest(url: try url("/upload/content", [
            .init(name: "vault_id", value: String(vaultID)), .init(name: "path", value: path),
        ]))
        request.httpMethod = "PUT"
        request.setValue(mimeType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        switch precondition {
        case .create: request.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .replace(let version): request.setValue(version, forHTTPHeaderField: "If-Match")
        }
        let (body, response) = try await transfers.upload(request, fromFile: file, progress: progress)
        return try Self.contentWrite(status: response.statusCode, body: body,
                                     etag: response.value(forHTTPHeaderField: "ETag"))
    }

    /// ``putContent(vaultID:path:from:precondition:mimeType:progress:)`` as a single-file resumable session. A
    /// precondition that fails at create (412) or at commit (`precondition_failed`) is ``ContentWrite/conflict(currentVersion:)``,
    /// as on `PUT /upload/content`. The session is deleted when the write can't complete; its parts are retried within
    /// the call, and the whole session resumes from the node's status after a dropped connection.
    private func putResumable(vaultID: Int64, path: String, from file: URL, size: Int64,
                              precondition: ContentPrecondition, mimeType: String?,
                              progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void)
        async throws(TransferError) -> ContentWrite
    {
        let precondition: UploadPrecondition = switch precondition {
        case .create: .createOnly
        case .replace(let version): .replace(version)
        }
        let target = VaultPathString.normalize(path)
        var entry = ResumableUploadRecord.File(source: file, relativePath: file.lastPathComponent, path: target,
                                               size: size, mimeType: mimeType, precondition: precondition)
        // A replica write changes one file: no restart may turn it into another version's write.
        entry.restarts = 0
        let record = ResumableUploadRecord(vaultID: vaultID, directory: VaultPathString.parent(of: target), files: [entry])
        var uploader = resumableUploader
        uploader.policy.fileRestarts = 1
        let outcome: ResumableUploader.Outcome
        do throws(TransferError) {
            var single = ResumableUploader(transfers: uploader.transfers, monitor: uploader.monitor, store: nil,
                                           policy: uploader.policy)
            single.reroute = uploader.reroute
            outcome = try await single.upload(record, progress: { progress($0.bytes, size) })
        } catch .preconditionFailed(let version) {
            return .conflict(currentVersion: version)
        }
        if let failure = outcome.failed.first {
            if case .preconditionFailed(let version) = failure.error { return .conflict(currentVersion: version) }
            throw failure.error
        }
        let committed = outcome.committed[target] ?? nil
        return .committed(created: precondition == .createOnly, entry: committed, etag: committed?.contentVersion)
    }

    /// Reads a `PUT /upload/content` answer.
    static func contentWrite(status: Int, body: Data, etag: String?) throws(TransferError) -> ContentWrite {
        struct Committed: Decodable {
            var created: Bool?
            var entry: WsModel.FsEntryBase?
        }
        struct Refused: Decodable {
            var code: String?
            var content_version: String?
        }
        switch status {
        case 200, 201:
            let answer = try? JSONDecoder().decode(Committed.self, from: body)
            return .committed(created: answer?.created ?? (status == 201), entry: answer?.entry,
                              etag: etag ?? answer?.entry?.contentVersion)
        case 412:
            let refused = try? JSONDecoder().decode(Refused.self, from: body)
            return .conflict(currentVersion: refused?.content_version ?? etag)
        case 409:
            throw .alreadyExists
        case 413:
            let text = TransferError.text(body)
            if text.lowercased().contains("space") { throw .quotaExceeded }
            throw .status(413, text.isEmpty ? "The file is larger than the server accepts." : text)
        default:
            throw TransferError.answer(status: status, body: body)
        }
    }
}
