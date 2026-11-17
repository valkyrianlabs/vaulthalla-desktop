public import Foundation
public import VHCloud
public import VHCore
public import VHRecovery
import OSLog

// MARK: - the switch

/// Desktop-only vaults are unfinished: nothing here has run in a signed app, so the whole feature (the cloud section's
/// "New Vault in Managed Storage", starting ``DeviceAccess`` and the engine, the Finder domains) stays behind this one
/// switch, off unless `defaults write sh.vaulthalla.app cloud.desktopVaults.enabled -bool YES`.
public enum DesktopVaultsFeature {
    public static let defaultsKey = "cloud.desktopVaults.enabled"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: defaultsKey) }
}

// MARK: - readiness and errors

/// Whether this Mac may create a Desktop-only vault now, and if not, where the person goes.
public enum DesktopVaultReadiness: Sendable, Equatable {
    case ready
    /// Not linked to Vaulthalla Cloud.
    case unlinked
    /// This Mac doesn't hold the account recovery key (Recovery Key: receive it, or create it).
    case noAccountKey
    /// No offline copy of the recovery key is confirmed (Recovery Key: print it or save it, then record it). The cloud
    /// refuses managed storage without one.
    case offlineCopyNeeded
    /// The plan gives no storage to write to (`storage_access` and its cause).
    case noStorage(access: String, cause: String)
    case unavailable(String)

    public var sentence: String {
        switch self {
        case .ready: "Ready."
        case .unlinked: "Link this Mac to your Vaulthalla Cloud account first."
        case .noAccountKey: "This Mac needs your account's recovery key first (Recovery Key)."
        case .offlineCopyNeeded:
            "Save an offline copy of your recovery key first (Recovery Key: print it or save it to 1Password). Without it, a vault kept only in managed storage couldn't be recovered if this Mac were lost."
        case .noStorage(let access, let cause):
            access == "read_delete" ? "Your plan is read-only right now (\(cause)): new vaults can't be stored."
                : "Your plan doesn't include managed storage right now (\(cause))."
        case .unavailable(let why): why
        }
    }
}

public enum DesktopVaultError: Error, Sendable, Equatable, CustomStringConvertible {
    case notReady(DesktopVaultReadiness)
    case cloud(DeviceAccessError)
    case vault(VaultError)
    /// The keychain refused (no credential lease, a damaged item).
    case keys(String)
    /// The cloud doesn't show this Mac holding the vault.
    case notHeldHere
    /// The cloud has no envelope of the vault this Mac's account key opens.
    case noKeyForVault
    case unknownVault

    public var description: String { "DesktopVaultError(\(sentence))" }

    public var sentence: String {
        switch self {
        case .notReady(let r): r.sentence
        case .cloud(let e): e.message
        case .vault(let e): e.sentence
        case .keys(let why): "This Mac's keychain refused the vault's key (\(why))."
        case .notHeldHere: "Vaulthalla Cloud doesn't show this Mac holding that vault. The account holder places it in the portal."
        case .noKeyForVault: "None of the vault's keys in Vaulthalla Cloud opens with this Mac's recovery key."
        case .unknownVault: "This Mac doesn't know that vault."
        }
    }

    static func from(_ e: any Error) -> DesktopVaultError {
        if let e = e as? DesktopVaultError { return e }
        if let e = e as? VaultError { return .vault(e) }
        if let e = e as? AccountItemError { return .keys(String(describing: e)) }
        if e is CredentialOwnershipError { return .keys("another part of Vaulthalla owns this Mac's credentials") }
        return .cloud(DeviceAccessError.from(e))
    }
}

/// Where a creation is.
public enum DesktopVaultCreationStep: Sendable, Equatable {
    case makingKey
    case enrolling
    case registering
    case switchingOn
    case waitingForStorage(DeviceAccessError?)
    case gettingKey
    case publishing
    case done
}

// MARK: - the lifecycle

