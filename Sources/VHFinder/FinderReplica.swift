public import Foundation

/// What the File Provider extension asks of a domain's replica, whatever backs the vault: ``VaultReplica`` for a vault
/// on a server (the ws contract and the node's lanes), the engine-backed replica in VHVault for a Desktop-only vault
/// (vl-vaultfmt's engine over its bucket). The operation-level seam docs/cloud-storage.md ("Wave 4 allowance") asked
/// for under the extension: enumeration with anchors, ranged fetches, conditional writes, rename, move, delete.
public protocol FinderReplica: Actor {
    var rootEntryID: Int64? { get async }
    var pinnedEntries: Set<Int64> { get async }
    func keepDownloaded(_ ids: [FinderItemID], _ keep: Bool) async throws(FinderError)
    func item(_ id: FinderItemID) async throws(FinderError) -> FinderItem
    func list(_ container: FinderItemID, page: EnumerationPage, pageSize: Int) async throws(FinderError)
        -> (items: [FinderItem], next: EnumerationPage?)
    func workingSet(page: EnumerationPage, pageSize: Int) async throws(FinderError) -> (items: [FinderItem], next: EnumerationPage?)
    var currentAnchor: SyncAnchor { get async }
    func changes(since anchor: SyncAnchor, limit: Int) async throws(FinderError) -> VaultReplica.Changes
    func fetch(_ id: FinderItemID, into directory: URL) async throws(FinderError) -> (url: URL, item: FinderItem)
    func fetchRange(_ id: FinderItemID, version: FinderItemVersion, minimal: Range<Int64>, alignment: Int64, strict: Bool,
                    into directory: URL) async throws(FinderError) -> VaultReplica.PartialFetch
    func create(_ template: VaultReplica.Template, contents: URL?, mayAlreadyExist: Bool) async throws(FinderError) -> FinderItem
    func modify(_ id: FinderItemID, base: FinderItemVersion, changes: VaultReplica.Changeset, failOnConflict: Bool)
        async throws(FinderError) -> VaultReplica.Modified
    func delete(_ id: FinderItemID, base: FinderItemVersion, recursive: Bool) async throws(FinderError)
    func thumbnails(for ids: [FinderItemID], size: Int, each: @Sendable (FinderItemID, Data?, FinderError?) -> Void) async
    func close() async
}

extension VaultReplica: FinderReplica {}

// Public makers for other backends (the memberwise initializers are internal).
extension VaultReplica.Changes {
    public static func make(updated: [FinderItem], deleted: [FinderItemID], anchor: SyncAnchor, moreComing: Bool) -> Self {
        Self(updated: updated, deleted: deleted, anchor: anchor, moreComing: moreComing)
    }
}

extension VaultReplica.PartialFetch {
    public static func make(url: URL, item: FinderItem, range: Range<Int64>) -> Self { Self(url: url, item: item, range: range) }
}

extension VaultReplica.Modified {
    public static func make(item: FinderItem, fetchContents: Bool, conflictCopy: FinderItem?) -> Self {
        Self(item: item, fetchContents: fetchContents, conflictCopy: conflictCopy)
    }
}

/// The File Provider domain of a Desktop-only vault (no server): `desktop-<vault uid>`. It has no `.`, so
/// ``VaultDomainID/init(identifier:)`` never takes it for a node's vault, and it carries neither `/` nor `:`.
public struct DesktopVaultDomainID: Hashable, Sendable, Codable, CustomStringConvertible {
    public static let prefix = "desktop-"
    public let vaultUid: String

    /// nil unless `vaultUid` is 26 lower-case base32 symbols.
    public init?(vaultUid: String) {
        let alphabet = Set("0123456789abcdefghjkmnpqrstvwxyz")
        guard vaultUid.count == 26, vaultUid.allSatisfy(alphabet.contains) else { return nil }
        self.vaultUid = vaultUid
    }

    public init?(identifier: String) {
        guard identifier.hasPrefix(Self.prefix) else { return nil }
        self.init(vaultUid: String(identifier.dropFirst(Self.prefix.count)))
    }

    public var identifier: String { Self.prefix + vaultUid }
    public var description: String { identifier }

    /// What Finder shows in its sidebar: `<vault> · This Mac` (the vault has no server to name).
    public static func displayName(vault: String) -> String {
        VaultDomain.displayName(vault: vault, node: "Managed Storage", vaultID: 0)
    }
}
