import Foundation
@testable import VHCloud
import VHCore
import VHKeykit
import VHRecovery

/// A clock tests move by hand; `sleep(until:)` moves it there at once.
final class ManualClock: DeviceAccessClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    func set(_ d: Date) { lock.withLock { current = d } }
    func sleep(until: Date) async throws {
        try Task.checkCancellation()
        lock.withLock { if until > current { current = until } }
    }
}

/// Vaulthalla Cloud's Desktop-only vault routes, written from the daemon's code (vaulthalla-cloud main):
/// `src/accounts/Deployments.cpp` (`registerVault`, `requireVault`, `heldElsewhere`, `releaseHold`, the
/// `/v1/vaults` routes and their reasons), `src/storage/ManagedStorage.cpp` (`overview`, `vaultView`, `keyView`,
/// `setVault`, `issueCredential`, `acknowledge`, the hooks that revoke keys) and `src/http/Errors.cpp` (the error
/// envelope with `reason`). The numbers are the daemon's defaults (`storage.desktop_key_minutes` 1440,
/// `storage.desktop_renew_minutes` 720, `storage.credentials_per_hour` 10). Secrets are sealed with vl-keykit to the
/// one-time key the request sends, exactly as the cloud does; linking and VHC1 verification are ``FakeCloud``'s.
final class FakeDeviceCloud: CloudTransport, @unchecked Sendable {
    let base = FakeCloud()
    let clock: ManualClock
    let lock = NSLock()

    static let keyMinutes: TimeInterval = 1440
    static let renewMinutes: TimeInterval = 720
    static let credentialsPerHour = 10

    var mac: String { base.installation }
    let otherMac = "t8strmqnma7qe89214v79ecrmc"
    let deployment = "a5r3c6tgm1kvn7e2b8x4q0w9yz"
    var names: [String: String] { [mac: "MacBook", otherMac: "iMac"] }

    struct Key {
        var id: String
        var installation: String
        var access: String
        var state: String  // issued, active, superseded, revoking, revoked
        var issuedAt: Date
        var expiresAt: Date
        var renewAfter: Date
        var revokeReason: String?
        var secret: Data
    }

    struct Hold {
        var installation: String
        var active: Bool
        var removedReason: String?
    }

    struct Vault {
        var uid: String
        var holds: [Hold] = []
        var replicas: [String] = []  // deployment ids
        var bucketState = "none"     // none, waiting, ready, off, emptying, ejecting, ejected
        var waitingReason: String?
        var enabled = false
        var keys: [Key] = []
        var holder: String? { holds.last(where: \.active)?.installation }
    }

    var vaults: [String: Vault] = [:]
    var order: [String] = []
    var entitlementState: String? = "active"
    var storageAccess = "full"
    var cause = "active"
    var offlineCopy = true
    var ejection: String?
    var installationRevoked = false
    /// What Desktop sent, for the checks that no secret leaves it.
    var sent: [String] = []
    var credentialRequests = 0
    /// Test switches: answer the next signed storage request with this failure; leave out a Mac key's expiry; seal
    /// to another installation's binding.
    var failNext: (status: Int, code: String, reason: String?, retryAfter: String?)?
    var omitExpiry = false
    var sealForAnotherInstallation = false
    private var counter = 0

