import CryptoKit
import Foundation

/// Moves the node registry from Application Support into the App Group container, where the sandboxed File Provider
/// extension can read it (docs/architecture.md §3, "Signing and the shared container").
///
/// **Non-destructive.** The registry is copied, the copy verified, and only then is the switch made: a marker in
/// Application Support (``RegistryPointer``) names the new location, and the old file is renamed to
/// ``RegistryEnvironment/backupName``, unchanged, as the backup. Nothing is deleted.
///
/// **Crash-safe and idempotent.** Each step is durable (`F_FULLFSYNC`, then an atomic rename) and the next launch
/// resumes from whatever state a crash left:
/// 1. copy into `nodes.json.migrating` in the group, read it back; an interrupted copy is simply redone;
/// 2. move it to `nodes.json` without replacing anything (`RENAME_EXCL`), read it back: a group registry identical to
///    the old one is a copy that got this far;
/// 3. write the marker: the switch;
/// 4. rename the old file to the backup: a leftover old file whose hash is the marker's is renamed on the next run.
///
/// **One migrator.** It runs only while the App Group's ``CredentialLease`` is held (by the owner, before it opens
/// the registry), and it takes the Application Support lease too, so neither a second new build nor a running older
/// one (which owns the old location) can write either file meanwhile. When an older build holds the old lease, the
/// migration waits for a later launch.
public enum RegistryMigration {
    public enum Outcome: Sendable, Hashable, CustomStringConvertible {
        /// No App Group (unsigned or development build): nothing to migrate from here. The registry stays in
        /// Application Support, or wherever an earlier migration's marker points.
        case unavailable
        /// Application Support has no registry: nothing to move.
        case nothingToMigrate
        case migrated(nodes: Int)
        /// A previous launch migrated it (and this one finished anything a crash left undone).
        case alreadyMigrated
        /// Another process owns the App Group's registry; that process migrates, this one reads.
        case ownedElsewhere(CredentialLease.Holder?)
        /// Another process (a Desktop build without the App Group) owns the Application Support registry: it stays
        /// there for now, and the next launch tries again.
        case deferred(CredentialLease.Holder?)
        /// Both locations hold a registry, they differ, and no migration recorded the move (the group's was started
        /// fresh, then another build wrote one in Application Support). Both are left as they are; the group's is used.
        case conflict
        /// The marker points at another container (the team changed): the old one is left alone.
        case pointsElsewhere(String)
        /// Nothing was switched; the registry stays in Application Support for now.
        case failed(String)

        public var description: String {
            switch self {
            case .unavailable: "no App Group in this build: nothing to migrate"
            case .nothingToMigrate: "nothing to migrate"
            case .migrated(let nodes): "migrated \(nodes) node\(nodes == 1 ? "" : "s") to the App Group container"
            case .alreadyMigrated: "already migrated"
            case .ownedElsewhere(let holder): "another process owns the registry\(Self.naming(holder))"
            case .deferred(let holder):
                "deferred: another process owns the Application Support registry\(Self.naming(holder))"
            case .conflict: "both locations hold a different registry; using the App Group's, leaving the other alone"
            case .pointsElsewhere(let path): "the migration marker points at \(path); leaving it alone"
            case .failed(let reason): "not migrated: \(reason)"
            }
        }

        /// Whether the App Group's registry is the one to use afterwards.
        public var usesAppGroup: Bool {
            switch self {
            case .nothingToMigrate, .migrated, .alreadyMigrated, .ownedElsewhere, .conflict, .pointsElsewhere: true
            case .unavailable, .deferred, .failed: false
            }
        }

        private static func naming(_ holder: CredentialLease.Holder?) -> String {
            holder.map { " (\($0.name), pid \($0.pid))" } ?? ""
        }
    }

