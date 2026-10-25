import FileProvider
import Foundation
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
        try await NSFileProviderManager.add(made)
    }

    func remove(identifier: String) async throws {
        guard let domain = try await NSFileProviderManager.domains().first(where: { $0.identifier.rawValue == identifier })
        else { return }
        try await NSFileProviderManager.remove(domain)
    }

    func removeAll() async throws {
        try await NSFileProviderManager.removeAllDomains()
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
