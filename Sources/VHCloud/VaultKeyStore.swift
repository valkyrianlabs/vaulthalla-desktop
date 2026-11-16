public import Foundation
public import VHCore

/// A Desktop-only vault's keys on this Mac: the account's app-only keychain items (``AccountKeychain``), as
/// ``BucketKeyStore`` keeps the bucket key, written only by the credential owner. `vault-key.<uid>` says which versions
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

    let items: LeasedAccountItems

    public init(items: LeasedAccountItems) { self.items = items }

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

// MARK: - the routes a Desktop-only vault's keys need

/// `PUT /v1/recovery/vaults/{uid}` (200): what enrolling stored (recovery `Enrollment.cpp`, `addRecoveryRoutes`).
public struct CloudEnrollment: Decodable, Sendable {
    public var created: Bool
    public var envelopesAdded: Int?
    public var versionsAdded: Int?
}

/// One envelope of `GET /v1/keys/vaults/{uid}/envelopes` (`KeyManager::envelopes`): to a generation of the account key.
public struct CloudVaultEnvelope: Decodable, Sendable {
    public var keyVersion: UInt32
    public var generation: UInt32
    public var fingerprint: String
    /// base64url KEV1.
    public var envelope: String
}

extension CloudClient {
    /// Enrolls a vault this Mac holds for recovery (key-manager.md "As built" 20): its envelopes (KEV1 to the account
    /// key, standard base64 as enrollment takes them) and key versions. Registers the vault as this Mac's if it is new
    /// (account-model.md "As built" 18).
    public func enrollDesktopVault(_ uid: String, envelopes: [Data], versions: [UInt32]) async throws -> CloudEnrollment {
        struct Version: Encodable { var version: UInt32 }
        struct Body: Encodable {
            var envelopes: [String]
            var keyVersions: [Version]
        }
        return try await signed("PUT", "/v1/recovery/vaults/\(try Self.checkedUid(uid))",
                                body: Body(envelopes: envelopes.map { $0.base64EncodedString() },
                                           keyVersions: versions.map(Version.init)))
    }

    /// `GET /v1/keys/vaults/{uid}/envelopes`: the vault's envelopes to every generation of the account key (a linked
    /// Desktop may read any vault of its account). Nil when the vault isn't enrolled or the account has no key yet (404).
    public func vaultEnvelopes(_ uid: String) async throws -> [CloudVaultEnvelope]? {
        struct Reply: Decodable { var envelopes: [CloudVaultEnvelope] }
        do {
            let reply: Reply = try await signed("GET", "/v1/keys/vaults/\(try Self.checkedUid(uid))/envelopes")
            return reply.envelopes
        } catch CloudError.notFound {
            return nil
        }
    }
}
