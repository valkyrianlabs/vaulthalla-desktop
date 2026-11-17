public import Foundation
public import VHCore

// MARK: - the key

/// A managed bucket's key as this Mac holds it for a Desktop-only vault: short-lived (the cloud's
/// `storage.desktop_key_minutes`, 24 hours), renewed from `renewAfter` (12 hours before the end). Or, once the
/// account's storage was ejected to the customer, the key the person made in their own provider account
/// (``Origin/customer``): no expiry, never renewed, never asked of the cloud. The secret is a zeroing ``SecretBytes``;
/// nothing here prints it.
public struct BucketKey: Sendable, CustomStringConvertible {
    public enum Origin: String, Codable, Sendable {
        /// Issued by Vaulthalla Cloud (short-lived, renewed through the cloud).
        case cloud
        /// Made by the person in their own provider account after an ejection.
        case customer
    }

    /// A customer's key has no expiry of its own: it lasts until the person deletes it at the provider.
    public static let noExpiry = Date(timeIntervalSince1970: 253_402_300_799)  // 9999-12-31T23:59:59Z

    public init(vaultUid: String, keyID: String, access: String, bucket: String, bucketID: String, s3Endpoint: String,
                region: String, expiresAt: Date, renewAfter: Date, secret: SecretBytes, origin: Origin = .cloud) {
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
        self.origin = origin
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
    public let origin: Origin

    public var description: String { "BucketKey(\(origin.rawValue), \(access), until \(expiresAt), redacted)" }

    func metadata(revoked: Bool = false) -> BucketKeyStore.Metadata {
        BucketKeyStore.Metadata(keyID: keyID, access: access, bucket: bucket, bucketID: bucketID, s3Endpoint: s3Endpoint,
                                region: region, expiresAt: Int64(expiresAt.timeIntervalSince1970),
                                renewAfter: Int64(renewAfter.timeIntervalSince1970), revoked: revoked,
                                origin: origin == .customer ? Origin.customer.rawValue : nil,
                                leftManaged: origin == .customer ? true : nil)
    }
}

/// Where a vault's bucket is: what a key the person brings is tried against, after an ejection.
public struct BucketLocation: Sendable, Equatable {
    public var bucket: String
    public var bucketID: String
    public var s3Endpoint: String
    public var region: String

    public init(bucket: String, bucketID: String, s3Endpoint: String, region: String) {
        self.bucket = bucket
        self.bucketID = bucketID
        self.s3Endpoint = s3Endpoint
        self.region = region
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
        /// The cloud's `revoked_reason` for a tombstone; ``BucketKeyStore/ownKeyRefused`` for a customer's key the
        /// provider refused.
        var revokedReason: String?
        /// `customer` for the person's own key after an ejection; nil (the cloud's) otherwise.
        var origin: String?
        /// The vault left managed storage (an ejection was seen): kept, with the bucket's location, whatever happens
        /// to the key, so the vault never needs the cloud to say so again. nil in items written before it existed.
        var leftManaged: Bool?

        init(keyID: String, access: String, bucket: String, bucketID: String, s3Endpoint: String, region: String,
             expiresAt: Int64, renewAfter: Int64, revoked: Bool, revokedReason: String? = nil, origin: String? = nil,
             leftManaged: Bool? = nil) {
            self.keyID = keyID
            self.access = access
            self.bucket = bucket
            self.bucketID = bucketID
            self.s3Endpoint = s3Endpoint
            self.region = region
            self.expiresAt = expiresAt
            self.renewAfter = renewAfter
            self.revoked = revoked
            self.revokedReason = revokedReason
            self.origin = origin
            self.leftManaged = leftManaged
        }
    }

