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

        try await leavingManagedStorage(client: client, account: account, memory: memory, lease: lease, me: me,
                                        sync: sync, otherVault: uid)
    }

    // MARK: stage 5: leaving managed storage

    static func ejectionView(_ j: [String: Any], _ uid: String) -> [String: Any]? {
        ((j["progress"] as? [String: Any])?["vaults"] as? [[String: Any]])?.first { $0["vault_uid"] as? String == uid }
    }

    static func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

    /// Stage 5 (docs/desktop-vaults.md, "Leaving managed storage"; vaulthalla-cloud managed-storage.md "Ejection" and "As
    /// built" 13, 25, 32): a vault this Mac holds goes through the account's ejection with the real daemon. The account
    /// holder asks; the Mac records it, reports its conversion and renews while the cloud can issue; the ejection runs
    /// through its destroy step to `ejected` with no further key asked; the Mac syncs until its last key ends, takes a key
    /// "the customer made in their own account" (an IAM key at moto scoped to the bucket) after refusing a wrong secret
    /// and another bucket's key; and a relaunch with the daemon stopped opens and syncs on that key alone.
    func leavingManagedStorage(client: CloudClient, account: CloudAccount, memory: MemoryAccountItemStore, lease: CredentialLease,
                               me: String, sync: DesktopVaultSession.Settings, otherVault: String) async throws {
        let container = FileManager.default.temporaryDirectory.appending(path: "vh-desktop-drill5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let items = LeasedAccountItems(items: memory, lease: lease)
        // The holding Mac reads the cloud's view every 15 s (the app: 30 minutes), so it sees the ejection in seconds.
        // Everything else is the app's: a leaving vault reads the view every 15 minutes, and before a renewal.
        var accessSettings = DeviceAccess.Settings()
        accessSettings.refreshInterval = 15
        let vaults = DesktopVaults(client: client, account: account, items: items, container: container,
                                   accessSettings: accessSettings, syncSettings: sync, bucketWait: 240)
        let name = "Drill Leaving \(tag)"
        let session = try await vaults.create(name: name)
        let uid = session.uid
        // Released before the relaunch (5.7): the engine's handle holds the vault's state lock, as a running app does.
        var held: Vault? = try #require(await session.openedVault())
        let beforeBytes = Data("written before the ejection \(tag)\n".utf8)
        let before = try await held!.perform { v throws(VaultError) in
            try v.write(beforeBytes, parent: try v.rootUID(), name: "before-\(tag).txt").entry.uid
        }
        await session.noteChange()
        _ = await session.syncNow(force: true)
        let synced = await session.status
        #expect(synced.state == .upToDate, "\(synced.sentence)")
        let e1 = try #require(await Self.copyKey(session.access))
        Self.note("5", "vault \(uid.prefix(6))… held by this Mac on the cloud's key \(e1.id.prefix(6))…")

        // ---- 5.1: the account holder asks, while the server holding the first vault is away (it can't report its own
        // conversion, so the ejection waits in `ejecting`: the Mac's renewal comes before the destroy step).
        _ = try await control("server-pause", ["pause": true])
        let asked = try await control("eject")
        #expect(asked["status"] as? Int == 202, "\(asked)")

        // ---- 5.2: the Mac sees `ejecting`, records it and reports its conversion at once.
        let reported = await eventually(120, every: 3) {
            let s = await session.access.status
            guard case .leaving = s.phase else { return false }
            return s.ejection?.reported == true
        }
        let leaving = await session.access.status
        #expect(reported, "the Mac converted in place and reported: \(leaving)")
        #expect(vaults.hasLeftManagedStorage(uid), "recorded on this Mac")
        #expect(leaving.ejection?.location?.bucket == e1.bucket)
        let ej1 = try await control("ejection", ["uid": uid])
        let writers1 = Self.ejectionView(ej1, uid)?["writers"] as? [[String: Any]] ?? []
        #expect(writers1.contains { $0["kind"] as? String == "desktop" && $0["installation_id"] as? String == me &&
                    $0["waited_for"] as? Bool == true && Self.number($0["converted_at"]) != nil },
                "GET /v1/storage/eject shows the Mac's report: \(ej1["progress"] ?? "-")")
        #expect((ej1["row"] as? [String: Any])?["destroyed_at"] is NSNull, "\(ej1["row"] ?? "-")")
        let view1 = try await client.storage().vault(uid)
        #expect(view1?.state == "ejecting" && view1?.credential?.renewableDuringEjection == true,
                "\(String(describing: view1))")
        Self.note("5", "ejecting: recorded, reported (\(writers1.count) writer(s) listed), renewable_during_ejection \(String(describing: view1?.credential?.renewableDuringEjection))")

        // ---- 5.3: while the cloud can still issue, the Mac renews at renew_after (5 minutes into the key).
        let renewed = await eventually(Double(Int(env["VH_DRILL_RENEW_WAIT"] ?? "420")!), every: 5) {
            await Self.copyKey(session.access).map { $0.id != e1.id } ?? false
        }
        #expect(renewed, "the Mac renewed its key during the ejection")
        let e2 = try #require(await Self.copyKey(session.access))
        let ej2 = try await control("ejection", ["uid": uid])
        let renewals = ej2["renewals"] as? [[String: Any]] ?? []
        #expect(renewals.contains { ($0["details"] as? [String: Any])?["during_ejection"] as? Bool == true },
                "audited storage.credential.renew during_ejection: \(renewals)")
        let keys2 = ej2["keys"] as? [[String: Any]] ?? []
        #expect(keys2.contains { $0["key_id"] as? String == e1.id && $0["revoke_reason"] as? String == "replaced" }, "\(keys2)")
        // The renewal's access is the basis key's (full): the ejection's own cancellation (billing leaves the plan
        // `restricted`) doesn't lower it.
        #expect(keys2.contains { $0["key_id"] as? String == e2.id && $0["state"] as? String == "active" &&
                    $0["access"] as? String == "full" }, "\(keys2)")
        #expect(await session.access.status.access == "full")
        #expect((ej2["row"] as? [String: Any])?["destroyed_at"] is NSNull, "renewed before the destroy step: \(ej2["row"] ?? "-")")
        if case .leaving(let until) = await session.accessPhase {
            let expiry = await session.access.status.expiresAt
            #expect(until == expiry)
        } else {
            Issue.record("still leaving after the renewal: \(await session.accessPhase)")
        }
        #expect(try await client.storage().vault(uid)?.credential?.renewableDuringEjection == true)
        let duringBytes = Data("written during the ejection \(tag)\n".utf8)
        let during = try await held!.perform { v throws(VaultError) in
            try v.write(duringBytes, parent: try v.rootUID(), name: "during-\(tag).txt").entry.uid
        }
        await session.noteChange()
        _ = await session.syncNow(force: true)
        let syncedDuring = await session.status
        #expect(syncedDuring.state == .upToDate, "\(syncedDuring.sentence)")
        Self.note("5", "renewed during the ejection: \(e1.id.prefix(6))… → \(e2.id.prefix(6))…, audited during_ejection; synced on it")

        // ---- 5.4: the server back; the ejection converts, tidies, destroys the cloud's credential and ejects.
        _ = try await control("server-pause", ["pause": false])
        var destroyedAt: Double?
        let destroyed = await eventually(600, every: 3) {
            destroyedAt = Self.number((try await control("ejection", ["uid": uid])["row"] as? [String: Any])?["destroyed_at"])
            return destroyedAt != nil
        }
        #expect(destroyed, "the ejection reached its destroy step")
        let view2 = try await client.storage().vault(uid)
        #expect(view2?.credential?.renewableDuringEjection == false, "after the destroy step: \(String(describing: view2))")
        let ejected = await eventually(300, every: 3) { try await client.storage().vault(uid)?.state == "ejected" }
        let view3 = try await client.storage().vault(uid)
        #expect(ejected && view3?.credential?.renewableDuringEjection == false, "\(String(describing: view3))")
        let ej4 = try await control("ejection", ["uid": uid])
        #expect((ej4["row"] as? [String: Any])?["state"] as? String == "complete", "\(ej4["row"] ?? "-")")
        Self.note("5", "destroy step at \(Int(destroyedAt ?? 0)); view: renewable_during_ejection false, bucket \(view3?.state ?? "?")")

        // ---- 5.5: the Mac syncs on its last key until it ends, then pauses for the person's own key.
        let afterBytes = Data("written after the destroy step \(tag)\n".utf8)
        let after = try await held!.perform { v throws(VaultError) in
            try v.write(afterBytes, parent: try v.rootUID(), name: "after-destroy-\(tag).txt").entry.uid
        }
        await session.noteChange()
        _ = await session.syncNow(force: true)
        let onLast = await session.status
        #expect(onLast.state == .upToDate, "on the last key: \(onLast.sentence)")
        let lastUntil = await session.access.status.expiresAt ?? Date()
        let paused = await eventually(max(0, lastUntil.timeIntervalSinceNow) + 90, every: 5) {
            await session.accessPhase == .needsOwnKey(.cloudKeyEnded)
        }
        _ = await session.syncNow(force: true)
        let pausedStatus = await session.status
        #expect(paused && pausedStatus.state == .needsOwnKey(.cloudKeyEnded), "\(pausedStatus.sentence)")
        #expect(pausedStatus.sentence.contains(e2.bucket), "\(pausedStatus.sentence)")
        #expect(await session.access.status.ejection?.renewalOver == true, "renewal recorded as over")
        #expect(Date() >= lastUntil, "paused only once the key's end passed")
        Self.note("5", "the last key ended at \(lastUntil); Mac says: \(pausedStatus.sentence)")

        // ---- 5.6: the person's own key: a wrong secret and another bucket's key change nothing; the right one switches.
        let bucketBefore = try await control("bucket", ["uid": uid])
        let own = try await control("own-key", ["uid": uid])
        let other = try await control("own-key", ["uid": uid, "of": otherVault])
        let ownID = try #require(own["key_id"] as? String)
        let ownSecret = try #require(own["secret"] as? String)
        #expect(own["bucket"] as? String == e2.bucket && other["bucket"] as? String != e2.bucket)
        await #expect(throws: DesktopVaultError.ownKey(.keyRefused)) {
            try await vaults.useOwnKey(uid, keyID: ownID, secret: SecretBytes(Data(String(repeating: "x", count: ownSecret.count).utf8)))
        }
        await #expect(throws: DesktopVaultError.ownKey(.keyRefused)) {
            try await vaults.useOwnKey(uid, keyID: try #require(other["key_id"] as? String),
                                       secret: SecretBytes(Data(try #require(other["secret"] as? String).utf8)))
        }
        #expect(await session.accessPhase == .needsOwnKey(.cloudKeyEnded))
        #expect(try BucketKeyStore(items: items).load(uid) == nil, "no key kept for a refused one")
        let bucketRefused = try await control("bucket", ["uid": uid])
        #expect(bucketRefused["versions"] as? Int == bucketBefore["versions"] as? Int &&
                bucketRefused["root"] as? String == bucketBefore["root"] as? String, "nothing written: \(bucketBefore) \(bucketRefused)")
        try await vaults.useOwnKey(uid, keyID: ownID, secret: SecretBytes(Data(ownSecret.utf8)))
        #expect(await session.accessPhase == .ownStorage)
        try await held!.perform { v throws(VaultError) in
            #expect(try v.readData(before) == beforeBytes)
        }
        let ownBytes = Data("written on the person's own key \(tag)\n".utf8)
        let onOwn = try await held!.perform { v throws(VaultError) in
            try v.write(ownBytes, parent: try v.rootUID(), name: "own-key-\(tag).txt").entry.uid
        }
        await session.noteChange()
        _ = await session.syncNow(force: true)
        let ownStatus = await session.status
        #expect(ownStatus.state == .upToDate && !ownStatus.unpublished, "\(ownStatus.sentence)")
        let bucketOwn = try await control("bucket", ["uid": uid])
        #expect((bucketOwn["versions"] as? Int ?? 0) > (bucketBefore["versions"] as? Int ?? 0) &&
                bucketOwn["root"] as? String != bucketBefore["root"] as? String, "published: \(bucketOwn)")
        // A fresh reader with that key alone and the vault's keys.
        let ownCopy = KeyCopy(id: ownID, secret: Data(ownSecret.utf8), bucket: e2.bucket, endpoint: e2.endpoint, region: e2.region)
        let (reader, _) = try await Vault.open(uid: try #require(Uid(base32: uid)), store: ownCopy.store,
                                               keys: KeychainVaultKeys(store: VaultKeyStore(items: items), uid: uid),
                                               stateURL: container.appending(path: "reader.state"), nodeID: "drill-reader")
        try await reader.perform { v throws(VaultError) in
            #expect(try v.readData(before) == beforeBytes)
            #expect(try v.readData(during) == duringBytes)
            #expect(try v.readData(after) == afterBytes)
            #expect(try v.readData(onOwn) == ownBytes)
        }
        // The daemon's side: no key request for this vault after the destroy step (and none answered other than 409).
        let ej5 = try await control("ejection", ["uid": uid])
        let requests = ej5["requests"] as? [[String: Any]] ?? []
        let late = requests.filter { $0["path"] as? String == "credentials" && (Self.number($0["at"]) ?? 0) > (destroyedAt ?? .infinity) }
        #expect(late.allSatisfy { $0["status"] as? Int == 409 }, "only 409s after the destroy step: \(late)")
        #expect(late.isEmpty, "no key asked after the destroy step: \(late)")
        let asks = requests.filter { $0["path"] as? String == "credentials" }
        Self.note("5", "own key: wrong secret and another bucket's key refused, nothing written; switched; fresh reader read 4 files; daemon answered \(asks.count) key request(s) for the vault (\(asks.map { "\($0["status"] ?? "?")" }.joined(separator: ","))), \(late.count) after the destroy step")

        // ---- 5.7: a relaunch with the cloud daemon stopped: new objects over the same keychain items and container.
        await vaults.closeAll()
        held = nil  // the first launch's engine handle (and its state lock) goes, as when the app quits
        let stopped = try await control("cloud-stop")
        #expect(stopped["stopped"] as? Bool == true)
        let items7 = LeasedAccountItems(items: memory, lease: lease)
        let client7 = try CloudClient(endpoint: env["VH_DRILL_CLOUD"]!, store: AccountCloudLinkStore(items: items7),
                                      transport: URLSessionCloudTransport())
        #expect((try? await client7.storage()) == nil, "the cloud is unreachable")
        let account7 = CloudAccount(client: client7, items: items7, holderKeys: HolderKeys(preferEnclave: false, userPresence: false))
        let vaults7 = DesktopVaults(client: client7, account: account7, items: items7, container: container,
                                    accessSettings: accessSettings, syncSettings: sync, bucketWait: 30)
        let session7 = try await vaults7.open(uid)
        #expect(await session7.accessPhase == .ownStorage)
        let vault7 = try #require(await session7.openedVault())
        let relaunchBytes = Data("written after the relaunch, the cloud stopped \(tag)\n".utf8)
        let relaunched = try await vault7.perform { v throws(VaultError) in
            #expect(try v.readData(onOwn) == ownBytes)
            return try v.write(relaunchBytes, parent: try v.rootUID(), name: "relaunched-\(tag).txt").entry.uid
        }
        await session7.noteChange()
        _ = await session7.syncNow(force: true)
        let status7 = await session7.status
        #expect(status7.state == .upToDate && !status7.unpublished, "\(status7.sentence)")
        let (reader7, _) = try await Vault.open(uid: try #require(Uid(base32: uid)), store: ownCopy.store,
                                                keys: KeychainVaultKeys(store: VaultKeyStore(items: items7), uid: uid),
                                                stateURL: container.appending(path: "reader7.state"), nodeID: "drill-reader-7")
        try await reader7.perform { v throws(VaultError) in
            #expect(try v.readData(relaunched) == relaunchBytes)
        }
        Self.note("5", "relaunched with the cloud stopped: \(await session7.accessPhase), \(status7.sentence)")
        await vaults7.closeAll()
    }
}

