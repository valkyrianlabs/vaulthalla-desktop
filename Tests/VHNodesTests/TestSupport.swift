import Foundation
import Security
import Synchronization
import Testing
import VHCore
import VHIdentity
@testable import VHNodes

/// Keychain hygiene, as in VHIdentityTests: every store gets a namespace unique to the run, tests only ever touch
/// the node tags below in it, and everything is deleted afterwards, also on failure. Nothing enumerates or prints
/// other Keychain items.
enum TestKeychain {
    /// Node tags tests may use; cleanup deletes all of them.
    static let nodeTags = ["node-a", "node-r", "daemon", "daemon-next"]

    static func namespace() -> String { "sh.vaulthalla.app.test.\(UUID().uuidString.lowercased())" }

    /// Runs `body` with a file-keychain store (the data protection keychain needs entitlements `swift test` lacks),
    /// holding the process-wide keychain lock, and deletes everything under the namespace afterwards.
    static func withStore<R: Sendable>(_ body: (DeviceIdentityStore) async throws -> R) async throws -> R {
        await KeychainLock.shared.acquire()
        let store = DeviceIdentityStore(configuration: .init(namespace: namespace(), keychain: .fileBased))
        do {
            let result = try await body(store)
            try await cleanUp(store)
            await KeychainLock.shared.release()
            return result
        } catch {
            try? await cleanUp(store)
            await KeychainLock.shared.release()
            throw error
        }
    }

    static func cleanUp(_ store: DeviceIdentityStore) async throws {
        for tag in nodeTags {
            do {
                try await store.deleteIdentity(for: tag)
            } catch IdentityError.missingEntitlement {
                return  // nothing could have been created
            }
        }
    }

    /// True when this process may use the data protection keychain (see VHIdentityTests): a delete of a random,
    /// never-written tag can't match anything, and an unsigned runner gets `errSecMissingEntitlement`.
    static var dataProtectionKeychainAvailable: Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: Data(namespace().utf8),
            kSecUseDataProtectionKeychain: true,
        ]
        return SecItemDelete(query as CFDictionary) != errSecMissingEntitlement
    }
}

/// Identities shared by every test in ``KeychainSuite``: creating one costs about a third of a second in the file
/// keychain, so the ones no test changes are made once. Tests that change a key (rotation) make their own under
/// "node-r" and delete it.
struct KeychainFixture: Sendable {
    let store: DeviceIdentityStore
    /// The mock daemon's server key.
    let server: DeviceIdentity
    /// A second server key: the announced next key, or an impostor.
    let otherServer: DeviceIdentity
    /// This Mac's key for "node-a".
    let device: DeviceIdentity

    @TaskLocal static var current: KeychainFixture?

    static func require() throws -> KeychainFixture {
        guard let current else { throw TestFailure("run inside KeychainSuite (the .sharedKeychain trait)") }
        return current
    }
}

/// Holds the keychain lock around a whole suite, with ``KeychainFixture`` set, and deletes everything afterwards.
struct SharedKeychain: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await TestKeychain.withStore { store in
            let fixture = KeychainFixture(
                store: store,
                server: try await store.createIdentity(for: "daemon", deviceName: "Server", backend: .software),
                otherServer: try await store.createIdentity(for: "daemon-next", deviceName: "Server 2",
                                                            backend: .software),
                device: try await store.createIdentity(for: "node-a", deviceName: "Test Mac", backend: .software))
            try await KeychainFixture.$current.withValue(fixture) { try await function() }
        }
    }
}

extension Trait where Self == SharedKeychain {
    static var sharedKeychain: Self { SharedKeychain() }
}

/// Every VHNodes test that touches the Keychain runs in here, one at a time.
@Suite(.serialized, .sharedKeychain, .timeLimit(.minutes(1))) struct KeychainSuite {}