    /// The tombstone reason of a customer's own key the provider refused: the vault waits for another key from the
    /// person, never for one from the cloud.
    public static let ownKeyRefused = "own_key_refused"

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
                         renewAfter: Date(timeIntervalSince1970: TimeInterval(m.renewAfter)), secret: SecretBytes(raw),
                         origin: m.origin == BucketKey.Origin.customer.rawValue ? .customer : .cloud)
    }

    /// Whether the vault left managed storage (its storage was ejected to the person): recorded the first time this Mac
    /// saw the ejection, and by the person's own key. Such a vault never asks the cloud for a key again, and needs the
    /// cloud for nothing to take the person's key. The File Provider extension reads it too.
    public func hasLeftManagedStorage(_ uid: String) throws -> Bool {
        guard let m = try metadata(uid) else { return false }
        return m.leftManaged == true || m.origin == BucketKey.Origin.customer.rawValue
    }

    /// Whether the person's own key was refused by the provider (the vault waits for another of theirs).
    public func ownKeyWasRefused(_ uid: String) throws -> Bool {
        guard let m = try metadata(uid) else { return false }
        return m.revoked && m.revokedReason == Self.ownKeyRefused
    }

    /// Records that the vault left managed storage, with its bucket's `location`: on the key kept for it (which stays in
    /// use until it ends), else as a record without a key. Nothing is removed.
    public func markLeftManaged(_ uid: String, location: BucketLocation) throws {
        var m = try metadata(uid) ?? Metadata(keyID: "", access: "full", bucket: location.bucket, bucketID: location.bucketID,
                                              s3Endpoint: location.s3Endpoint, region: location.region, expiresAt: 0,
                                              renewAfter: 0, revoked: true)
        guard m.leftManaged != true else { return }
        m.leftManaged = true
        if m.bucket.isEmpty {
            (m.bucket, m.bucketID, m.s3Endpoint, m.region) = (location.bucket, location.bucketID, location.s3Endpoint, location.region)
        }
        try items.write(Self.item(uid), JSONEncoder().encode(m), operation: "record that a vault left managed storage")
    }

    /// The cloud's reason when it revoked the last key and the person hasn't asked for a new one; nil otherwise (and for
    /// a vault that left managed storage, which has no cloud to revoke its keys).
    public func revokedReason(_ uid: String) throws -> String? {
        guard let m = try metadata(uid), m.revoked, m.leftManaged != true, m.origin != BucketKey.Origin.customer.rawValue else {
            return nil
        }
        return m.revokedReason ?? "account_holder"
    }

    /// Where the vault's kept (or refused) key points.
    public func location(_ uid: String) throws -> BucketLocation? {
        try metadata(uid).map { BucketLocation(bucket: $0.bucket, bucketID: $0.bucketID, s3Endpoint: $0.s3Endpoint, region: $0.region) }
    }

    /// Keeps `key` (replacing the vault's previous key and its secret).
    public func save(_ key: BucketKey) throws {
        let previous = try? metadata(key.vaultUid)
        var raw = key.secret.withUnsafeBytes { Data($0) }
        defer { raw.resetBytes(in: 0 ..< raw.count) }
        try items.write(Self.secretItem(key.vaultUid, key.keyID), raw, operation: "store a storage key")
        var m = key.metadata()
        if previous?.leftManaged == true { m.leftManaged = true }  // a vault that left managed storage stays left
        try items.write(Self.item(key.vaultUid), JSONEncoder().encode(m), operation: "store a storage key")
        if let previous, !previous.keyID.isEmpty, previous.keyID != key.keyID {
            try? items.delete(Self.secretItem(key.vaultUid, previous.keyID), operation: "forget a storage key")
        }
    }

    /// Forgets the vault's key and its secret; with `revokedReason`, leaves a tombstone without either. A vault that left
    /// managed storage keeps its record (and the bucket's location), without the key: it is never forgotten.
    public func delete(_ uid: String, revokedReason: String? = nil) throws {
        if let m = try? metadata(uid) {
            if !m.keyID.isEmpty { try items.delete(Self.secretItem(uid, m.keyID), operation: "forget a storage key") }
            if m.leftManaged == true || m.origin == BucketKey.Origin.customer.rawValue {
                var t = m
                t.revoked = true
                t.leftManaged = true
                t.revokedReason = revokedReason
                try items.write(Self.item(uid), JSONEncoder().encode(t), operation: "forget a storage key")
                return
            }
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

