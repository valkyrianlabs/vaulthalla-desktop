import CryptoKit
import Foundation
import Testing
import VHCore
@testable import VHCloud
import VHKeykit
import VHRecovery
@testable import VHVault

/// The Desktop-only vault drill (docs/desktop-vaults.md, "The drill"): Desktop's real client code against the real
/// Vaulthalla Cloud daemon, moto, the portal and a Vaulthalla server, all on the Linux box `dev`, which
/// `tools/vaultfmt/desktop-drill.sh` starts (vaulthalla-cloud `ci/milestone --only desktop`) and reaches through SSH
/// tunnels to its loopback (the same port numbers here, so the endpoints the cloud names work on this Mac). The owner's
/// browser and the operator's view are the drill's control endpoint there. Opt-in: runs only with VH_LIVE_DRILL.
///
///   VH_DRILL_CLOUD, VH_DRILL_CONTROL (http://127.0.0.1:<port>), VH_DRILL_TOKEN (the control endpoint's bearer)
///
/// No keychain item and no app data is touched: the link, the account key, the vault key and the bucket key live in a
/// ``MemoryAccountItemStore``, the vault's state and records in a temporary container, both gone with the test.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VH_LIVE_DRILL"] != nil), .serialized)
struct LiveDesktopDrillTests {
    let env = ProcessInfo.processInfo.environment
    let tag = String(UUID().uuidString.prefix(8)).lowercased()

    // MARK: the control endpoint

    struct ControlError: Error, CustomStringConvertible {
        let description: String
    }

