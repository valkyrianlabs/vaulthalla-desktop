public import Foundation
public import VHVaultKeys

// MARK: - what this Mac knows about its vaults

/// A Desktop-only vault this Mac holds or held: its uid, its name, and how far its creation got. Names and uids only
/// (the state file beside it holds the tree in plaintext too, under the system's data protection); no key.
public struct DesktopVaultRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Hold: String, Codable, Sendable { case holding, released }

    public var uid: String
    public var name: String
    public var createdAt: Date
    /// The first root is in the bucket. Until then an open may still create the vault (the bucket was not ready yet).
    public var published: Bool
    /// Placed on this Mac from another (the keys came from the account key's envelopes).
    public var adopted: Bool
    public var hold: Hold
    /// The engine's node id for this Mac (its cloud installation id), recorded so the File Provider extension, which
    /// can't read the cloud link, opens the vault as the same writer. nil in records written before it existed.
    public var nodeID: String?
    /// The account key generation the vault's sealed label (its name, for the portal and other installations) was last
    /// sent to the cloud for; nil until one was (it is sent again after a rename or an account key rotation).
    public var labelGeneration: UInt32?

    public init(uid: String, name: String, createdAt: Date, published: Bool, adopted: Bool, hold: Hold, nodeID: String? = nil,
                labelGeneration: UInt32? = nil) {
        self.uid = uid
        self.name = name
        self.createdAt = createdAt
        self.published = published
        self.adopted = adopted
        self.hold = hold
        self.nodeID = nodeID
        self.labelGeneration = labelGeneration
    }

    public var id: String { uid }
}

/// `<container>/FileProvider/desktop-vaults.json`: the records, written atomically. The container is the App Group's
/// (the File Provider extension's), else Application Support in a build without the group.
public struct DesktopVaultRegistry: Sendable {
    public let container: URL

    public init(container: URL) { self.container = container }

    public var directory: URL { container.appending(path: "FileProvider", directoryHint: .isDirectory) }
    var url: URL { directory.appending(path: "desktop-vaults.json", directoryHint: .notDirectory) }

    /// The engine's state file for `uid` (`FileStateBlob`), beside the server vaults' replica databases.
    public func stateURL(_ uid: String) -> URL { directory.appending(path: "desktop-\(uid).vlvfstate", directoryHint: .notDirectory) }
    /// Where streamed uploads gather their sealed bytes.
    public func scratchURL(_ uid: String) -> URL { directory.appending(path: "desktop-\(uid).uploads", directoryHint: .isDirectory) }

    public func load() throws -> [DesktopVaultRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try d.decode([DesktopVaultRecord].self, from: data)
    }

    public func record(_ uid: String) throws -> DesktopVaultRecord? { try load().first { $0.uid == uid } }

    public func save(_ record: DesktopVaultRecord) throws {
        var all = try load().filter { $0.uid != record.uid }
        all.append(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        try e.encode(all.sorted { $0.createdAt < $1.createdAt }).write(to: url, options: [.atomic])
    }
}

/// The engine's keys from the keychain (``VaultKeyStore``): copied into the library's buffer for each lookup.
public struct KeychainVaultKeys: VaultKeySource {
    let store: VaultKeyStore
    let uid: String

    public init(store: VaultKeyStore, uid: String) {
        self.store = store
        self.uid = uid
    }

    public func currentVersion() throws -> UInt32 {
        guard let held = try store.versions(uid) else { throw VaultError(local: "no_vault_key", "This Mac holds no key of this vault.") }
        return held.current
    }

    public func copyKey(version: UInt32, into buffer: UnsafeMutableRawBufferPointer) throws -> Bool {
        try store.withKey(uid, version: version) { raw in
            guard buffer.count >= raw.count else { return false }
            buffer.copyMemory(from: raw)
            return true
        } ?? false
    }
}

