public import Foundation
public import VHCloud
import OSLog
import VHCore
import VHRecovery

/// One Desktop-only vault this Mac holds, open: its bucket key's renewal (``DeviceAccess``, started here, which the app
/// held back until an engine existed) and the engine's sync: publish shortly after each local change, refresh on a timer
/// (one HEAD while nothing moved), collect garbage once a day. Its state in words is ``Status/sentence``.
public actor DesktopVaultSession {
    public struct Settings: Sendable, Equatable {
        /// A change is published this long after the last one (changes in a burst go in one root).
        public var publishDelay: TimeInterval = 2
        /// The bucket is checked for other writers' roots this often.
        public var refreshInterval: TimeInterval = 60
        /// The sync loop runs by itself; tests drive ``syncNow()`` instead.
        public var automatic = true

        public init() {}
    }

    public enum State: Sendable, Equatable {
        case opening
        /// No bucket key yet, or the cloud says not yet (its bucket, the offline copy, the plan).
        case waitingForStorage(DeviceAccessError?)
        case syncing
        case upToDate
        /// Changes stay on this Mac until the bucket can be reached; `why` in words.
        case paused(String)
        /// A newer writer's root (the writer floor): this Mac reads and sends nothing until Vaulthalla is updated.
        case needsUpdate
        /// The engine refused the bucket's root (rollback, fork...): nothing is published until it moves on.
        case refusedRoot(String)
        /// DeviceAccess stopped (released, moved, revoked...).
        case stopped(DeviceAccess.Stop)
        /// The vault's storage was ejected to the person's own provider account and this Mac waits for a key they make
        /// there (``DesktopVaults/useOwnKey(_:keyID:secret:)``). Nothing local is deleted.
        case needsOwnKey(DeviceAccess.OwnKeyNeed)
    }

    /// The vault leaving managed storage (an ejection), while it does and after.
    public struct Leaving: Sendable, Equatable {
        /// ``DeviceAccess/Phase/leaving(keyUntil:)``, ``DeviceAccess/Phase/needsOwnKey(_:)`` or ``DeviceAccess/Phase/ownStorage``.
        public var phase: DeviceAccess.Phase
        public var ejection: DeviceAccess.Ejection?
    }

    public struct Status: Sendable, Equatable {
        public var state: State
        public var unpublished: Bool
        public var lastSynced: Date?
        /// Two-sided content changes seen (both generations kept: this Mac's current, the other a version).
        public var contentConflicts: UInt64
        /// Objects placed under /Recovered when this Mac re-anchored (written, never named in a published root).
        public var recovered: UInt64
        /// The engine's change-log revision after the last round: when it moves, Finder is told to enumerate changes.
        public var revision: UInt64 = 0
        /// Set while the vault's storage is ejected to the person (and after).
        public var leaving: Leaving?

        /// What the person reads about the vault.
        public var sentence: String {
            let ejection = leaving.flatMap { DeviceAccessWording.leaving($0.phase, ejection: $0.ejection, now: Date())?.text }
            if case .needsOwnKey = state, let ejection { return ejection }
            var s: String = switch state {
            case .opening: "Opening\u{2026}"
            case .waitingForStorage(let why): why.map { "Waiting: \($0.message)" } ?? "Waiting for its storage."
            case .syncing: "Syncing\u{2026}"
            case .upToDate: unpublished ? "Changes waiting to be sent." : "Up to date."
            case .paused(let why): "Paused: \(why)"
            case .needsUpdate:
                "Needs an update: a newer version of Vaulthalla wrote this vault. This Mac reads it and keeps its own changes until Vaulthalla is updated."
            case .refusedRoot(let reason):
                "Paused: this Mac refused the vault's storage (\(reason)), so it sends nothing. Your files on this Mac are kept."
            case .stopped(let stop): DesktopVaultSession.words(stop)
            case .needsOwnKey: "Paused: this vault needs a key from your own storage account. Nothing on this Mac is deleted."
            }
            if let ejection { s = ejection + " " + s }
            if contentConflicts > 0 {
                s += contentConflicts == 1 ? " One file was changed here and elsewhere: both versions are kept (Versions)."
                    : " \(contentConflicts) files were changed here and elsewhere: both versions of each are kept (Versions)."
            }
            if recovered > 0 {
                s += " \(recovered) unnamed file\(recovered == 1 ? " was" : "s were") found in its storage and put in \u{201C}Recovered\u{201D}."
            }
            return s
        }
    }

    public nonisolated let uid: String
    public nonisolated let name: String
    let nodeID: String
    public nonisolated let access: DeviceAccess
    let store: any VaultStore
    let keys: any VaultKeySource
    let registry: DesktopVaultRegistry
    let envelopes: [UInt32: Data]
    var joining: Bool
    let settings: Settings

    public private(set) var vault: Vault?
    /// Finder shows the vault: the File Provider extension runs its engine; only DeviceAccess runs here.
    public private(set) var engineHandedOver = false
    public private(set) var status = Status(state: .opening, unpublished: false, lastSynced: nil, contentConflicts: 0, recovered: 0)
    private var accessTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var publishAt: Date?
    private var nextRefresh: Date = .distantPast
    private var observers: [UUID: @Sendable (Status) -> Void] = [:]
    private static let log = Logger(subsystem: "sh.vaulthalla.app", category: "vault.session")

    init(uid: String, name: String, nodeID: String, access: DeviceAccess, store: any VaultStore, keys: any VaultKeySource,
         registry: DesktopVaultRegistry, envelopes: [UInt32: Data], joining: Bool, settings: Settings) {
        self.uid = uid
        self.name = name
        self.nodeID = nodeID
        self.access = access
        self.store = store
        self.keys = keys
        self.registry = registry
        self.envelopes = envelopes
        self.joining = joining
        self.settings = settings
    }

    public var accessPhase: DeviceAccess.Phase { get async { await access.phase } }

    /// Starts the bucket key's renewal and, with ``Settings/automatic``, the sync loop. Opens from the state file at once
    /// when there is one (listing needs no network).
    public func start() async {
        if accessTask == nil {
            let access = access
            if settings.automatic {
                accessTask = Task { await access.run() }
            } else {
                await access.step()
            }
        }
        if !engineHandedOver, vault == nil, FileManager.default.fileExists(atPath: registry.stateURL(uid).path(percentEncoded: false)) {
            await openVault()
        }
        if settings.automatic, syncTask == nil, !engineHandedOver {
            syncTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let wait = await self.syncNow()
                    try? await Task.sleep(for: .seconds(max(0.5, wait)))
                }
            }
        }
    }

    public func observe(_ handler: @escaping @Sendable (Status) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        handler(status)
        return id
    }

    public func stopObserving(_ id: UUID) { observers[id] = nil }

    private func set(_ s: Status) {
        guard s != status else { return }
        status = s
        for o in observers.values { o(s) }
    }

    private func set(_ state: State) {
        var s = status
        s.state = state
        set(s)
    }

    /// A local change was journalled: publish it shortly.
    public func noteChange() {
        publishAt = Date() + settings.publishDelay
        var s = status
        s.unpublished = true
        set(s)
    }

    /// A write met another edit of the same file: the engine kept both (this one current, the other a version).
    public func noteWriteConflict() {
        var s = status
        s.contentConflicts += 1
        set(s)
    }

    /// The vault, opened; nil while there is no state and no bucket key yet, or while Finder runs it.
    public func openedVault() async -> Vault? {
        if engineHandedOver { return nil }
        if vault == nil { await openVault() }
        return vault
    }

    /// Hands the engine to the File Provider extension (one engine per vault): what is unpublished is published if it
    /// can be, then the handle goes (its state lock with it). DeviceAccess keeps running here.
    public func handOverEngine() async {
        guard !engineHandedOver else { return }
        engineHandedOver = true
        syncTask?.cancel()
        syncTask = nil
        if let vault, (try? vault.status().unpublished) == true {
            _ = try? await vault.perform { v throws(VaultError) in try v.publish() }
        }
        vault = nil
    }

    /// Takes the engine back from the extension.
    public func takeEngineBack() async {
        guard engineHandedOver else { return }
        engineHandedOver = false
        await start()
    }

    /// One round: open if needed, refresh when due, publish when due. Returns how long until the next round is due.
    @discardableResult
    public func syncNow(force: Bool = false) async -> TimeInterval {
        let phase = await access.phase
        let leaving: Leaving? = switch phase {
        case .leaving, .needsOwnKey, .ownStorage: Leaving(phase: phase, ejection: await access.status.ejection)
        default: nil
        }
        if leaving != status.leaving {
            var s = status
            s.leaving = leaving
            set(s)
        }
        if case .stopped(let stop) = phase {
            set(.stopped(stop))
            return settings.refreshInterval
        }
        if case .needsOwnKey(let need) = phase {
            set(.needsOwnKey(need))
            return min(settings.refreshInterval, 5)
        }
        if engineHandedOver { return settings.refreshInterval }
        let haveKey = await access.withS3Credentials { _ in true } ?? false
        if vault == nil { await openVault() }
        guard let vault else {
            set(.waitingForStorage(Self.waitingReason(phase)))
            return min(settings.refreshInterval, 5)
        }
        guard haveKey else {
            set(.waitingForStorage(Self.waitingReason(phase)))
            return min(settings.refreshInterval, 5)
        }
        let now = Date()
        let refreshDue = force || now >= nextRefresh
        let publishDue = force || (publishAt.map { now >= $0 } ?? false) || joining
        guard refreshDue || publishDue else {
            return min(nextRefresh.timeIntervalSince(now), publishAt?.timeIntervalSince(now) ?? .infinity)
        }
        set(.syncing)
        let joining = joining
        let outcome: Result<(RefreshInfo?, PublishInfo?, EngineStatus), VaultError> = await {
            do throws(VaultError) {
                return .success(try await vault.perform { v throws(VaultError) in
                    let r: RefreshInfo? = refreshDue ? try v.refresh() : nil
                    // Taking a vault over (adopted from another Mac): no join (a version_log bucket has one writer, and
                    // refuses a second with writers_refused); the first publish names this Mac alone.
                    var p: PublishInfo?
                    if try v.status().unpublished || joining { p = try v.publish() }
                    _ = try? v.collectGarbageIfDue()
                    return (r, p, try v.status())
                })
            } catch {
                return .failure(error)
            }
        }()
        nextRefresh = now + settings.refreshInterval
        switch outcome {
        case .success(let (r, p, engine)):
            if joining { self.joining = false }
            if p?.published == true, var record = try? registry.record(uid), !record.published {
                record.published = true
                try? registry.save(record)
            }
            publishAt = nil
            var s = status
            s.unpublished = engine.unpublished
            s.revision = engine.revision
            s.contentConflicts += r?.contentConflicts ?? 0
            s.lastSynced = Date()
            s.state = engine.updateNeeded ? .needsUpdate : engine.refusedReason.map(State.refusedRoot) ?? .upToDate
            set(s)
        case .failure(let e):
            Self.log.notice("sync: \(e.name, privacy: .public)")
            var s = status
            s.unpublished = (try? vault.status().unpublished) ?? true
            s.state = switch e.status {
            case VaultStatus.writerFloor: .needsUpdate
            case VaultStatus.applyStopped: .paused(e.sentence)
            default: .paused(e.sentence)
            }
            set(s)
            if e.isTransient { publishAt = Date() + max(settings.publishDelay, 15) }
        }
        return settings.automatic ? min(settings.refreshInterval, publishAt.map { $0.timeIntervalSinceNow } ?? .infinity) : 0
    }

    static func waitingReason(_ phase: DeviceAccess.Phase) -> DeviceAccessError? {
        switch phase {
        case .waiting(let e): e
        case .retrying(let e, _, _): e
        case .paused: .paymentRequired(cause: nil)
        default: nil
        }
    }

    /// The first root of a vault this Mac just created: the engine makes the vault, adds key 1 with its envelope (PUT
    /// first) and publishes.
    func finishCreation() async throws(VaultError) {
        if vault == nil { await openVault() }
        guard let vault else {
            throw VaultError(local: "not_open", "The vault couldn't be opened yet.")
        }
        _ = try await vault.perform { v throws(VaultError) in try v.publish() }
        if var r = try? registry.record(uid) {
            r.published = true
            try? registry.save(r)
        }
        var s = status
        s.unpublished = false
        s.lastSynced = Date()
        s.state = .upToDate
        set(s)
    }

    private func openVault() async {
        guard vault == nil, !engineHandedOver, let wire = Uid(base32: uid) else { return }
        let record = try? registry.record(uid)
        let creating = record.map { !$0.published } ?? false
        do throws(VaultError) {
            let (v, info) = try await Vault.open(uid: wire, store: store, keys: keys, stateURL: registry.stateURL(uid),
                                                 nodeID: nodeID, createName: creating ? (record?.name ?? name) : nil)
            if info.anchor == .created || (joining && info.anchor == .reanchored) {
                try await addCurrentKey(v, created: info.anchor == .created)
            }
            vault = v
            var s = status
            s.recovered += info.recovered
            s.unpublished = (try? v.status().unpublished) ?? false
            if info.anchor == .created { s.unpublished = true }
            s.state = .upToDate
            set(s)
        } catch {
            // No state and no reachable bucket yet, or the bucket key isn't in force: the next round tries again.
            Self.log.notice("open: \(error.name, privacy: .public)")
        }
    }

    /// Adds the current key version with its envelope: always for a new vault; after adopting, only when the bucket's
    /// root doesn't list it yet (the envelope is in the bucket already; the engine refuses a version it has).
    private func addCurrentKey(_ v: Vault, created: Bool) async throws(VaultError) {
        guard let version = try? keys.currentVersion(), let envelope = envelopes[version] else { return }
        let keys = keys
        try await v.perform { v throws(VaultError) in
            let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: 32, alignment: 1)
            defer {
                raw.initializeMemory(as: UInt8.self, repeating: 0)
                raw.deallocate()
            }
            guard (try? keys.copyKey(version: version, into: raw)) == true else {
                throw VaultError(local: "no_vault_key", "This Mac holds no key of this vault.")
            }
            do throws(VaultError) {
                try v.addKey(version: version, key: SecretBytes(UnsafeRawBufferPointer(raw)), envelopes: [envelope])
            } catch where !created && [VaultStatus.keyVersion, VaultStatus.keyMismatch].contains(error.status) {
                // Already in the root.
            }
        }
    }

    /// The head this Mac knows (the engine's recorded root), to check a key the person brings against; nil while the
    /// engine isn't open here (Finder runs it, or it never opened).
    func knownHead() async -> (epoch: UInt64, rootSHA256: String)? {
        guard let vault, let s = try? await vault.perform({ v throws(VaultError) in try v.status() }),
              let epoch = s.epoch, let sha = s.rootSHA256 else { return nil }
        return (epoch, sha)
    }

    /// The person's own key is in use (``DesktopVaults/useOwnKey(_:keyID:secret:)``): the next round refreshes and sends
    /// what waited.
    func ownKeyInUse() async {
        nextRefresh = .distantPast
        if status.unpublished { publishAt = Date() }
        set(.upToDate)
        if !settings.automatic { await syncNow(force: true) }
    }

    /// This Mac stops holding the vault (``DeviceAccess/release()``); the session closes, local data stays.
    func release() async throws {
        try await access.release()
        await close()
    }

    public func close() async {
        accessTask?.cancel()
        syncTask?.cancel()
        accessTask = nil
        syncTask = nil
        vault = nil
    }

    static func words(_ stop: DeviceAccess.Stop) -> String {
        switch stop {
        case .notHeld(let e): "Stopped: \(e.message)"
        case .moved(_, let name): "Moved to the server \u{201C}\(name)\u{201D}. This Mac keeps its copy but no longer syncs it."
        case .reassigned(let to):
            "Given to " + (to.map { "the Mac \u{201C}\($0)\u{201D}" } ?? "another Mac") + ". This Mac keeps its copy but no longer syncs it."
        case .takenOff: "The account holder took this vault off this Mac. Its files here are kept."
        case .keyRevoked: "Its storage key was revoked in the portal. Ask for a new one to sync again."
        case .vaultRemoved: "Your account no longer has this vault."
        case .unlinked: "This Mac isn't linked to Vaulthalla Cloud any more."
        case .released: "This Mac stopped holding this vault. Its files here are kept."
        }
    }
}