    func control(_ op: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "\(env["VH_DRILL_CONTROL"]!)/\(op)")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 900
        r.setValue("Bearer \(env["VH_DRILL_TOKEN"]!)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: r)
        let out = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ControlError(description: "\(op): \(String(decoding: data, as: UTF8.self).prefix(1500))")
        }
        return out
    }

    /// Polls `fn` until it returns true or `timeout` passes.
    func eventually(_ timeout: TimeInterval, every: TimeInterval = 2, _ fn: () async throws -> Bool) async -> Bool {
        let end = Date() + timeout
        while Date() < end {
            if (try? await fn()) == true { return true }
            try? await Task.sleep(for: .seconds(every))
        }
        return (try? await fn()) == true
    }

    static func note(_ stage: String, _ text: String) { print("drill: stage \(stage): \(text)") }

    // MARK: what the Mac wrote

    /// path → {kind, size, sha256} from the vault's own folder, as the portal's reader and the server's tree compare it.
    static func manifest(_ v: Vault) throws(VaultError) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        func walk(_ dir: String, _ prefix: String) throws(VaultError) {
            for e in try v.list(dir) where !e.trashed {
                let path = "\(prefix)/\(e.name)"
                if e.kind == .directory {
                    out[path] = ["kind": "d"]
                    try walk(e.uid, path)
                } else if e.kind == .file {
                    let bytes = try v.readData(e.uid)
                    out[path] = ["kind": "f", "size": bytes.count,
                                 "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
                }
            }
        }
        try walk(try v.rootUID(), "")
        return out
    }

    struct KeyCopy: Sendable {
        let id: String
        let secret: Data
        let bucket: String
        let endpoint: String
        let region: String
        var store: S3Store {
            S3Store(credentials: StaticS3Credentials(accessKeyID: id, secret: secret, bucket: bucket, endpoint: endpoint,
                                                     region: region),
                    scratch: FileManager.default.temporaryDirectory.appending(path: "vh-drill-scratch-\(UUID().uuidString)"))
        }

        /// moto's answer to this key: nil when it reads, else the refusal.
        func refusal() -> String? {
            do {
                _ = try store.head(".vaulthalla/root")
                return nil
            } catch {
                return String(describing: error)
            }
        }
    }

    static func copyKey(_ access: DeviceAccess) async -> KeyCopy? {
        await access.withS3Credentials { c in
            KeyCopy(id: c.accessKeyID, secret: Data(c.secret), bucket: c.bucket, endpoint: c.endpoint, region: c.region)
        }
    }

    // MARK: the drill

    @Test func theDesktopOnlyVaultDrill() async throws {
        let container = FileManager.default.temporaryDirectory.appending(path: "vh-desktop-drill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let lease = CredentialLease(forRegistry: container.appending(path: "nodes.json"), holder: "drill")
        try lease.acquire()
        let memory = MemoryAccountItemStore()
        let items = LeasedAccountItems(items: memory, lease: lease)
        let client = try CloudClient(endpoint: env["VH_DRILL_CLOUD"]!, store: AccountCloudLinkStore(items: items),
                                     transport: URLSessionCloudTransport())
        let account = CloudAccount(client: client, items: items, holderKeys: HolderKeys(preferEnclave: false, userPresence: false))

        // ---------------------------------------------------------------- 1: link, the account key, the state
        let started = try await client.startLink(name: "Drill Mac \(tag)")
        let approved = try await control("approve-link", ["user_code": started.userCode, "fingerprint": started.fingerprint])
        #expect(try await client.claimLink() == .linked)
        let me = try #require(try client.link()?.installationID)
        #expect(approved["installation_id"] as? String == me)
        let installation = try await client.installation()
        #expect(installation.kind == "desktop")
        #expect(try await account.status().cloud == nil)  // the account has no key yet: Desktop makes it

        let first = try await account.prepareFirstKey()
        let recoveryCode = try first.recoveryCode().withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        let open = try await account.submit(first, offlineCopyConfirmed: true)
        let decided = try await control("approve-key", ["request_id": open.request.id, "code": open.code])
        #expect(decided["status"] as? String == "approved")
        #expect(try await account.checkPendingKey() == .applied)
        let keyStatus = try await account.status()
        #expect(keyStatus.holdsCurrent && keyStatus.offlineCopyConfirmedAt != nil)
        let cloudKey = (decided["account_key"] as? [String: Any])?["current"] as? [String: Any]
        #expect(cloudKey?["fingerprint"] as? String == keyStatus.fingerprint?.text,
                "cloud \(cloudKey?["fingerprint"] ?? "-") vs Desktop \(keyStatus.fingerprint?.text ?? "-")")
        #expect(try await client.billing().state == "active")
        let view = try await client.storage()
        #expect(view.entitlement.storageAccess == "full" && view.accountKeyOfflineCopyConfirmed)
        Self.note("1", "linked as \(installation.kind), account key generation \(keyStatus.held?.generation ?? 0) held, offline copy confirmed, plan \(view.entitlement.plan) \(view.entitlement.storageAccess)")

        // ---------------------------------------------------------------- 2: a Desktop-only vault for real
        var sync = DesktopVaultSession.Settings()
        sync.refreshInterval = 20
        let vaults = DesktopVaults(client: client, account: account, items: items, container: container,
                                   syncSettings: sync, bucketWait: 240)
        #expect(await vaults.readiness() == .ready)
        let name = "Drill Taxes \(tag)"
        let steps = StepLog()
        let session: DesktopVaultSession
        do {
            session = try await vaults.create(name: name) { steps.add($0) }
        } catch {
            // What the creation got to, for the report: the steps, the key loop's phase, and moto's answer to the key.
            var phase: DeviceAccess.Phase?
            var key: KeyCopy?
            if let uid = await vaults.records().first?.uid, let held = await vaults.session(uid) {
                phase = await held.accessPhase
                key = await Self.copyKey(held.access)
            }
            Issue.record("create: \(error); steps \(steps.all); phase \(String(describing: phase)); moto: \(key?.refusal() ?? "reads")")
            throw error
        }
        let uid = session.uid
        let phase = await session.accessPhase
        let sentence = await session.status.sentence
        let cloudView = (try? await control("storage", ["uid": uid])).map { "\($0)" } ?? "-"
        #expect(steps.all.contains(.publishing) && steps.all.last == .done,
                "steps \(steps.all), phase \(phase), \(sentence), cloud \(cloudView)")
        let held = try await client.storage().vault(uid)
        #expect(held?.desktop?.installationId == me && held?.state == "ready")
        let vault = try #require(await session.openedVault())

        let report = Data((0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0 &* 7919 &+ 13) })
        let notes = Data("drill plaintext \(tag): the quarterly numbers\n".utf8)
        let names = ["Docs-\(tag)", "report-\(tag).bin", "notes-\(tag).txt", "draft-\(tag).txt", "final-\(tag).txt",
                     "trash-\(tag).txt", "empty-\(tag).txt", "Deep-\(tag)", "inner-\(tag).txt"]
        try await vault.perform { v throws(VaultError) in
            let root = try v.rootUID()
            let docs = try v.mkdir(parent: root, name: names[0])
            _ = try v.write(report, parent: docs.uid, name: names[1])
            _ = try v.write(notes, parent: root, name: names[2])
            let draft = try v.write(Data("a draft \(tag)".utf8), parent: docs.uid, name: names[3]).entry
            try v.rename(draft.uid, to: names[4])
            let trash = try v.write(Data("thrown away \(tag)".utf8), parent: root, name: names[5]).entry
            try v.trashEntry(trash.uid)
            _ = try v.write(Data(), parent: root, name: names[6])
            let deep = try v.mkdir(parent: docs.uid, name: names[7])
            _ = try v.write(Data("inner \(tag)".utf8), parent: deep.uid, name: names[8])
        }
        await session.noteChange()
        _ = await session.syncNow(force: true)
        let afterCreate = await session.status
        #expect(afterCreate.state == .upToDate && !afterCreate.unpublished, "\(afterCreate.sentence)")

        // Renewal: the run loop renews at renew_after; the old key goes at the provider.
        let k1 = try #require(await Self.copyKey(session.access))
        let renewed = await eventually(Double(Int(env["VH_DRILL_RENEW_WAIT"] ?? "420")!), every: 5) {
            await Self.copyKey(session.access).map { $0.id != k1.id } ?? false
        }
        #expect(renewed, "the bucket key was renewed")
        let k2 = try #require(await Self.copyKey(session.access))
        let keys2 = try await control("storage", ["uid": uid])["keys"] as? [[String: Any]] ?? []
        #expect(keys2.contains { $0["key_id"] as? String == k1.id && $0["revoke_reason"] as? String == "replaced" })
        #expect(await eventually(60) { k1.refusal() != nil }, "moto refuses the replaced key")
        try await vault.perform { v throws(VaultError) in
            _ = try v.write(Data("after renewal \(tag)".utf8), parent: try v.rootUID(), name: "after-renewal-\(tag).txt")
        }
        _ = await session.syncNow(force: true)
        let afterRenewal = await session.status
        #expect(afterRenewal.state == .upToDate, "\(afterRenewal.sentence)")
        Self.note("2", "renewed: \(k1.id.prefix(6))… → \(k2.id.prefix(6))…, the old one refused by moto")

        // Expiry: the cloud revokes the key at its end and deletes it at moto; the Mac's next request is refused (403)
        // and the key is replaced without waiting for the next scheduled renewal.
        _ = try await control("expire", ["uid": uid])
        #expect(await eventually(60) { k2.refusal() != nil }, "moto refuses the expired key")
        let refusedAt = Date()
        // The write itself meets the refusal first (the content goes up at once); the session's key loop is woken by
        // it and the write succeeds again once the new key is in.
        var firstRefusal: String?
        let replaced = await eventually(150, every: 3) {
            do {
                try await vault.perform { v throws(VaultError) in
                    _ = try v.write(Data("after expiry \(tag)".utf8), parent: try v.rootUID(), name: "after-expiry-\(tag).txt")
                }
            } catch {
                firstRefusal = firstRefusal ?? String(describing: error)
                return false
            }
            await session.noteChange()
            _ = await session.syncNow(force: true)
            let k = await Self.copyKey(session.access)
            let state = await session.status.state
            return k != nil && k!.id != k2.id && state == .upToDate
        }
        #expect(replaced, "the expired key was replaced after moto refused it and the change published")
        #expect(firstRefusal?.contains("403") == true, "the first write after the expiry met moto's 403: \(firstRefusal ?? "none")")
        let k3 = try #require(await Self.copyKey(session.access))
        Self.note("2", "expired key refused by moto and replaced after \(Int(Date().timeIntervalSince(refusedAt))) s")

        let expect = try await vault.perform { v throws(VaultError) in
            let m = try Self.manifest(v)
            return (try? JSONSerialization.data(withJSONObject: m)) ?? Data()
        }
        let expected = try #require(try JSONSerialization.jsonObject(with: expect) as? [String: Any])
        #expect(expected.keys.contains("/\(names[0])/\(names[4])") && !expected.keys.contains("/\(names[0])/\(names[3])"))
        #expect(!expected.keys.contains("/\(names[5])"))
        let needles = (names + [name, "drill plaintext \(tag)", "after renewal \(tag)", "inner \(tag)"]).map {
            Data($0.utf8).base64EncodedString()
        } + [report.prefix(32).base64EncodedString()]
        let inspected = try await control("inspect", ["uid": uid, "needles": needles])
        #expect((inspected["names_not_opaque"] as? [Any])?.isEmpty == true, "\(inspected)")
        #expect((inspected["found"] as? [Any])?.isEmpty == true, "\(inspected)")
        #expect(inspected["control"] as? Bool == true && (inspected["versions"] as? Int ?? 0) > 5)
        let recorded = (try await control("storage", ["uid": uid])["versions"] as? [[String: Any]]) ?? []
        let macVault = try Provenance.macOriginVaultID(uid: Data(try #require(Uid(base32: uid)).bytes))
        #expect(recorded.count == 1 && recorded.first?["origin_node_id"] as? String == me &&
                (recorded.first?["origin_vault_id"] as? NSNumber)?.uint32Value == macVault &&
                recorded.first?["attested"] as? Bool == true, "version 1 recorded under this Mac's origin: \(recorded)")
        Self.note("2", "bucket: \(inspected["versions"] ?? 0) object versions, names opaque, no name or plaintext found")

        // ---------------------------------------------------------------- 3: the portal reads it back
        let read = try await control("portal-read", ["uid": uid, "expect": expected, "recovery_code": recoveryCode])
        for c in read["checks"] as? [[String: Any]] ?? [] {
            #expect(c["ok"] as? Bool == true, "\(c["check"] ?? "") \(c["detail"] ?? "")")
        }
        #expect(read["rc"] as? Int == 0, "\(read["stderr"] ?? "")")
        let write = try await control("reader-write", ["uid": uid])
        #expect(write["access"] as? String == "read" && write["read"] is Int, "\(write)")
        #expect(write["write"] as? Int == 403, "moto refuses the reader key's write: \(write)")
        Self.note("3", "portal: \((read["checks"] as? [Any])?.count ?? 0) checks, rc \(read["rc"] ?? "?"); reader write \(write["write"] ?? "?")")

        // ---------------------------------------------------------------- 4: a server takes it over
        let macKey = try #require(await Self.copyKey(session.access))
        #expect(macKey.id == k3.id || macKey.refusal() == nil)
        // The server's restore, approved by the owner and delivered by this Mac (the account key's holder).
        func takeOver(salvage: Bool) async throws -> [String: Any] {
            let server = try await control("server-start", ["uid": uid, "salvage": salvage, "name": name])
            #expect(server["started"] as? Bool == true, "\(server)")
            #expect(server["approved"] as? Int == 200, "\(server)")
            let restoreID = server["restore_id"] as? String
            let deliverable = try await client.deliverable()
            let restore = try #require(deliverable.first { $0.id == restoreID }, "the Mac sees the server's restore")
            #expect(restore.restoreCode == server["restore_code"] as? String, "the Mac computes the code the server printed")
            let delivered = try await account.deliver(restore)
            #expect(delivered.versions == [1] && delivered.missing.isEmpty)
            return try await control("server-finish", ["uid": uid, "expect": expected])
        }
        // This Mac attested version 1 when it created the vault (docs/desktop-vaults.md, "Key provenance"): the server
        // proves it canonically. First the negative: with the recorded attestation made wrong (one bit), the version is
        // unproven and the restore stops with salvage_required; then, put back as the Mac recorded it, canonical.
        _ = try await control("attestation", ["uid": uid])
        let wrong = try await takeOver(salvage: false)
        let refusal = (wrong["result"] as? [String: Any])?["error"] as? String
        #expect(wrong["exit"] as? Int == 2 && refusal == "salvage_required", "a wrong attestation proves nothing: \(wrong)")
        _ = try await control("attestation", ["uid": uid, "restore": true])
        let finished = try await takeOver(salvage: false)
        let result = finished["result"] as? [String: Any]
        #expect(result?["mode"] as? String == "canonical" && (result?["salvage"] is NSNull || result?["salvage"] == nil),
                "a canonical restore, nothing salvaged: \(finished)")
        Self.note("4", "wrong attestation: \(refusal ?? "accepted?"); as recorded: \(result?["mode"] ?? "?")")
        #expect(finished["exit"] as? Int == 0, "\(finished)")
        #expect((finished["diff"] as? [String: Any])?.isEmpty == true, "the server's tree is the Mac's: \(finished)")
        // Restored under the vault's own name (spaces and all), mounted as its slug (vaulthalla-server migration 096).
        #expect(finished["vault_name"] as? String == name && finished["fuse_name"] as? String == "drill-taxes-\(tag)",
                "\(finished["vault_name"] ?? "-") at \(finished["fuse_name"] ?? "-")")
        let keys4 = finished["keys"] as? [[String: Any]] ?? []
        #expect(keys4.contains { $0["key_id"] as? String == macKey.id && $0["revoke_reason"] as? String == "desktop_moved" },
                "\(keys4)")
        #expect(keys4.contains { $0["kind"] as? String == "server" && $0["state"] as? String == "active" }, "\(keys4)")
        #expect(await eventually(90) { macKey.refusal() != nil }, "moto refuses the Mac's key once the vault moved")
        let moved = try await client.storage().vault(uid)
        #expect(moved?.movedTo?.name == "drill-nas", "\(String(describing: moved))")
        let stopped = await eventually(120, every: 3) {
            _ = await session.syncNow(force: true)
            if case .stopped(.moved(_, let to)) = await session.accessPhase { return to == "drill-nas" }
            return false
        }
        _ = await session.syncNow(force: true)
        let movedSentence = await session.status.sentence
        #expect(movedSentence.contains("drill-nas"), "\(movedSentence)")
        #expect(stopped, "the Mac's client reports the vault moved to drill-nas: \(movedSentence)")
        let refused = try await control("reader-refused", ["uid": uid])
        #expect(refused["status"] as? Int == 409 && refused["reason"] as? String == "held_by_server", "\(refused)")
        let page = refused["page"] as? [String: Any]
        #expect(page?["rc"] as? Int == 0, "\(String(describing: page))")
        Self.note("4", "server restored \(finished["entries"] ?? 0) entries equal; Mac key \(macKey.id.prefix(6))… revoked and refused; Mac says: \(movedSentence); reader refused \(refused["reason"] ?? "?")")
        await vaults.closeAll()
    }
}
