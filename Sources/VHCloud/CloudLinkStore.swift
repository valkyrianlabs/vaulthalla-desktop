public import Foundation
import Security

/// This Mac's Vaulthalla Cloud link: its Ed25519 identity key (Ed25519 can't live in the Secure Enclave, so the raw
/// key is a keychain item, this device only) and where the linking ceremony stands. One per Mac; linking is never
/// required for anything else Desktop does.
public struct CloudLink: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case pending, linked }

    public var endpoint: String
    public var name: String
    public var state: State
    /// The raw 32-byte Ed25519 private key, base64. Only in the keychain item.
    public var identityKey: String
    public var requestID: String?
    public var installationID: String?
    public var accountID: Int64?

    public init(endpoint: String, name: String, state: State, identityKey: String, requestID: String? = nil,
                installationID: String? = nil, accountID: Int64? = nil) {
        self.endpoint = endpoint
        self.name = name
        self.state = state
        self.identityKey = identityKey
        self.requestID = requestID
        self.installationID = installationID
        self.accountID = accountID
    }

    enum CodingKeys: String, CodingKey {
        case endpoint, name, state
        case identityKey = "identity_key"
        case requestID = "request_id"
        case installationID = "installation_id"
        case accountID = "account_id"
    }
}

public protocol CloudLinkStore: Sendable {
    func load() throws -> CloudLink?
    func save(_ link: CloudLink) throws
    func delete() throws
}

public enum CloudLinkStoreError: Error, Sendable, Equatable {
    case keychain(OSStatus)
    case corrupt
}

/// The link in one generic-password keychain item (service `sh.vaulthalla.app.cloud`, account `link`), readable after
/// the first unlock, never migrating to another Mac. `.fileBased` is for tests and unsigned tools, which can't use the
/// data protection keychain.
public struct KeychainCloudLinkStore: CloudLinkStore {
    public enum Keychain: Sendable { case dataProtection, fileBased }

    public let service: String
    public let keychain: Keychain
    public let accessGroup: String?

    public init(service: String = "sh.vaulthalla.app.cloud", keychain: Keychain = .dataProtection,
                accessGroup: String? = nil) {
        self.service = service
        self.keychain = keychain
        self.accessGroup = accessGroup
    }

    private func query() -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "link"]
        if keychain == .dataProtection {
            q[kSecUseDataProtectionKeychain] = true
            if let accessGroup { q[kSecAttrAccessGroup] = accessGroup }
        }
        return q
    }

    public func load() throws -> CloudLink? {
        var q = query()
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw CloudLinkStoreError.keychain(status) }
        guard let link = try? JSONDecoder().decode(CloudLink.self, from: data) else { throw CloudLinkStoreError.corrupt }
        return link
    }

    public func save(_ link: CloudLink) throws {
        let data = try JSONEncoder().encode(link)
        let update = SecItemUpdate(query() as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw CloudLinkStoreError.keychain(update) }
        var add = query()
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CloudLinkStoreError.keychain(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudLinkStoreError.keychain(status) }
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
