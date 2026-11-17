public import Foundation
import Security
public import VHKeykit
public import VHVaultKeys

/// What this Mac uploads with an enrollment so a server can prove the key versions it created (docs/desktop-vaults.md,
/// "Key provenance"; vaulthalla-server spec 03 §6.5): its origin (this installation's id, the vault id vl-keykit derives
/// from the uid), its attestation key, and per version the key check and the attestation over it.
public struct VaultProvenance: Sendable, Equatable {
    public struct Version: Sendable, Equatable {
        public var version: UInt32
        public var keyCheck: String
        public var signature: Data
    }

    public var nodeID: String
    public var vaultID: UInt32
    public var keyID: UInt32
    public var publicKey: Data
    public var versions: [Version]
}

/// This Mac's attestation signing key: a 32-byte Ed25519 seed in the item `attestation-key` of the account's
/// **app-only** keychain group (this device only, written only by the credential owner, like the link and the account
/// key), never in the group shared with the File Provider extension, and not the Secure Enclave, which signs only P-256
/// while the format is Ed25519. Made on first need.
public struct AttestationKeyStore: Sendable {
    public static let item = "attestation-key"
    let items: LeasedAccountItems

    public init(items: LeasedAccountItems) { self.items = items }

    /// Lends the seed for one operation, making it first when there is none.
    func withSeed<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        if var raw = try items.read(Self.item) {
            defer { raw.resetBytes(in: 0 ..< raw.count) }
            guard raw.count == 32 else { throw AccountItemError.corrupt("the stored attestation key") }
            return try raw.withUnsafeBytes(body)
        }
        var seed = Data(count: 32)
        defer { seed.resetBytes(in: 0 ..< seed.count) }
        let status = seed.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AccountItemError.corrupt("no randomness for an attestation key") }
        try items.write(Self.item, seed, operation: "make this Mac's attestation key")
        return try seed.withUnsafeBytes(body)
    }

    /// The provenance of `versions` of vault `uid` (each version's key lent by `key`), attested by this Mac
    /// (`installationID`). Only for versions this Mac created: it never attests a version it adopted.
    public func provenance(uid: String, installationID: String, versions: [UInt32],
                           key: (UInt32, (UnsafeRawBufferPointer) throws -> Void) throws -> Void) throws -> VaultProvenance {
        guard let wire = Uid32.bytes(uid) else { throw KeykitError.invalidArgument }
        let vaultID = try Provenance.macOriginVaultID(uid: wire)
        return try withSeed { seed in
            let publicKey = try Provenance.publicKey(seed: seed)
            var out: [VaultProvenance.Version] = []
            for v in versions.sorted() {
                var check = ""
                try key(v) { raw in check = try Provenance.keyCheck(key: raw, vaultID: UInt64(vaultID), version: v) }
                guard !check.isEmpty else { continue }
                let signature = try Provenance.attest(seed: seed, nodeID: installationID, vaultID: UInt64(vaultID),
                                                      version: v, keyCheck: check)
                out.append(.init(version: v, keyCheck: check, signature: signature))
            }
            return VaultProvenance(nodeID: installationID, vaultID: vaultID, keyID: Provenance.keyID(publicKey: publicKey),
                                   publicKey: publicKey, versions: out)
        }
    }
}
