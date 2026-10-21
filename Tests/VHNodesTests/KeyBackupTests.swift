import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
import VHIdentity
import VHTransport
@testable import VHKeyBackup
@testable import VHNodes
@testable import VHOnePassword

/// The daemon's vault keys as the mock answers `vault.keys.*`: what each vault holds, needs and has recorded, plus
/// the faults a test scripts. Key checks come from the fake helper (Swift never computes BLAKE2b).
final class DaemonKeys: Sendable {
    struct Vault: Sendable {
        var id: Int64
        var name: String
        var current: Int
        /// Older versions still needed (an unfinished rotation's outgoing key).
        var needed: [Int] = []
        var rotating = false
        var exported: Int?
        /// The versions this node can read. A restore puts the rest back from `truth`.
        var readable: Set<Int>
        var unavailableReason: String?
        var exportRefusal: (message: String, code: String)?
        /// Answers the confirmation with `conflict` (a rotation landed in between).
        var confirmConflict = false
        /// Exports `current` under another version's check (a corrupt export the helper must refuse).
        var corruptExport = false
        /// The node attests the keys it exports (`node_id` + `attestation` per version).
        var attests = false
        /// Recover-mode imports restore only versions whose attestation verifies (a daemon with attestations).
        var requiresAttestation = false
    }

    static let attestingNode = "srv-node-a"

    /// The mock's attestation of a version: "valid" only as the mock itself signs it.
    static func attestation(_ vault: Int64, _ version: Int) -> JSONValue {
        ["key_id": "ed25519:node-a", "signature": .string("sig-\(vault)-\(version)")]
    }

    let vaults: Mutex<[Int64: Vault]>
    /// The real key of every (vault, version), and its check.
    let truth: [Int64: [Int: [UInt8]]]
    let checks: [String: String]
    /// What `vault.keys.import` received and wrote, per vault and version.
    let imported = Mutex<[Int64: [Int: [UInt8]]]>([:])
    /// The attestations the last import carried, per vault and version.
    let receivedAttestations = Mutex<[Int64: [Int: JSONValue]]>([:])

    static func key(_ vault: Int64, _ version: Int) -> [UInt8] {
        [UInt8](repeating: UInt8(truncatingIfNeeded: Int(vault) * 16 + version), count: 32)
    }

    init(_ vaults: [Vault], versions: [Int64: [Int]], helper: OnePasswordHelper) async throws {
        var truth: [Int64: [Int: [UInt8]]] = [:]
        var checks: [String: String] = [:]
        for (vault, list) in versions {
            for version in list {
                let key = Self.key(vault, version)
                truth[vault, default: [:]][version] = key
                checks["\(vault)/\(version)"] = try await helper.testKeyCheck(key, vault: vault, version: version)
            }
        }
        self.truth = truth
        self.checks = checks
        self.vaults = Mutex(Dictionary(uniqueKeysWithValues: vaults.map { ($0.id, $0) }))
    }

    func check(_ vault: Int64, _ version: Int) -> String { checks["\(vault)/\(version)"] ?? "" }

    func update(_ id: Int64, _ change: (inout Vault) -> Void) {
        vaults.withLock { change(&$0[id]!) }
    }

    func install(on daemon: MockDaemon) {
        daemon.answer("vault.keys.status") { [self] _ in
            let list = vaults.withLock { $0.values.sorted { $0.id < $1.id } }
            return .ok(["vaults": .array(list.map(status))])
        }
        daemon.answer("vault.keys.export") { [self] payload in
            guard let id = payload["vault_id"]?.integerValue, let vault = vaults.withLock({ $0[id] }) else {
                return .refuse("No such vault.", code: "not_found")
            }
            if let refusal = vault.exportRefusal { return .refuse(refusal.message, code: refusal.code) }
            return .ok(export(vault))
        }
        daemon.answer("vault.keys.export.confirm") { [self] payload in
            guard let id = payload["vault_id"]?.integerValue, let version = payload["version"]?.integerValue,
                  let keyCheck = payload["key_check"]?.stringValue, let vault = vaults.withLock({ $0[id] }) else {
                return .refuse("Bad payload.", code: "invalid")
            }
            if vault.confirmConflict || Int(version) != vault.current {
                return .refuse("key version \(version) is no longer the current key of vault '\(vault.name)'", code: "conflict")
            }
            guard keyCheck == check(id, Int(version)) else {
                return .refuse("the key check does not match key version \(version)", code: "conflict")
            }
            update(id) { $0.exported = Int(version) }
            return .ok(["vault_id": .integer(id), "version": .integer(version), "exported_at": 1_790_000_000])
        }
        daemon.answer("vault.keys.import") { [self] payload in importKeys(payload) }
    }

