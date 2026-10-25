import Foundation
public import VHCore
public import VHIdentity
public import VHNodes

/// Whether the File Provider extension could serve a domain: it reads the registry and the device identity the
/// credential owner keeps in the App Group, as a read-only consumer (``CredentialReader``), and changes neither.
public struct ExtensionReadiness: Hashable, Sendable, CustomStringConvertible {
    public enum State: Hashable, Sendable {
        /// The node is paired and this Mac's key for it is readable.
        case ready(deviceID: String, backend: KeyBackend)
        /// The domain's identifier isn't `<node id>.<vault id>`.
        case notAVaultDomain
        /// The extension has no App Group (an unsigned build): nothing is shared with it.
        case noAppGroup
        /// The App Group holds no registry yet: the app hasn't migrated or written it.
        case registryMissing
        /// The registry or the Keychain says no (unknown node, not paired, revoked, missing key, unreadable).
        case credentials(CredentialFailure)
    }

    public let domainIdentifier: String
    public let vault: VaultDomainID?
    public let state: State

    public init(domainIdentifier: String, vault: VaultDomainID?, state: State) {
        self.domainIdentifier = domainIdentifier
        self.vault = vault
        self.state = state
    }

    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// One line for the log: identifiers and states, never key material.
    public var description: String {
        let subject = vault.map { "node \($0.nodeID), vault \($0.vaultID)" } ?? "domain \(domainIdentifier)"
        return switch state {
        case .ready(let deviceID, let backend): "ready: \(subject), device \(deviceID) (\(backend.rawValue) key)"
        case .notAVaultDomain: "not ready: \(subject) isn't a Vaulthalla vault domain"
        case .noAppGroup: "not ready: no App Group (unsigned build), so no shared registry or keys"
        case .registryMissing: "not ready: the App Group holds no node registry yet (open Vaulthalla once)"
        case .credentials(let failure): "not ready: \(subject): \(failure.description)"
        }
    }

    /// Checks `domainIdentifier` against the registry at `registry` (nil: no App Group) with `reader`, which must be
    /// a consumer's: it loads, never writes.
    public static func check(domainIdentifier: String, registry: RegistryLocation?, reader: CredentialReader)
        async -> ExtensionReadiness
    {
        guard let vault = VaultDomainID(identifier: domainIdentifier) else {
            return ExtensionReadiness(domainIdentifier: domainIdentifier, vault: nil, state: .notAVaultDomain)
        }
        func result(_ state: State) -> ExtensionReadiness {
            ExtensionReadiness(domainIdentifier: domainIdentifier, vault: vault, state: state)
        }
        guard let registry else { return result(.noAppGroup) }
        guard FileManager.default.fileExists(atPath: registry.registryURL.path) else { return result(.registryMissing) }
        do {
            let credentials = try await reader.load(vault.nodeID)
            return result(.ready(deviceID: credentials.identity.deviceID, backend: credentials.identity.backend))
        } catch {
            return result(.credentials(error))
        }
    }
}
