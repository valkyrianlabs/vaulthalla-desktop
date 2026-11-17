public import Foundation
import VHRecovery

// Desktop-only vaults (wave 4): a vault this Mac holds with no server, kept in Vaulthalla Cloud managed storage. The
// routes and shapes are the daemon's (vaulthalla-cloud main, src/accounts/Deployments.cpp and src/storage/; "As built"
// 16 to 21 of docs/design/account-model.md and 25 and 26 of docs/design/managed-storage.md). Where a document and the
// code disagree, these follow the code.

/// `GET /v1/storage`, as a Desktop sees it: the whole account read-only, and for each vault its bucket, the Mac that
/// holds it (with its key's state, never its id) and this Mac's own key (with its id).
public struct CloudStorage: Codable, Hashable, Sendable {
    public struct Entitlement: Codable, Hashable, Sendable {
        /// active, past_due, restricted, suspended, ended; nil without a subscription.
        public var state: String?
        public var plan: String
        public var storageQuotaBytes: Int64
        /// full, read_delete or none: what a key issued now allows.
        public var storageAccess: String
        /// Why (`over_quota`, the entitlement state, `no_quota`...).
        public var cause: String
    }

    public struct Usage: Codable, Hashable, Sendable {
        public var storedBytes: Int64?
        public var date: String?
    }

    public struct Ejection: Codable, Hashable, Sendable {
        /// requested, converting, tidying, destroying, ejecting, refused, complete...
        public var state: String
        public var completedAt: Int64?
        public var refused: String?
    }

    /// One installation's key for the bucket (`keyView`): the key in force (issued first, then active, then
    /// superseded) with `state` `expired` once past its expiry; `expired` without an id after the cloud revoked it for
    /// expiring (until a newer key); a Mac's key revoked for another reason: `none` with `revoked_reason` and
    /// `revoked_at` (null while the provider call is pending); else `none`. Only this Mac's own view carries `key_id`.
    public struct KeyView: Codable, Hashable, Sendable {
        public var keyId: String?
        /// none, issued, active, superseded, expired.
        public var state: String
        /// full or read_delete.
        public var access: String?
        public var expiresAt: Int64?
        public var renewAfter: Int64?
        /// Why a Mac's newest key went (managed-storage.md "As built" 27): account_holder, suspended, ended, restricted,
        /// over_quota, no_plan, hold_removed, hold_reassigned, released, moved, installation_revoked, not_acknowledged,
        /// replaced, access_changed, not_delivered, ejection, other.
        public var revokedReason: String?
        public var revokedAt: Int64?

        public init(keyId: String? = nil, state: String, access: String? = nil, expiresAt: Int64? = nil, renewAfter: Int64? = nil,
                    revokedReason: String? = nil, revokedAt: Int64? = nil) {
            self.keyId = keyId
            self.state = state
            self.access = access
            self.expiresAt = expiresAt
            self.renewAfter = renewAfter
            self.revokedReason = revokedReason
            self.revokedAt = revokedAt
        }
    }

    /// Why this Mac no longer holds a vault, while that is the latest fact (`accounts::lastRelease`): `reason` released
    /// (this Mac released it), hold_removed (the account holder took it off), hold_reassigned (given to another Mac,
    /// `to`), moved (a restore put it on a server, `to`, as `moved_to`).
    public struct Released: Codable, Hashable, Sendable {
        public struct To: Codable, Hashable, Sendable {
            /// desktop or server.
            public var kind: String
            public var installationId: String?
            public var deploymentId: String?
            public var name: String?
        }

        public var reason: String
        public var to: To?
        public var at: Int64?
    }

    /// The Mac holding a Desktop-only vault, with its key's state.
    public struct Holder: Codable, Hashable, Sendable {
        public var installationId: String
        public var name: String
        public var fingerprint: String
        public var lastSeen: Int64?
        public var credential: KeyView?
    }

    public struct MovedTo: Codable, Hashable, Sendable {
        public var deploymentId: String
        public var name: String
    }