/// Desktop-only vaults on this Mac (docs/desktop-vaults.md): creating one (a new vault key made here, wrapped to the
/// account key and enrolled, so it is recoverable before any file is stored; registered with no deployment; storage on;
/// the bucket; the bucket key; the first publish), opening one this Mac holds, adopting one the account holder placed
/// here from another Mac (its keys from the cloud's envelopes, opened with the account key), and stopping holding one.
/// Each open vault is a ``DesktopVaultSession``: its ``DeviceAccess`` renewal loop and its sync loop.
public actor DesktopVaults {
    public typealias StoreFactory = @Sendable (_ access: DeviceAccess, _ scratch: URL) -> any VaultStore

    let client: CloudClient
    let account: CloudAccount
    let vaultKeys: VaultKeyStore
    let bucketKeys: BucketKeyStore
    /// This Mac's attestation key, in the account's app-only items (never the group shared with the extension).
    let attestationKeys: AttestationKeyStore
    public nonisolated let registry: DesktopVaultRegistry
    let makeStore: StoreFactory
    let clock: any DeviceAccessClock
    let accessSettings: DeviceAccess.Settings
    let syncSettings: DesktopVaultSession.Settings
    /// How long a creation waits for the bucket and its key before it returns (the vault then finishes on its own).
    let bucketWait: TimeInterval
    private(set) var sessions: [String: DesktopVaultSession] = [:]
    /// The File Provider extension's word that the provider refused a vault's bucket key.
    public nonisolated let refusals: KeyRefusalSignal
    private static let log = Logger(subsystem: "sh.vaulthalla.app", category: "vault.desktop")

    public init(client: CloudClient, account: CloudAccount, items: LeasedAccountItems, container: URL,
                makeStore: StoreFactory? = nil, clock: any DeviceAccessClock = SystemDeviceAccessClock(),
                accessSettings: DeviceAccess.Settings = .init(), syncSettings: DesktopVaultSession.Settings = .init(),
                bucketWait: TimeInterval = 120, vaultItems: VaultItems? = nil) {
        self.client = client
        self.account = account
        // Vault keys and the bucket key: the group shared with the File Provider extension (`vaultItems`; the app passes
        // ``VaultItems/app(lease:)``), else `items` alone.
        let keyItems = vaultItems ?? VaultItems(shared: items)
        vaultKeys = VaultKeyStore(vaultItems: keyItems)
        bucketKeys = BucketKeyStore(vaultItems: keyItems)
        attestationKeys = AttestationKeyStore(items: items)
        refusals = KeyRefusalSignal(container: container)
        registry = DesktopVaultRegistry(container: container)
        self.makeStore = makeStore ?? { access, scratch in S3Store(credentials: access, scratch: scratch) }
        self.clock = clock
        self.accessSettings = accessSettings
        self.syncSettings = syncSettings
        self.bucketWait = bucketWait
    }

    func installationID() throws(DesktopVaultError) -> String {
        guard let link = try? client.link(), link.state == .linked, let id = link.installationID else { throw .notReady(.unlinked) }
        return id
    }

    /// The vaults this Mac holds or held.
    public func records() -> [DesktopVaultRecord] { (try? registry.load()) ?? [] }

    public func session(_ uid: String) -> DesktopVaultSession? { sessions[uid] }

    // MARK: readiness

    /// Linked, holding the current account key, an offline copy confirmed, and a plan with storage to write to.
    public func readiness() async -> DesktopVaultReadiness {
        guard (try? installationID()) != nil else { return .unlinked }
        do {
            guard try await account.status().holdsCurrent else { return .noAccountKey }
            let storage = try await client.storage()
            guard storage.accountKeyOfflineCopyConfirmed else { return .offlineCopyNeeded }
            guard storage.entitlement.storageAccess == "full" else {
                return .noStorage(access: storage.entitlement.storageAccess, cause: storage.entitlement.cause)
            }
            return .ready
        } catch {
            let e = DeviceAccessError.from(error)
            return e == .unlinked ? .unlinked : .unavailable(e.message)
        }
    }

    // MARK: creating

    /// Creates a Desktop-only vault named `name`. When its storage isn't ready within the wait, the vault is registered,
    /// enrolled and recorded, and its session finishes the creation once the bucket and its key arrive.
    public func create(name: String, progress: @escaping @Sendable (DesktopVaultCreationStep) -> Void = { _ in })
        async throws(DesktopVaultError) -> DesktopVaultSession
    {
        let readiness = await readiness()
        guard readiness == .ready else { throw .notReady(readiness) }
        let me = try installationID()
        let uid = Uid.random()
        let text = uid.base32
        do {
            // The key first, and only on this Mac until its envelope is in the cloud.
            progress(.makingKey)
            guard let statement = try await account.heldStatement() else { throw DesktopVaultError.notReady(.noAccountKey) }
            let key = newVaultKey()
            try vaultKeys.save(text, version: 1, key: key)
            let envelope = try KEV1.wrap(vaultKey: key, suite: .x25519, keyVersion: 1, vaultUid: uid,
                                         recipientPublicKey: statement.x25519PublicKey)
            try registry.save(DesktopVaultRecord(uid: text, name: name, createdAt: Date(), published: false, adopted: false,
                                                 hold: .holding, nodeID: me))
            // Recoverable before anything is stored: the envelope to the account key, enrolled (which registers it).
            progress(.enrolling)
            // With this Mac's provenance of version 1 (its key check and attestation), so a server can adopt it.
            _ = try await client.enrollDesktopVault(text, envelopes: [envelope], versions: [1],
                                                    provenance: try provenance(text, versions: [1], installationID: me))
            progress(.registering)
            _ = try await client.registerDesktopVault(text)
            progress(.switchingOn)
            _ = try await client.setManagedStorage(text, enabled: true)
            let session = try makeSession(text, name: name, installationID: me, envelopes: [1: envelope])
            sessions[text] = session
            await session.start()
            progress(.waitingForStorage(nil))
            let deadline = clock.now + bucketWait
            while clock.now < deadline {
                let phase = await session.accessPhase
                if phase == .holding { break }
                if case .stopped = phase { break }
                if case .waiting(let why) = phase { progress(.waitingForStorage(why)) }
                try? await clock.sleep(until: clock.now + 1)
            }
            progress(.gettingKey)
            if await session.accessPhase == .holding {
                progress(.publishing)
                try await session.finishCreation()
            }
            progress(.done)
            return session
        } catch {
            throw DesktopVaultError.from(error)
        }
    }

    // MARK: provenance

    /// This Mac's provenance of `versions` of `uid` (docs/desktop-vaults.md, "Key provenance"): each key from the
    /// keychain, checked and attested with vl-keykit.
    func provenance(_ uid: String, versions: [UInt32], installationID: String) throws -> VaultProvenance {
        let keys = vaultKeys
        return try attestationKeys.provenance(uid: uid, installationID: installationID, versions: versions) { v, use in
            guard try keys.withKey(uid, version: v, { try use($0) }) != nil else {
                throw VaultError(local: "no_vault_key", "This Mac holds no key of this vault.")
            }
        }
    }

    /// Enrolls again, with their provenance, the versions of a vault this Mac created and still holds: a vault enrolled
    /// before Desktop attested gets its versions proven (the cloud lets the enrolling Mac fill a bare version once); an
    /// enrolled one changes nothing. Best effort: a failure is logged and tried at the next open.
    func attestCreatedVersions(_ uid: String, installationID: String) async {
        do {
            guard let held = try vaultKeys.versions(uid) else { return }
            // The envelopes the cloud has already (the same bytes: nothing new is stored); none, nothing to backfill.
            guard let recorded = try await client.vaultEnvelopes(uid), !recorded.isEmpty else { return }
            let envelopes = recorded.compactMap { Base64URL.decode($0.envelope) }
            let p = try provenance(uid, versions: held.versions, installationID: installationID)
            _ = try await client.enrollDesktopVault(uid, envelopes: envelopes, versions: held.versions, provenance: p)
        } catch {
            Self.log.notice("provenance: not recorded yet: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: opening

    /// Opens a vault this Mac holds (its keys in the keychain): the state file, else a re-anchor from the bucket.
    /// `engine` false: only its bucket key's renewal runs here (Finder shows the vault, so the extension runs the
    /// engine with the key this Mac keeps renewing in the shared group).
    public func open(_ uid: String, engine: Bool = true) async throws(DesktopVaultError) -> DesktopVaultSession {
        if let s = sessions[uid] {
            if engine { await s.takeEngineBack() } else { await s.handOverEngine() }
            return s
        }
        let me = try installationID()
        guard var record = try? registry.record(uid), record.hold == .holding else { throw .unknownVault }
        guard (try? vaultKeys.versions(uid)) != nil else { throw .noKeyForVault }
        if record.nodeID == nil {  // the extension opens it as this Mac's writer too
            record.nodeID = me
            try? registry.save(record)
        }
        if !record.adopted { await attestCreatedVersions(uid, installationID: me) }
        let session = try makeSession(uid, name: record.name, installationID: me, envelopes: [:])
        sessions[uid] = session
        if !engine { await session.handOverEngine() }
        await session.start()
        return session
    }

    /// Finder shows `uid`: the extension runs its engine; this Mac keeps renewing its bucket key.
    public func handOver(_ uid: String) async { await sessions[uid]?.handOverEngine() }

    /// Finder no longer shows `uid`: the engine runs here again.
    public func takeBack(_ uid: String) async { await sessions[uid]?.takeEngineBack() }

    /// Follows the extension's refusals (the provider refused a vault's bucket key, 401/403): DeviceAccess reads the
    /// cloud's view and asks for a new key at once. Called at launch, on every signal, and on the app's refreshes.
    public func followRefusals() async {
        for r in refusals.take() {
            guard let s = sessions[r.vaultUid] else { continue }
            await s.access.providerRefusedKey()
            await s.access.step()
        }
    }

    /// Opens every vault this Mac holds (the app's launch).
    public func openHeld() async -> [String: DesktopVaultError] {
        var failed: [String: DesktopVaultError] = [:]
        for r in records() where r.hold == .holding && sessions[r.uid] == nil {
            do throws(DesktopVaultError) { _ = try await open(r.uid) } catch { failed[r.uid] = error }
        }
        return failed
    }

    /// Vaults the cloud shows this Mac holding that it has no keys for yet: placed here from another Mac.
    public func adoptable() async throws(DesktopVaultError) -> [String] {
        let me = try installationID()
        do {
            let view = try await client.storage()
            return view.vaults.filter { $0.desktop?.installationId == me && (try? vaultKeys.versions($0.vaultUid)) == nil }
                .map(\.vaultUid)
        } catch {
            throw DesktopVaultError.from(error)
        }
    }

    // MARK: adopting

    /// The account holder placed `uid` on this Mac (the portal's `PUT /v1/vaults/{uid}/desktop`): its keys come from the
    /// cloud's envelopes, opened with this Mac's account key, then the vault opens from the bucket (a re-anchor) and this
    /// Mac joins its writers.
    public func adopt(_ uid: String, name: String) async throws(DesktopVaultError) -> DesktopVaultSession {
        let me = try installationID()
        guard let wire = Uid(base32: uid) else { throw .unknownVault }
        do {
            let view = try await client.storage()
            guard view.vault(uid)?.desktop?.installationId == me else { throw DesktopVaultError.notHeldHere }
            guard let envelopes = try await client.vaultEnvelopes(uid), !envelopes.isEmpty else { throw DesktopVaultError.noKeyForVault }
            let keys = try await account.openVaultKeys(envelopes, vaultUid: wire)
            guard let current = keys.keys.max() else { throw DesktopVaultError.noKeyForVault }
            for (version, key) in keys.sorted(by: { $0.key < $1.key }) {
                try vaultKeys.save(uid, version: version, key: key, makeCurrent: version == current)
            }
            try registry.save(DesktopVaultRecord(uid: uid, name: name, createdAt: Date(), published: true, adopted: true,
                                                 hold: .holding, nodeID: me))
            let raw = Dictionary(envelopes.compactMap { e in Base64URL.decode(e.envelope).map { (e.keyVersion, $0) } }) { a, _ in a }
            let session = try makeSession(uid, name: name, installationID: me, envelopes: raw, joining: true)
            sessions[uid] = session
            await session.start()
            return session
        } catch {
            throw DesktopVaultError.from(error)
        }
    }

    // MARK: releasing

    /// This Mac stops holding `uid`: the cloud revokes its bucket key and the vault waits, unplaced, for the account
    /// holder. Local files, the state and the keys stay (the keys are recovery material; their envelopes are in the
    /// cloud).
    public func stopHolding(_ uid: String) async throws(DesktopVaultError) {
        do {
            if let s = sessions.removeValue(forKey: uid) {
                try await s.release()
            } else {
                try await client.releaseDesktopVault(uid)
            }
            if var r = try registry.record(uid) {
                r.hold = .released
                try registry.save(r)
            }
        } catch {
            throw DesktopVaultError.from(error)
        }
    }

    /// Closes one vault's session (the File Provider extension takes the vault over: one engine per vault).
    public func close(_ uid: String) async {
        await sessions.removeValue(forKey: uid)?.close()
    }

    public func closeAll() async {
        for s in sessions.values { await s.close() }
        sessions = [:]
    }

    private func makeSession(_ uid: String, name: String, installationID: String, envelopes: [UInt32: Data],
                             joining: Bool = false) throws(DesktopVaultError) -> DesktopVaultSession {
        let access: DeviceAccess
        do {
            access = try DeviceAccess(client: client, vaultUid: uid, installationID: installationID, store: bucketKeys,
                                      clock: clock, settings: accessSettings)
        } catch {
            throw DesktopVaultError.from(error)
        }
        return DesktopVaultSession(uid: uid, name: name, nodeID: installationID, access: access,
                                   store: makeStore(access, registry.scratchURL(uid)),
                                   keys: KeychainVaultKeys(store: vaultKeys, uid: uid), registry: registry,
                                   envelopes: envelopes, joining: joining, settings: syncSettings)
    }
}
