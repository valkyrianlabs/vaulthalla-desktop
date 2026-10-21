import Foundation

/// A node's attestation of one key version: an Ed25519 signature (by the node's key `keyID`) over
/// "vh-key-attest-v1" ‖ node_id ‖ UInt64BE(vault_id) ‖ UInt32BE(version) ‖ key_check. Non-secret metadata, kept
/// byte for byte; only the daemon verifies it (on import). Its presence is what makes a recovery "guaranteed".
public struct KeyAttestation: Sendable, Equatable, Hashable, Codable {
    public let keyID: String
    public let signature: String

    public init(keyID: String, signature: String) {
        self.keyID = keyID
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case signature
    }
}