    public struct Vault: Codable, Hashable, Sendable, Identifiable {
        public var vaultUid: String
        public var enabled: Bool
        /// none, waiting, pending, created, ready, off, emptying, deleted, ejecting, ejected.
        public var state: String
        /// A waiting bucket's reason: payment_required, over_quota, account_key_unconfirmed, bucket_limit.
        public var reason: String?
        public var bucket: String?
        public var bucketId: String?
        public var s3Endpoint: String?
        public var region: String?
        public var contentRetentionDays: Int64?
        public var detachedAt: Int64?
        public var convertedAt: Int64?
        /// The Mac that holds the vault, or nil (a server holds it, or nobody does).
        public var desktop: Holder?
        /// This installation's own key.
        public var credential: KeyView?
        /// A restore moved the vault off this Mac onto a server.
        public var movedTo: MovedTo?
        /// Why this Mac no longer holds it (this Mac's own view only).
        public var released: Released?

        public var id: String { vaultUid }
    }

    public var entitlement: Entitlement
    public var usage: Usage
    public var accountKeyOfflineCopyConfirmed: Bool
    public var ejection: Ejection?
    public var ejectionPortalUrl: String?
    public var provider: String
    public var vaults: [Vault]

    public func vault(_ uid: String) -> Vault? { vaults.first { $0.vaultUid == uid } }
}

/// `GET /v1/storage/eject` (ManagedStorage `ejection`): the ejection and, per vault whose bucket is being ejected or was,
/// every writer with its own conversion report (managed-storage.md "As built" 29). The customer's address is never here.
public struct CloudEjectionProgress: Codable, Hashable, Sendable {
    public struct Writer: Codable, Hashable, Sendable {
        /// server or desktop.
        public var kind: String
        public var deploymentId: String?
        public var installationId: String?
        public var name: String
        /// Whether the ejection waits for this writer (always for the Mac holding a Desktop-only vault).
        public var waitedFor: Bool
        public var convertedAt: Int64?
    }

    public struct Vault: Codable, Hashable, Sendable {
        public var vaultUid: String
        /// ejecting or ejected.
        public var state: String
        public var convertedAt: Int64?
        public var writers: [Writer]
    }

    public var ejection: CloudStorage.Ejection?
    public var vaults: [Vault]

    /// Whether `installationID` (a Mac) reported its conversion of `uid`.
    public func converted(_ uid: String, by installationID: String) -> Bool {
        vaults.first { $0.vaultUid == uid }?.writers.contains { $0.kind == "desktop" && $0.installationId == installationID
            && $0.convertedAt != nil } ?? false
    }
}

/// `POST /v1/storage/vaults/{uid}/credentials` (201): a bucket key, its secret sealed to the one-time key the request
/// sent. A Mac's key always carries `expires_at` and `renew_after`; a server's carries neither.
public struct CloudIssuedCredential: Decodable, Sendable, CustomStringConvertible {
    public var keyId: String
    public var access: String
    public var bucket: String
    public var bucketId: String
    public var s3Endpoint: String
    public var region: String
    /// base64url of the `\x89VHC` box; opens only with the one-time key.
    public var sealedSecret: String
    public var expiresAt: Int64?
    public var renewAfter: Int64?

    public var description: String { "CloudIssuedCredential(access: \(access), redacted)" }
}