    private func status(_ v: Vault) -> JSONValue {
        let available = v.readable.isSuperset(of: Set([v.current] + v.needed))
        let needed: [JSONValue] = ([v.current] + v.needed).map { version in
            ["version": .integer(Int64(version)),
             "key_check": v.readable.contains(version) ? .string(check(v.id, version)) : .null,
             "reason": version == v.current ? "current" : "rotation"]
        }
        let missing = ([v.current] + v.needed).filter { !v.readable.contains($0) }
        return [
            "vault_id": .integer(v.id), "vault_name": .string(v.name), "deleted": false, "key_retain_until": .null,
            "version": .integer(Int64(v.current)),
            "key_check": v.readable.contains(v.current) ? .string(check(v.id, v.current)) : .null,
            "key_available": .bool(available),
            "unavailable_reason": available ? .null : .string(v.unavailableReason ?? "key_unsealable"),
            "unavailable_detail": available ? .null : "The key doesn't unseal on this host. Run vh vault keys import.",
            "exported_version": v.exported.map { .integer(Int64($0)) } ?? .null,
            "exported_at": v.exported == nil ? .null : 1_790_000_000,
            "rotation_in_progress": .bool(v.rotating), "needed_versions": .array(needed),
            "missing_versions": .array(missing.map { .integer(Int64($0)) }),
        ]
    }

    private func export(_ v: Vault) -> JSONValue {
        let currentCheck = v.corruptExport ? check(v.id, v.needed.first ?? 1) : check(v.id, v.current)
        let info: JSONValue = [
            "type": "AES-256-GCM", "key_size": 32, "key_version": .integer(Int64(v.current)), "iv_size": 12,
            "tag_size": 16, "iv_gen": "libsodium::randombytes_buf", "cipher_impl": "libsodium::crypto_aead_aes256gcm",
            "hardware_accel": "AES-NI (runtime checked)", "aad": false, "files_hashed_with": "libsodium",
            "sealed_by": "Vaulthalla v1.9.0", "created_at": "2026-10-01 10:00:00", "exported_by": "cooper",
            "exported_at": "2026-10-21 09:00:00", "key_check": .string(currentCheck),
        ]
        var object: JSONObject = [
            "vault_id": .integer(v.id), "vault_name": .string(v.name),
            "key": .string(Data(truth[v.id]![v.current]!).base64EncodedString()), "key_check": .string(currentCheck),
            "key_info": info,
        ]
        if v.attests {
            object["node_id"] = .string(Self.attestingNode)
            object["attestation"] = Self.attestation(v.id, v.current)
        }
        if !v.needed.isEmpty {
            object["historical_keys"] = .array(v.needed.sorted().map { version in
                var entry: JSONObject = [
                    "key_version": .integer(Int64(version)),
                    "key": .string(Data(truth[v.id]![version]!).base64EncodedString()),
                    "key_check": .string(check(v.id, version)), "reason": "rotation",
                    "created_at": "2026-09-01 10:00:00", "retired_at": .null]
                if v.attests { entry["attestation"] = Self.attestation(v.id, version) }
                return .object(entry)
            })
        }
        return .object(object)
    }

