public import Foundation
import CryptoKit
import VLKeykit

/// Key provenance through vl-keykit (`attestation.hpp`, the one implementation vaulthalla-server signs and proves with;
/// spec 03 §6.5): the key check of a vault key version, this Mac's attestation over it, and the origin vault id of a
/// vault a Mac created. Nothing here re-implements a format; Swift only marshals.
public enum Provenance {
    /// The key check (32 lower-case hex digits) of `key` (32 bytes) as version `version` of the origin's vault `vaultID`.
    public static func keyCheck(key: UnsafeRawBufferPointer, vaultID: UInt64, version: UInt32) throws(KeykitError) -> String {
        try textOutput(Int(VL_KEYKIT_KEY_CHECK_TEXT_SIZE)) { out, n in
            vl_keykit_key_check(key.bindMemory(to: UInt8.self).baseAddress, key.count, vaultID, version, out, n)
        }
    }

    /// The Ed25519 public key (32 bytes) of a 32-byte attestation seed.
    public static func publicKey(seed: UnsafeRawBufferPointer) throws(KeykitError) -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        try check(vl_keykit_attestation_public_key(seed.bindMemory(to: UInt8.self).baseAddress, seed.count, &out))
        return Data(out)
    }

    /// The seed's attestation (64 bytes) of version `version`, key check `keyCheck`, of vault `vaultID` at `nodeID`.
    public static func attest(seed: UnsafeRawBufferPointer, nodeID: String, vaultID: UInt64, version: UInt32,
                              keyCheck: String) throws(KeykitError) -> Data {
        var out = [UInt8](repeating: 0, count: 64)
        try check(nodeID.withText { n, nn in
            keyCheck.withText { c, cn in
                vl_keykit_attest(seed.bindMemory(to: UInt8.self).baseAddress, seed.count, n, nn, vaultID, version, c, cn, &out)
            }
        })
        return Data(out)
    }

    /// Whether `signature` is `publicKey`'s attestation over those fields (anything malformed is false).
    public static func verify(publicKey: Data, nodeID: String, vaultID: UInt64, version: UInt32, keyCheck: String,
                              signature: Data) -> Bool {
        var valid: Int32 = 0
        let status = publicKey.withBytes { pk, pkn in
            nodeID.withText { n, nn in
                keyCheck.withText { c, cn in
                    signature.withBytes { s, sn in
                        vl_keykit_attestation_verify(pk, pkn, n, nn, vaultID, version, c, cn, s, sn, &valid)
                    }
                }
            }
        }
        return status == VL_KEYKIT_OK && valid == 1
    }

    /// The origin vault id of a vault a Mac created (`vault_id` in its key checks and attestations), from its uid.
    public static func macOriginVaultID(uid: Data) throws(KeykitError) -> UInt32 {
        var out: UInt32 = 0
        try uid.withFixed(16) { p throws(KeykitError) in try check(vl_keykit_mac_origin_vault_id(p, &out)) }
        return out
    }

    /// The id this Mac's attestation key goes by (`key_id`, in a server's 1 ... 2^31 - 1): derived from the public key,
    /// so it needs no counter and a new key gets a new id. Every attestation carries the public key too.
    public static func keyID(publicKey: Data) -> UInt32 {
        let digest = Array(SHA256.hash(data: publicKey))
        let head = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
        return 1 + head % 2_147_483_647
    }
}
