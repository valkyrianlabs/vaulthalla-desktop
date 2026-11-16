public import Foundation
public import VHCore

// MARK: - the key

/// A managed bucket's key as this Mac holds it for a Desktop-only vault: short-lived (the cloud's
/// `storage.desktop_key_minutes`, 24 hours), renewed from `renewAfter` (12 hours before the end). The secret is a
/// zeroing ``SecretBytes``; nothing here prints it.
public struct BucketKey: Sendable, CustomStringConvertible {
    public init(vaultUid: String, keyID: String, access: String, bucket: String, bucketID: String, s3Endpoint: String,
                region: String, expiresAt: Date, renewAfter: Date, secret: SecretBytes) {
        self.vaultUid = vaultUid
        self.keyID = keyID
        self.access = access
        self.bucket = bucket
        self.bucketID = bucketID
        self.s3Endpoint = s3Endpoint
        self.region = region
        self.expiresAt = expiresAt
        self.renewAfter = renewAfter
        self.secret = secret
    }

    public let vaultUid: String
    public let keyID: String
    /// full, or read_delete (restricted, over quota).
    public let access: String
    public let bucket: String
    public let bucketID: String
    public let s3Endpoint: String
    public let region: String
    public var expiresAt: Date
    public var renewAfter: Date
    public let secret: SecretBytes

    public var description: String { "BucketKey(\(access), until \(expiresAt), redacted)" }

    func metadata(revoked: Bool = false) -> BucketKeyStore.Metadata {
        BucketKeyStore.Metadata(keyID: keyID, access: access, bucket: bucket, bucketID: bucketID, s3Endpoint: s3Endpoint,
                                region: region, expiresAt: Int64(expiresAt.timeIntervalSince1970),
                                renewAfter: Int64(renewAfter.timeIntervalSince1970), revoked: revoked)
    }
}

/// Where a ``BucketKey`` lives across launches: the keychain group the app shares with the File Provider extension
/// (``VaultKeychain``), written only by the credential owner (the app, which renews it) and read by the extension. Two items per
/// vault: `storage-key.<uid>` (what the key is: no secret) and `storage-key.<uid>.<key id>` (the secret's bytes, never
/// encoded as text). Never UserDefaults, a file or a log. A tombstone (`revoked`, no secret) remembers that the cloud
/// revoked the key, so a relaunch doesn't ask for a new one behind the account holder's back.
public struct BucketKeyStore: Sendable {
    struct Metadata: Codable, Equatable {
        var keyID: String
        var access: String
        var bucket: String
        var bucketID: String
        var s3Endpoint: String
        var region: String
        var expiresAt: Int64
        var renewAfter: Int64
        var revoked: Bool
        /// The cloud's `revoked_reason` for a tombstone.
        var revokedReason: String?
    }

    public static func item(_ uid: String) -> String { "storage-key.\(uid)" }
    static func secretItem(_ uid: String, _ keyID: String) -> String { "storage-key.\(uid).\(keyID)" }

    let items: VaultItems

    /// Over the shared group's items (and, in the app, the old app-only group to move from).
    public init(vaultItems: VaultItems) { items = vaultItems }
    /// Over `items` alone (tests, and stores that never moved).
    public init(items: LeasedAccountItems) { self.items = VaultItems(shared: items) }

    /// The key kept for `uid`, if one is (nil for none, or a tombstone).
    public func load(_ uid: String) throws -> BucketKey? {
        guard let m = try metadata(uid), !m.revoked else { return nil }
        guard var raw = try items.read(Self.secretItem(uid, m.keyID)) else { return nil }
        defer { raw.resetBytes(in: 0 ..< raw.count) }
        return BucketKey(vaultUid: uid, keyID: m.keyID, access: m.access, bucket: m.bucket, bucketID: m.bucketID,
                         s3Endpoint: m.s3Endpoint, region: m.region,
                         expiresAt: Date(timeIntervalSince1970: TimeInterval(m.expiresAt)),
                         renewAfter: Date(timeIntervalSince1970: TimeInterval(m.renewAfter)), secret: SecretBytes(raw))
    }

    /// The cloud's reason when it revoked the last key and the person hasn't asked for a new one; nil otherwise.
    public func revokedReason(_ uid: String) throws -> String? {
        guard let m = try metadata(uid), m.revoked else { return nil }
        return m.revokedReason ?? "account_holder"
    }

    /// Keeps `key` (replacing the vault's previous key and its secret).
    public func save(_ key: BucketKey) throws {
        let previous = try? metadata(key.vaultUid)
        var raw = key.secret.withUnsafeBytes { Data($0) }
        defer { raw.resetBytes(in: 0 ..< raw.count) }
        try items.write(Self.secretItem(key.vaultUid, key.keyID), raw, operation: "store a storage key")
        try items.write(Self.item(key.vaultUid), JSONEncoder().encode(key.metadata()), operation: "store a storage key")
        if let previous, previous.keyID != key.keyID {
            try? items.delete(Self.secretItem(key.vaultUid, previous.keyID), operation: "forget a storage key")
        }
    }

    /// Forgets the vault's key and its secret; with `revokedReason`, leaves a tombstone without either.
    public func delete(_ uid: String, revokedReason: String? = nil) throws {
        if let m = try? metadata(uid) {
            try items.delete(Self.secretItem(uid, m.keyID), operation: "forget a storage key")
            if let revokedReason {
                var t = m
                t.revoked = true
                t.revokedReason = revokedReason
                try items.write(Self.item(uid), JSONEncoder().encode(t), operation: "forget a storage key")
                return
            }
        }
        try items.delete(Self.item(uid), operation: "forget a storage key")
    }

    private func metadata(_ uid: String) throws -> Metadata? {
        guard let data = try items.read(Self.item(uid)) else { return nil }
        guard let m = try? JSONDecoder().decode(Metadata.self, from: data) else {
            throw AccountItemError.corrupt("a stored storage key")
        }
        return m
    }
}