    private func importKeys(_ payload: JSONValue) -> MockDaemon.Reply {
        guard let id = payload["vault_id"]?.integerValue, let vault = vaults.withLock({ $0[id] }),
              let keys = payload["keys"], let current = keys["key_info"]?["key_version"]?.integerValue,
              let head = keys["key"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
            return .refuse("the export entry needs key and key_info.key_version", code: "invalid")
        }
        var received: [Int: [UInt8]] = [Int(current): Array(head)]
        var sentChecks: [Int: String] = [:]
        var attestations: [Int: JSONValue] = [:]
        sentChecks[Int(current)] = keys["key_check"]?.stringValue
        attestations[Int(current)] = keys["attestation"]
        for entry in keys["historical_keys"]?.arrayValue ?? [] {
            guard let version = entry["key_version"]?.integerValue,
                  let bytes = entry["key"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
                return .refuse("every historical_keys entry needs key and key_version", code: "invalid")
            }
            received[Int(version)] = Array(bytes)
            sentChecks[Int(version)] = entry["key_check"]?.stringValue
            attestations[Int(version)] = entry["attestation"]
        }
        receivedAttestations.withLock { $0[id] = attestations }
        for (version, bytes) in received {
            guard bytes == truth[id]?[version], sentChecks[version] == check(id, version) else {
                return .refuse("key version \(version) doesn't authenticate this vault's files", code: "invalid")
            }
        }
        let salvage = payload["mode"]?.stringValue == "salvage"
        let unreadable = received.keys.filter { !vault.readable.contains($0) }.sorted(by: >)
        if salvage {
            guard payload["confirm_name"]?.stringValue == vault.name else {
                return .refuse("Salvage re-encrypts what versions \(unreadable.map(String.init).joined(separator: ", ")) still decrypt under a new key. Type the vault's name to confirm.",
                               code: "vault_key_salvage")
            }
            update(id) { $0.readable = Set([$0.current + 1]); $0.current += 1; $0.needed = [] }
            return .ok(["vault_id": .integer(id), "vault_name": .string(vault.name), "deleted": false, "written": true,
                        "key_available": true, "note": .null,
                        "versions": .array(unreadable.sorted().map { ["version": .integer(Int64($0)), "outcome": "salvaged",
                                                                      "detail": "re-encrypted", "verified_files": 0, "failed_files": 0] }),
                        "salvage": ["new_key_version": .integer(Int64(vault.current + 1)), "recovered_files": 41,
                                    "unrecoverable_count": 1, "unrecoverable_files": [["path": "/Photos/2019/broken.heic"]]]])
        }
        // Recover: with attestations required, a version is restored only when its attestation verifies.
        let verified = Set(unreadable.filter { !vault.requiresAttestation || attestations[$0] == Self.attestation(id, $0) })
        let toWrite = unreadable.filter { verified.contains($0) }
        if !toWrite.isEmpty, payload["confirm_name"]?.stringValue != vault.name {
            return .refuse("This writes key versions \(toWrite.map(String.init).joined(separator: ", ")) of vault '\(vault.name)'. Type the vault's name to confirm.",
                           code: "vault_key_import")
        }
        imported.withLock { $0[id] = received.filter { toWrite.contains($0.key) || vault.readable.contains($0.key) } }
        update(id) { $0.readable.formUnion(toWrite) }
        let versions: [JSONValue] = received.keys.sorted().map { version in
            let restored = toWrite.contains(version)
            let salvageOnly = unreadable.contains(version) && !restored
            return ["version": .integer(Int64(version)),
                    "outcome": .string(restored ? "restored" : salvageOnly ? "needs_salvage" : "unchanged"),
                    "detail": .string(restored ? "verified against 3 files"
                        : salvageOnly ? "no valid attestation from this node" : "this host holds the same key"),
                    "verified_files": restored ? 3 : 0, "failed_files": 0]
        }
        let available = vaults.withLock { v in v[id].map { $0.readable.isSuperset(of: Set([$0.current] + $0.needed)) } ?? false }
        return .ok(["vault_id": .integer(id), "vault_name": .string(vault.name), "deleted": false,
                    "written": .bool(!toWrite.isEmpty), "key_available": .bool(available), "note": .null,
                    "versions": .array(versions)])
    }
}

extension KeychainSuite {
@Suite(.enabled(if: FakeOnePassword.goAvailable, "needs a Go toolchain to build the helper's fake mode"))
struct KeyBackupTests {
    struct Lab {
        let daemon: MockDaemon
        let node: KeyBackupNode
        let helper: OnePasswordHelper
        let keys: DaemonKeys
        let sync: KeyBackupSync

        /// The table's rows as the app computes them: the node's status plus 1Password's item metadata.
        func rows(in vault: OnePasswordVault) async throws -> [VaultKeyRow] {
            let statuses = try await VaultKeyCommands(node.transport).status()
            return VaultKeyRows.rows(node: node, statuses: statuses, items: try await sync.items(in: vault))
        }

