import FileProvider
import Foundation
import Observation
import VHCloud
import VHCore
import VHFinder
import VHVault

/// Desktop-only vaults in the app (docs/desktop-vaults.md), behind ``DesktopVaultsFeature`` (off by default: nothing
/// here has run in a signed app). It opens a session for every vault this Mac holds (each starts its ``DeviceAccess``,
/// which the app held back until an engine existed), creates new ones, adopts one the account holder placed here, stops
/// holding one, and shows each vault's state in words.
@MainActor
@Observable
final class DesktopVaultsModel {
    private(set) var records: [DesktopVaultRecord] = []
    private(set) var states: [String: DesktopVaultSession.Status] = [:]
    private(set) var readiness: DesktopVaultReadiness?
    private(set) var creating: DesktopVaultCreationStep?
    private(set) var adoptable: [String] = []
    private(set) var problem: String?
    /// Vaults shown in Finder: their engine runs in the File Provider extension, not here.
    private(set) var inFinder: Set<String> = []

    @ObservationIgnored let vaults: DesktopVaults
    @ObservationIgnored private var observed: Set<String> = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var refusalObserver: KeyRefusalSignal.Observer?

    init(client: CloudClient, account: CloudAccount, items: LeasedAccountItems) {
        let container = RegistryEnvironment.current().groupContainer ?? URL.applicationSupportDirectory
        // Vault keys and the bucket key in the group shared with the File Provider extension, moved from the app-only
        // group on first use; this app alone writes them (it holds the lease) and alone talks to the cloud.
        vaults = DesktopVaults(client: client, account: account, items: items, container: container,
                               vaultItems: .app(lease: items.lease))
        records = (try? vaults.registry.load()) ?? []
    }

    /// Vaults this Mac holds that left managed storage: their storage is in the person's own provider account. Known from
    /// this Mac's own records, whatever its link to the cloud.
    var leftVaults: [DesktopVaultRecord] { records.filter { $0.hold == .holding && vaults.hasLeftManagedStorage($0.uid) } }

    func hasLeft(_ uid: String) -> Bool { vaults.hasLeftManagedStorage(uid) }

    /// Opens the vaults that left managed storage, linked or not (they need no cloud), so their state shows and they take
    /// the person's own key. The rest open with ``start()`` once this Mac is linked.
    func startLeft() async {
        records = await vaults.records()
        let left = leftVaults
        guard !left.isEmpty else { return }
        if !started {
            inFinder = Set(((try? await NSFileProviderManager.domains()) ?? []).compactMap {
                DesktopVaultDomainID(identifier: $0.identifier.rawValue)?.vaultUid
            })
        }
        for r in left where await vaults.session(r.uid) == nil {
            do throws(DesktopVaultError) { _ = try await vaults.open(r.uid, engine: !inFinder.contains(r.uid)) } catch {
                problem = error.sentence
            }
        }
        if refusalObserver == nil {
            let vaults = vaults
            refusalObserver = vaults.refusals.observe { Task { await vaults.followRefusals() } }
        }
        await observeSessions()
    }

    /// The vaults this Mac holds, open, once per launch (after the link is known).
    func start() async {
        guard !started else { return await refresh() }
        started = true
        inFinder = Set(((try? await NSFileProviderManager.domains()) ?? []).compactMap {
            DesktopVaultDomainID(identifier: $0.identifier.rawValue)?.vaultUid
        })
        records = await vaults.records()
        // Every held vault's bucket key is renewed here; its engine runs here unless Finder shows it.
        for r in records where r.hold == .holding {
            do throws(DesktopVaultError) { _ = try await vaults.open(r.uid, engine: !inFinder.contains(r.uid)) } catch {
                problem = error.sentence
            }
        }
        let vaults = vaults
        if refusalObserver == nil { refusalObserver = vaults.refusals.observe { Task { await vaults.followRefusals() } } }
        await observeSessions()
        await refresh()
    }

    func refresh() async {
        await vaults.followRefusals()
        readiness = await vaults.readiness()
        adoptable = (try? await vaults.adoptable()) ?? []
        records = await vaults.records()
    }

    private func observeSessions() async {
        for r in await vaults.records() where !observed.contains(r.uid) {
            guard let session = await vaults.session(r.uid) else { continue }
            observed.insert(r.uid)
            let uid = r.uid
            _ = await session.observe { [weak self] status in
                Task { @MainActor in self?.states[uid] = status }
            }
        }
    }

