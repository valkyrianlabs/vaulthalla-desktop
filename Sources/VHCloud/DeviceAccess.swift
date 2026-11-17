public import Foundation
public import VHCore
import OSLog
import VHKeykit
import VHRecovery

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
///
/// An ejection (the account's managed storage handed to the customer's own provider account: managed-storage.md "As
/// built" 13 and 25) converts the vault in place: from the moment the cloud's view shows its bucket `ejecting` (or
/// `ejected`), this Mac reports the conversion (`POST .../ejected`, which the ejection waits for), keeps syncing on
/// the cloud's last key until that key ends (``Phase/leaving(keyUntil:)``), and never asks the cloud for a key for the
/// vault again. Then it waits for a key the person makes in their own account (``Phase/needsOwnKey(_:)``), which
/// ``useOwnKey(_:)`` takes once it was checked against the bucket (``Phase/ownStorage``).
public actor DeviceAccess {
    public struct Settings: Sendable, Equatable {
        /// How often the cloud's view is read while all is well (a revocation or a move is seen within this).
        public var refreshInterval: TimeInterval = 30 * 60
        /// How often a vault that waits (its bucket, the offline copy, an ejection) is checked again.
        public var waitingInterval: TimeInterval = 15 * 60
        /// A bucket being provisioned (storage just switched on) is checked again after this, doubling per check up to
        /// `waitingInterval`: provisioning takes seconds to minutes, and a new vault waits for it.
        public var provisioningInterval: TimeInterval = 10
        /// How often a paused vault (no storage access) is checked again.
        public var pausedInterval: TimeInterval = 60 * 60
        /// The first retry after a failure, doubling per failure up to `backoffCap`.
        public var backoffBase: TimeInterval = 30
        public var backoffCap: TimeInterval = 30 * 60

        public init() {}
    }

    /// Why the loop stopped. Every stop forgets the key and keeps local files. Only ``keyRevoked(reason:)`` (the account
    /// holder revoked the key) and ``takenOff`` (the account holder took the vault off this Mac) stay stopped until a
    /// person acts (``resume()``, or the account holder placing the vault here again); ``unlinked`` until linked again.
    /// The others end as soon as the cloud's view shows this Mac holding the vault again.
    public enum Stop: Sendable, Equatable {
        /// Another device holds the vault, or nobody does (``DeviceAccessError/heldByServer``, `heldByAnotherMac`,
        /// `unplaced`), with no `released` fact about this Mac.
        case notHeld(DeviceAccessError)
        /// A restore moved the vault to the server `name` (`moved_to`, `released.reason` `moved`).
        case moved(deploymentID: String, name: String)
        /// The account holder gave the vault to another Mac (`released.reason` `hold_reassigned`).
        case reassigned(to: String?)
        /// The account holder took the vault off this Mac (`released.reason` `hold_removed`).
        case takenOff
        /// The cloud revoked this Mac's key while it still holds the vault: `account_holder` (in the portal), or a
        /// reason this version doesn't know (`other`).
        case keyRevoked(reason: String)
        /// The account no longer has this vault.
        case vaultRemoved
        /// This Mac's link was revoked.
        case unlinked
        /// This Mac released the vault (`released.reason` `released`).
        case released
    }

    /// Why a vault whose storage was ejected to the person waits for their own key.
    public enum OwnKeyNeed: Sendable, Equatable {
        /// The cloud's last key for the bucket ended (it expired, or the provider refused it); the cloud gives no other.
        case cloudKeyEnded
        /// The provider refused the person's own key (deleted, or without the access the vault needs).
        case refused
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
        /// The account's storage is being ejected to the person (or was): the vault was converted in place and syncs on
        /// the cloud's last key until `keyUntil`. No key is asked of the cloud again.
        case leaving(keyUntil: Date)
        /// Paused until the person enters a key they made in their own provider account; nothing local is deleted.
        case needsOwnKey(OwnKeyNeed)
        /// On the person's own key, in their own provider account. The cloud is never asked for a key for this vault.
        case ownStorage
    }

    /// An ejection as this vault sees it.
    public struct Ejection: Sendable, Equatable {
        /// The bucket a key of the person's must reach (its name, endpoint and region stay the same).
        public var location: BucketLocation?
        /// The cloud recorded this Mac's conversion report.
        public var reported: Bool
        /// The ejection finished: the bucket is in the person's own account now (its state `ejected`).
        public var complete: Bool
        /// `GET /v1/storage`'s `provider` (b2: Backblaze), whose account the bucket goes to.
        public var provider: String?
    }

    /// What the UI shows: never a key id or a secret.
    public struct Status: Sendable, Equatable {
        public var phase: Phase
        public var access: String?
        public var expiresAt: Date?
        public var renewAfter: Date?
        public var nextCheck: Date?
        /// Set once the vault's storage is being ejected to the person (or was).
        public var ejection: Ejection?
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
    /// After ``resume()``: the cloud's lingering `revoked_reason` `account_holder` is the one the person overrode.
    private var resumed = false
    private var failures = 0
    /// The run loop's current sleep, which a refused key ends early.
    private var sleeper: Task<Void, any Error>?
    /// Checks in a row that found the bucket still being provisioned.
    private var provisioningChecks = 0
    /// An ejection: where the bucket is, whether the cloud recorded this Mac's conversion, whether it finished.
    private var ejection: Ejection?
    /// When the conversion report is tried again after a failure, and how many failed in a row.
    private var reportAt: Date = .distantPast
    private var reportFailures = 0
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
        if (try? store.isOwnStorage(vaultUid)) == true {
            // The person's own key (or their refused one): this vault left managed storage, and the cloud is never asked
            // for a key again. Whether the cloud recorded the conversion is read once per launch.
            phase = key != nil ? .ownStorage : .needsOwnKey(.refused)
            ejection = Ejection(location: try? store.location(vaultUid), reported: false, complete: true)
        } else if let reason = try? store.revokedReason(vaultUid) {
            phase = .stopped(.keyRevoked(reason: reason))
        }
    }

    public var status: Status {
        Status(phase: phase, access: key?.access, expiresAt: key?.expiresAt, renewAfter: key?.renewAfter, nextCheck: nextWake(),
               ejection: ejection)
    }

    public func observe(_ handler: @escaping @Sendable (Status) -> Void) {
        onChange = handler
        handler(status)
    }

    /// Runs the loop until it stops or the task is cancelled.
    public func run() async {
        while !Task.isCancelled {
            guard let next = await step() else { return }
            // Never a busy loop, whatever a step returns. The sleep is its own task so that the provider refusing the
            // key (``providerRefusedKey()``) ends it early instead of waiting for `renew_after` or the next view read.
            let clock = clock
            let until = max(next, clock.now + 1)
            let nap = Task { try await clock.sleep(until: until) }
            sleeper = nap
            _ = await withTaskCancellationHandler { await nap.result } onCancel: { nap.cancel() }
            sleeper = nil
        }
    }

    /// Does what is due now (read the cloud's view, renew) and returns when to come back, or nil once stopped.
    @discardableResult
    public func step() async -> Date? {
        defer { onChange?(status) }
        let now = clock.now
        if case .stopped = phase { return nil }
        if isLeaving { return await stepLeaving(now) }
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
        case .leaving, .needsOwnKey, .ownStorage: return await stepLeaving(now)
        case .retrying(_, _, let at) where now < at: return at
        default: break
        }
        if renewNow || key == nil || now >= key!.renewAfter { await renew(now: now) }
        return nextWake()
    }

    /// Follows a view of `GET /v1/storage` read elsewhere (the section's refresh), without waiting for the loop. A stop
    /// that isn't the account holder's revocation ends here once the view shows this Mac holding the vault again (the
    /// account holder placed it back; the caller runs the loop again).
    public func apply(_ view: CloudStorage) async {
        if isLeaving {
            observeEjection(view)
            onChange?(status)
            return
        }
        if case .stopped(let stop) = phase {
            guard Self.endsWhenHeldAgain(stop), let v = view.vault(vaultUid), v.movedTo == nil, v.released == nil,
                  v.desktop?.installationId == installationID else { return }
            phase = .starting
            renewNow = true
        }
        await reconcile(view, now: clock.now)
        onChange?(status)
    }

    /// Whether a stop ends by itself when the cloud shows this Mac holding the vault again.
    static func endsWhenHeldAgain(_ stop: Stop) -> Bool {
        switch stop {
        case .keyRevoked, .unlinked: false
        default: true
        }
    }

    /// The provider refused the key (the sync engine's 401 or 403): the cloud's view is read now, and a new key asked for
    /// (the loop wakes, rather than keep a dead key until `renew_after`).
    public func providerRefusedKey() {
        switch phase {
        case .ownStorage:
            // The person's own key: kept as a tombstone that says the vault is theirs, so no relaunch asks the cloud.
            key = nil
            do { try store.delete(vaultUid, revokedReason: BucketKeyStore.ownKeyRefused) } catch {
                Self.log.notice("device access: a refused key couldn't be removed: \(String(describing: error), privacy: .public)")
            }
            phase = .needsOwnKey(.refused)
            onChange?(status)
            return
        case .leaving:
            forget()
            phase = .needsOwnKey(.cloudKeyEnded)
            onChange?(status)
            return
        case .needsOwnKey: return
        default: break
        }
        nextRefresh = .distantPast
        renewNow = true
        sleeper?.cancel()
    }

    /// After ``Stop/keyRevoked(reason:)``, the person asks for a new key.
    public func resume() {
        guard case .stopped(.keyRevoked) = phase else { return }
        try? store.delete(vaultUid)
        resumed = true
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

    /// The person's own key for the vault's bucket, made in their own provider account after an ejection, once the
    /// caller checked it reaches this vault's bucket (``VaultBucketCheck``): kept where the bucket key lives (the
    /// keychain group shared with the File Provider extension), and used from now on. Never asks the cloud for anything
    /// but the conversion report, if it is still due. Refused while the vault is still in managed storage.
    public func useOwnKey(_ own: BucketKey) throws {
        guard own.origin == .customer, own.vaultUid == vaultUid else { throw DeviceAccessError.malformed("not the person's own key") }
        guard isLeaving else {
            throw DeviceAccessError.forbidden("This vault is still in Vaulthalla Cloud's managed storage; it takes no key of yours.")
        }
        try store.save(own)
        key = own
        phase = .ownStorage
        renewNow = false
        failures = 0
        if ejection == nil { ejection = Ejection(location: nil, reported: false, complete: true) }
        ejection?.location = BucketLocation(bucket: own.bucket, bucketID: own.bucketID, s3Endpoint: own.s3Endpoint, region: own.region)
        sleeper?.cancel()  // the loop wakes: a conversion report still due goes now
        onChange?(status)
    }

    /// Where a key of the person's must reach, once the vault's storage is being ejected to them (or was).
    public var ownKeyLocation: BucketLocation? { isLeaving ? ejection?.location : nil }

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
        case .leaving(let until):
            return [nextRefresh, until, ejection?.reported == false ? reportAt : nil].compactMap { $0 }.min()
        case .needsOwnKey: return [nextRefresh, ejection?.reported == false ? reportAt : nil].compactMap { $0 }.min()
        case .ownStorage: return ejection?.reported == false ? reportAt : clock.now + settings.pausedInterval
        case .starting, .holding:
            if renewNow || key == nil { return clock.now }
            return [nextRefresh, key!.renewAfter, key!.expiresAt].min()
        }
    }

    private func forget(revokedReason: String? = nil) {
        key = nil
        do { try store.delete(vaultUid, revokedReason: revokedReason) } catch {
            Self.log.notice("device access: a stored storage key couldn't be removed: \(String(describing: error), privacy: .public)")
        }
    }

    private func forgetIfExpired(_ now: Date) {
        guard let key, now >= key.expiresAt else { return }
        forget()
        renewNow = true
    }

    private func stop(_ reason: Stop) {
        if case .keyRevoked(let why) = reason { forget(revokedReason: why) } else { forget() }
        phase = .stopped(reason)
        renewNow = false
    }

    private func reconcile(_ view: CloudStorage, now: Date) async {
        nextRefresh = now + settings.refreshInterval
        guard let v = view.vault(vaultUid) else { return stop(.vaultRemoved) }
        if let moved = v.movedTo { return stop(.moved(deploymentID: moved.deploymentId, name: moved.name)) }
        guard let holder = v.desktop, holder.installationId == installationID else {
            // Why this Mac lost the vault, as the cloud records it.
            switch v.released?.reason {
            case "released": return stop(.released)
            case "hold_removed": return stop(.takenOff)
            case "hold_reassigned": return stop(.reassigned(to: v.released?.to?.name ?? v.desktop?.name))
            case "moved":
                let to = v.released?.to
                return stop(.moved(deploymentID: to?.deploymentId ?? "", name: to?.name ?? "a server"))
            default: break
            }
            if let other = v.desktop { return stop(.notHeld(.heldByAnotherMac(name: other.name))) }
            // A server's vault, or nobody's (never this Mac's): the vault's own record says which.
            let replicas = (try? await client.vault(vaultUid))?.replicas ?? []
            return stop(.notHeld(replicas.isEmpty ? .unplaced : .heldByServer(name: nil)))
        }
        // Ejected to the customer, or being: converted in place (before the plan's check: the ejection ends the
        // subscription, and the vault must not wait for a plan).
        if v.state == "ejecting" || v.state == "ejected" {
            beginLeaving(v, now: now)
            ejection?.provider = view.provider
            return
        }
        if view.entitlement.storageAccess == "none" {
            // Suspended or ended: the cloud revoked every key and refuses new ones.
            forget()
            phase = .paused(entitlement: view.entitlement.state)
            nextRefresh = now + settings.pausedInterval
            return
        }
        if let e = view.ejection, e.state != "refused", e.state != "complete" { return wait(.ejecting, now: now) }
        switch v.state {
        case "ready": provisioningChecks = 0
        case "off", "none": return wait(.bucketOff, now: now)
        case "emptying", "deleted":
            forget()
            return wait(.bucketDeleting, now: now)
        default:
            return wait(v.reason == "account_key_unconfirmed" ? .accountKeyUnconfirmed
                        : v.reason == "payment_required" ? .paymentRequired(cause: view.entitlement.cause) : .bucketNotReady, now: now)
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
            switch Self.afterRevocation(c.revokedReason, hadKey: key != nil) {
            case .stopRevoked(let why) where !(resumed && why == "account_holder"): return stop(.keyRevoked(reason: why))
            case .unlinked: return stop(.unlinked)
            case .ejecting:
                forget()
                return wait(.ejecting, now: now)
            default:
                forget()
                renewNow = true
            }
        }
        if case .retrying(_, _, let at) = phase, at > now {} else { phase = .holding }
        forgetIfExpired(now)
    }

    enum AfterRevocation: Equatable { case renew, stopRevoked(String), unlinked, ejecting }

    /// What a key the cloud shows as gone (`none`) means while this Mac still holds the vault, by `revoked_reason`.
    /// Stops only for the account holder's own revocation and reasons this version doesn't know; renews by itself after
    /// the plan's changes (the cloud refuses a key while the plan gives none: the entitlement check above pauses
    /// first), the key's own lifecycle, and an old hold's reasons once the vault is placed here again.
    static func afterRevocation(_ reason: String?, hadKey: Bool) -> AfterRevocation {
        switch reason {
        case nil: hadKey ? .stopRevoked("account_holder") : .renew  // a daemon before "As built" 27: assume the holder
        case "suspended", "ended", "no_plan", "restricted", "over_quota": .renew
        case "replaced", "not_acknowledged", "not_delivered", "access_changed": .renew
        case "hold_removed", "hold_reassigned", "released", "moved": .renew
        case "installation_revoked": .unlinked
        case "ejection": .ejecting
        default: .stopRevoked(reason!)  // account_holder, other, anything newer
        }
    }

    // MARK: leaving managed storage (an ejection)

    private var isLeaving: Bool {
        switch phase {
        case .leaving, .needsOwnKey, .ownStorage: true
        default: false
        }
    }

    /// The cloud's view shows the vault's bucket being ejected (or ejected): the vault converts in place. The cloud's
    /// key in hand stays in use until it ends; none is asked for again.
    private func beginLeaving(_ v: CloudStorage.Vault, now: Date) {
        observeEjection(v)
        renewNow = false
        nextRefresh = now + settings.waitingInterval
        if let key, key.origin == .cloud, now < key.expiresAt {
            phase = .leaving(keyUntil: key.expiresAt)
        } else {
            forget()
            phase = .needsOwnKey(.cloudKeyEnded)
        }
    }

    private func observeEjection(_ view: CloudStorage) {
        if let v = view.vault(vaultUid) { observeEjection(v) }
        ejection?.provider = view.provider
    }

    private func observeEjection(_ v: CloudStorage.Vault) {
        var e = ejection ?? Ejection(location: nil, reported: false, complete: false)
        if let bucket = v.bucket, let id = v.bucketId, let endpoint = v.s3Endpoint, let region = v.region {
            e.location = BucketLocation(bucket: bucket, bucketID: id, s3Endpoint: endpoint, region: region)
        } else if e.location == nil, let key {
            e.location = BucketLocation(bucket: key.bucket, bucketID: key.bucketID, s3Endpoint: key.s3Endpoint, region: key.region)
        }
        if v.state == "ejected" { e.complete = true }
        ejection = e
    }

    /// One round while the vault leaves managed storage: the cloud's last key ending, the conversion report until the
    /// cloud recorded it, and (until the person's own key is in use) the cloud's view now and then, to say when the
    /// bucket became the person's. Never a key request.
    private func stepLeaving(_ now: Date) async -> Date? {
        if case .leaving = phase, key == nil || now >= key!.expiresAt {
            forget()
            phase = .needsOwnKey(.cloudKeyEnded)
        }
        if ejection?.reported != true, now >= reportAt { await reportConversion(now) }
        if phase != .ownStorage, now >= nextRefresh {
            nextRefresh = now + settings.waitingInterval
            if let view = try? await client.storage() { observeEjection(view) }
        }
        return nextWake()
    }

    /// `POST .../ejected`, once: the ejection waits for it. The cloud's own record is read first (a relaunch reports
    /// nothing twice); a vault whose storage the cloud says isn't being ejected has nothing to report.
    private func reportConversion(_ now: Date) async {
        do {
            if try await client.ejectionProgress().converted(vaultUid, by: installationID) {
                ejection?.reported = true
                return
            }
            try await client.reportEjectionConverted(vaultUid)
            ejection?.reported = true
        } catch {
            let e = DeviceAccessError.from(error)
            if case .other(409, "not_ejecting", _) = e {
                ejection?.reported = true
                return
            }
            Self.log.notice("device access: the conversion report waits: \(e.name, privacy: .public)")
            reportFailures += 1
            // Unlinked: nothing can report it until this Mac is linked again (a relaunch tries once more).
            reportAt = e == .unlinked ? .distantFuture
                : now + min(settings.pausedInterval, settings.backoffBase * pow(2, Double(min(reportFailures - 1, 16))))
        }
    }

    private func wait(_ reason: DeviceAccessError, now: Date) {
        phase = .waiting(reason)
        guard reason == .bucketNotReady else {
            nextRefresh = now + settings.waitingInterval
            return
        }
        let delay = settings.provisioningInterval * pow(2, Double(min(provisioningChecks, 16)))
        provisioningChecks += 1
        nextRefresh = now + min(settings.waitingInterval, delay)
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
            resumed = false
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
        case .ejecting, .ejected:
            // The cloud's view says which vault is being ejected: read it now (it converts the vault in place).
            phase = .waiting(e)
            nextRefresh = now
        case .paymentRequired:
            forget()
            phase = .paused(entitlement: nil)
            nextRefresh = now + settings.pausedInterval
        case .bucketNotReady, .bucketOff, .bucketDeleting, .accountKeyUnconfirmed:
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
