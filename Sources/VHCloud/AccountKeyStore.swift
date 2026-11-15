public import Foundation
public import VHCore
public import VHKeykit

/// The account recovery key as this Mac keeps it: never in the clear, only as KAK1 sealed to this Mac's holder key, for
/// one generation of the account (docs/cloud-storage.md, "Keeping it"). The plaintext exists only inside a VLKeykit
/// handle during one operation.
public struct HeldAccountKey: Codable, Sendable, Equatable {
    public var accountPublicID: String
    /// The generation's statement, verified against the cloud's chain when it was stored.
    public var statement: KeyStatement
    public var holderKind: HolderKeyKind
    /// The holder key's data representation (Secure Enclave) or scalar (software).
    public var holderKey: Data
    public var holderPublicKey: Data
    public var kak1: Data
    /// Whether the cloud lists this Mac as a holder of this generation (`POST /v1/keys/holders` succeeded).
    public var registered: Bool
    /// The key request (create or rotate) this generation waits on, before it is the account's current one.
    public var pendingRequestID: String?
    /// The payload text the request was made with (its code is computed from it).
    public var pendingPayload: String?
    public var storedAt: Date

    public init(accountPublicID: String, statement: KeyStatement, holderKind: HolderKeyKind, holderKey: Data,
                holderPublicKey: Data, kak1: Data, registered: Bool, pendingRequestID: String? = nil,
                pendingPayload: String? = nil, storedAt: Date = .now) {
        self.accountPublicID = accountPublicID
        self.statement = statement
        self.holderKind = holderKind
        self.holderKey = holderKey
        self.holderPublicKey = holderPublicKey
        self.kak1 = kak1
        self.registered = registered
        self.pendingRequestID = pendingRequestID
        self.pendingPayload = pendingPayload
        self.storedAt = storedAt
    }

    public var generation: UInt32 { statement.generation }
    public var fingerprint: Fingerprint { statement.fingerprint }
}

/// Where ``HeldAccountKey`` lives: the item `account-key` (the generation this Mac holds) and `account-key.pending` (a
/// new key waiting for its request's approval), in the account's app-only items, written only by the credential owner.
public struct AccountKeyStore: Sendable {
    public static let heldItem = "account-key"
    public static let pendingItem = "account-key.pending"
    let items: LeasedAccountItems

    public init(items: LeasedAccountItems) { self.items = items }

    public var role: CredentialRole { items.role }

    public func held() throws -> HeldAccountKey? { try read(Self.heldItem) }
    public func pending() throws -> HeldAccountKey? { try read(Self.pendingItem) }

    public func saveHeld(_ key: HeldAccountKey) throws {
        try items.write(Self.heldItem, JSONEncoder().encode(key), operation: "store the account recovery key")
    }

    public func savePending(_ key: HeldAccountKey) throws {
        try items.write(Self.pendingItem, JSONEncoder().encode(key), operation: "store a new account recovery key")
    }

    /// The pending key becomes the held one (its request was approved).
    public func promotePending() throws {
        guard var key = try pending() else { return }
        key.pendingRequestID = nil
        key.pendingPayload = nil
        try saveHeld(key)
        try items.delete(Self.pendingItem, operation: "store the account recovery key")
    }

    public func deletePending() throws { try items.delete(Self.pendingItem, operation: "forget a new account recovery key") }
    public func deleteHeld() throws { try items.delete(Self.heldItem, operation: "forget the account recovery key") }

    private func read(_ name: String) throws -> HeldAccountKey? {
        guard let data = try items.read(name) else { return nil }
        guard let key = try? JSONDecoder().decode(HeldAccountKey.self, from: data) else {
            throw AccountItemError.corrupt("the stored account recovery key")
        }
        return key
    }
}
