public import Foundation
public import VHVaultKeys
import OSLog
import VHRecovery

/// The bucket key as the File Provider extension signs with it: read from the shared keychain group (``BucketKeyStore``),
/// which the app writes as it renews the key. The extension never asks the cloud: a key past its expiry is not used,
/// and a key the provider refuses (401/403) is dropped and reported to the app through ``KeyRefusalSignal``.
public final class SharedBucketKeyCredentials: S3CredentialSource, @unchecked Sendable {
    let store: BucketKeyStore
    let uid: String
    let signal: KeyRefusalSignal
    let now: @Sendable () -> Date
    private let lock = NSLock()
    private var refusedKeyID: String?

    public init(store: BucketKeyStore, uid: String, signal: KeyRefusalSignal, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.uid = uid
        self.signal = signal
        self.now = now
    }

    /// What the shared group holds now, in ``SharedKeyState``'s words.
    public var state: SharedKeyState {
        guard let key = try? store.load(uid) else { return .none }
        if lock.withLock({ refusedKeyID == key.keyID }) { return .refused }
        return now() < key.expiresAt ? .inForce(expiresAt: key.expiresAt) : .expired(at: key.expiresAt)
    }

    public func withS3Credentials<R: Sendable>(_ body: @Sendable (S3Credentials) throws -> R) async rethrows -> R? {
        // Read each time: the app may have renewed it since (a keychain read, no network).
        guard let key = try? store.load(uid), now() < key.expiresAt, lock.withLock({ refusedKeyID != key.keyID }) else {
            return nil
        }
        return try key.secret.withUnsafeBytes { secret in
            try body(S3Credentials(accessKeyID: key.keyID, secret: secret, bucket: key.bucket, endpoint: key.s3Endpoint,
                                   region: key.region))
        }
    }

    public func providerRefused() async {
        guard let key = try? store.load(uid) else { return }
        lock.withLock { refusedKeyID = key.keyID }
        signal.post(uid: uid, keyID: key.keyID)
    }
}

/// The engine host of the File Provider extension for a Desktop-only domain. It opens the vault itself (one process per
/// vault: the state file is locked, and the app hands the engine over when it shows the vault in Finder), with the
/// vault key and the bucket key from the keychain group it shares with the app, as a reader (no lease). It makes no
/// cloud call and links no cloud client (VHVaultEngine doesn't depend on VHCloud): the app renews the bucket key.
/// Sync: publish two seconds after a change, refresh every minute while the extension runs.
public actor ExtensionEngineHost: EngineHost {
    let uid: String
    let registry: DesktopVaultRegistry
    let items: VaultItems
    let credentials: SharedBucketKeyCredentials
    private var vault: Vault?
    private var loop: Task<Void, Never>?
    private var publishAt: Date?
    private var failure: String?
    private static let log = Logger(subsystem: "sh.vaulthalla.app", category: "fileprovider-engine")

    public init(uid: String, container: URL, items: VaultItems = .fileProvider()) {
        self.uid = uid
        registry = DesktopVaultRegistry(container: container)
        self.items = items
        credentials = SharedBucketKeyCredentials(store: BucketKeyStore(vaultItems: items), uid: uid,
                                                 signal: KeyRefusalSignal(container: container))
    }

    public func openedVault() async -> Vault? {
        if vault == nil { await open() }
        return vault
    }

    public func noteChange() async { publishAt = Date() + 2 }
    public func noteWriteConflict() async {}

    /// Why the vault can't be served or synced: no record or key here, or the bucket key's state.
    public func unavailableReason() async -> String? { failure ?? credentials.state.sentence }

    private func open() async {
        guard let wire = Uid(base32: uid) else { return }
        guard let record = try? registry.record(uid), record.hold == .holding, let node = record.nodeID else {
            failure = "Open Vaulthalla once: it prepares this vault for Finder."
            return
        }
        let store = S3Store(credentials: credentials, scratch: registry.scratchURL(uid))
        let keys = KeychainVaultKeys(store: VaultKeyStore(vaultItems: items), uid: uid)
        do throws(VaultError) {
            vault = try await Vault.open(uid: wire, store: store, keys: keys, stateURL: registry.stateURL(uid), nodeID: node).vault
            failure = nil
            startLoop()
        } catch {
            Self.log.notice("open: \(error.name, privacy: .public)")
            failure = error.name == "state_busy" ? "Vaulthalla is handing this vault to Finder; try again in a moment." : nil
        }
    }

    private func startLoop() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var nextRefresh = Date()
            while !Task.isCancelled {
                guard let self else { return }
                nextRefresh = await self.round(nextRefresh: nextRefresh)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// One round: publish when due, refresh every minute; quietly nothing while there is no usable key.
    private func round(nextRefresh: Date) async -> Date {
        guard let vault else { return nextRefresh }
        let now = Date()
        let publishDue = publishAt.map { now >= $0 } ?? false
        guard publishDue || now >= nextRefresh else { return nextRefresh }
        guard case .inForce = credentials.state else { return now + 60 }
        do throws(VaultError) {
            try await vault.perform { v throws(VaultError) in
                _ = try v.refresh()
                if try v.status().unpublished { _ = try v.publish() }
            }
            publishAt = nil
        } catch {
            Self.log.notice("sync: \(error.name, privacy: .public)")
            if publishDue { publishAt = now + 15 }
        }
        return now + 60
    }

    public func replicaClosing() async { await close() }

    public func close() async {
        loop?.cancel()
        loop = nil
        if let vault, (try? vault.status().unpublished) == true {
            _ = try? await vault.perform { v throws(VaultError) in try v.publish() }
        }
        vault = nil
    }
}
