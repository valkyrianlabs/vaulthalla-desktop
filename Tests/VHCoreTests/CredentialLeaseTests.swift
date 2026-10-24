import Foundation
import Testing
import VHCore

/// The credential owner lease (docs/architecture.md §3, "Credential ownership"): one holder at a time across handles
/// and processes, released when the holder exits or crashes and then taken over, and the registry read-only without
/// it.
@Suite struct CredentialLeaseTests {
    private let directory: URL
    private let registryURL: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CredentialLeaseTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        registryURL = directory.appending(path: "nodes.json")
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func node(_ name: String) -> Node {
        Node(id: NodeID(rawValue: "id-\(name)"), displayName: name, endpoint: NodeEndpoint(host: "\(name).local"))
    }

    // MARK: One holder

    @Test func twoHandlesCannotBothHoldTheLease() throws {
        defer { cleanUp() }
        let first = CredentialLease(forRegistry: registryURL, holder: "app")
        let second = CredentialLease(forRegistry: registryURL, holder: "agent")
        #expect(first.fileURL == directory.appending(path: CredentialLease.fileName))
        try first.acquire()
        try first.acquire()  // already held by this handle: nothing changes
        #expect(first.isHeld && first.role == .owner)

        #expect {
            try second.acquire()
        } throws: { error in
            guard case CredentialOwnershipError.held(let holder?) = error else { return false }
            return holder.name == "app" && holder.pid == getpid()
        }
        #expect(!second.isHeld && second.role == .consumer)

