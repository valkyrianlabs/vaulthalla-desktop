import FileProvider
import Foundation
import VHCore
import VHFinder

/// This app's File Provider domains through `NSFileProviderManager` (docs/architecture.md §7, File Provider). The
/// system ties every domain to the extension embedded in the calling app, so this only works from Vaulthalla's own
/// executable. A new domain stays `userEnabled == false`, showing nothing, until the operator turns Vaulthalla on
/// under File Providers in System Settings once; no API can do that for them.
nonisolated struct FileProviderDomains: DomainRegistrar {
    func domains() async throws -> [DomainSnapshot] {
        try await NSFileProviderManager.domains().map(Self.snapshot)
    }

    func add(_ domain: VaultDomain) async throws {
        let made = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(rawValue: domain.id.identifier),
                                        displayName: domain.displayName)
        // Deleting in Finder sends files to the server's trash and recovery, not a synced Trash (vaulthalla/desktop#4).
        made.supportsSyncingTrash = false
        // A new domain starts from an empty replica: a database left by an earlier domain of the vault is stale.
        Self.deleteReplica(identifier: domain.id.identifier)
        try await NSFileProviderManager.add(made)
    }

    func remove(identifier: String) async throws {
        guard let domain = try await NSFileProviderManager.domains().first(where: { $0.identifier.rawValue == identifier })
        else { return }
        try await NSFileProviderManager.remove(domain)
        Self.deleteReplica(identifier: identifier)
    }

    func removeAll() async throws {
        let identifiers = try await NSFileProviderManager.domains().map(\.identifier.rawValue)
        try await NSFileProviderManager.removeAllDomains()
        identifiers.forEach(Self.deleteReplica)
    }

    /// Asks the extension to report the working set's changes (it lists the folders Finder enumerated again). The
    /// background agent will do this when the server reports changes (desktop#5); until then, a developer command.
    func signal(identifier: String) async throws {
        guard let domain = try await NSFileProviderManager.domains().first(where: { $0.identifier.rawValue == identifier }),
              let manager = NSFileProviderManager(for: domain)
        else { throw CocoaError(.fileNoSuchFile) }
        try await manager.signalEnumerator(for: .workingSet)
    }

    /// The domain's replica database in the App Group container (``ReplicaLocation``): a cache the extension rebuilds,
    /// removed with its domain. Builds without the App Group have none here.
    private static func deleteReplica(identifier: String) {
        guard let container = RegistryEnvironment.current().groupContainer else { return }
        ReplicaStore.deleteFiles(at: ReplicaLocation.storeURL(domain: identifier, in: container))
    }

    /// Where Finder shows the domain (`~/Library/CloudStorage/Vaulthalla-<name>`).
    func rootURL(identifier: String) async throws -> URL? {
        guard let domain = try await NSFileProviderManager.domains().first(where: { $0.identifier.rawValue == identifier }),
              let manager = NSFileProviderManager(for: domain)
        else { return nil }
        return try await manager.getUserVisibleURL(for: .rootContainer)
    }

    private static func snapshot(_ domain: NSFileProviderDomain) -> DomainSnapshot {
        DomainSnapshot(identifier: domain.identifier.rawValue, displayName: domain.displayName,
                       userEnabled: domain.userEnabled, isDisconnected: domain.isDisconnected,
                       isHidden: domain.isHidden)
    }
}
