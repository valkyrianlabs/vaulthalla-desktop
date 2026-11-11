public import Foundation

/// The recovery kit (vaulthalla-server spec 03 §5.3; vl-keykit `kit.hpp`), the document a customer keeps to recover
/// vaults from their buckets (in the vault's 1Password item, printed, or from `vh-recovery kit create`):
///
///     {"type": "vh.recovery-kit", "v": 1, "recovery_seed": "<27 symbols>",
///      "vaults": [{"vault_uid": "<b32>", "origin": {"node_id": "…", "vault_id": 42},
///                  "attestation_public_keys": [{"key_id": 3, "public_key": "<b64>"}],
///                  "checkpoint": {"epoch": 812, "root_sha256": "<hex>", "at": "…"}}]}
///
/// Members a reader doesn't know are ignored. Reading one never stores the seed anywhere.
public struct RecoveryKit: Sendable {
    public static let type = "vh.recovery-kit"
    public static let version = 1

    public enum Failure: Error, Sendable, Equatable {
        case badKit(String)
        case unsupportedVersion
        case seed(RecoverySeed.Failure)
    }

    public struct AttestationKey: Sendable, Equatable {
        public let keyID: UInt32
        public let publicKey: Data  // Ed25519, 32 bytes
    }

    public struct Checkpoint: Sendable, Equatable {
        public let epoch: UInt64
        public let rootSHA256: String
        public let at: String?
    }

    public struct Vault: Sendable, Equatable {
        public let uid: Uid
        public let originNodeID: String?
        public let originVaultID: UInt64?
        public let attestationKeys: [AttestationKey]
        public let checkpoint: Checkpoint?
    }

    public let seed: RecoverySeed
    public let vaults: [Vault]

    public func vault(_ uid: Uid) -> Vault? { vaults.first { $0.uid == uid } }

    public init(json data: Data) throws(Failure) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .badKit("not a JSON object")
        }
        guard root["type"] as? String == Self.type else { throw .badKit("not a recovery kit") }
        guard let v = root["v"] as? Int else { throw .badKit("no version") }
        guard v == Self.version else { throw .unsupportedVersion }
        guard let text = root["recovery_seed"] as? String else { throw .badKit("no recovery_seed") }
        do {
            seed = try RecoverySeed(text: text)
        } catch {
            throw .seed(error)
        }
        var out: [Vault] = []
        for entry in root["vaults"] as? [[String: Any]] ?? [] {
            guard let uidText = entry["vault_uid"] as? String, let uid = Uid(base32: uidText) else {
                throw .badKit("a vault without a valid vault_uid")
            }
            let origin = entry["origin"] as? [String: Any]
            var keys: [AttestationKey] = []
            for k in entry["attestation_public_keys"] as? [[String: Any]] ?? [] {
                guard let id = (k["key_id"] as? NSNumber)?.uint32Value, let b64 = k["public_key"] as? String,
                      let pk = Data(base64Encoded: b64), pk.count == 32
                else { throw .badKit("a malformed attestation public key") }
                keys.append(AttestationKey(keyID: id, publicKey: pk))
            }
            var checkpoint: Checkpoint?
            if let c = entry["checkpoint"] as? [String: Any] {
                guard let epoch = (c["epoch"] as? NSNumber)?.uint64Value, let root = c["root_sha256"] as? String
                else { throw .badKit("a malformed checkpoint") }
                checkpoint = Checkpoint(epoch: epoch, rootSHA256: root, at: c["at"] as? String)
            }
            out.append(Vault(uid: uid, originNodeID: origin?["node_id"] as? String,
                             originVaultID: (origin?["vault_id"] as? NSNumber)?.uint64Value, attestationKeys: keys,
                             checkpoint: checkpoint))
        }
        vaults = out
    }
}
