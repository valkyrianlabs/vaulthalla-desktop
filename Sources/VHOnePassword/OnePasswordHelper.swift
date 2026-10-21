public import Foundation
import VHCore

/// Talks to the bundled `vaulthalla-1password` helper (Helpers/vaulthalla-1password): launches it on first use,
/// sends one request at a time over JSON lines, and decodes typed results.
///
/// - Key material goes in as `SecretBytes` and is base64-encoded straight into the request buffer, which is zeroed
///   after it is written; revealed keys are decoded from the response bytes straight into `SecretBytes`, and only a
///   redacted copy of the line reaches `JSONDecoder`. No payload is logged.
/// - Each request waits at most its timeout. On a timeout the helper is stopped (it may be stuck behind a 1Password
///   prompt nobody answered); the next request starts a new one.
/// - If the helper exits, the request in flight fails with `.exited` and the next request starts it again,
///   re-running `account.check` for the account last checked. After `maxConsecutiveCrashes` exits without an answer
///   in between, requests fail with `.crashLoop` until `resetFailures()`.
/// - `close()` (or releasing the actor) closes the helper's stdin, which makes it exit, and terminates it.
public actor OnePasswordHelper {
    public struct Configuration: Sendable {
        public var executableURL: URL
        /// Added to the helper's minimal environment (HOME, TMPDIR, PATH, LANG). Never put secrets here.
        public var environment: [String: String]
        /// How long a request may take. 1Password may be waiting for Touch ID, so the default is generous.
        public var requestTimeout: Duration
        public var maxResponseBytes: Int
        public var maxConsecutiveCrashes: Int

        public init(
            executableURL: URL, environment: [String: String] = [:], requestTimeout: Duration = .seconds(120),
            maxResponseBytes: Int = 8 << 20, maxConsecutiveCrashes: Int = 3
        ) {
            self.executableURL = executableURL
            self.environment = environment
            self.requestTimeout = requestTimeout
            self.maxResponseBytes = maxResponseBytes
            self.maxConsecutiveCrashes = maxConsecutiveCrashes
        }

        /// The helper inside an app bundle: `Contents/Helpers/vaulthalla-1password`.
        public static func bundled(in bundle: Bundle = .main) -> Configuration {
            Configuration(executableURL: bundle.bundleURL.appending(path: "Contents/Helpers/vaulthalla-1password"))
        }
    }

    public let configuration: Configuration

    private var process: HelperProcess?
    private var generation = 0
    private var readerTask: Task<Void, Never>?
    private var nextID = 1
    private var inflight: Inflight?
    private var authorizedAccount: String?
    private var sessionAccount: String?
    private var consecutiveCrashes = 0
    private var closed = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private struct Inflight {
        let id: Int
        let op: String
        let generation: Int
        let continuation: CheckedContinuation<ResponseLine, any Error>
        let timeout: Task<Void, Never>
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        readerTask?.cancel()
        process?.terminate()
    }

    // MARK: - Operations

    /// Connects to the 1Password account (`account.check`). 1Password may ask the user to approve with Touch ID.
    /// Other operations need a successful check first; after a helper restart it is repeated automatically.
    @discardableResult
    public func checkAccount(_ account: String) async throws -> OnePasswordAccountStatus {
        try await serialized {
            if let bound = sessionAccount, bound != account, process != nil {
                // The SDK binds a process to one account: start a fresh helper for another one.
                stopProcess()
            }
            let status: OnePasswordAccountStatus = try await exchange("account.check", reauthorize: false) { w in
                w.field("account", account)
            }.value
            authorizedAccount = account
            sessionAccount = account
            return status
        }
    }

    /// Finds the 1Password vault with this title, or creates it.
    public func ensureVault(title: String = "Vaulthalla") async throws -> OnePasswordVault {
        try await serialized {
            try await exchange("vault.ensure") { w in w.field("title", title) }.value
        }
    }

    /// Metadata of every Vaulthalla backup item in a 1Password vault. Never key values.
    public func listItems(onePasswordVaultID: String) async throws -> [BackupItem] {
        try await serialized {
            let items: WireItems = try await exchange("items.list") { w in
                w.field("vault_id", onePasswordVaultID)
            }.value
            return items.items
        }
    }

    /// Writes (or updates) the item for one vault. Never changes a stored version: a different key under an existing
    /// version number fails with `version_conflict`.
    public func upsert(_ backup: BackupUpsert) async throws -> BackupUpsertOutcome {
        let capacity = 1024 + backup.versions.reduce(0) {
            $0 + ($1.key.count + 2) / 3 * 4 + $1.keyCheck.utf8.count + 96 + ($1.nodeID?.utf8.count ?? 0)
                + ($1.attestation.map { $0.keyID.utf8.count + $0.signature.utf8.count + 48 } ?? 0)
        }
        return try await serialized {
            try await exchange("item.upsert", capacity: capacity) { w in
                w.field("vault_id", backup.onePasswordVaultID)
                w.field("node_id", backup.nodeID)
                w.field("node_name", backup.nodeName)
                w.field("vault_uuid", backup.vaultUUID)
                w.field("vault_name", backup.vaultName)
                w.field("current_version", backup.currentVersion)
                w.key("versions")
                w.beginArray()
                for version in backup.versions {
                    w.beginObject()
                    w.field("version", version.version)
                    w.key("key_b64")
                    w.base64(version.key)
                    w.field("key_check", version.keyCheck)
                    w.key("needed")
                    w.bool(version.needed)
                    if let node = version.nodeID { w.field("node_id", node) }
                    if let attestation = version.attestation {
                        w.key("attestation")
                        w.beginObject()
                        w.field("key_id", attestation.keyID)
                        w.field("signature", attestation.signature)
                        w.endObject()
                    }
                    w.endObject()
                }
                w.endArray()
            }.value
        }
    }

    /// Reads key versions back out of 1Password (restore and export only). All versions when `versions` is nil.
    public func reveal(onePasswordVaultID: String, itemID: String, versions: [Int]? = nil) async throws -> RevealedKeys {
        try await serialized {
            let (wire, secrets): (WireReveal, [SecretBytes]) = try await exchange("item.reveal") { w in
                w.field("vault_id", onePasswordVaultID)
                w.field("item_id", itemID)
                if let versions {
                    w.key("versions")
                    w.beginArray()
                    for v in versions { w.int(v) }
                    w.endArray()
                }
            }
            guard secrets.count == wire.versions.count else {
                throw OnePasswordHelperError.protocolViolation("reveal: \(secrets.count) keys for \(wire.versions.count) versions")
            }
            let keys = zip(wire.versions, secrets).map { v, key in
                KeyVersion(version: v.version, key: key, keyCheck: v.keyCheck, needed: v.state != "retired",
                           nodeID: v.nodeID, attestation: v.attestation)
            }
            return RevealedKeys(
                itemID: wire.itemID, onePasswordVaultID: wire.vaultID, nodeID: wire.nodeID, vaultUUID: wire.vaultUUID,
                currentVersion: wire.currentVersion, versions: keys
            )
        }
    }

    /// Stops the helper. Later requests fail with `.closed`.
    public func close() {
        closed = true
        stopProcess()
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    /// Allows restarts again after `.crashLoop`.
    public func resetFailures() {
        consecutiveCrashes = 0
    }

    /// The helper's recent stderr lines (redacted diagnostics), for a support view. Empty when it isn't running.
    public var diagnostics: [String] {
        process?.diagnostics ?? []
    }

    // MARK: - Test hooks

    /// The running helper's pid (tests).
    var processIdentifier: Int32? { process?.processIdentifier }

    /// Sends any op and decodes its result as `R` (tests: the fake build's fault injection, malformed requests).
    func send<R: Decodable & Sendable>(
        op: String, as _: R.Type, timeout: Duration? = nil, params: (inout RequestLineWriter) -> Void = { _ in }
    ) async throws -> R {
        try await serialized {
            try await exchange(op, timeout: timeout, build: params).value
        }
    }

    // MARK: - Machinery

    /// Runs `body` with no other request in flight (one request at a time; the helper is sequential anyway).
    private func serialized<R: Sendable>(_ body: () async throws -> R) async throws -> R {
        if closed { throw OnePasswordHelperError.closed }
        if busy {
            await withCheckedContinuation { waiters.append($0) }
            if closed { throw OnePasswordHelperError.closed }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume() // hand over; busy stays true
            }
        }
        return try await body()
    }

    /// Starts the helper if needed and, after a restart, re-authorizes the account last checked.
    private func ensureProcess(reauthorize: Bool) async throws -> HelperProcess {
        if let process { return process }
        if consecutiveCrashes >= configuration.maxConsecutiveCrashes { throw OnePasswordHelperError.crashLoop }
        let launched: HelperProcess
        do {
            launched = try HelperProcess(
                executableURL: configuration.executableURL, environment: helperEnvironment(),
                maxLineBytes: configuration.maxResponseBytes
            )
        } catch {
            throw OnePasswordHelperError.launchFailed(String(describing: error))
        }
        generation += 1
        let current = generation
        process = launched
        sessionAccount = nil
        readerTask = Task { [weak self, output = launched.output] in
            for await item in output {
                await self?.received(item, generation: current)
            }
            await self?.ended(generation: current)
        }
        if reauthorize, let account = authorizedAccount {
            let _: (OnePasswordAccountStatus, [SecretBytes]) = try await send(
                "account.check", on: launched, timeout: nil, capacity: 256
            ) { w in w.field("account", account) }
            sessionAccount = account
        }
        return launched
    }

    private func helperEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "TMPDIR", "LANG", "USER", "LOGNAME"] {
            if let value = inherited[key] { env[key] = value }
        }
        env.merge(configuration.environment) { _, new in new }
        return env
    }

    private func exchange<R: Decodable>(
        _ op: String, reauthorize: Bool = true, timeout: Duration? = nil, capacity: Int = 512,
        build: (inout RequestLineWriter) -> Void
    ) async throws -> (value: R, secrets: [SecretBytes]) {
        let process = try await ensureProcess(reauthorize: reauthorize)
        let (value, secrets): (R, [SecretBytes]) = try await send(
            op, on: process, timeout: timeout, capacity: capacity, build: build
        )
        return (value, secrets)
    }

    private func send<R: Decodable>(
        _ op: String, on process: HelperProcess, timeout: Duration?, capacity: Int,
        build: (inout RequestLineWriter) -> Void
    ) async throws -> (R, [SecretBytes]) {
        let id = nextID
        nextID += 1
        var writer = RequestLineWriter(id: id, op: op, capacity: capacity)
        build(&writer)
        var line = writer.finish()
        defer { line.wipe() }

        let limit = timeout ?? configuration.requestTimeout
        let generation = self.generation
        let response: ResponseLine = try await withCheckedThrowingContinuation { continuation in
            let timer = Task { [weak self] in
                try? await Task.sleep(for: limit)
                if !Task.isCancelled { await self?.timedOut(id: id) }
            }
            inflight = Inflight(id: id, op: op, generation: generation, continuation: continuation, timeout: timer)
            do {
                try line.withUnsafeBytes { try process.write($0) }
            } catch {
                finish(id: id, with: .failure(error))
            }
        }
        let decoder = JSONDecoder()
        let envelope: WireEnvelope<R>
        do {
            envelope = try decoder.decode(WireEnvelope<R>.self, from: response.redacted)
        } catch {
            throw OnePasswordHelperError.protocolViolation("\(op): undecodable response")
        }
        if envelope.ok, let result = envelope.result {
            return (result, response.secrets)
        }
        guard let error = envelope.error else {
            throw OnePasswordHelperError.protocolViolation("\(op): response without result or error")
        }
        throw OnePasswordHelperError.refused(
            code: HelperErrorCode(rawValue: error.code), message: error.message, hint: error.hint, detail: error.detail
        )
    }

    private func finish(id: Int, with result: Result<ResponseLine, any Error>) {
        guard let current = inflight, current.id == id else { return }
        inflight = nil
        current.timeout.cancel()
        current.continuation.resume(with: result)
    }

    private func received(_ output: HelperOutput, generation: Int) {
        guard generation == self.generation else { return }
        switch output {
        case .oversize:
            if let current = inflight {
                finish(id: current.id, with: .failure(OnePasswordHelperError.protocolViolation("response too large")))
            }
        case .line(var bytes):
            let response: ResponseLine
            do {
                response = try ResponseLine.take(&bytes)
            } catch {
                if let current = inflight {
                    finish(id: current.id, with: .failure(OnePasswordHelperError.protocolViolation("malformed key in response")))
                }
                return
            }
            guard let header = try? JSONDecoder().decode(WireHeader.self, from: response.redacted) else {
                return // not a response line; ignore
            }
            consecutiveCrashes = 0 // it answered, so it's alive
            switch header.id {
            case .int(let id):
                finish(id: id, with: .success(response))
            case .null:
                // The helper couldn't parse a request; with one request at a time, it was the one in flight.
                if let current = inflight { finish(id: current.id, with: .success(response)) }
            case .string:
                return // not ours
            }
        }
    }

    private func ended(generation: Int) {
        guard generation == self.generation else { return }
        let status = process?.exitStatus
        process?.terminate()
        process = nil
        sessionAccount = nil
        if !closed { consecutiveCrashes += 1 }
        if let current = inflight {
            finish(id: current.id, with: .failure(closed ? OnePasswordHelperError.closed : .exited(status: status)))
        }
    }

    private func timedOut(id: Int) {
        guard let current = inflight, current.id == id else { return }
        finish(id: id, with: .failure(OnePasswordHelperError.timeout(op: current.op)))
        stopProcess() // it may be stuck behind a prompt; the next request starts a fresh one
    }

    private func stopProcess() {
        generation += 1 // events from the old process are ignored from now on
        readerTask?.cancel()
        readerTask = nil
        process?.terminate()
        process = nil
        sessionAccount = nil
        if let current = inflight {
            finish(id: current.id, with: .failure(closed ? OnePasswordHelperError.closed : .exited(status: nil)))
        }
    }
}