/// The keychain lock shared with VHIdentityTests: a FIFO within this target, plus a lock file every target that
/// writes keys takes, because `swift test` runs all targets in one process and the file keychain fails under
/// concurrent writers.
actor KeychainLock {
    static let shared = KeychainLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let file = open(
        FileManager.default.temporaryDirectory.appending(path: "sh.vaulthalla.app.test.keychain.lock").path,
        O_CREAT | O_RDWR, 0o600)

    func acquire() async {
        if held {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            held = true
        }
        while flock(file, LOCK_EX | LOCK_NB) != 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        flock(file, LOCK_UN)
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}

/// A node registry in a directory of its own, with its credential lease held: the test is the credential owner
/// (docs/architecture.md §3). ``owner`` writes; ``consumer`` is the read-only view every other process gets.
final class TestRegistry: Sendable {
    let directory: URL
    let fileURL: URL
    let lease: CredentialLease
    let owner: NodeStore
    let consumer: NodeStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "vh-registry-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileURL = directory.appending(path: "nodes.json")
        lease = CredentialLease(forRegistry: fileURL, holder: "test")
        try lease.acquire()
        owner = NodeStore(fileURL: fileURL, lease: lease)
        consumer = NodeStore(fileURL: fileURL)
    }

    /// The owner's keys (they create, rotate and delete) and a consumer's (they only read), over one store.
    func ownerKeys(_ store: DeviceIdentityStore) -> DeviceKeys {
        DeviceKeys(primary: store, development: nil, preferredBackend: .software, lease: lease)
    }

    static func consumerKeys(_ store: DeviceIdentityStore) -> DeviceKeys {
        DeviceKeys(primary: store, development: nil, preferredBackend: .software)
    }

    func remove() {
        lease.release()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Runs `body` with a fresh registry, removed afterwards (also on failure).
    static func with<R>(_ body: (TestRegistry) async throws -> R) async throws -> R {
        let registry = try TestRegistry()
        defer { registry.remove() }
        return try await body(registry)
    }
}

/// Collects a stream's elements so a test can wait for one that matches.
final class Recorder<Element: Sendable>: Sendable {
    private final class Storage: Sendable {
        let items = Mutex<[Element]>([])
    }

    private let storage = Storage()
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<Element>) {
        let consumer = Task { [storage] in
            for await item in stream { storage.items.withLock { $0.append(item) } }
        }
        task.withLock { $0 = consumer }
    }

    deinit { task.withLock { $0?.cancel() } }

    var all: [Element] { storage.items.withLock { $0 } }

    /// Waits until an element after the first `skipping` matches; returns it, or nil after `timeout`.
    @discardableResult
    func first(after skipping: Int = 0, within timeout: Duration = .seconds(5),
               where predicate: @Sendable (Element) -> Bool) async -> Element? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let match = all.dropFirst(skipping).first(where: predicate) { return match }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

extension NodeSession.Event {
    var status: NodeSession.Status? {
        if case .status(let status) = self { return status }
        return nil
    }

    var pairing: PairingState? {
        if case .recordChanged(let pairing, _) = self { return pairing }
        return nil
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Fast settings so a suite stays well under its time budget.
enum Fast {
    static func session() -> NodeSession.Configuration {
        var configuration = NodeSession.Configuration()
        configuration.reconnect = .init(base: .milliseconds(20), cap: .milliseconds(80))
        configuration.connectTimeout = .seconds(2)
        configuration.requestTimeout = .seconds(2)
        return configuration
    }

    static func pairing(port: UInt16) -> PairingClient.Configuration {
        var configuration = PairingClient.Configuration(
            endpoint: NodeEndpoint(host: "127.0.0.1", port: port), deviceName: "Test Mac", appVersion: "0.1.0-test")
        configuration.statusPause = .milliseconds(50)
        configuration.immediateReply = .milliseconds(30)
        configuration.requestTimeout = .seconds(2)
        configuration.statusTimeout = .seconds(3)
        configuration.connectTimeout = .seconds(2)
        configuration.reconnectDelay = .milliseconds(50)
        return configuration
    }
}