    init(clock: ManualClock) { self.clock = clock }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let deviceRoute = path.hasPrefix("/v1/storage") || path.hasPrefix("/v1/vaults")
        guard deviceRoute else { return try await base.send(request) }
        return lock.withLock { handle(request) }
    }

    // MARK: what the portal, billing, other devices and the cloud's jobs do

    /// A new uid the account holder placed on `installation` (or registered by this Mac when it is `mac`).
    func vault(heldBy installation: String?, bucket: String = "ready") -> String {
        lock.withLock {
            let uid = Uid.random().base32
            var v = Vault(uid: uid)
            if let installation { v.holds = [Hold(installation: installation, active: true)] }
            v.bucketState = bucket
            v.enabled = bucket != "none"
            vaults[uid] = v
            order.append(uid)
            return uid
        }
    }

    func serverVault() -> String {
        lock.withLock {
            let uid = Uid.random().base32
            var v = Vault(uid: uid)
            v.replicas = [deployment]
            vaults[uid] = v
            order.append(uid)
            return uid
        }
    }

    /// The bucket provisioning job finished.
    func provision(_ uid: String) { lock.withLock { vaults[uid]!.bucketState = "ready"; vaults[uid]!.waitingReason = nil } }

    /// `PUT /v1/vaults/{uid}/desktop` by the owner: the vault moves to `installation`; the old Mac's keys go
    /// (`desktop_reassigned`).
    func ownerPlaces(_ uid: String, on installation: String) {
        lock.withLock { releaseHold(uid, reason: "reassigned"); vaults[uid]!.holds.append(Hold(installation: installation, active: true)) }
    }

    /// `DELETE /v1/vaults/{uid}/desktop` by the owner (`desktop_owner`).
    func ownerTakesOff(_ uid: String) { lock.withLock { releaseHold(uid, reason: "owner") } }

    /// `DELETE /v1/storage/credentials/{key_id}` by the owner.
    func ownerRevokesKeys(_ uid: String) {
        lock.withLock {
            for i in vaults[uid]!.keys.indices where !["revoking", "revoked"].contains(vaults[uid]!.keys[i].state) {
                vaults[uid]!.keys[i].state = "revoked"
                vaults[uid]!.keys[i].revokeReason = "owner"
            }
        }
    }

    /// A restore approved onto a server (`moveVault`): the Mac's hold goes (`moved`), the server's replica comes.
    func serverAdopts(_ uid: String) {
        lock.withLock {
            releaseHold(uid, reason: "moved")
            vaults[uid]!.replicas = [deployment]
        }
    }

    /// Billing's state, and what storage's `account.enforce` does with it (ManagedStorage `decide` and the swap).
    func entitle(_ state: String, overQuota: Bool = false) {
        lock.withLock {
            entitlementState = state
            switch state {
            case "active", "past_due": storageAccess = overQuota ? "read_delete" : "full"; cause = overQuota ? "over_quota" : state
            case "restricted": storageAccess = "read_delete"; cause = state
            default: storageAccess = "none"; cause = state
            }
            for uid in order {
                for i in vaults[uid]!.keys.indices {
                    let k = vaults[uid]!.keys[i]
                    if storageAccess == "none", !["revoking", "revoked"].contains(k.state) {
                        vaults[uid]!.keys[i].state = "revoked"
                        vaults[uid]!.keys[i].revokeReason = "entitlement_\(state)"
                    } else if storageAccess != "none", k.access != storageAccess {
                        if k.state == "active" { vaults[uid]!.keys[i].state = "superseded" }
                        if k.state == "issued" { vaults[uid]!.keys[i].state = "revoked"; vaults[uid]!.keys[i].revokeReason = "swap" }
                    }
                }
            }
        }
    }

    /// `expireDue()`: every key past its `expires_at` is revoked (`expired`).
    func expireDue() {
        lock.withLock {
            for uid in order {
                for i in vaults[uid]!.keys.indices where ["issued", "active", "superseded"].contains(vaults[uid]!.keys[i].state)
                    && vaults[uid]!.keys[i].expiresAt <= clock.now {
                    vaults[uid]!.keys[i].state = "revoked"
                    vaults[uid]!.keys[i].revokeReason = "expired"
                }
            }
        }
    }

    func keys(_ uid: String) -> [Key] { lock.withLock { vaults[uid]!.keys } }
    func activeKey(_ uid: String) -> Key? { keys(uid).first { $0.state == "active" } }

    // MARK: the daemon's logic

    private func releaseHold(_ uid: String, reason: String) {
        guard let i = vaults[uid]!.holds.lastIndex(where: \.active) else { return }
        let installation = vaults[uid]!.holds[i].installation
        vaults[uid]!.holds[i].active = false
        vaults[uid]!.holds[i].removedReason = reason
        // Hooks::onDesktopReleased: that Mac's keys for the bucket go.
        for k in vaults[uid]!.keys.indices where vaults[uid]!.keys[k].installation == installation
            && !["revoking", "revoked"].contains(vaults[uid]!.keys[k].state) {
            vaults[uid]!.keys[k].state = "revoked"
            vaults[uid]!.keys[k].revokeReason = "desktop_\(reason)"
        }
    }

    private func keyView(_ v: Vault, _ installation: String) -> [String: Any] {
        let rank = ["issued": 0, "active": 1, "superseded": 2]
        let inForce = v.keys.filter { $0.installation == installation && rank[$0.state] != nil }
            .sorted { (rank[$0.state]!, -$0.issuedAt.timeIntervalSince1970) < (rank[$1.state]!, -$1.issuedAt.timeIntervalSince1970) }
        if let k = inForce.first {
            return ["key_id": k.id, "state": k.expiresAt <= clock.now ? "expired" : k.state, "access": k.access,
                    "expires_at": secs(k.expiresAt), "renew_after": secs(k.renewAfter)]
        }
        if let last = v.keys.filter({ $0.installation == installation }).max(by: { $0.issuedAt < $1.issuedAt }),
           last.revokeReason == "expired" {
            return ["state": "expired", "access": last.access, "expires_at": secs(last.expiresAt), "renew_after": secs(last.renewAfter)]
        }
        return ["state": "none"]
    }

    private func vaultView(_ v: Vault, _ installation: String) -> [String: Any] {
        let visible = ["ready", "off", "ejecting", "ejected"].contains(v.bucketState)
        var out: [String: Any] = ["vault_uid": v.uid, "enabled": v.enabled, "state": v.bucketState,
                                  "reason": v.waitingReason ?? NSNull(),
                                  "bucket": visible ? "vhc-\(v.uid)" : NSNull(), "bucket_id": visible ? "b-\(v.uid)" : NSNull(),
                                  "s3_endpoint": visible ? "https://s3.us-west-004.backblazeb2.test" : NSNull(),
                                  "region": visible ? "us-west-004" : NSNull(),
                                  "content_retention_days": v.bucketState == "none" ? NSNull() : 30,
                                  "detached_at": NSNull(), "converted_at": NSNull()]
        if let h = v.holder {
            var key = keyView(v, h)
            key["key_id"] = nil
            out["desktop"] = ["installation_id": h, "name": names[h] ?? "Mac", "fingerprint": "aaaa-bbbb-cccc-dddd",
                              "last_seen": NSNull(), "credential": key]
        } else {
            out["desktop"] = NSNull()
        }
        out["credential"] = keyView(v, installation)
        // movedFromDesktop: this Mac's hold removed as `moved`, a replica active, and no hold of its own again.
        if v.holds.contains(where: { $0.installation == installation && $0.removedReason == "moved" }),
           !v.replicas.isEmpty, !v.holds.contains(where: { $0.installation == installation && $0.active }) {
            out["moved_to"] = ["deployment_id": v.replicas[0], "name": "nas"]
        }
        return out
    }

    private func vaultJSON(_ v: Vault) -> [String: Any] {
        var out: [String: Any] = ["vault_uid": v.uid, "label": NSNull(), "registered_at": 1,
                                  "replicas": v.replicas.map { ["deployment_id": $0, "origin_vault_id": 3, "added_at": 1] }]
        out["desktop"] = v.holder.map { ["installation_id": $0, "name": names[$0] ?? "Mac", "fingerprint": "aaaa-bbbb-cccc-dddd",
                                         "last_seen": NSNull(), "since": 1] as [String: Any] } ?? NSNull()
        return out
    }

    /// Deployments.cpp `heldElsewhere`.
    private func heldElsewhere(_ v: Vault) -> (Int, String, String) {
        if !v.replicas.isEmpty { return (409, "held_by_server", "the server \"nas\" holds this vault") }
        if let h = v.holder {
            return (409, "held_by_desktop", "the Mac \"\(names[h] ?? "Mac")\" holds this vault; for now one Mac writes to a vault")
        }
        return (409, "unplaced", "no device holds this vault; the account holder places it in the portal")
    }

    private func secs(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970.rounded(.down)) }

    private func handle(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let method = request.httpMethod!
        sent.append("\(method) \(request.url!.absoluteString) \(String(decoding: request.httpBody ?? Data(), as: UTF8.self))")
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func reply(_ status: Int, _ json: Any, headers: [String: String]? = nil) -> (Data, HTTPURLResponse) {
            (status == 204 ? Data() : try! JSONSerialization.data(withJSONObject: json),
             HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        // src/http/Errors.cpp errorResponse: `reason` only when the Error has one.
        func refuse(_ status: Int, _ code: String, _ message: String, reason: String? = nil,
                    headers: [String: String]? = nil) -> (Data, HTTPURLResponse) {
            var error: [String: Any] = ["code": code, "message": message]
            if let reason { error["reason"] = reason }
            return reply(status, ["error": error], headers: headers)
        }
        func conflict(_ r: (Int, String, String)) -> (Data, HTTPURLResponse) { refuse(r.0, "conflict", r.2, reason: r.1) }
        guard !installationRevoked, base.verifies(request) else {
            return refuse(401, "unauthenticated", "request signature rejected")
        }
        if let f = failNext {
            failNext = nil
            return refuse(f.status, f.code, "refused for the test", reason: f.reason, headers: f.retryAfter.map { ["Retry-After": $0] })
        }
        let parts = path.split(separator: "/").map(String.init)
        let me = mac
        switch (method, parts.count) {
        case ("GET", 2) where path == "/v1/storage":
            let ejectionJSON: Any = ejection.map { ["state": $0, "requested_at": 1, "subscription_cancelled_at": NSNull(),
                                                    "tidied_at": NSNull(), "credential_destroyed_at": NSNull(),
                                                    "completed_at": NSNull(), "refused": NSNull()] as [String: Any] } ?? NSNull()
            return reply(200, ["entitlement": ["state": entitlementState.map { $0 as Any } ?? NSNull(), "plan": "storage_1tb",
                                               "storage_quota_bytes": 1_000_000_000_000, "storage_access": storageAccess,
                                               "cause": cause],
                               "usage": ["stored_bytes": NSNull(), "date": NSNull()],
                               "account_key_offline_copy_confirmed": offlineCopy, "ejection": ejectionJSON,
                               "ejection_portal_url": "https://app.vaulthalla.test/storage/leave", "provider": "fake",
                               "vaults": order.map { vaultView(vaults[$0]!, me) }])
        case ("GET", 3) where parts[1] == "vaults":
            guard let v = vaults[parts[2]] else { return refuse(404, "not_found", "no such vault") }
            return reply(200, vaultJSON(v))
        case ("POST", 2) where path == "/v1/vaults":
            guard let uid = body["vault_uid"] as? String, Uid(base32: uid) != nil else {
                return refuse(400, "invalid_argument", "`vault_uid` is the vault's uid (26 lower-case base32 symbols)")
            }
            if body["origin_vault_id"] != nil { return refuse(400, "invalid_argument", "a Desktop's vault has no `origin_vault_id`") }
            if let v = vaults[uid] {
                if v.holder == me { return reply(200, vaultJSON(v).merging(["created": false]) { $1 }) }
                return conflict(heldElsewhere(v))
            }
            vaults[uid] = Vault(uid: uid, holds: [Hold(installation: me, active: true)])
            order.append(uid)
            return reply(201, vaultJSON(vaults[uid]!).merging(["created": true]) { $1 })
        case ("DELETE", 4) where parts[1] == "vaults" && parts[3] == "replica":
            guard let v = vaults[parts[2]] else { return refuse(404, "not_found", "no such vault", reason: "no_such_vault") }
            guard v.holder == me else { return conflict(heldElsewhere(v)) }
            releaseHold(v.uid, reason: "desktop")
            return reply(204, [:])
        case ("PUT", 4) where parts[1] == "storage" && parts[2] == "vaults":
            let uid = parts[3]
            guard var v = vaults[uid] else { return refuse(404, "not_found", "no such vault") }
            if body["content_retention_days"] != nil, v.holder != me {
                return refuse(403, "forbidden", "a Desktop changes the switch only; retention is the server's or the portal's")
            }
            guard let enabled = body["enabled"] as? Bool else { return refuse(400, "invalid_argument", "send `enabled`") }
            if v.bucketState == "none", enabled {
                v.bucketState = "waiting"
            } else if enabled, v.bucketState == "off" {
                v.bucketState = "ready"
            } else if !enabled, ["ready", "waiting"].contains(v.bucketState) {
                v.bucketState = "off"
            }
            v.enabled = enabled
            vaults[uid] = v
            return reply(202, vaultView(v, me))
        case ("POST", 5) where parts[1] == "storage" && parts[2] == "vaults" && parts[4] == "credentials":
            let uid = parts[3]
            guard let pkText = body["public_key"] as? String, let pk = Base64URL.decode(pkText), pk.count == 32 else {
                return refuse(400, "invalid_argument", "`public_key` is the one-time X25519 public key, base64url of 32 bytes")
            }
            // requireVault(Write) for a Desktop.
            guard let v = vaults[uid] else { return refuse(404, "not_found", "no such vault", reason: "no_such_vault") }
            guard v.holder == me else { return conflict(heldElsewhere(v)) }
            guard offlineCopy else {
                return refuse(409, "conflict", "the account key's offline copy isn't confirmed yet", reason: "account_key_unconfirmed")
            }
            if v.bucketState != "ready" {
                if v.bucketState == "off" { return refuse(409, "conflict", "this vault's storage is switched off", reason: "bucket_off") }
                if v.bucketState == "ejecting" { return refuse(409, "conflict", "this account's storage is being ejected", reason: "ejecting") }
                return refuse(409, "conflict", "this vault's bucket isn't ready", reason: "bucket_not_ready")
            }
            if let e = ejection, e != "refused" { return refuse(409, "conflict", "this account's storage is being ejected", reason: "ejecting") }
            if storageAccess == "none" { return refuse(402, "payment_required", "managed storage needs an active plan (\(cause))") }
            let recent = order.flatMap { vaults[$0]!.keys }.filter { $0.installation == me && $0.issuedAt > clock.now - 3600 }.count
            if recent >= Self.credentialsPerHour {
                return refuse(429, "rate_limited", "too many storage credentials requested in the last hour; try later")
            }
            counter += 1
            let keyID = "005fake\(counter)"
            let secret = Data("SECRET-\(counter)-\(UUID().uuidString)".utf8)
            let issued = Date(timeIntervalSince1970: clock.now.timeIntervalSince1970.rounded(.down))
            let expires = issued + Self.keyMinutes * 60
            let renew = expires - Self.renewMinutes * 60
            let binding = sealForAnotherInstallation ? otherMac : me
            let sealed = try! StorageCredential.seal(SecretBytes(secret), installationID: binding,
                                                     vaultUid: Data(Uid(base32: uid)!.bytes), keyID: keyID, to: pk)
            // A new request revokes this Mac's earlier key still `issued` (a lost response).
            for i in vaults[uid]!.keys.indices where vaults[uid]!.keys[i].installation == me && vaults[uid]!.keys[i].state == "issued" {
                vaults[uid]!.keys[i].state = "revoked"
                vaults[uid]!.keys[i].revokeReason = "replaced_unacknowledged"
            }
            vaults[uid]!.keys.append(Key(id: keyID, installation: me, access: storageAccess, state: "issued", issuedAt: issued,
                                         expiresAt: expires, renewAfter: renew, secret: secret))
            credentialRequests += 1
            return reply(201, ["key_id": keyID, "access": storageAccess, "bucket": "vhc-\(uid)", "bucket_id": "b-\(uid)",
                               "s3_endpoint": "https://s3.us-west-004.backblazeb2.test", "region": "us-west-004",
                               "sealed_secret": Base64URL.encode(sealed),
                               "expires_at": omitExpiry ? NSNull() as Any : secs(expires),
                               "renew_after": omitExpiry ? NSNull() as Any : secs(renew)])
        case ("POST", 5) where parts[1] == "storage" && parts[2] == "credentials" && parts[4] == "ack":
            let keyID = parts[3]
            guard let uid = order.first(where: { u in vaults[u]!.keys.contains { $0.id == keyID && $0.installation == me } }),
                  let i = vaults[uid]!.keys.firstIndex(where: { $0.id == keyID }) else {
                return refuse(404, "not_found", "no such key for this installation", reason: "no_such_key")
            }
            let state = vaults[uid]!.keys[i].state
            if state == "active" { return reply(204, [:]) }
            guard state == "issued" else { return refuse(409, "conflict", "this key is \(state); ask for a new one", reason: "key_\(state)") }
            for j in vaults[uid]!.keys.indices where vaults[uid]!.keys[j].installation == me && j != i
                && ["active", "superseded"].contains(vaults[uid]!.keys[j].state) {
                vaults[uid]!.keys[j].state = "revoked"
                vaults[uid]!.keys[j].revokeReason = "replaced"
            }
            vaults[uid]!.keys[i].state = "active"
            return reply(204, [:])
        default:
            return refuse(404, "not_found", "no route \(method) \(path)")
        }
    }
}