        // Released: the other handle takes it over, and the first can't take it back.
        first.release()
        #expect(!first.isHeld)
        try second.acquire()
        #expect(second.currentHolder()?.name == "agent")
        #expect(throws: CredentialOwnershipError.self) { try first.acquire() }
        second.release()
        #expect(second.currentHolder() == nil, "a released lease names no holder")
    }

    @Test func aDeallocatedHolderReleasesTheLease() throws {
        defer { cleanUp() }
        var holder: CredentialLease? = CredentialLease(forRegistry: registryURL, holder: "app")
        try holder?.acquire()
        let waiting = CredentialLease(forRegistry: registryURL, holder: "agent")
        #expect(throws: CredentialOwnershipError.self) { try waiting.acquire() }
        holder = nil
        try waiting.acquire()
        #expect(waiting.isHeld)
    }

    // MARK: Across processes

    /// `lockf(1)` takes the same BSD `flock` lock on the lease file, as another owner process would.
    static let lockf = URL(filePath: "/usr/bin/lockf")
    static var hasLockf: Bool { FileManager.default.isExecutableFile(atPath: lockf.path) }

    /// Starts a process that holds the lease file's lock while it runs `command`, and waits until it holds it.
    private func otherOwner(_ lease: CredentialLease, running command: [String]) async throws -> Process {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = Self.lockf
        process.arguments = ["-k", "-s", lease.fileURL.path] + command
        try process.run()
        let probe = CredentialLease(fileURL: lease.fileURL, holder: "probe")
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            do {
                // Not held yet: let go at once so the other process gets it.
                try probe.acquire()
                probe.release()
            } catch {
                return process
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        process.terminate()
        throw CancellationError()
    }

    @Test(.enabled(if: hasLockf, "needs /usr/bin/lockf"), .timeLimit(.minutes(1)))
    func anotherProcessExcludesThisOneUntilItCrashes() async throws {
        defer { cleanUp() }
        let lease = CredentialLease(forRegistry: registryURL, holder: "app")
        let other = try await otherOwner(lease, running: ["/bin/sleep", "60"])
        defer { if other.isRunning { other.terminate() } }

        #expect(throws: CredentialOwnershipError.self) { try lease.acquire() }
        #expect(NodeStore(fileURL: registryURL, lease: lease).role == .consumer)
        // A takeover waits for the holder; it never steals the lease from a running one.
        await #expect(throws: CredentialOwnershipError.self) {
            try await lease.acquire(waitingUpTo: .milliseconds(300), checkingEvery: .milliseconds(20))
        }

        // The owner crashes (SIGKILL: no cleanup of its own). The kernel drops its lock and the lease is taken over.
        kill(other.processIdentifier, SIGKILL)
        try await lease.acquire(waitingUpTo: .seconds(5), checkingEvery: .milliseconds(20))
        #expect(lease.isHeld)
        other.waitUntilExit()
    }

    @Test(.enabled(if: hasLockf, "needs /usr/bin/lockf"), .timeLimit(.minutes(1)))
    func aLeaseFreedByAnExitingOwnerIsTakenOver() async throws {
        defer { cleanUp() }
        let lease = CredentialLease(forRegistry: registryURL, holder: "agent")
        let other = try await otherOwner(lease, running: ["/bin/sleep", "1"])
        defer { if other.isRunning { other.terminate() } }
        #expect(throws: CredentialOwnershipError.self) { try lease.acquire() }
        try await lease.acquire(waitingUpTo: .seconds(10), checkingEvery: .milliseconds(50))
        #expect(lease.isHeld)
        other.waitUntilExit()
        #expect(other.terminationStatus == 0)
    }

    @Test(.enabled(if: hasLockf, "needs /usr/bin/lockf"), .timeLimit(.minutes(1)))
    func anotherProcessCantTakeAHeldLease() async throws {
        defer { cleanUp() }
        let lease = CredentialLease(forRegistry: registryURL, holder: "app")
        try lease.acquire()
        let other = Process()
        other.executableURL = Self.lockf
        other.arguments = ["-k", "-s", "-t", "0", lease.fileURL.path, "/usr/bin/true"]
        try other.run()
        other.waitUntilExit()
        #expect(other.terminationStatus == 75, "lockf exits EX_TEMPFAIL when it can't take the lock")
    }

    // MARK: The registry follows the lease

    @Test func theRegistryIsReadOnlyWithoutTheLease() throws {
        defer { cleanUp() }
        let lease = CredentialLease(forRegistry: registryURL, holder: "app")
        try lease.acquire()
        let owner = NodeStore(fileURL: registryURL, lease: lease)
        #expect(owner.role == .owner)
        try owner.add(node("a"))

        // A consumer reads what the owner wrote and can't change it.
        let consumer = NodeStore(fileURL: registryURL)
        #expect(consumer.role == .consumer)
        #expect(try consumer.load().map(\.displayName) == ["a"])
        let saved = try Data(contentsOf: registryURL)
        #expect(throws: NodeStore.Failure.notOwner) { try consumer.add(node("b")) }
        #expect(throws: NodeStore.Failure.notOwner) { try consumer.update(node("a")) }
        #expect(throws: NodeStore.Failure.notOwner) { try consumer.remove(NodeID(rawValue: "id-a")) }
        #expect(throws: NodeStore.Failure.notOwner) { try consumer.reorder([]) }
        #expect(throws: NodeStore.Failure.notOwner) { try consumer.move(NodeID(rawValue: "id-a"), to: 0) }
        #expect(try Data(contentsOf: registryURL) == saved)

        // It sees the owner's later changes on reload.
        try owner.add(node("c"))
        #expect(try consumer.reload().map(\.displayName) == ["a", "c"])

        // An owner that lets go stops writing at once.
        lease.release()
        #expect(owner.role == .consumer)
        #expect(throws: NodeStore.Failure.notOwner) { try owner.add(node("d")) }
    }

    @Test func aLeaseOnlyOpensItsOwnRegistry() throws {
        defer { cleanUp() }
        let elsewhere = CredentialLease(forRegistry: directory.appending(path: "other/nodes.json"), holder: "app")
        try elsewhere.acquire()
        #expect(!elsewhere.covers(registry: registryURL))
        let store = NodeStore(fileURL: registryURL, lease: elsewhere)
        #expect(store.role == .consumer)
        #expect(throws: NodeStore.Failure.notOwner) { try store.add(node("a")) }
        #expect(!FileManager.default.fileExists(atPath: registryURL.path))
    }
}