        func row(_ id: Int64, in vault: OnePasswordVault) async throws -> VaultKeyRow {
            try #require(try await rows(in: vault).first { $0.vaultID == id })
        }
    }

    /// A live Device session to the mock daemon with `vaults`, and the fake 1Password helper.
    private func withLab(
        _ vaults: [DaemonKeys.Vault], versions: [Int64: [Int]], _ body: (Lab) async throws -> Void
    ) async throws {
        let shared = try KeychainFixture.require()
        let daemon = try await MockDaemon.start(identity: shared.server)
        defer { daemon.stop() }
        daemon.register(shared.device.spkiSHA256)
        let node = Node(
            id: NodeID(rawValue: "node-a"), displayName: "vh-test",
            endpoint: NodeEndpoint(host: "127.0.0.1", port: daemon.port),
            pairing: .paired(serverSPKISHA256: shared.server.spkiSHA256, deviceID: shared.device.deviceID, since: .now),
            serverNodeID: "srv-node-a")
        let session = NodeSession(node: node, keys: DeviceKeys(primary: shared.store, development: nil,
                                                               preferredBackend: .software),
                                  configuration: Fast.session())
        let events = Recorder(session.events)
        await session.start()
        #expect(await events.first { $0.status == .online } != nil)
        let helper = try FakeOnePassword.helper()
        let keys = try await DaemonKeys(vaults, versions: versions, helper: helper)
        keys.install(on: daemon)
        let lab = Lab(daemon: daemon, node: KeyBackupNode(node: node, transport: session), helper: helper, keys: keys,
                      sync: KeyBackupSync(store: helper, settings: OnePasswordSettings(account: "Cooper")))
        do {
            try await body(lab)
        } catch {
            await helper.close()
            await session.stop()
            throw error
        }
        await helper.close()
        await session.stop()
    }

    private static func photos(current: Int = 2, needed: [Int] = [1], rotating: Bool = true) -> DaemonKeys.Vault {
        DaemonKeys.Vault(id: 7, name: "Photos", current: current, needed: needed, rotating: rotating,
                         readable: Set([current] + needed))
    }

    @Test func syncExportsUpsertsAndConfirms() async throws {
        try await withLab([Self.photos()], versions: [7: [1, 2]]) { lab in
            let vault = try await lab.sync.prepare()
            #expect(vault.title == "Vaulthalla" && vault.created)
            let before = try await lab.row(7, in: vault)
            // Mid-rotation and never backed up: both keys are missing from 1Password.
            #expect(before.status == .rotating(missingVersions: [2, 1]))
            #expect(before.needsBackup && before.backupNodeID == "srv-node-a")

            let events = Mutex<[String]>([])
            let outcomes = await lab.sync.run([before], nodes: [lab.node], into: vault) { event in
                switch event {
                case .started(let id): events.withLock { $0.append("start \(id)") }
                case .finished(let id, _): events.withLock { $0.append("done \(id)") }
                }
            }
            #expect(outcomes[before.id] == .backedUp(version: 2, written: true))
            #expect(events.withLock { $0 } == ["start node-a/7", "done node-a/7"])

            // The confirmation carried what 1Password read back: version 2 and its key check.
            let confirm = try #require(lab.daemon.payloads(of: "vault.keys.export.confirm").last)
            #expect(confirm["vault_id"]?.integerValue == 7 && confirm["version"]?.integerValue == 2)
            #expect(confirm["key_check"]?.stringValue == lab.keys.check(7, 2))

            // 1Password holds both versions, byte for byte, under the server's node id.
            let after = try await lab.row(7, in: vault)
            let item = try #require(after.item)
            #expect(item.nodeID == "srv-node-a" && item.vaultUUID == "7" && item.vaultName == "Photos")
            #expect(item.versions.map(\.version) == [2, 1] && item.keyCheck == lab.keys.check(7, 2))
            let revealed = try await lab.helper.reveal(onePasswordVaultID: vault.id, itemID: item.itemID)
            #expect(revealed.versions.map { $0.key.withUnsafeBytes { Array($0) } }
                == [DaemonKeys.key(7, 2), DaemonKeys.key(7, 1)])
            // The rotation is still running, but nothing is missing any more.
            #expect(after.status == .rotating(missingVersions: []) && !after.needsBackup)

            // Once the rotation finishes the vault is backed up and recorded; another sync moves nothing.
            lab.keys.update(7) { $0.rotating = false; $0.needed = [] }
            let done = try await lab.row(7, in: vault)
            #expect(done.status == .backedUp(confirmed: true))
            let writes = try await lab.helper.testWrites()
            #expect(await lab.sync.run([done], nodes: [lab.node], into: vault)[done.id] == .skipped("Already backed up."))
            #expect(try await lab.helper.testWrites() == writes)
            #expect(lab.daemon.count(of: "vault.keys.export") == 1)
        }
    }

