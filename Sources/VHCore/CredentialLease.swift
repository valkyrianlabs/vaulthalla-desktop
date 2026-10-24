public import Foundation
import Synchronization

/// What a process may do with this Mac's device credentials and the node registry (docs/architecture.md §3,
/// "Credential ownership").
public enum CredentialRole: String, Sendable, Hashable, Codable {
    /// Holds the ``CredentialLease``: the only process that creates, rotates or deletes device keys and writes the
    /// registry (pairing outcomes, rotated device ids, server pin announcements and promotions, revocations, edits).
    case owner
    /// Reads the keys and the registry the owner maintains, reloads them when a node refuses the key it presented,
    /// and never changes either.
    case consumer
}

/// Why a process can't own the credentials, or may not do something only the owner does.
public enum CredentialOwnershipError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Another process (or another lease handle) holds the lease.
    case held(by: CredentialLease.Holder?)
    /// The lease file can't be opened or locked.
    case unavailable(String)
    /// The operation creates, rotates or deletes a device key, or writes the registry, and this process is a
    /// consumer.
    case notOwner(operation: String)

    public var description: String {
        switch self {
        case .held(let holder):
            if let holder {
                "Another Vaulthalla process (\(holder.name), pid \(holder.pid)) manages this Mac's device keys."
            } else {
                "Another Vaulthalla process manages this Mac's device keys."
            }
        case .unavailable(let reason): "The device key lease can't be taken: \(reason)"
        case .notOwner(let operation):
            "This process can't \(operation): another Vaulthalla process manages this Mac's device keys."
        }
    }
}

/// The exclusive lease that makes one process the owner of this Mac's device credentials and node registry.
///
/// It is a BSD `flock(2)` exclusive lock on a small file next to the registry (``fileURL(forRegistry:)``), taken
/// without waiting. The kernel ties the lock to the open file, so it is released when the holder calls ``release()``,
/// is deallocated, exits or crashes; there is no stale lease to clean up, and the file is never deleted (deleting a
/// lock file lets two processes lock different files). Two handles conflict even within one process. The file is
/// opened close-on-exec, so helpers the owner launches don't inherit the lease.
///
/// The lease moves with the registry: when the registry moves (to an App Group container, so the File Provider
/// extension can read it), the lease file moves with it, and every process that agrees on the registry agrees on the
/// lease. Which process tries to take it is the caller's choice: today the app; the background agent once it ships.
///
/// A handle starts unheld. ``NodeStore`` and `DeviceKeys` hold a handle and check ``isHeld`` before every change, so
/// a process that takes the lease later (a takeover after the owner exited) becomes the owner without being rebuilt,
/// and one that releases it stops changing anything at once.
public final class CredentialLease: Sendable {
    /// Who holds the lease, as the holder wrote it into the file after taking it (diagnostics only: the lock, not the
    /// file's contents, is the lease).
    public struct Holder: Codable, Hashable, Sendable {
        /// The holder's role name: `app`, `agent`, or a test's.
        public var name: String
        public var pid: Int32
        public var since: Date

        public init(name: String, pid: Int32, since: Date) {
            self.name = name
            self.pid = pid
            self.since = since
        }
    }

    public static let fileName = "credential-owner.lease"

    public let fileURL: URL
    /// The name this handle records as the holder when it takes the lease.
    public let holderName: String

    /// The locked descriptor while the lease is held.
    private let descriptor = Mutex<Int32?>(nil)

    public init(fileURL: URL, holder: String) {
        self.fileURL = fileURL
        self.holderName = holder
    }

    /// A handle for the lease of the registry at `registryURL`.
    public convenience init(forRegistry registryURL: URL, holder: String) {
        self.init(fileURL: Self.fileURL(forRegistry: registryURL), holder: holder)
    }

    deinit {
        release()
    }

    /// The lease file of the registry at `registryURL`: `credential-owner.lease` in the same directory.
    public static func fileURL(forRegistry registryURL: URL) -> URL {
        registryURL.deletingLastPathComponent().appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Whether this is the lease of the registry at `registryURL`.
    public func covers(registry registryURL: URL) -> Bool {
        fileURL.standardizedFileURL.path == Self.fileURL(forRegistry: registryURL).standardizedFileURL.path
    }

    public var isHeld: Bool {
        descriptor.withLock { $0 != nil }
    }

    public var role: CredentialRole {
        isHeld ? .owner : .consumer
    }

    /// Takes the lease now, or throws ``CredentialOwnershipError/held(by:)`` if another process or handle holds it.
    /// Taking a lease this handle already holds does nothing.
    public func acquire() throws(CredentialOwnershipError) {
        let result: Result<Void, CredentialOwnershipError> = descriptor.withLock { held in
            if held != nil { return .success(()) }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                return .failure(.unavailable("its folder can't be created (\(error.localizedDescription))"))
            }
            let fd = open(fileURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return .failure(.unavailable(String(cString: strerror(errno)))) }
            var status: Int32
            repeat { status = flock(fd, LOCK_EX | LOCK_NB) } while status != 0 && errno == EINTR
            guard status == 0 else {
                let code = errno
                close(fd)
                if code == EWOULDBLOCK { return .failure(.held(by: nil)) }
                return .failure(.unavailable(String(cString: strerror(code))))
            }
            Self.record(Holder(name: holderName, pid: getpid(), since: .now), in: fd)
            held = fd
            return .success(())
        }
        switch result {
        case .success: return
        case .failure(.held): throw .held(by: currentHolder())
        case .failure(let error): throw error
        }
    }

    /// Takes the lease once its holder lets go (releases it, exits or crashes), checking every `interval`; throws
    /// ``CredentialOwnershipError/held(by:)`` if it is still held after `timeout`. A takeover, not a steal: a
    /// running holder keeps it.
    public func acquire(waitingUpTo timeout: Duration, checkingEvery interval: Duration = .milliseconds(100))
        async throws(CredentialOwnershipError)
    {
        let deadline = ContinuousClock.now + timeout
        while true {
            do {
                return try acquire()
            } catch .held(let holder) {
                guard ContinuousClock.now < deadline, !Task.isCancelled else { throw .held(by: holder) }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Lets go of the lease. The file stays.
    public func release() {
        descriptor.withLock { held in
            guard let fd = held else { return }
            // Name no holder once nobody holds it (a crashed holder's record stays, but its lock doesn't).
            _ = ftruncate(fd, 0)
            flock(fd, LOCK_UN)
            close(fd)
            held = nil
        }
    }

    /// The holder the lease file names. That is who holds the lease only while someone does; for diagnostics.
    public func currentHolder() -> Holder? {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Holder.self, from: data)
    }

    private static func record(_ holder: Holder, in fd: Int32) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(holder) else { return }
        guard ftruncate(fd, 0) == 0 else { return }
        _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    }
}
