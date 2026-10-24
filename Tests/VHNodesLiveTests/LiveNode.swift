import Foundation
import Security
import Synchronization
import Testing
import VHContract
import VHCore
import VHIdentity
import VHNodes

/// The live daemon these tests talk to: a private test instance started by `tools/interop/vh-instance.sh` on a
/// Linux box (docs/interop-testing.md). Opt-in: without `VH_LIVE_NODE` every live test is skipped.
///
/// - `VH_LIVE_NODE`: the device listener as this Mac reaches it, `host:port` (e.g. `192.0.2.10:36982`).
/// - `VH_LIVE_SSH`: the ssh destination of the box running the instance (default `dev`).
/// - `VH_LIVE_RUN`: the instance's run directory there (default `/tmp/vhi_interop`).
///
/// Pairing decisions are made out of band, as the operator would: `vh` over ssh, as the seeded user.
enum LiveNode {
    private static let environment = ProcessInfo.processInfo.environment

    static let endpoint: NodeEndpoint? = environment["VH_LIVE_NODE"].flatMap(NodeEndpoint.init(parsing:))
    static var isConfigured: Bool { endpoint != nil }
    static let sshDestination = environment["VH_LIVE_SSH"] ?? "dev"
    static let runDirectory = environment["VH_LIVE_RUN"] ?? "/tmp/vhi_interop"

    static func requireEndpoint() throws -> NodeEndpoint {
        guard let endpoint else { throw LiveFailure("VH_LIVE_NODE is not set") }
        return endpoint
    }

    /// What `vh-instance.sh up` recorded: the daemon's pin, contract hash and seeded vault.
    struct Instance: Decodable {
        var alive: Bool
        var devicePort: Int
        var vaultID: Int64
        var user: String
        var serverSPKISHA256: String
        var wsHash: String

        enum CodingKeys: String, CodingKey {
            case alive, user
            case devicePort = "device_port"
            case vaultID = "vault_id"
            case serverSPKISHA256 = "server_spki_sha256"
            case wsHash = "ws_hash"
        }
    }

    static func instance() async throws -> Instance {
        let text = try await remote(["cat", "\(runDirectory)/status.json"])
        return try JSONDecoder().decode(Instance.self, from: Data(text.utf8))
    }

    /// `vh <arguments>` on the instance, non-interactive, as the seeded user (or the super admin). Throws on a
    /// non-zero exit with the command's output.
    @discardableResult
    static func vh(_ arguments: [String], admin: Bool = false) async throws -> String {
        try await remote(["\(runDirectory)/\(admin ? "vh-admin" : "vh")"] + arguments)
    }

    /// `vh <arguments> --json`, decoded.
    static func vhJSON(_ arguments: [String], admin: Bool = false) async throws -> JSONValue {
        let text = try await vh(arguments + ["--json"], admin: admin)
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Runs a command on the instance's box. Every argument is single-quoted for the remote shell.
    private static func remote(_ command: [String]) async throws -> String {
        let line = command.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        return try await run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", sshDestination, line])
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let collected = Mutex((out: Data(), err: Data()))
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            collected.withLock { $0.out.append(chunk) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            collected.withLock { $0.err.append(chunk) }
        }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        let rest = (output.fileHandleForReading.readDataToEndOfFile(), errors.fileHandleForReading.readDataToEndOfFile())
        let (out, err) = collected.withLock { ($0.out + rest.0, $0.err + rest.1) }
        let text = String(decoding: out, as: UTF8.self)
        guard status == 0 else {
            throw LiveFailure("`\(arguments.last ?? executable)` exited \(status): \(text)\(String(decoding: err, as: UTF8.self))")
        }
        return text
    }
}

/// Keychain hygiene as in VHIdentityTests/TestSupport.swift: a namespace unique to the run, only the node tags
/// below, everything deleted afterwards (also on failure), and the keychain lock shared with the other test targets.
enum LiveKeychain {
    static let nodeTags = ["live-node", "live-denied"]

    static func withKeys<R: Sendable>(_ body: (DeviceKeys) async throws -> R) async throws -> R {
        await KeychainLock.shared.acquire()
        let store = DeviceIdentityStore(configuration: .init(
            namespace: "sh.vaulthalla.desktop.test.\(UUID().uuidString.lowercased())", keychain: .fileBased))
        // The suite is the credential owner: it pairs, rotates and deletes (docs/architecture.md §3).
        let leaseDirectory = FileManager.default.temporaryDirectory
            .appending(path: "vh-live-lease-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: leaseDirectory) }
        let lease = CredentialLease(forRegistry: leaseDirectory.appending(path: "nodes.json"), holder: "live-test")
        try lease.acquire()
        defer { lease.release() }
        let keys = DeviceKeys(primary: store, development: nil, preferredBackend: .software, lease: lease)
        do {
            let result = try await body(keys)
            try await cleanUp(store)
            await KeychainLock.shared.release()
            return result
        } catch {
            try? await cleanUp(store)
            await KeychainLock.shared.release()
            throw error
        }
    }

    private static func cleanUp(_ store: DeviceIdentityStore) async throws {
        for tag in nodeTags {
            try await store.deleteIdentity(for: tag)
            // Nothing of this run's namespace stays behind: no current key, no rotation's replacement.
            #expect(try await store.identity(for: tag) == nil)
            #expect(try await store.pendingRotation(for: tag) == nil)
        }
    }
}

/// The keychain lock of VHIdentityTests / VHNodesTests: a FIFO in this target plus the lock file every target that
/// writes keys takes (`swift test` runs all targets in one process; the file keychain fails under concurrent writers).
actor KeychainLock {
    static let shared = KeychainLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let file = open(
        FileManager.default.temporaryDirectory.appending(path: "sh.vaulthalla.desktop.test.keychain.lock").path,
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

    /// The first element after the first `skipping` that matches, waiting up to `timeout`; nil if none arrives.
    func first(after skipping: Int = 0, within timeout: Duration,
               where predicate: @Sendable (Element) -> Bool) async -> Element? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let match = all.dropFirst(skipping).first(where: predicate) { return match }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return all.dropFirst(skipping).first(where: predicate)
    }
}

struct LiveFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init(hexString: String) {
        var bytes = [UInt8]()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            bytes.append(UInt8(hexString[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}

/// The seeded binary: byte i is (i * 7 + 3) mod 256 (tools/interop/vh-instance.sh).
let seededBlob = Data((0..<65536).map { UInt8(($0 * 7 + 3) % 256) })
let seededHello = Data("Hello from the Vaulthalla interop instance.\n".utf8)