    /// Migrates if needed. The caller holds `groupLease`, the App Group registry's lease; `legacyLease` (the
    /// Application Support registry's) is taken here when there is something to move, and stays held on success.
    public static func run(in environment: RegistryEnvironment, groupLease: CredentialLease,
                           legacyLease: CredentialLease) -> Outcome
    {
        guard let groupURL = environment.groupRegistryURL, let stagingURL = environment.stagingURL,
              let appGroup = environment.appGroup
        else { return .unavailable }
        guard groupLease.isHeld, groupLease.covers(registry: groupURL),
              legacyLease.covers(registry: environment.legacyRegistryURL)
        else { return .failed("the App Group registry's lease isn't held") }

        let files = FileManager.default
        let legacyURL = environment.legacyRegistryURL

        // Already switched: finish the backup rename a crash may have left undone.
        if let pointerData = try? Data(contentsOf: environment.pointerURL) {
            guard let pointer = try? RegistryPointer.decode(pointerData) else {
                return .failed("the migration marker \(environment.pointerURL.path) can't be read")
            }
            guard pointer.registryURL.standardizedFileURL.path == groupURL.standardizedFileURL.path else {
                return .pointsElsewhere(pointer.registry)
            }
            if let leftover = try? Data(contentsOf: legacyURL), sha256(leftover) == pointer.sha256,
               (try? legacyLease.acquire()) != nil
            {
                _ = try? keepAsBackup(legacyURL, environment: environment)
            }
            return .alreadyMigrated
        }

        guard files.fileExists(atPath: legacyURL.path) else { return .nothingToMigrate }
        do {
            try legacyLease.acquire()
        } catch .held(let holder) {
            return .deferred(holder)
        } catch {
            return .failed(error.description)
        }

        let original: Data
        let nodes: [Node]
        do {
            original = try Data(contentsOf: legacyURL)
            nodes = try NodeStore(fileURL: legacyURL).reload()
        } catch {
            return .failed("the registry in Application Support can't be read (\(Self.describe(error)))")
        }

        do {
            if let existing = try? Data(contentsOf: groupURL) {
                // A copy that got as far as step 2 is identical; anything else was written as the group's own.
                guard existing == original else { return .conflict }
            } else {
                try writeDurably(original, to: stagingURL)
                try verify(stagingURL, matches: original, nodes: nodes.count)
                try moveExclusively(stagingURL, to: groupURL)
            }
            try verify(groupURL, matches: original, nodes: nodes.count)
            let pointer = RegistryPointer(registry: groupURL.path(percentEncoded: false), appGroup: appGroup,
                                          sha256: sha256(original), migratedAt: .now)
            try writeDurably(pointer.encoded(), to: environment.pointerURL)
        } catch {
            return .failed(Self.describe(error))
        }
        _ = try? keepAsBackup(legacyURL, environment: environment)
        return .migrated(nodes: nodes.count)
    }

    // MARK: - Steps

    public struct StepFailure: Error, CustomStringConvertible {
        public let description: String
        /// The `errno` of a failed system call, else 0.
        public var code: Int32 = 0
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? NodeStore.Failure { return error.description }
        if let error = error as? StepFailure { return error.description }
        return error.localizedDescription
    }

    private static func verify(_ url: URL, matches original: Data, nodes: Int) throws {
        guard try Data(contentsOf: url) == original else {
            throw StepFailure(description: "the copy at \(url.path) doesn't match the original")
        }
        guard try NodeStore(fileURL: url).reload().count == nodes else {
            throw StepFailure(description: "the copy at \(url.path) doesn't hold the same nodes")
        }
    }

