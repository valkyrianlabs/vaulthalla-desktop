public import Foundation
import os

/// Which local file an upload is sending: its path plus size, modification time, inode and device. A file whose
/// identity changed since a part was sent is a different file, so its parts can't be resumed.
public struct SourceIdentity: Codable, Hashable, Sendable {
    public var size: Int64
    public var modifiedSeconds: Int64
    public var modifiedNanoseconds: Int64
    public var inode: UInt64
    public var device: Int64

    public init(size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64, inode: UInt64, device: Int64) {
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.inode = inode
        self.device = device
    }

    /// The identity of the file at `url` now (following a symlink), or nil when it can't be read.
    public static func of(_ url: URL) -> SourceIdentity? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return SourceIdentity(size: Int64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                              modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec), inode: UInt64(info.st_ino),
                              device: Int64(info.st_dev))
    }
}

/// What a write may only do on the server (one per file of a resumable session).
public enum UploadPrecondition: Codable, Hashable, Sendable {
    /// The target must not exist (`duplicate_policy: "reject"`, the upload session's rule).
    case reject
    /// Create only (`if_none_match: "*"`): 412 when anything is there.
    case createOnly
    /// Replace while the file is still this `content_version` (`if_match`, compare-and-swap at commit).
    case replace(String)
}

/// One resumable upload as it is persisted between runs (and app launches): the files, where each goes, the session
/// each is in, and the ranges the node acknowledged as durably stored. Paths are the user's own data: the record is
/// kept 0600 in the app's Application Support and never logged in the clear.
public struct ResumableUploadRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var vaultID: Int64
    /// The vault folder the files go into.
    public var directory: String
    public var createdAt: Date
    public var files: [File]

    public struct File: Codable, Sendable, Hashable {
        public var source: URL
        /// Relative to ``ResumableUploadRecord/directory`` ("photos/2024/a.jpg").
        public var relativePath: String
        /// The vault path it goes to.
        public var path: String
        public var size: Int64
        public var mimeType: String?
        public var precondition: UploadPrecondition
        /// The source as it was when its first byte was sent; nil before.
        public var identity: SourceIdentity?
        public var state: State
        /// Why it failed, in words.
        public var failure: String?
        /// The session it is in, and its id there.
        public var uploadID: String?
        public var fileID: String?
        /// What the node acknowledged as durably stored.
        public var stored: ByteRanges
        /// How often it started over (the source changed, the key rotated, the session expired).
        public var restarts: Int

        public enum State: String, Codable, Sendable, Hashable {
            case pending, committed, failed
        }

        public init(source: URL, relativePath: String, path: String, size: Int64, mimeType: String?,
                    precondition: UploadPrecondition) {
            self.source = source
            self.relativePath = relativePath
            self.path = path
            self.size = size
            self.mimeType = mimeType
            self.precondition = precondition
            state = .pending
            stored = ByteRanges()
            restarts = 0
        }
    }

    public init(id: UUID = UUID(), vaultID: Int64, directory: String, files: [File], createdAt: Date = Date()) {
        self.id = id
        self.vaultID = vaultID
        self.directory = directory
        self.files = files
        self.createdAt = createdAt
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Bytes the node holds: committed files whole, pending ones as acknowledged.
    public var storedBytes: Int64 {
        files.reduce(0) { total, file in
            total + (file.state == .committed ? file.size : min(file.size, file.stored.byteCount))
        }
    }

    /// The vault folders the files go into.
    public var folders: Set<String> {
        Set(files.map { VaultPathString.parent(of: $0.path) }).union([VaultPathString.normalize(directory)])
    }
}

/// Persisted resumable uploads: one JSON file per upload in `directory` (Application Support, per node), written
/// atomically with mode 0600 after each change of substance (throttled by the uploader), removed when the upload ends.
public final class ResumableStore: Sendable {
    public let directory: URL
    private let log = Logger(subsystem: "sh.vaulthalla.app", category: "resumable-store")

    public init(directory: URL) {
        self.directory = directory
    }

    private func file(_ id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString.lowercased()).json", directoryHint: .notDirectory)
    }

    public func save(_ record: ResumableUploadRecord) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(record)
            let target = file(record.id)
            try data.write(to: target, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path(percentEncoded: false))
        } catch {
            log.error("couldn't save upload \(record.id, privacy: .public): \(error.localizedDescription, privacy: .private)")
        }
    }

    public func load(_ id: UUID) -> ResumableUploadRecord? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ResumableUploadRecord.self, from: data)
    }

    /// Every persisted upload, oldest first. A file that doesn't decode is left alone (a newer build's).
    public func all() -> [ResumableUploadRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.compactMap { name -> ResumableUploadRecord? in
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))) else { return nil }
            return load(id)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }
}
