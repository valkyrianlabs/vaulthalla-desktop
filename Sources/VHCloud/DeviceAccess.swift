public import Foundation
public import VHCore
import OSLog
import VHKeykit
import VHRecovery

// MARK: - the key

/// A managed bucket's key as this Mac holds it for a Desktop-only vault: short-lived (the cloud's
/// `storage.desktop_key_minutes`, 24 hours), renewed from `renewAfter` (12 hours before the end). The secret is a
/// zeroing ``SecretBytes``; nothing here prints it.
public struct BucketKey: Sendable, CustomStringConvertible {
    public let vaultUid: String
    public let keyID: String
    /// full, or read_delete (restricted, over quota).
    public let access: String
    public let bucket: String
    public let bucketID: String
    public let s3Endpoint: String
    public let region: String
    public var expiresAt: Date
    public var renewAfter: Date
    public let secret: SecretBytes

    public var description: String { "BucketKey(\(access), until \(expiresAt), redacted)" }

    func metadata(revoked: Bool = false) -> BucketKeyStore.Metadata {
        BucketKeyStore.Metadata(keyID: keyID, access: access, bucket: bucket, bucketID: bucketID, s3Endpoint: s3Endpoint,
                                region: region, expiresAt: Int64(expiresAt.timeIntervalSince1970),
                                renewAfter: Int64(renewAfter.timeIntervalSince1970), revoked: revoked)
    }
}

/// Where a ``BucketKey`` lives across launches: the account's app-only keychain items (``AccountKeychain``, the
/// group that holds the link's identity key and the account key), written only by the credential owner. Two items per
/// vault: `storage-key.<uid>` (what the key is: no secret) and `storage-key.<uid>.<key id>` (the secret's bytes, never
/// encoded as text). Never UserDefaults, a file or a log. A tombstone (`revoked`, no secret) remembers that the cloud
/// revoked the key, so a relaunch doesn't ask for a new one behind the account holder's back.
public struct BucketKeyStore: Sendable {
    struct Metadata: Codable, Equatable {
        var keyID: String
        var access: String
        var bucket: String
        var bucketID: String
        var s3Endpoint: String
        var region: String
        var expiresAt: Int64
        var renewAfter: Int64
        var revoked: Bool
    }

    public static func item(_ uid: String) -> String { "storage-key.\(uid)" }
    static func secretItem(_ uid: String, _ keyID: String) -> String { "storage-key.\(uid).\(keyID)" }

    let items: LeasedAccountItems

    public init(items: LeasedAccountItems) { self.items = items }

    /// The key kept for `uid`, if one is (nil for none, or a tombstone).
    public func load(_ uid: String) throws -> BucketKey? {
        guard let m = try metadata(uid), !m.revoked else { return nil }
        guard var raw = try items.read(Self.secretItem(uid, m.keyID)) else { return nil }
        defer { raw.resetBytes(in: 0 ..< raw.count) }
        return BucketKey(vaultUid: uid, keyID: m.keyID, access: m.access, bucket: m.bucket, bucketID: m.bucketID,
                         s3Endpoint: m.s3Endpoint, region: m.region,
                         expiresAt: Date(timeIntervalSince1970: TimeInterval(m.expiresAt)),
                         renewAfter: Date(timeIntervalSince1970: TimeInterval(m.renewAfter)), secret: SecretBytes(raw))
    }

    /// Whether the cloud revoked the last key and the person hasn't asked for a new one.
    public func isRevoked(_ uid: String) throws -> Bool { try metadata(uid)?.revoked == true }

    /// Keeps `key` (replacing the vault's previous key and its secret).
    public func save(_ key: BucketKey) throws {
        let previous = try? metadata(key.vaultUid)
        var raw = key.secret.withUnsafeBytes { Data($0) }
        defer { raw.resetBytes(in: 0 ..< raw.count) }
        try items.write(Self.secretItem(key.vaultUid, key.keyID), raw, operation: "store a storage key")
        try items.write(Self.item(key.vaultUid), JSONEncoder().encode(key.metadata()), operation: "store a storage key")
        if let previous, previous.keyID != key.keyID {
            try? items.delete(Self.secretItem(key.vaultUid, previous.keyID), operation: "forget a storage key")
        }
    }