/// Why the cloud refused a Desktop-only vault operation, in the daemon's own reasons, each with plain words.
/// Nothing here carries a secret: the cloud's messages never do, and Desktop adds none.
public enum DeviceAccessError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 409 `held_by_server`: a server replicates the vault (one writer); `details.name` names it.
    case heldByServer(name: String?)
    /// 409 `held_by_desktop`: another Mac holds it; `details.name` names it.
    case heldByAnotherMac(name: String?)
    /// 409 `unplaced`: nobody holds it; the account holder places it in the portal.
    case unplaced
    /// 404 `no_such_vault`: not a vault of this account (or a malformed uid).
    case noSuchVault
    /// 404 `no_such_key`: acknowledging a key that isn't this Mac's.
    case noSuchKey
    /// 409 `key_<state>`: acknowledging a key that is no longer issued (revoking, revoked, superseded).
    case keyNotIssued(state: String)
    /// 409 `bucket_not_ready`: its bucket is waiting or being prepared.
    case bucketNotReady
    /// 409 `bucket_off`: its storage is switched off.
    case bucketOff
    /// 409 `bucket_deleting`: its bucket is being deleted.
    case bucketDeleting
    /// 409 `ejecting`: the account's storage is moving to the customer's own provider account.
    case ejecting
    /// 409 `ejected`: it moved there.
    case ejected
    /// 409 `account_key_unconfirmed`: no offline copy of the account recovery key is confirmed.
    case accountKeyUnconfirmed
    /// 402 `payment_required`: the plan gives no storage access; `details.cause` (suspended, ended, no_storage_plan...).
    case paymentRequired(cause: String?)
    /// 403 `step_up_required`: the action (`details.action`) needs the account holder's fresh step-up, in the portal.
    case stepUpRequired(action: String?)
    /// 403 `switch_only`: a Mac that doesn't hold the vault changes its switch only, never its retention.
    case switchOnly
    /// 403 `installation_only` / `portal_only`: the route is another kind of caller's.
    case wrongCaller(reason: String)
    /// 400 `invalid_*`, `nothing_to_change`, `desktop_has_no_origin`: a request Desktop shouldn't have sent.
    case invalidRequest(reason: String)
    /// 503 `provider_unavailable` / `provider_key_id_invalid`: the provider made no usable key; ask again.
    case providerUnavailable(reason: String)
    /// 429 `rate_limited` (at most `storage.credentials_per_hour` keys per installation and hour).
    case rateLimited(retryAfter: Int?)
    /// 401, or this Mac has no link: the installation was revoked or never linked.
    case unlinked
    /// 403: what this installation may not do (a Mac that doesn't hold a vault changes its switch only).
    case forbidden(String)
    /// The cloud, or the network to it, failed; trying again later may work.
    case unavailable(String)
    /// An answer Desktop can't use (a missing expiry, a key id it can't put in a path, a box that doesn't open).
    case malformed(String)
    /// Any other refusal, with the daemon's reason when it gave one.
    case other(status: Int, reason: String?, message: String)

    public var description: String { "DeviceAccessError.\(name)" }

    /// A stable name for logs and tests (never a secret, never a message).
    public var name: String {
        switch self {
        case .heldByServer: "held_by_server"
        case .heldByAnotherMac: "held_by_desktop"
        case .unplaced: "unplaced"
        case .noSuchVault: "no_such_vault"
        case .noSuchKey: "no_such_key"
        case .keyNotIssued(let s): "key_\(s)"
        case .bucketNotReady: "bucket_not_ready"
        case .bucketOff: "bucket_off"
        case .bucketDeleting: "bucket_deleting"
        case .ejecting: "ejecting"
        case .ejected: "ejected"
        case .accountKeyUnconfirmed: "account_key_unconfirmed"
        case .paymentRequired: "payment_required"
        case .stepUpRequired: "step_up_required"
        case .switchOnly: "switch_only"
        case .wrongCaller(let r), .invalidRequest(let r), .providerUnavailable(let r): r
        case .rateLimited: "rate_limited"
        case .unlinked: "unlinked"
        case .forbidden: "forbidden"
        case .unavailable: "unavailable"
        case .malformed: "malformed"
        case .other(let status, let reason, _): reason ?? "status_\(status)"
        }
    }

    /// The sentence a person reads.
    public var message: String {
        switch self {
        case .heldByServer(let name):
            (name.map { "The server \u{201C}\($0)\u{201D} holds this vault" } ?? "A server holds this vault")
                + ", so this Mac can't write to it. A vault has one writer."
        case .heldByAnotherMac(let name):
            (name.map { "The Mac \u{201C}\($0)\u{201D} holds this vault." } ?? "Another Mac holds this vault.")
                + " For now one Mac writes to a vault; the account holder can move it in the portal."
        case .unplaced:
            "No device holds this vault. The account holder places it on a Mac or a server in the portal."
        case .noSuchVault: "Your Vaulthalla Cloud account has no such vault."
        case .noSuchKey: "Vaulthalla Cloud doesn't know this storage key. This Mac asks for a new one."
        case .keyNotIssued: "That storage key is no longer valid. This Mac asks for a new one."
        case .bucketNotReady: "Its storage isn't ready yet."
        case .bucketOff: "Its storage is switched off."
        case .bucketDeleting: "Its storage is being deleted."
        case .ejecting: "Your account's storage is moving to your own storage account."
        case .ejected: "Your account's storage is in your own storage account now."
        case .accountKeyUnconfirmed:
            "No offline copy of your recovery key is confirmed yet. Storage starts once one is (Recovery Key)."
        case .paymentRequired(let cause):
            switch cause {
            case "suspended": "Storage is paused until payment is updated."
            case "ended": "Your plan ended: it no longer includes storage."
            case "no_storage_plan", "none": "Your plan doesn't include storage."
            default: "Your plan doesn't include storage access right now."
            }
        case .stepUpRequired: "The account holder approves this in the portal."
        case .switchOnly: "This Mac doesn't hold this vault: it can only switch its storage on or off."
        case .wrongCaller: "Vaulthalla Cloud takes this from another kind of device."
        case .invalidRequest: "Vaulthalla Cloud refused a request this version of Vaulthalla sent."
        case .providerUnavailable: "The storage provider didn't make a key. This Mac tries again."
        case .rateLimited(let after):
            after.map { "Too many storage keys were asked for. Trying again in \($0) seconds." }
                ?? "Too many storage keys were asked for in the last hour. Trying again later."
        case .unlinked: "This Mac isn't linked to Vaulthalla Cloud any more."
        case .forbidden(let m): m
        case .unavailable: "Vaulthalla Cloud can't be reached right now. This Mac tries again."
        case .malformed: "Vaulthalla Cloud answered in a way this version of Vaulthalla doesn't understand."
        case .other(_, _, let m): m
        }
    }

    /// Maps the client's errors. A refusal without a reason keeps its status's meaning.
    public static func from(_ error: any Error) -> DeviceAccessError {
        if let e = error as? DeviceAccessError { return e }
        guard let e = error as? CloudError else { return .unavailable(String(describing: type(of: error))) }
        switch e {
        case .declined(let status, _, let reason, let message, let details):
            switch reason {
            case "held_by_server": return .heldByServer(name: details["name"])
            case "held_by_desktop": return .heldByAnotherMac(name: details["name"])
            case "unplaced": return .unplaced
            case "no_such_vault": return .noSuchVault
            case "no_such_key": return .noSuchKey
            case "bucket_not_ready": return .bucketNotReady
            case "bucket_off": return .bucketOff
            case "bucket_deleting": return .bucketDeleting
            case "ejecting": return .ejecting
            case "ejected": return .ejected
            case "account_key_unconfirmed": return .accountKeyUnconfirmed
            case "payment_required": return .paymentRequired(cause: details["cause"])
            case "step_up_required": return .stepUpRequired(action: details["action"])
            case "switch_only": return .switchOnly
            case "installation_only", "portal_only": return .wrongCaller(reason: reason)
            case "provider_unavailable", "provider_key_id_invalid": return .providerUnavailable(reason: reason)
            case "request_not_verified", "sign_in_required": return .unlinked
            case "rate_limited": return .rateLimited(retryAfter: nil)
            case let r where status == 400 && (r.hasPrefix("invalid_") || r == "nothing_to_change" || r == "desktop_has_no_origin"):
                return .invalidRequest(reason: r)
            case let r where r.hasPrefix("key_"): return .keyNotIssued(state: String(r.dropFirst(4)))
            default: return .other(status: status, reason: reason, message: message)
            }
        case .paymentRequired: return .paymentRequired(cause: nil)
        case .rateLimited(let after, _): return .rateLimited(retryAfter: after)
        case .unauthenticated, .notLinked: return .unlinked
        case .forbidden(let m): return .forbidden(m)
        // A 404 without a reason is a route this daemon doesn't serve (As built 27), never a vault or key it lacks.
        case .notFound(let m): return .other(status: 404, reason: nil, message: m)
        case .unreachable, .unavailable, .tooLarge: return .unavailable(e.message)
        case .malformed(let m): return .malformed(m)
        case .conflict(let m): return .other(status: 409, reason: nil, message: m)
        case .invalid(let m): return .other(status: 400, reason: nil, message: m)
        case .refused(let status, let code, let m): return .other(status: status, reason: code, message: m)
        default: return .other(status: 0, reason: nil, message: e.message)
        }
    }
}

