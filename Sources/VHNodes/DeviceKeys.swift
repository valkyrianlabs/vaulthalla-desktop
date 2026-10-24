public import Foundation
public import VHCore
public import VHIdentity
import os

/// This Mac's device keys, one per node, and where each one lives.
///
/// A new key goes in the Secure Enclave (`primary`, the data protection keychain). An unsigned or development build
/// can't use either (`IdentityError.missingEntitlement`), so it gets a software key in `development` (the file-based
/// keychain) instead, and the identity says so (`DeviceIdentity.backend == .software`): the UI labels it "Software
/// key (development build)".
///
/// The choice is made once, when a node's key is created. Lookups search both keychains and use whatever exists, and
/// rotation keeps the backend and keychain of the key it replaces, so an existing node never changes backend behind
/// the operator's back. A node whose key is missing stays missing (re-pairing creates a new one); nothing here
/// creates a key except ``identityForPairing(nodeTag:deviceName:replacingExisting:)``.
///
/// **One owner.** Creating, rotating and deleting keys is for the credential owner only: the process holding the
/// ``CredentialLease`` these keys were made with (docs/architecture.md §3, "Credential ownership"). Without a held
/// lease every such call throws ``CredentialOwnershipError/notOwner(operation:)`` before touching the Keychain, and the
/// keys are read-only: ``identity(for:)`` and ``pendingRotation(for:)`` serve consumers (the MCP bridge, the File
/// Provider extension, the app while another process owns).
public final class DeviceKeys: Sendable {
    public let primary: DeviceIdentityStore
    public let development: DeviceIdentityStore?
    /// The backend new keys are created on in `primary`.
    public let preferredBackend: KeyBackend
    /// The lease that makes this process the owner; nil for a consumer.
    public let lease: CredentialLease?

    private let log = Logger(subsystem: "sh.vaulthalla.desktop", category: "device-keys")

    public init(primary: DeviceIdentityStore, development: DeviceIdentityStore?,
                preferredBackend: KeyBackend = .secureEnclave, lease: CredentialLease? = nil) {
        self.primary = primary
        self.development = development
        self.preferredBackend = preferredBackend
        self.lease = lease
    }

    /// The app's keys: Secure Enclave in the data protection keychain, with a file-keychain software fallback under
    /// its own namespace for builds without keychain entitlements. Read-only unless `lease` is given and held.
    public static func standard(lease: CredentialLease? = nil) -> DeviceKeys {
        DeviceKeys(
            primary: DeviceIdentityStore(),
            development: DeviceIdentityStore(configuration: .init(
                namespace: "sh.vaulthalla.desktop.device.development", keychain: .fileBased)),
            lease: lease)
    }

    /// Whether this process may create, rotate and delete keys now.
    public var role: CredentialRole {
        lease?.role ?? .consumer
    }

    /// Throws unless this process holds the lease.
    private func requireOwner(_ operation: String) throws(CredentialOwnershipError) {
        guard role == .owner else { throw .notOwner(operation: operation) }
    }

    private var stores: [DeviceIdentityStore] { [primary] + (development.map { [$0] } ?? []) }

    /// The node's current identity, from whichever keychain holds it.
    public func identity(for nodeTag: String) async throws -> DeviceIdentity? {
        try await locate(nodeTag)?.identity
    }

    /// The replacement identity of an unfinished rotation, if any. Found even while the current key is missing
    /// (between the two Keychain steps of completing a rotation), so a consumer that reads mid-rotation still finds
    /// the key the owner is moving to.
    public func pendingRotation(for nodeTag: String) async throws -> DeviceIdentity? {
        if let store = try await locate(nodeTag)?.store { return try await store.pendingRotation(for: nodeTag) }
        for store in stores {
            do {
                if let pending = try await store.pendingRotation(for: nodeTag) { return pending }
            } catch IdentityError.missingEntitlement {
                continue
            }
        }
        return nil
    }

    /// The identity to pair `nodeTag` with. An existing one is reused (a retry after a declined or expired request
    /// keeps the key, docs/pairing.md §3) unless `replacingExisting`: a revoked key can never be approved again, so
    /// pairing again after a revocation deletes it and starts with a fresh key.
    public func identityForPairing(nodeTag: String, deviceName: String, replacingExisting: Bool) async throws
        -> DeviceIdentity
    {
        try requireOwner("create a device key")
        if replacingExisting {
            try await deleteIdentity(for: nodeTag)
        } else if let existing = try await identity(for: nodeTag) {
            return existing
        }
        do {
            return try await primary.createIdentity(for: nodeTag, deviceName: deviceName, backend: preferredBackend)
        } catch IdentityError.missingEntitlement {
            guard let development else { throw IdentityError.missingEntitlement(operation: "create device key") }
            log.notice("no keychain entitlements: using a software device key (development build)")
            return try await development.createIdentity(for: nodeTag, deviceName: deviceName, backend: .software)
        }
    }

    /// Starts a rotation in the keychain that holds the node's key (same backend).
    public func rotate(for nodeTag: String, serverSPKISHA256: Data) async throws -> IdentityRotation {
        try requireOwner("rotate a device key")
        guard let store = try await locate(nodeTag)?.store else { throw IdentityError.notFound(nodeTag: nodeTag) }
        return try await store.rotate(for: nodeTag, serverSPKISHA256: serverSPKISHA256)
    }

    @discardableResult
    public func completeRotation(for nodeTag: String) async throws -> DeviceIdentity {
        try requireOwner("complete a device key rotation")
        guard let store = try await locate(nodeTag)?.store else { throw IdentityError.notFound(nodeTag: nodeTag) }
        return try await store.completeRotation(for: nodeTag)
    }

    public func cancelRotation(for nodeTag: String) async throws {
        try requireOwner("cancel a device key rotation")
        guard let store = try await locate(nodeTag)?.store else { return }
        try await store.cancelRotation(for: nodeTag)
    }

    /// Deletes the node's key (and any pending replacement) from both keychains.
    public func deleteIdentity(for nodeTag: String) async throws {
        try requireOwner("delete a device key")
        for store in stores {
            do {
                try await store.deleteIdentity(for: nodeTag)
            } catch IdentityError.missingEntitlement {
                // This build can't touch that keychain, so it can't have put anything there either.
            }
        }
    }

    private func locate(_ nodeTag: String) async throws -> (store: DeviceIdentityStore, identity: DeviceIdentity)? {
        for store in stores {
            do {
                if let identity = try await store.identity(for: nodeTag) { return (store, identity) }
            } catch IdentityError.missingEntitlement {
                continue
            }
        }
        return nil
    }
}

extension KeyBackend {
    /// How the node details name the backend.
    public var displayName: String {
        switch self {
        case .secureEnclave: "Secure Enclave"
        case .software: "Software key (development build)"
        }
    }
}