    /// Forgets the vault's key and its secret; with `revoked`, leaves a tombstone without either.
    public func delete(_ uid: String, revoked: Bool = false) throws {
        if let m = try? metadata(uid) {
            try items.delete(Self.secretItem(uid, m.keyID), operation: "forget a storage key")
            if revoked {
                var t = m
                t.revoked = true
                try items.write(Self.item(uid), JSONEncoder().encode(t), operation: "forget a storage key")
                return
            }
        }
        try items.delete(Self.item(uid), operation: "forget a storage key")
    }

    private func metadata(_ uid: String) throws -> Metadata? {
        guard let data = try items.read(Self.item(uid)) else { return nil }
        guard let m = try? JSONDecoder().decode(Metadata.self, from: data) else {
            throw AccountItemError.corrupt("a stored storage key")
        }
        return m
    }
}

// MARK: - time

/// The clock the renewal loop reads and sleeps on; tests inject one they move by hand.
public protocol DeviceAccessClock: Sendable {
    var now: Date { get }
    func sleep(until: Date) async throws
}

public struct SystemDeviceAccessClock: DeviceAccessClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(until: Date) async throws {
        let seconds = until.timeIntervalSinceNow
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
}

// MARK: - the loop

/// This Mac's access to the managed bucket of one Desktop-only vault it holds: the sealed credential exchange
/// (a one-time X25519 key, the sealed secret opened, the key acknowledged), and renewal driven by the cloud's
/// `renew_after` and `expires_at`. It reads `GET /v1/storage` to follow what the cloud decides: a key the cloud
/// superseded or expired is renewed at once, a key it revoked stops the loop (the account holder's decision), the
/// entitlement's `storage_access` `none` (suspended, ended) pauses it, and a vault moved to a server, placed on another
/// Mac or released stops it, keeping every local file. Failures back off. The secret lives in memory and in
/// ``BucketKeyStore`` only, and is forgotten when its key is superseded, expires or is revoked.
public actor DeviceAccess {
    public struct Settings: Sendable, Equatable {
        /// How often the cloud's view is read while all is well (a revocation or a move is seen within this).
        public var refreshInterval: TimeInterval = 30 * 60
        /// How often a vault that waits (its bucket, the offline copy, an ejection) is checked again.
        public var waitingInterval: TimeInterval = 15 * 60
        /// How often a paused vault (no storage access) is checked again.
        public var pausedInterval: TimeInterval = 60 * 60
        /// The first retry after a failure, doubling per failure up to `backoffCap`.
        public var backoffBase: TimeInterval = 30
        public var backoffCap: TimeInterval = 30 * 60

        public init() {}
    }

    /// Why the loop stopped for good (until ``resume()``). Every stop forgets the key and keeps local files.
    public enum Stop: Sendable, Equatable {
        /// Another device holds the vault, or nobody does (``DeviceAccessError/heldByServer``, `heldByAnotherMac`,
        /// `unplaced`).
        case notHeld(DeviceAccessError)
        /// A restore moved the vault to the server `name`.
        case moved(deploymentID: String, name: String)
        /// The cloud revoked this Mac's key while it still holds the vault (the account holder, in the portal).
        case keyRevoked
        /// The account no longer has this vault.
        case vaultRemoved
        /// This Mac's link was revoked.
        case unlinked
        /// This Mac released the vault.
        case released
        /// The account's storage moved to the customer's own provider account.
        case ejected
    }

    public enum Phase: Sendable, Equatable {
        case starting
        /// A key in force; renewal from its `renewAfter`.
        case holding
        /// The cloud says not yet (its bucket, the offline copy, an ejection in progress); checked again later.
        case waiting(DeviceAccessError)
        /// No storage access on the plan (`storage_access` `none`); checked again later.
        case paused(entitlement: String?)
        /// A failure; the next attempt is at `at`.
        case retrying(DeviceAccessError, attempt: Int, at: Date)
        case stopped(Stop)
    }

    /// What the UI shows: never a key id or a secret.
    public struct Status: Sendable, Equatable {
        public var phase: Phase
        public var access: String?
        public var expiresAt: Date?
        public var renewAfter: Date?
        public var nextCheck: Date?
    }

    /// What the sync engine signs with, valid only inside ``DeviceAccess/withCredentials(_:)``.
    public struct Credentials {
        public let accessKeyID: String
        public let secret: UnsafeRawBufferPointer
        public let bucket: String
        public let bucketID: String
        public let s3Endpoint: String
        public let region: String
        public let access: String
    }

    public let vaultUid: String
    public let installationID: String
    let client: CloudClient
    let store: BucketKeyStore
    let clock: any DeviceAccessClock
    let settings: Settings
    private let uidBytes: Data

    private(set) var key: BucketKey?
    public private(set) var phase: Phase = .starting
    private var nextRefresh: Date = .distantPast
    private var renewNow = false
    private var failures = 0
    private var onChange: (@Sendable (Status) -> Void)?

    private static let log = Logger(subsystem: "sh.vaulthalla.app", category: "cloud.device-access")

    public init(client: CloudClient, vaultUid: String, installationID: String, store: BucketKeyStore,
                clock: any DeviceAccessClock = SystemDeviceAccessClock(), settings: Settings = Settings()) throws {
        guard let uid = Uid(base32: vaultUid) else { throw DeviceAccessError.noSuchVault }
        self.vaultUid = vaultUid
        self.installationID = installationID
        self.client = client
        self.store = store
        self.clock = clock
        self.settings = settings
        uidBytes = Data(uid.bytes)
        key = try? store.load(vaultUid)
        if (try? store.isRevoked(vaultUid)) == true { phase = .stopped(.keyRevoked) }
    }

    public var status: Status {
        Status(phase: phase, access: key?.access, expiresAt: key?.expiresAt, renewAfter: key?.renewAfter, nextCheck: nextWake())
    }

    public func observe(_ handler: @escaping @Sendable (Status) -> Void) {
        onChange = handler
        handler(status)
    }

    /// Runs the loop until it stops or the task is cancelled.
    public func run() async {
        while !Task.isCancelled {
            guard let next = await step() else { return }
            // Never a busy loop, whatever a step returns.
            do { try await clock.sleep(until: max(next, clock.now + 1)) } catch { return }
        }
    }

    /// Does what is due now (read the cloud's view, renew) and returns when to come back, or nil once stopped.
    @discardableResult
    public func step() async -> Date? {
        defer { onChange?(status) }
        let now = clock.now
        if case .stopped = phase { return nil }
        forgetIfExpired(now)
        if now >= nextRefresh {
            do {
                let view = try await client.storage()
                await reconcile(view, now: now)
            } catch {
                handle(error, now: now, refreshing: true)
                return nextWake()
            }
        }
        switch phase {
        case .stopped: return nil
        case .waiting, .paused: return nextWake()
        case .retrying(_, _, let at) where now < at: return at
        default: break
        }
        if renewNow || key == nil || now >= key!.renewAfter { await renew(now: now) }
        return nextWake()
    }

    /// Follows a view of `GET /v1/storage` read elsewhere (the section's refresh), without waiting for the loop.
    public func apply(_ view: CloudStorage) async {
        if case .stopped = phase { return }
        await reconcile(view, now: clock.now)
        onChange?(status)
    }

    /// The provider refused the key (the sync engine's 401 or 403): read the cloud's view at the next step.
    public func providerRefusedKey() {
        nextRefresh = .distantPast
        renewNow = true
    }

    /// After ``Stop/keyRevoked``, the person asks for a new key.
    public func resume() {
        guard case .stopped(.keyRevoked) = phase else { return }
        try? store.delete(vaultUid)
        phase = .starting
        nextRefresh = .distantPast
        renewNow = true
        onChange?(status)
    }

    /// The vault's storage switch, as the vault's writer.
    public func setStorage(enabled: Bool) async throws(DeviceAccessError) {
        do {
            _ = try await client.setManagedStorage(vaultUid, enabled: enabled)
            nextRefresh = .distantPast
        } catch {
            throw DeviceAccessError.from(error)
        }
    }

    /// This Mac stops holding the vault: the cloud revokes its key and the vault waits, unplaced, for the account
    /// holder. Local files are not touched.
    public func release() async throws(DeviceAccessError) {
        do {
            try await client.releaseDesktopVault(vaultUid)
        } catch {
            throw DeviceAccessError.from(error)
        }
        stop(.released)
        onChange?(status)
    }

    /// The key in force, for signing requests now. Nil without one (or past its expiry); the secret's buffer is zeroed
    /// when `body` returns.
    public func withCredentials<R>(_ body: (Credentials) throws -> R) rethrows -> R? {
        guard let key, clock.now < key.expiresAt else { return nil }
        if case .stopped = phase { return nil }
        return try key.secret.withUnsafeBytes { secret in
            try body(Credentials(accessKeyID: key.keyID, secret: secret, bucket: key.bucket, bucketID: key.bucketID,
                                 s3Endpoint: key.s3Endpoint, region: key.region, access: key.access))
        }
    }

    // MARK: internals

    private func nextWake() -> Date? {
        switch phase {
        case .stopped: return nil
        case .retrying(_, _, let at): return [at, key?.expiresAt].compactMap { $0 }.min()
        case .waiting, .paused: return [nextRefresh, key?.expiresAt].compactMap { $0 }.min()
        case .starting, .holding:
            if renewNow || key == nil { return clock.now }
            return [nextRefresh, key!.renewAfter, key!.expiresAt].min()
        }
    }

    private func forget(revoked: Bool = false) {
        key = nil
        do { try store.delete(vaultUid, revoked: revoked) } catch {
            Self.log.notice("device access: a stored storage key couldn't be removed: \(String(describing: error), privacy: .public)")
        }
    }

    private func forgetIfExpired(_ now: Date) {
        guard let key, now >= key.expiresAt else { return }
        forget()
        renewNow = true
    }

    private func stop(_ reason: Stop) {
        forget(revoked: reason == .keyRevoked)
        phase = .stopped(reason)
        renewNow = false
    }

    private func reconcile(_ view: CloudStorage, now: Date) async {
        nextRefresh = now + settings.refreshInterval
        guard let v = view.vault(vaultUid) else { return stop(.vaultRemoved) }
        if let moved = v.movedTo { return stop(.moved(deploymentID: moved.deploymentId, name: moved.name)) }
        guard let holder = v.desktop, holder.installationId == installationID else {
            if let other = v.desktop { return stop(.notHeld(.heldByAnotherMac(name: other.name))) }
            // A server's vault, or nobody's: the vault's own record says which.
            let replicas = (try? await client.vault(vaultUid))?.replicas ?? []
            return stop(.notHeld(replicas.isEmpty ? .unplaced : .heldByServer))
        }
        if v.state == "ejected" { return stop(.ejected) }
        if view.entitlement.storageAccess == "none" {
            // Suspended or ended: the cloud revoked every key and refuses new ones.
            forget()
            phase = .paused(entitlement: view.entitlement.state)
            nextRefresh = now + settings.pausedInterval
            return
        }
        if let e = view.ejection, e.state != "refused", e.state != "complete" { return wait(.ejecting, now: now) }
        switch v.state {
        case "ready": break
        case "ejecting": return wait(.ejecting, now: now)
        case "off", "none": return wait(.bucketOff, now: now)
        case "emptying", "deleted":
            forget()
            return wait(.bucketDeleting, now: now)
        default:
            return wait(v.reason == "account_key_unconfirmed" ? .accountKeyUnconfirmed
                        : v.reason == "payment_required" ? .paymentRequired : .bucketNotReady, now: now)
        }
        let c = v.credential ?? CloudStorage.KeyView(state: "none")
        let mine = key != nil && c.keyId == key?.keyID
        switch c.state {
        case "active" where mine:
            if let e = c.expiresAt { key!.expiresAt = Date(timeIntervalSince1970: TimeInterval(e)) }
            if let r = c.renewAfter { key!.renewAfter = Date(timeIntervalSince1970: TimeInterval(r)) }
            failures = 0
        case "active":
            // Another key of this Mac is in force (a response lost after its acknowledgement): this one is not.
            forget()
            renewNow = true
        case "issued":
            // A key whose answer never arrived; asking again revokes it. The key held here may still be active.
            renewNow = true
        case "superseded", "expired":
            // Replaced by the cloud (a restricted plan, over quota) or past its expiry: no longer the key in force, so
            // it is forgotten at once and a new one asked for.
            forget()
            renewNow = true
        default:  // none
            if key != nil { return stop(.keyRevoked) }
            renewNow = true
        }
        if case .retrying(_, _, let at) = phase, at > now {} else { phase = .holding }
        forgetIfExpired(now)
    }

    private func wait(_ reason: DeviceAccessError, now: Date) {
        phase = .waiting(reason)
        nextRefresh = now + settings.waitingInterval
    }

    private func renew(now: Date) async {
        do {
            let oneTime = try CredentialKey.generate()
            let issued = try await client.requestStorageCredential(vaultUid, publicKey: try oneTime.publicKey())
            let keyID = try CloudClient.checkedKeyID(issued.keyId)
            guard let expires = issued.expiresAt, let renew = issued.renewAfter, renew < expires,
                  issued.access == "full" || issued.access == "read_delete" else {
                throw DeviceAccessError.malformed("a Mac's key without a valid expiry")
            }
            guard let sealed = Base64URL.decode(issued.sealedSecret) else { throw DeviceAccessError.malformed("the sealed secret") }
            let secret: SecretBytes
            do {
                secret = try oneTime.open(sealed, installationID: installationID, vaultUid: uidBytes, keyID: keyID).secretBytes()
            } catch {
                // Not for this Mac, vault or key id: never used. The cloud revokes an unacknowledged key itself.
                throw DeviceAccessError.malformed("a sealed secret that doesn't open for this Mac")
            }
            try await client.acknowledgeStorageCredential(keyID)
            let fresh = BucketKey(vaultUid: vaultUid, keyID: keyID, access: issued.access, bucket: issued.bucket,
                                  bucketID: issued.bucketId, s3Endpoint: issued.s3Endpoint, region: issued.region,
                                  expiresAt: Date(timeIntervalSince1970: TimeInterval(expires)),
                                  renewAfter: Date(timeIntervalSince1970: TimeInterval(renew)), secret: secret)
            do { try store.save(fresh) } catch {
                // Kept in memory only (a process without the credential lease); a relaunch renews.
                Self.log.notice("device access: the storage key is kept in memory only: \(String(describing: error), privacy: .public)")
            }
            key = fresh
            failures = 0
            renewNow = false
            phase = .holding
            nextRefresh = now + settings.refreshInterval
        } catch {
            handle(error, now: now)
        }
    }

    private func handle(_ error: any Error, now: Date, refreshing: Bool = false) {
        let e = DeviceAccessError.from(error)
        Self.log.notice("device access: \(e.name, privacy: .public)")
        switch e {
        case .unlinked: stop(.unlinked)
        case .heldByServer, .heldByAnotherMac, .unplaced: stop(.notHeld(e))
        case .noSuchVault: stop(.vaultRemoved)
        case .paymentRequired:
            forget()
            phase = .paused(entitlement: nil)
            nextRefresh = now + settings.pausedInterval
        case .bucketNotReady, .bucketOff, .bucketDeleting, .accountKeyUnconfirmed, .ejecting:
            wait(e, now: now)
        case .rateLimited(let after):
            failures += 1
            let at = now + max(TimeInterval(after ?? 0), backoff())
            phase = .retrying(e, attempt: failures, at: at)
        default:
            failures += 1
            phase = .retrying(e, attempt: failures, at: now + backoff())
            if refreshing { nextRefresh = now + backoff() }
        }
    }

    private func backoff() -> TimeInterval {
        min(settings.backoffBase * pow(2, Double(max(failures - 1, 0))), settings.backoffCap)
    }
}