    @Test func aBackupAlreadyInOnePasswordIsOnlyConfirmed() async throws {
        try await withLab([Self.photos(current: 1, needed: [], rotating: false)], versions: [7: [1]]) { lab in
            let vault = try await lab.sync.prepare()
            lab.keys.update(7) { $0.confirmConflict = true }
            let first = try await lab.row(7, in: vault)
            #expect(await lab.sync.run([first], nodes: [lab.node], into: vault)[first.id]
                == .storedNotConfirmed(version: 1, reason: "key version 1 is no longer the current key of vault 'Photos'"))
            // 1Password holds it; the node never recorded it.
            lab.keys.update(7) { $0.confirmConflict = false }
            let second = try await lab.row(7, in: vault)
            #expect(second.status == .backedUp(confirmed: false))
            let exports = lab.daemon.count(of: "vault.keys.export")
            #expect(await lab.sync.run([second], nodes: [lab.node], into: vault)[second.id]
                == .backedUp(version: 1, written: false))
            #expect(lab.daemon.count(of: "vault.keys.export") == exports, "no key moved for a confirmation")
            #expect(try await lab.row(7, in: vault).status == .backedUp(confirmed: true))
        }
    }

    @Test func aRotationBetweenStoreAndConfirmIsReportedThenCaughtUp() async throws {
        try await withLab([Self.photos(current: 1, needed: [], rotating: false)], versions: [7: [1, 2]]) { lab in
            let vault = try await lab.sync.prepare()
            let row = try await lab.row(7, in: vault)
            // The node rotates to v2 right after exporting v1: the confirmation of v1 is refused.
            lab.daemon.answer("vault.keys.export.confirm") { [keys = lab.keys] _ in
                keys.update(7) { $0.current = 2; $0.needed = [1]; $0.rotating = true; $0.readable = [1, 2] }
                return .refuse("key version 1 is no longer the current key of vault 'Photos' (current: 2)", code: "conflict")
            }
            let outcome = await lab.sync.run([row], nodes: [lab.node], into: vault)[row.id]
            guard case .storedNotConfirmed(1, let reason) = outcome else {
                Issue.record("got \(String(describing: outcome))")
                return
            }
            #expect(reason.contains("no longer the current key"))

            // The next status shows the new key missing; the next sync stores it next to v1 and confirms it.
            lab.keys.install(on: lab.daemon)
            let next = try await lab.row(7, in: vault)
            #expect(next.status == .rotating(missingVersions: [2]))
            #expect(await lab.sync.run([next], nodes: [lab.node], into: vault)[next.id] == .backedUp(version: 2, written: true))
            let item = try #require(try await lab.row(7, in: vault).item)
            #expect(item.versions.map(\.version) == [2, 1] && item.currentVersion == 2)
            #expect(lab.keys.vaults.withLock { $0[7]?.exported } == 2)
        }
    }

    @Test func partialFailureIsReportedPerVault() async throws {
        var denied = DaemonKeys.Vault(id: 8, name: "Taxes", current: 1, readable: [1])
        denied.exportRefusal = ("Permission denied: this account lacks the encryption-key Export permission", "denied")
        var corrupt = DaemonKeys.Vault(id: 9, name: "Scans", current: 2, needed: [1], readable: [1, 2])
        corrupt.corruptExport = true
        let vaults = [Self.photos(current: 1, needed: [], rotating: false), denied, corrupt]
        try await withLab(vaults, versions: [7: [1], 8: [1], 9: [1, 2]]) { lab in
            let vault = try await lab.sync.prepare()
            let rows = try await lab.rows(in: vault)
            #expect(rows.map(\.vaultID) == [7, 8, 9] && rows.allSatisfy(\.needsBackup))
            let outcomes = await lab.sync.run(rows, nodes: [lab.node], into: vault)

            #expect(outcomes["node-a/7"] == .backedUp(version: 1, written: true))
            guard case .failed(.export, let deniedMessage) = outcomes["node-a/8"] else {
                Issue.record("vault 8: \(String(describing: outcomes["node-a/8"]))")
                return
            }
            #expect(deniedMessage.contains("may not export vault keys on vh-test"))
            guard case .failed(.store, let corruptMessage) = outcomes["node-a/9"] else {
                Issue.record("vault 9: \(String(describing: outcomes["node-a/9"]))")
                return
            }
            #expect(corruptMessage.contains("doesn't match its key check"))

            // Only the good vault was confirmed and stored.
            #expect(lab.daemon.payloads(of: "vault.keys.export.confirm").map { $0["vault_id"]?.integerValue } == [7])
            let after = try await lab.rows(in: vault)
            #expect(after.filter { $0.item != nil }.map(\.vaultID) == [7])
            #expect(after.first { $0.vaultID == 8 }?.needsBackup == true)
        }
    }

    @Test func anOlderDaemonWithoutKeyBackupIsNamed() async throws {
        try await withLab([Self.photos(current: 1, needed: [], rotating: false)], versions: [7: [1]]) { lab in
            let vault = try await lab.sync.prepare()
            let row = try await lab.row(7, in: vault)
            lab.daemon.answer("vault.keys.export") { _ in .refuse("Unknown command: vault.keys.export", code: "") }
            guard case .failed(.export, let message) = await lab.sync.run([row], nodes: [lab.node], into: vault)[row.id] else {
                Issue.record("expected an export failure")
                return
            }
            #expect(message.contains("Update it first"))
        }
    }

    @Test func restoreVerifiesExportsAndImportsBackToTheNode() async throws {
        try await withLab([Self.photos(current: 2, needed: [1], rotating: true)], versions: [7: [1, 2]]) { lab in
            let vault = try await lab.sync.prepare()
            let row = try await lab.row(7, in: vault)
            #expect(await lab.sync.run([row], nodes: [lab.node], into: vault)[row.id] == .backedUp(version: 2, written: true))

            // The node's database is restored onto a new host: neither key unseals any more.
            lab.keys.update(7) { $0.readable = []; $0.unavailableReason = "key_unsealable" }
            let broken = try await lab.row(7, in: vault)
            guard case .keyUnavailable(let unavailable) = broken.status else {
                Issue.record("got \(broken.status)")
                return
            }
            #expect(unavailable.reason == "key_unsealable" && unavailable.versions == [2, 1])
            #expect(unavailable.backup == .complete && unavailable.canRestore)
            #expect(!broken.daemon.keyAvailable)

            // (a) Verify: 1Password holds both versions the node can't read.
            let verification = KeyRestore.verify(daemon: broken.daemon, item: broken.item)
            #expect(verification.lines.map(\.verdict) == [.restorable, .restorable] && verification.isComplete)

            let restore = KeyRestore(store: lab.helper)
            // (b) Export: the CLI's JSON shape, every version, keys from 1Password; written 0600.
            let document = try await restore.exportDocument(broken, in: vault, exportedBy: "Vaulthalla Desktop")
            let file = FileManager.default.temporaryDirectory.appending(path: "vh-keys-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            try SecretFile.write(document, to: file)
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
            #expect(json["vault_id"]?.integerValue == 7 && json["vault_name"]?.stringValue == "Photos")
            #expect(json["key_info"]?["key_version"]?.integerValue == 2 && json["key_check"]?.stringValue == lab.keys.check(7, 2))
            #expect(json["key"]?.stringValue == Data(DaemonKeys.key(7, 2)).base64EncodedString())
            #expect(json["historical_keys"]?.arrayValue?.map { $0["key_version"]?.integerValue } == [1])
            // The same document decodes as the contract's export model, so `vh vault keys import` reads it.
            #expect(try JSONDecoder().decode(ImportShape.self, from: Data(contentsOf: file)).key_info.key_version == 2)

            // (c) Import: the daemon plans first and asks for the vault's name.
            let node = lab.node
            let planned = await restore.importToNode(broken, on: node, in: vault, confirmName: nil, exportedBy: "test")
            guard case .needsConfirmation(let message) = planned else {
                Issue.record("got \(planned)")
                return
            }
            #expect(message.contains("versions 2, 1") && message.contains("Photos"))
            #expect(lab.keys.imported.withLock { $0[7] } == nil, "nothing written without the name")

            let done = await restore.importToNode(broken, on: node, in: vault, confirmName: "Photos", exportedBy: "test")
            guard case .imported(let result) = done else {
                Issue.record("got \(done)")
                return
            }
            #expect(result.keyAvailable && result.written)
            #expect(result.versions.map(\.outcome) == ["restored", "restored"])
            // The daemon received exactly the original keys.
            #expect(lab.keys.imported.withLock { $0[7] } == [1: DaemonKeys.key(7, 1), 2: DaemonKeys.key(7, 2)])
            // And the vault reads as backed up again.
            let recovered = try await lab.row(7, in: vault)
            #expect(recovered.daemon.keyAvailable && recovered.status == .rotating(missingVersions: []))
        }
    }

    @Test func importSendsOnlyTheVersionsTheNodeNeeds() async throws {
        try await withLab([Self.photos(current: 2, needed: [1], rotating: true)], versions: [7: [1, 2]]) { lab in
            let vault = try await lab.sync.prepare()
            _ = await lab.sync.run([try await lab.row(7, in: vault)], nodes: [lab.node], into: vault)
            // The rotation finished; later v2 is lost. v1 is retired in 1Password and isn't needed.
            lab.keys.update(7) { $0.rotating = false; $0.needed = []; $0.readable = [] }
            let row = try await lab.row(7, in: vault)
            #expect(KeyRestore.verify(daemon: row.daemon, item: row.item).lines.map(\.verdict) == [.restorable, .retired])
            let outcome = await KeyRestore(store: lab.helper).importToNode(row, on: lab.node, in: vault,
                                                                         confirmName: "Photos", exportedBy: "test")
            guard case .imported(let result) = outcome else {
                Issue.record("got \(outcome)")
                return
            }
            #expect(result.keyAvailable)
            #expect(lab.keys.imported.withLock { $0[7] } == [2: DaemonKeys.key(7, 2)])
        }
    }

    // MARK: Attestations (guaranteed recovery) and salvage

    @Test func attestationsTravelFromTheNodeThroughOnePasswordAndBack() async throws {
        var photos = Self.photos(current: 2, needed: [1], rotating: true)
        photos.attests = true
        photos.requiresAttestation = true
        try await withLab([photos], versions: [7: [1, 2]]) { lab in
            let vault = try await lab.sync.prepare()
            #expect(await lab.sync.run([try await lab.row(7, in: vault)], nodes: [lab.node], into: vault)["node-a/7"]
                == .backedUp(version: 2, written: true))
            let row = try await lab.row(7, in: vault)
            // 1Password holds each version's attestation as metadata, byte for byte.
            let item = try #require(row.item)
            #expect(item.versions.map(\.attestation) == [
                KeyAttestation(keyID: "ed25519:node-a", signature: "sig-7-2"),
                KeyAttestation(keyID: "ed25519:node-a", signature: "sig-7-1"),
            ])
            #expect(item.versions.allSatisfy { $0.nodeID == DaemonKeys.attestingNode })
            #expect(row.recoveryAssurance == .guaranteed)

            // Recover sends them back unchanged, and the daemon restores both versions as the vault's own.
            lab.keys.update(7) { $0.readable = [] }
            let broken = try await lab.row(7, in: vault)
            let outcome = await KeyRestore(store: lab.helper).importToNode(
                broken, on: lab.node, in: vault, confirmName: "Photos", exportedBy: "test")
            guard case .imported(let report) = outcome else {
                Issue.record("got \(outcome)")
                return
            }
            #expect(report.keyAvailable && report.needsSalvage.isEmpty)
            #expect(lab.keys.receivedAttestations.withLock { $0[7] }
                == [2: DaemonKeys.attestation(7, 2), 1: DaemonKeys.attestation(7, 1)])
        }
    }

    @Test func backingUpAgainAddsAttestationsToAnOlderBackup() async throws {
        try await withLab([Self.photos(current: 2, needed: [1], rotating: true)], versions: [7: [1, 2]]) { lab in
            let vault = try await lab.sync.prepare()
            _ = await lab.sync.run([try await lab.row(7, in: vault)], nodes: [lab.node], into: vault)
            let before = try await lab.row(7, in: vault)
            #expect(before.recoveryAssurance == .bestEffort(unattestedVersions: [2, 1]))
            let keyBefore = try await lab.helper.reveal(onePasswordVaultID: vault.id, itemID: try #require(before.item).itemID)
                .versions.map { $0.key.withUnsafeBytes { Array($0) } }

            // The node is updated and attests keys now; nothing is "missing", so only a forced backup refreshes them.
            lab.keys.update(7) { $0.attests = true }
            #expect(await lab.sync.run([before], nodes: [lab.node], into: vault)["node-a/7"]
                == .skipped("A key rotation is under way; 1Password already holds every key it needs."))
            #expect(await lab.sync.run([before], nodes: [lab.node], into: vault, force: true)["node-a/7"]
                == .backedUp(version: 2, written: true))
            let after = try await lab.row(7, in: vault)
            #expect(after.recoveryAssurance == .guaranteed)
            let keyAfter = try await lab.helper.reveal(onePasswordVaultID: vault.id, itemID: try #require(after.item).itemID)
                .versions.map { $0.key.withUnsafeBytes { Array($0) } }
            #expect(keyAfter == keyBefore, "refreshing attestations never touches a stored key")
        }
    }

    @Test func recoverReportsWhatNeedsSalvageAndSalvageIsItsOwnConfirmedStep() async throws {
        var photos = Self.photos(current: 2, needed: [1], rotating: true)
        photos.requiresAttestation = true // the daemon now wants attestations; this backup predates them
        try await withLab([photos], versions: [7: [1, 2]]) { lab in
            let vault = try await lab.sync.prepare()
            _ = await lab.sync.run([try await lab.row(7, in: vault)], nodes: [lab.node], into: vault)
            lab.keys.update(7) { $0.readable = [] }
            let broken = try await lab.row(7, in: vault)
            #expect(broken.recoveryAssurance == .bestEffort(unattestedVersions: [2, 1]))
            let restore = KeyRestore(store: lab.helper)

            // Recover: nothing verifies, so nothing is written and no name is asked; both versions need salvage.
            let recovered = await restore.importToNode(broken, on: lab.node, in: vault, confirmName: nil, exportedBy: "t")
            guard case .imported(let report) = recovered else {
                Issue.record("got \(recovered)")
                return
            }
            #expect(!report.keyAvailable && !report.written)
            #expect(report.needsSalvage.map(\.version) == [1, 2])
            #expect(lab.keys.imported.withLock { $0[7] }?.isEmpty ?? true)

            // Salvage asks for the vault's name under its own code, then reports what it saved and lost.
            let asked = await restore.importToNode(broken, on: lab.node, in: vault, mode: .salvage, confirmName: nil,
                                                   exportedBy: "t")
            guard case .needsConfirmation(let message) = asked else {
                Issue.record("got \(asked)")
                return
            }
            #expect(message.contains("Type the vault's name"))
            let salvaged = await restore.importToNode(broken, on: lab.node, in: vault, mode: .salvage,
                                                      confirmName: "Photos", exportedBy: "t")
            guard case .imported(let salvage) = salvaged, let details = salvage.salvage else {
                Issue.record("got \(salvaged)")
                return
            }
            #expect(salvage.keyAvailable)
            #expect(details.newKeyVersion == 3 && details.recoveredFiles == 41 && details.unrecoverableCount == 1)
            #expect(details.unrecoverableFiles == ["/Photos/2019/broken.heic"])
            #expect(lab.daemon.payloads(of: "vault.keys.import").last?["mode"]?.stringValue == "salvage")
            #expect(lab.daemon.payloads(of: "vault.keys.import").first?["mode"] == nil, "recover leaves mode out")
        }
    }

    /// The parts of the export model `vh vault keys import` needs.
    struct ImportShape: Decodable {
        struct Info: Decodable { let key_version: Int }
        let vault_id: Int
        let key: String
        let key_info: Info
    }
}
}