    /// Writes `data` to a new file beside `url`, flushes it to the disk, and renames it over `url`.
    static func writeDurably(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)",
                                            directoryHint: .notDirectory)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix("create \(temporary.path)") }
        var written = 0
        let ok = data.withUnsafeBytes { buffer -> Bool in
            while written < buffer.count {
                let count = write(fd, buffer.baseAddress! + written, buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += count
            }
            return fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
        }
        let failure = ok ? nil : posix("write \(temporary.path)")
        close(fd)
        if let failure {
            unlink(temporary.path)
            throw failure
        }
        guard rename(temporary.path, url.path) == 0 else {
            let failure = posix("rename \(temporary.path)")
            unlink(temporary.path)
            throw failure
        }
        syncDirectory(directory)
    }

    /// Renames `source` to `destination`, failing rather than replacing an existing file.
    private static func moveExclusively(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw posix("move \(source.path) to \(destination.path)")
        }
        syncDirectory(destination.deletingLastPathComponent())
    }

    /// Renames the migrated Application Support registry to the backup name (or a dated one if that is taken).
    private static func keepAsBackup(_ legacyURL: URL, environment: RegistryEnvironment) throws {
        do {
            try moveExclusively(legacyURL, to: environment.backupURL)
        } catch let failure as StepFailure where failure.code == EEXIST {
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            try moveExclusively(legacyURL, to: environment.legacyDirectory.appending(
                path: "\(RegistryEnvironment.backupName)-\(stamp)", directoryHint: .notDirectory))
        }
    }

    private static func syncDirectory(_ directory: URL) {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    private static func posix(_ what: String) -> StepFailure {
        let code = errno
        return StepFailure(description: "\(what): \(String(cString: strerror(code)))", code: code)
    }
}

/// The registry and lease the credential **owner** opens at launch (the app today, the background agent later),
/// migrating the registry into the App Group first when it can (docs/architecture.md §3).
public struct RegistryOwnership: Sendable {
    public let location: RegistryLocation
    /// The registry's lease; held unless another process owns the registry (then this process is a consumer and
    /// may take it over later).
    public let lease: CredentialLease
    public let migration: RegistryMigration.Outcome
    /// After a migration, the Application Support lease, held so a Desktop build without the App Group started
    /// alongside stays read-only on the old location. Keep it as long as `lease`.
    public let legacyLease: CredentialLease?

    /// Takes the App Group registry's lease, migrates, and returns the registry to use. Without the App Group, or
    /// when the migration can't run now, the Application Support registry (or where its marker points) as before.
    public static func open(in environment: RegistryEnvironment, holder: String) -> RegistryOwnership {
        guard let groupURL = environment.groupRegistryURL else {
            let location = RegistryLocation.resolve(in: environment)
            let lease = CredentialLease(forRegistry: location.registryURL, holder: holder)
            try? lease.acquire()
            return RegistryOwnership(location: location, lease: lease, migration: .unavailable, legacyLease: nil)
        }
        let groupLocation = RegistryLocation(registryURL: groupURL, source: .appGroup)
        let groupLease = CredentialLease(forRegistry: groupURL, holder: holder)
        do {
            try groupLease.acquire()
        } catch {
            let holder: CredentialLease.Holder? = if case .held(let named) = error { named } else { nil }
            // The owner of the group's registry migrated (or is migrating) before using it.
            return RegistryOwnership(location: groupLocation, lease: groupLease,
                                     migration: .ownedElsewhere(holder), legacyLease: nil)
        }
        let legacyLease = CredentialLease(forRegistry: environment.legacyRegistryURL, holder: holder)
        let outcome = RegistryMigration.run(in: environment, groupLease: groupLease, legacyLease: legacyLease)
        if outcome.usesAppGroup {
            return RegistryOwnership(location: groupLocation, lease: groupLease, migration: outcome,
                                     legacyLease: legacyLease.isHeld ? legacyLease : nil)
        }
        // Stay where the registry is: the old location, owned if its lease is free (a failed migration took it).
        groupLease.release()
        try? legacyLease.acquire()
        return RegistryOwnership(
            location: RegistryLocation(registryURL: environment.legacyRegistryURL, source: .applicationSupport),
            lease: legacyLease, migration: outcome, legacyLease: nil)
    }
}
