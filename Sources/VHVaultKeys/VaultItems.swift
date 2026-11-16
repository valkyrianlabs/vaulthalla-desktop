public import Foundation
public import VHCore
import OSLog

/// The keychain group the app and the File Provider extension share for Desktop-only vaults:
/// `<TEAM>.sh.vaulthalla.app.vault` (both targets' `keychain-access-groups`). It holds only what the extension needs to
/// read and write a vault's files: each vault's key versions (``VaultKeyStore``) and the bucket key in force
/// (``BucketKeyStore``, its metadata and secret). The account link's identity key and the account key stay in the
/// app's own group (``AccountKeychain``). The app writes here (it holds the credential lease and alone talks to the
/// cloud); the extension only reads.
///
/// Items are generic passwords under service `sh.vaulthalla.app.vault`, in the data protection keychain,
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable: readable by a background extension without
/// UI once the Mac has been unlocked after boot, never restored onto another Mac or synced to iCloud. Raw bytes, never
/// text.
public enum VaultKeychain {
    public static let service = "sh.vaulthalla.app.vault"
    public static let groupSuffix = "sh.vaulthalla.app.vault"

    /// The shared group for this process's team, from its App Group entitlement; nil when unsigned.
    public static func accessGroup() -> String? {
        AppGroup.entitledIdentifier().map { String($0.dropLast(AppGroup.suffix.count)) + groupSuffix }
    }
}

extension KeychainAccountItemStore {
    /// The shared group's items: the data protection keychain in that group when signed, the file keychain otherwise.
    public static func sharedVault() -> KeychainAccountItemStore {
        if let group = VaultKeychain.accessGroup() {
            KeychainAccountItemStore(service: VaultKeychain.service, keychain: .dataProtection(accessGroup: group))
        } else {
            KeychainAccountItemStore(service: VaultKeychain.service, keychain: .fileBased)
        }
    }
}

/// The items a vault's key stores read and write: the shared group, and (in the app only) the app-only group that an
/// earlier, unreleased build kept them in. An item found only in the old group is moved on first use: written to the
/// shared group, read back and compared, and only then deleted from the old one. A failed read-back leaves the old
/// item in place (and removes the bad copy); a crash between the write and the delete leaves both, and the next use
/// deletes the old one once the two are equal. No other compatibility path: the feature never shipped.
public struct VaultItems: Sendable {
    public let shared: LeasedAccountItems
    public let legacy: LeasedAccountItems?
    private static let log = Logger(subsystem: "sh.vaulthalla.app", category: "vault.keys")

    public init(shared: LeasedAccountItems, legacy: LeasedAccountItems? = nil) {
        self.shared = shared
        self.legacy = legacy
    }

    /// The app's: the shared group (written under `lease`), moving from the app-only group.
    public static func app(lease: CredentialLease?) -> VaultItems {
        VaultItems(shared: LeasedAccountItems(items: KeychainAccountItemStore.sharedVault(), lease: lease),
                   legacy: LeasedAccountItems(items: KeychainAccountItemStore.standard(), lease: lease))
    }

    /// The File Provider extension's: the shared group, read only (no lease, no old group).
    public static func fileProvider() -> VaultItems {
        VaultItems(shared: LeasedAccountItems(items: KeychainAccountItemStore.sharedVault(), lease: nil))
    }

    public var role: CredentialRole { shared.role }

    public func read(_ name: String) throws -> Data? {
        let here = try shared.read(name)
        guard let legacy, shared.role == .owner, var old = try? legacy.read(name) else { return here }
        defer { old.resetBytes(in: 0 ..< old.count) }
        if var here {
            // A move that crashed before its delete (equal), or an old item a newer write superseded (unequal: kept
            // until a write of that name, never deleted on a guess).
            defer { here.resetBytes(in: 0 ..< here.count) }
            if here == old { try? legacy.delete(name, operation: "move a vault key item") }
            return Data(here)
        }
        try shared.write(name, old, operation: "move a vault key item")
        guard var back = try? shared.read(name), back == old else {
            Self.log.error("a vault key item didn't read back from the shared group; kept in the old one")
            try? shared.delete(name, operation: "move a vault key item")
            return Data(old)
        }
        back.resetBytes(in: 0 ..< back.count)
        // A delete that fails (or a crash here) leaves both, equal: the next use deletes the old one.
        try? legacy.delete(name, operation: "move a vault key item")
        return Data(old)
    }

    public func write(_ name: String, _ data: Data, operation: String) throws {
        try shared.write(name, data, operation: operation)
        // A newer value of a moved item: the old group's copy goes.
        if let legacy, shared.role == .owner, (try? legacy.read(name)) != nil { try? legacy.delete(name, operation: operation) }
    }

    public func delete(_ name: String, operation: String) throws {
        try shared.delete(name, operation: operation)
        if let legacy, shared.role == .owner { try legacy.delete(name, operation: operation) }
    }
}
