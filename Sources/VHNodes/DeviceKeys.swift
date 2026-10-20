public import Foundation
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
public final class DeviceKeys: Sendable {
    public let primary: DeviceIdentityStore
    public let development: DeviceIdentityStore?
    /// The backend new keys are created on in `primary`.
    public let preferredBackend: KeyBackend

    private let log = Logger(subsystem: "sh.vaulthalla.desktop", category: "device-keys")

    public init(primary: DeviceIdentityStore, development: DeviceIdentityStore?, preferredBackend: KeyBackend = .secureEnclave) {
        self.primary = primary
        self.development = development
        self.preferredBackend = preferredBackend
    }

    /// The app's keys: Secure Enclave in the data protection keychain, with a file-keychain software fallback under
    /// its own namespace for builds without keychain entitlements.
    public static func standard() -> DeviceKeys {
        DeviceKeys(
            primary: DeviceIdentityStore(),
            development: DeviceIdentityStore(configuration: .init(
                namespace: "sh.vaulthalla.desktop.device.development", keychain: .fileBased)))
    }

    private var stores: [DeviceIdentityStore] { [primary] + (development.map { [$0] } ?? []) }

    /// The node's current identity, from whichever keychain holds it.
    public func identity(for nodeTag: String) async throws -> DeviceIdentity? {
        try await locate(nodeTag)?.identity
    }

    /// The replacement identity of an unfinished rotation, if any.
    public func pendingRotation(for nodeTag: String) async throws -> DeviceIdentity? {
        guard let store = try await locate(nodeTag)?.store else { return nil }
        return try await store.pendingRotation(for: nodeTag)
    }

    /// The identity to pair `nodeTag` with. An existing one is reused (a retry after a declined or expired request
    /// keeps the key, docs/pairing.md §3) unless `replacingExisting`: a revoked key can never be approved again, so
    /// pairing again after a revocation deletes it and starts with a fresh key.
    public func identityForPairing(nodeTag: String, deviceName: String, replacingExisting: Bool) async throws
        -> DeviceIdentity
    {
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
        guard let store = try await locate(nodeTag)?.store else { throw IdentityError.notFound(nodeTag: nodeTag) }
        return try await store.rotate(for: nodeTag, serverSPKISHA256: serverSPKISHA256)
    }

    @discardableResult
    public func completeRotation(for nodeTag: String) async throws -> DeviceIdentity {
        guard let store = try await locate(nodeTag)?.store else { throw IdentityError.notFound(nodeTag: nodeTag) }
        return try await store.completeRotation(for: nodeTag)
    }

    public func cancelRotation(for nodeTag: String) async throws {
        guard let store = try await locate(nodeTag)?.store else { return }
        try await store.cancelRotation(for: nodeTag)
    }

    /// Deletes the node's key (and any pending replacement) from both keychains.
    public func deleteIdentity(for nodeTag: String) async throws {
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
