public import Foundation

/// This Mac's Vaulthalla Cloud link: its Ed25519 identity key (VHC1-Ed25519; Ed25519 can't live in the Secure
/// Enclave, so the raw key is a keychain item in the app-only group, this device only) and where the linking ceremony
/// stands. One per macOS account; linking is never required for anything else Desktop does.
public struct CloudLink: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case pending, linked }

    public var endpoint: String
    public var name: String
    public var state: State
    /// The raw 32-byte Ed25519 private key, base64. Only in the keychain item.
    public var identityKey: String
    public var requestID: String?
    public var installationID: String?
    /// The account's public id (UUID text) from the claim: what key statements name. The cloud's internal numeric
    /// account id is never kept.
    public var accountPublicID: String?

    public init(endpoint: String, name: String, state: State, identityKey: String, requestID: String? = nil,
                installationID: String? = nil, accountPublicID: String? = nil) {
        self.endpoint = endpoint
        self.name = name
        self.state = state
        self.identityKey = identityKey
        self.requestID = requestID
        self.installationID = installationID
        self.accountPublicID = accountPublicID
    }

    enum CodingKeys: String, CodingKey {
        case endpoint, name, state
        case identityKey = "identity_key"
        case requestID = "request_id"
        case installationID = "installation_id"
        case accountPublicID = "account_public_id"
    }
}

public protocol CloudLinkStore: Sendable {
    func load() throws -> CloudLink?
    func save(_ link: CloudLink) throws
    func delete() throws
}

/// The link as the item `link` of the account's items (``AccountKeychain``), written only by the credential owner.
public struct AccountCloudLinkStore: CloudLinkStore {
    public static let itemName = "link"
    let items: LeasedAccountItems

    public init(items: LeasedAccountItems) { self.items = items }

    public func load() throws -> CloudLink? {
        guard let data = try items.read(Self.itemName) else { return nil }
        guard let link = try? JSONDecoder().decode(CloudLink.self, from: data) else {
            throw AccountItemError.corrupt("the cloud link")
        }
        return link
    }

    public func save(_ link: CloudLink) throws {
        try items.write(Self.itemName, JSONEncoder().encode(link), operation: "change this Mac's Vaulthalla Cloud link")
    }

    public func delete() throws {
        try items.delete(Self.itemName, operation: "unlink this Mac from Vaulthalla Cloud")
    }
}

/// In memory, for tests and previews.
public final class MemoryCloudLinkStore: CloudLinkStore, @unchecked Sendable {
    private let lock = NSLock()
    private var link: CloudLink?

    public init(_ link: CloudLink? = nil) { self.link = link }

    public func load() throws -> CloudLink? { lock.withLock { link } }
    public func save(_ link: CloudLink) throws { lock.withLock { self.link = link } }
    public func delete() throws { lock.withLock { link = nil } }
}
