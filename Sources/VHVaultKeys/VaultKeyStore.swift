public import Foundation
public import VHCore

/// A Desktop-only vault's keys on this Mac: the keychain group the app shares with the File Provider extension
/// (``VaultKeychain``), as ``BucketKeyStore`` keeps the bucket key, written only by the credential owner. `vault-key.<uid>` says which versions
/// this Mac holds and which one new objects are sealed under (no secret); `vault-key.<uid>.<version>` holds that
/// version's 32 bytes, never encoded as text. Never UserDefaults, a file or a log. Every version is also in the cloud,
/// wrapped (KEV1) to the account recovery key, before anything is sealed under it.
public struct VaultKeyStore: Sendable {
    struct Index: Codable, Equatable {
        var versions: [UInt32]
        var current: UInt32
    }

    public static func item(_ uid: String) -> String { "vault-key.\(uid)" }
    static func keyItem(_ uid: String, _ version: UInt32) -> String { "vault-key.\(uid).\(version)" }

    let items: VaultItems

    public init(vaultItems: VaultItems) { items = vaultItems }
    public init(items: LeasedAccountItems) { self.items = VaultItems(shared: items) }

    /// The versions held and the current one; nil when this Mac holds no key of the vault.
    public func versions(_ uid: String) throws -> (versions: [UInt32], current: UInt32)? {
        guard let data = try items.read(Self.item(uid)) else { return nil }
        guard let index = try? JSONDecoder().decode(Index.self, from: data), index.versions.contains(index.current) else {
            throw AccountItemError.corrupt("a stored vault key list")
        }
        return (index.versions, index.current)
    }

    /// Lends key `version` to `body` (nil when this Mac doesn't hold it); the read buffer is wiped afterwards.
    public func withKey<R>(_ uid: String, version: UInt32, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R? {
        guard var raw = try items.read(Self.keyItem(uid, version)) else { return nil }
        defer { raw.resetBytes(in: 0 ..< raw.count) }
        guard raw.count == 32 else { throw AccountItemError.corrupt("a stored vault key") }
        return try raw.withUnsafeBytes(body)
    }

    /// Keeps key `version` (32 bytes), and makes it current when `makeCurrent` or when it is the first.
    public func save(_ uid: String, version: UInt32, key: SecretBytes, makeCurrent: Bool = true) throws {
        guard key.count == 32, version > 0 else { throw AccountItemError.corrupt("a vault key") }
        var raw = key.withUnsafeBytes { Data($0) }
        defer { raw.resetBytes(in: 0 ..< raw.count) }
        try items.write(Self.keyItem(uid, version), raw, operation: "store a vault key")
        var index = (try? versions(uid)).flatMap { $0 }.map { Index(versions: $0.versions, current: $0.current) }
            ?? Index(versions: [], current: version)
        if !index.versions.contains(version) { index.versions.append(version) }
        index.versions.sort()
        if makeCurrent { index.current = version }
        try items.write(Self.item(uid), JSONEncoder().encode(index), operation: "store a vault key")
    }

    /// Forgets every key of the vault (only once its envelopes are known to be in the cloud: they are recovery
    /// material).
    public func delete(_ uid: String) throws {
        if let held = try? versions(uid) {
            for v in held.versions { try items.delete(Self.keyItem(uid, v), operation: "forget a vault key") }
        }
        try items.delete(Self.item(uid), operation: "forget a vault key")
    }
}