    func create(name: String) async -> Bool {
        problem = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            problem = "Give the vault a name."
            return false
        }
        do throws(DesktopVaultError) {
            _ = try await vaults.create(name: trimmed) { step in Task { @MainActor [weak self] in self?.creating = step } }
            creating = nil
            await observeSessions()
            await refresh()
            return true
        } catch {
            creating = nil
            problem = error.sentence
            await refresh()
            return false
        }
    }

    func adopt(_ uid: String, name: String) async {
        do throws(DesktopVaultError) {
            _ = try await vaults.adopt(uid, name: name)
            await observeSessions()
            await refresh()
        } catch {
            problem = error.sentence
        }
    }

    func stopHolding(_ uid: String) async -> String? {
        do throws(DesktopVaultError) {
            if inFinder.contains(uid) { await setShownInFinder(uid, false) }
            try await vaults.stopHolding(uid)
            await refresh()
            return nil
        } catch {
            return error.sentence
        }
    }

    func holds(_ uid: String) -> Bool { records.contains { $0.uid == uid && $0.hold == .holding } }

    /// The name this Mac gave a vault it holds or held (no unlock needed: it is this Mac's own record).
    func name(_ uid: String) -> String? { records.first { $0.uid == uid }?.name }

    /// Renames a vault this Mac holds: here, in Finder, and its sealed label for the portal and other installations.
    func rename(_ uid: String, to name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Give the vault a name." }
        do throws(DesktopVaultError) {
            try await vaults.rename(uid, to: trimmed)
        } catch {
            return error.sentence
        }
        records = await vaults.records()
        if inFinder.contains(uid) {
            // The domain's display name follows (adding a domain with the same identifier updates it).
            let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: DesktopVaultDomainID.prefix + uid),
                                              displayName: DesktopVaultDomainID.displayName(vault: trimmed))
            domain.supportsSyncingTrash = false
            try? await NSFileProviderManager.add(domain)
        }
        return nil
    }

    // MARK: leaving managed storage (an ejection)

    /// The vault's storage is being ejected to the person's own provider account, or was (nil otherwise).
    func leaving(_ uid: String) -> DesktopVaultSession.Leaving? { states[uid]?.leaving }

    /// Whether the vault can take the person's own key now (its storage is being ejected to them, or was).
    func takesOwnKey(_ uid: String) -> Bool { leaving(uid) != nil }

    /// The vault's storage in the person's own account, in words (the line ``DeviceAccessWording/leaving`` says).
    func leavingLine(_ uid: String) -> ManagedStorageWording.Line? {
        guard let l = leaving(uid) else { return nil }
        return DeviceAccessWording.leaving(l.phase, ejection: l.ejection, now: .now)
    }

    /// A short state for a vault that left managed storage.
    func leftState(_ uid: String) -> (label: String, tone: ManagedStorageWording.Tone) {
        switch leaving(uid)?.phase {
        case .ownStorage?: ("On your own key", .ok)
        case .needsOwnKey(.refused)?: ("Key refused", .danger)
        case .needsOwnKey?: ("Needs your key", .warn)
        case .leaving?: ("Moving", .info)
        default: ("Opening", .neutral)
        }
    }

    /// Whether the vault is paused until the person's own key.
    func needsOwnKey(_ uid: String) -> Bool {
        if case .needsOwnKey? = leaving(uid)?.phase { return true }
        return false
    }

    /// Checks the person's own key against the vault's bucket (reads only) and switches the vault to it. The secret goes
    /// straight into zeroing bytes and the keychain group shared with the Finder extension; it is never logged.
    func useOwnKey(_ uid: String, keyID: String, secret: String) async -> String? {
        let bytes = SecretBytes(Data(secret.utf8))
        do throws(DesktopVaultError) {
            try await vaults.useOwnKey(uid, keyID: keyID, secret: bytes)
        } catch {
            return error.sentence
        }
        if let s = await vaults.session(uid) { _ = await s.syncNow(force: true) }
        return nil
    }

    func sentence(_ uid: String) -> String? {
        if inFinder.contains(uid) {
            return "Shown in Finder: Finder syncs it; Vaulthalla renews its storage key while it runs. If Vaulthalla isn't running when the key expires, Finder pauses the vault until you open Vaulthalla; nothing is lost."
        }
        return states[uid]?.sentence
    }

    /// Shows the vault in Finder (a `desktop-<uid>` domain) or stops showing it. One engine per vault: while Finder
    /// shows it, the extension runs it and this app closes its own session; stopping gives it back here.
    func setShownInFinder(_ uid: String, _ shown: Bool) async {
        let identifier = NSFileProviderDomainIdentifier(rawValue: DesktopVaultDomainID.prefix + uid)
        do {
            if shown {
                let name = records.first { $0.uid == uid }?.name ?? "Vault"
                await vaults.handOver(uid)
                let domain = NSFileProviderDomain(identifier: identifier, displayName: DesktopVaultDomainID.displayName(vault: name))
                domain.supportsSyncingTrash = false  // deletes go to the vault's own trash
                try await NSFileProviderManager.add(domain)
                inFinder.insert(uid)
                // As for server vaults: the background agent keeps Finder fresh while a vault is shown there.
                BackgroundAgent.update(hasDomains: true)
            } else {
                if let d = try await NSFileProviderManager.domains().first(where: { $0.identifier == identifier }) {
                    try await NSFileProviderManager.remove(d, mode: .preserveDirtyUserData)
                }
                inFinder.remove(uid)
                await vaults.takeBack(uid)
                await FinderVaults.updateAgent()
            }
        } catch {
            problem = "Finder refused (\(error.localizedDescription))."
        }
    }

    /// The creation's step in words.
    static func words(_ step: DesktopVaultCreationStep) -> String {
        switch step {
        case .makingKey: "Making the vault's key on this Mac\u{2026}"
        case .enrolling: "Wrapping it to your recovery key\u{2026}"
        case .registering: "Registering the vault\u{2026}"
        case .switchingOn: "Switching its storage on\u{2026}"
        case .waitingForStorage(let why): why.map { "Waiting: \($0.message)" } ?? "Waiting for its storage\u{2026}"
        case .gettingKey: "Getting the storage key\u{2026}"
        case .publishing: "Writing the vault's first state\u{2026}"
        case .done: "Done."
        }
    }

    /// What a Desktop-only vault can't do yet, said where it is created.
    static let limits: [String] = [
        "One Mac writes to it for now: this one. Another Mac gets it only when you move it there in the portal.",
        "No share links and no search on a server: there is no server.",
        "Recovering it without this Mac needs your account's recovery key (the offline copy you saved).",
        "If this Mac is lost, changes it hadn't sent yet lose their names: the files' bytes stay in storage and come back under \u{201C}Recovered\u{201D}, without their names or folders.",
    ]
}
