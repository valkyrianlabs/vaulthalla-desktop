public import Foundation
public import VHCore
import Security

/// The keychain items of this Mac's Vaulthalla Cloud account: the link (its identity key) and the wrapped account key.
/// They live in an app-only access group, `<TEAM>.sh.vaulthalla.app.account`, which the app and its agent (the same
/// executable) are entitled to and the File Provider extension and `vaulthalla-mcp.app` are not
/// (docs/cloud-storage.md, "Who may touch it"). This device only, readable after the first unlock.
public enum AccountKeychain {
    public static let service = "sh.vaulthalla.app.account"
    public static let groupSuffix = "sh.vaulthalla.app.account"

    /// The app-only group for this process's team, from its App Group entitlement; nil when unsigned.
    public static func accessGroup() -> String? {
        AppGroup.entitledIdentifier().map { String($0.dropLast(AppGroup.suffix.count)) + groupSuffix }
    }
}

/// One generic-password item per name under ``AccountKeychain/service``.
public protocol AccountItemStore: Sendable {
    func read(_ name: String) throws -> Data?
    func write(_ name: String, _ data: Data) throws
    func delete(_ name: String) throws
}

public enum AccountItemError: Error, Sendable, Equatable {
    case keychain(OSStatus)
    case corrupt(String)
}

/// The data protection keychain in the app-only group, or (unsigned builds and tests, which can't use it) the file
/// keychain.
public struct KeychainAccountItemStore: AccountItemStore {
    public enum Keychain: Sendable, Hashable {
        case dataProtection(accessGroup: String?)
        case fileBased
    }

    public let service: String
    public let keychain: Keychain

    public init(service: String = AccountKeychain.service, keychain: Keychain) {
        self.service = service
        self.keychain = keychain
    }

    /// The app's store: the data protection keychain in the app-only group when this process is signed with one, the
    /// file keychain otherwise (a development build).
    public static func standard() -> KeychainAccountItemStore {
        if let group = AccountKeychain.accessGroup() {
            KeychainAccountItemStore(keychain: .dataProtection(accessGroup: group))
        } else {
            KeychainAccountItemStore(keychain: .fileBased)
        }
    }

    /// The query naming item `name`; pure, so tests check it.
    public func query(_ name: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: name]
        if case .dataProtection(let group) = keychain {
            q[kSecUseDataProtectionKeychain as String] = true
            if let group { q[kSecAttrAccessGroup as String] = group }
        }
        return q
    }

    /// The attributes a new item gets besides its data.
    public func addAttributes() -> [String: Any] {
        [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
         kSecAttrSynchronizable as String: false]
    }

    public func read(_ name: String) throws -> Data? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw AccountItemError.keychain(status) }
        return data
    }

    public func write(_ name: String, _ data: Data) throws {
        let update = SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AccountItemError.keychain(update) }
        var add = query(name).merging(addAttributes()) { $1 }
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AccountItemError.keychain(status) }
    }

    public func delete(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountItemError.keychain(status) }
    }
}

/// In memory, for tests and previews.
public final class MemoryAccountItemStore: AccountItemStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func read(_ name: String) throws -> Data? { lock.withLock { items[name] } }
    public func write(_ name: String, _ data: Data) throws { lock.withLock { items[name] = data } }
    public func delete(_ name: String) throws { lock.withLock { items[name] = nil } }
    public var names: [String] { lock.withLock { items.keys.sorted() } }
}

/// Only the credential owner (the process holding the ``CredentialLease``) writes the account's items, as for the
/// node registry and device keys (docs/architecture.md §3). A store made without a lease is read-only.
public struct LeasedAccountItems: Sendable {
    public let items: any AccountItemStore
    public let lease: CredentialLease?

    public init(items: any AccountItemStore, lease: CredentialLease?) {
        self.items = items
        self.lease = lease
    }

    public var role: CredentialRole { lease?.role ?? .consumer }

    public func read(_ name: String) throws -> Data? { try items.read(name) }

    public func write(_ name: String, _ data: Data, operation: String) throws {
        guard role == .owner else { throw CredentialOwnershipError.notOwner(operation: operation) }
        try items.write(name, data)
    }

    public func delete(_ name: String, operation: String) throws {
        guard role == .owner else { throw CredentialOwnershipError.notOwner(operation: operation) }
        try items.delete(name)
    }
}