extension CloudClient {
    /// `GET /v1/storage`: the account's storage as a Desktop reads it.
    public func storage() async throws -> CloudStorage { try await signed("GET", "/v1/storage") }

    /// `GET /v1/vaults/{uid}`: one vault, with its replicas and the Mac holding it.
    public func vault(_ uid: String) async throws -> CloudVault {
        try await signed("GET", "/v1/vaults/\(try Self.checkedUid(uid))")
    }

    /// `POST /v1/vaults {vault_uid}` from this Mac: registers a new vault held by this Mac, with no deployment (201,
    /// `created` true); the same call again is a no-op for the Mac that holds it (200, `created` false). A vault
    /// another device holds, or nobody does, is refused (409 `held_by_server`, `held_by_desktop`, `unplaced`): nobody
    /// takes a vault by declaring it.
    public func registerDesktopVault(_ uid: String) async throws -> (vault: CloudVault, created: Bool) {
        struct Body: Encodable { var vaultUid: String }
        struct Created: Decodable { var created: Bool }
        let data = try await signedData("POST", "/v1/vaults", body: encode(Body(vaultUid: try Self.checkedUid(uid))))
        do {
            return (try Self.decoder.decode(CloudVault.self, from: data), try Self.decoder.decode(Created.self, from: data).created)
        } catch {
            throw CloudError.malformed("/v1/vaults")
        }
    }

