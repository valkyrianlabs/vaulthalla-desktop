import Foundation

/// A node's attestation of one key version, as the daemon sends it (`{key_id, signature}`, `WsModel.VaultKeyAttestation`):
/// an Ed25519 signature by the node's signing key `keyID` over "vh-key-attest-v1" ‖ node_id ‖ UInt64BE(vault_id) ‖
/// UInt32BE(version) ‖ key_check. Public, non-secret metadata (it reveals nothing about the key), stored with the key
/// in 1Password and handed back unchanged: only the daemon verifies it, on import. A version restores as the vault's
/// own only with it; without it, the key can only be salvaged.
public struct KeyAttestation: Sendable, Equatable, Hashable, Codable {
    /// Which of the node's signing keys signed (`key_attestation_keys.id`), a JSON number.
    public let keyID: Int64
    /// The signature, base64 (64 bytes), exactly as the daemon sent it.
    public let signature: String

    public init(keyID: Int64, signature: String) {
        self.keyID = keyID
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case signature
    }

    /// One the daemon could verify at all: a signing key id in 1...2^31 - 1 (`key_attestation_keys.id` is a SERIAL)
    /// and a 64-byte signature in base64. A malformed attestation (a hand edit, damage) is as good as none: the daemon
    /// reads it as unattested.
    public var isWellFormed: Bool {
        guard (1...Int64(Int32.max)).contains(keyID), let bytes = Data(base64Encoded: signature) else { return false }
        return bytes.count == 64
    }
}
