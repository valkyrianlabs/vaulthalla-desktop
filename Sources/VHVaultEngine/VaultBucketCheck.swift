public import Foundation
public import VHRecovery
import VLVaultfmt

/// Whether a bucket reached with a key the person brings (their own, after their managed storage was ejected to them) is
/// this vault's, before Desktop switches the vault to that key: one GET of the manifest root (`.vaulthalla/root`, its
/// current version), nothing written, listed or deleted. The root must authenticate with this vault's keys under its
/// uid (`vl_vaultfmt_root_open`: a root object of this vault, sealed with one of its keys) and, when this Mac knows the
/// vault's head, follow it by the chain rules (not older, not another root at the same epoch).
public enum VaultBucketCheck {
    public enum Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        /// The provider refused the key (401/403): wrong key id or secret, a key without read access, another bucket's.
        /// Decided by the caller from the store's typed signal (``S3CredentialSource/providerRefused()``), never here.
        case keyRefused
        /// The bucket couldn't be reached (the network, the endpoint).
        case unreachable(String)
        /// The bucket holds no vault root.
        case noVault
        /// The root there isn't this vault's, or none of this Mac's keys of the vault opens it.
        case anotherVault
        /// The root is this vault's but older than, or forked from, what this Mac already has.
        case behind(String)

        public var description: String { "VaultBucketCheck.Refusal.\(name)" }

        public var name: String {
            switch self {
            case .keyRefused: "key_refused"
            case .unreachable: "unreachable"
            case .noVault: "no_vault"
            case .anotherVault: "another_vault"
            case .behind(let why): why
            }
        }

        public var sentence: String {
            switch self {
            case .keyRefused:
                "Backblaze refused that key. Check the key ID and the application key, and that the key may read and write this vault's bucket."
            case .unreachable:
                "The bucket couldn't be reached with that key right now. Check the connection and try again."
            case .noVault: "That bucket holds no vault. Check that the key is for this vault's bucket."
            case .anotherVault: "That bucket holds another vault, not this one. Check that the key is for this vault's bucket."
            case .behind:
                "That bucket holds an older state of this vault than this Mac has. Nothing was switched; check that the key is for this vault's bucket."
            }
        }
    }

    /// Checks `store` (signed with the key to try) holds `uid`'s vault; returns the epoch its root is at.
    public static func verify(_ store: any VaultStore, uid: Uid, keys: any VaultKeySource,
                              known: (epoch: UInt64, rootSHA256: String)?) throws(Refusal) -> UInt64 {
        let root: Data
        do {
            root = try store.get(".vaulthalla/root", versionID: nil).bytes
        } catch {
            // A refusal (401/403) reaches the caller through the credential source's `providerRefused()`, which the
            // store calls; here every failed GET is "unreachable".
            switch error {
            case .notFound: throw .noVault
            case .failed(let why), .outcomeUnknown(let why): throw .unreachable(why)
            default: throw .unreachable(String(describing: error))
            }
        }
        var ring: OpaquePointer?
        guard vl_vaultfmt_keyring_new(&ring) == VaultStatus.ok, let ring else { throw .unreachable("no keyring") }
        defer { vl_vaultfmt_keyring_free(ring) }
        let current = (try? keys.currentVersion()) ?? 0
        guard current > 0 else { throw .anotherVault }
        let raw = UnsafeMutableRawBufferPointer.allocate(byteCount: 32, alignment: 1)
        defer {
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            raw.deallocate()
        }
        for version in 1 ... current where (try? keys.copyKey(version: version, into: raw)) == true {
            _ = vl_vaultfmt_keyring_add(ring, version, raw.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
        }
        var uidBytes = uid.bytes
        var opened: OpaquePointer?
        let status: Int32 = root.withUnsafeBytes { r in
            uidBytes.withUnsafeMutableBufferPointer { u in
                if let known {
                    return known.rootSHA256.withCString { sha in
                        var k = vl_vaultfmt_known(epoch: known.epoch, root_sha256: sha)
                        return vl_vaultfmt_root_open(r.baseAddress?.assumingMemoryBound(to: UInt8.self), r.count, u.baseAddress,
                                                     ring, &k, &opened)
                    }
                }
                return vl_vaultfmt_root_open(r.baseAddress?.assumingMemoryBound(to: UInt8.self), r.count, u.baseAddress, ring,
                                             nil, &opened)
            }
        }
        defer { if let opened { vl_vaultfmt_root_free(opened) } }
        guard status == VaultStatus.ok, let opened else {
            let name = VaultStatus.name(status)
            if name.hasPrefix("chain_") { throw .behind(name) }
            throw .anotherVault
        }
        var info = vl_vaultfmt_root_info()
        guard vl_vaultfmt_root_info_get(opened, &info) == VaultStatus.ok else { throw .anotherVault }
        return info.epoch
    }
}