    /// `PUT /v1/storage/vaults/{uid} {enabled}`: the vault's storage switch (202, the vault's storage view). For a
    /// vault this Mac holds it is the writer's switch, as a server's for its replicas; retention stays the portal's here.
    public func setManagedStorage(_ uid: String, enabled: Bool) async throws -> CloudStorage.Vault {
        struct Body: Encodable { var enabled: Bool }
        return try await signed("PUT", "/v1/storage/vaults/\(try Self.checkedUid(uid))", body: Body(enabled: enabled))
    }

    /// `POST /v1/storage/vaults/{uid}/credentials {public_key}`: a bucket key for a vault this Mac holds, its secret
    /// sealed to `publicKey` (the one-time X25519 key, base64url). Asking again is the renewal.
    public func requestStorageCredential(_ uid: String, publicKey: Data) async throws -> CloudIssuedCredential {
        struct Body: Encodable { var publicKey: String }
        return try await signed("POST", "/v1/storage/vaults/\(try Self.checkedUid(uid))/credentials",
                                body: Body(publicKey: Base64URL.encode(publicKey)))
    }

    /// `POST /v1/storage/credentials/{key_id}/ack` (204): the key is `active`; the cloud revokes this Mac's older keys
    /// for the bucket.
    public func acknowledgeStorageCredential(_ keyID: String) async throws {
        try await signedEmpty("POST", "/v1/storage/credentials/\(try Self.checkedKeyID(keyID))/ack")
    }

    /// `DELETE /v1/vaults/{uid}/replica` from this Mac (204): it stops holding the vault, which stays registered with
    /// nobody holding it (`unplaced`) until the account holder places it again; the cloud revokes this Mac's keys for
    /// its bucket. Local files are not touched.
    public func releaseDesktopVault(_ uid: String) async throws {
        try await signedEmpty("DELETE", "/v1/vaults/\(try Self.checkedUid(uid))/replica")
    }

    /// A vault uid as the daemon takes it in a path (26 lower-case base32 symbols, `crypto::isRandomId`).
    static func checkedUid(_ uid: String) throws -> String {
        guard Uid(base32: uid) != nil, uid == uid.lowercased() else { throw DeviceAccessError.noSuchVault }
        return uid
    }

    /// A key id as Desktop puts it in a path: 1 to 128 URL-unreserved characters, which the daemon enforces since
    /// "As built" 27 (`storage/004_key_id_charset.sql`); checked here too, so nothing else is ever signed into a path.
    static func checkedKeyID(_ id: String) throws -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard (1 ... 128).contains(id.count), id.allSatisfy(unreserved.contains) else {
            throw DeviceAccessError.malformed("a key id Desktop can't put in a path")
        }
        return id
    }
}
