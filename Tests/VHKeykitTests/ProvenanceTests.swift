import Foundation
import Testing
@testable import VHKeykit

/// Key provenance through the C API against vl-keykit's `vectors/key_provenance.json` (vaulthalla-server's, verbatim):
/// the key checks, the server's and the Mac's attestations, the Mac's origin vault ids, and the negatives.
struct ProvenanceTests {
    static var doc: [String: Any] { VHC.load("key_provenance") }
    static func list(_ name: String) -> [[String: Any]] { doc[name] as! [[String: Any]] }
    static func hex(_ s: Any?) -> Data {
        let t = s as! String
        return Data(stride(from: 0, to: t.count, by: 2).map {
            UInt8(t[t.index(t.startIndex, offsetBy: $0) ..< t.index(t.startIndex, offsetBy: $0 + 2)], radix: 16)!
        })
    }

    @Test func keyChecksMatch() throws {
        for c in Self.list("key_checks") {
            let got = try Self.hex(c["key_hex"]).withUnsafeBytes {
                try Provenance.keyCheck(key: $0, vaultID: (c["vault_id"] as! NSNumber).uint64Value,
                                        version: (c["version"] as! NSNumber).uint32Value)
            }
            #expect(got == c["key_check"] as? String)
        }
    }

    @Test func attestationsMatchAndVerify() throws {
        for a in Self.list("attestations") {
            let node = a["node_id"] as! String, check = a["key_check"] as! String
            let vault = (a["vault_id"] as! NSNumber).uint64Value, version = (a["version"] as! NSNumber).uint32Value
            let seed = Self.hex(a["seed_hex"])
            let pk = try seed.withUnsafeBytes { try Provenance.publicKey(seed: $0) }
            let sig = try seed.withUnsafeBytes {
                try Provenance.attest(seed: $0, nodeID: node, vaultID: vault, version: version, keyCheck: check)
            }
            #expect(pk == Self.hex(a["public_key_hex"]) && sig == Self.hex(a["signature_hex"]))
            #expect(Provenance.verify(publicKey: pk, nodeID: node, vaultID: vault, version: version, keyCheck: check, signature: sig))
        }
    }

    @Test func macOriginVaultIDs() throws {
        for u in Self.list("mac_origin_vault_ids") {
            let uid = try #require(Uid32Test.bytes(u["vault_uid"] as! String))
            #expect(try Provenance.macOriginVaultID(uid: uid) == (u["vault_id"] as! NSNumber).uint32Value)
        }
        #expect(throws: KeykitError.self) { _ = try Provenance.macOriginVaultID(uid: Data(count: 15)) }
    }

    @Test func negativesAreRefused() throws {
        for n in Self.list("negative") {
            switch n["what"] as! String {
            case "verify":
                #expect(!Provenance.verify(publicKey: Self.hex(n["public_key_hex"]), nodeID: n["node_id"] as! String,
                                           vaultID: (n["vault_id"] as! NSNumber).uint64Value,
                                           version: (n["version"] as! NSNumber).uint32Value,
                                           keyCheck: n["key_check"] as! String, signature: Self.hex(n["signature_hex"])))
            case "key_check":
                #expect(throws: KeykitError.self) {
                    _ = try Self.hex(n["key_hex"]).withUnsafeBytes {
                        try Provenance.keyCheck(key: $0, vaultID: (n["vault_id"] as! NSNumber).uint64Value, version: 1)
                    }
                }
            default:
                let seed = Data(count: 32)
                #expect(throws: KeykitError.self) {
                    _ = try seed.withUnsafeBytes {
                        try Provenance.attest(seed: $0, nodeID: n["node_id"] as! String,
                                              vaultID: (n["vault_id"] as! NSNumber).uint64Value, version: 3,
                                              keyCheck: n["key_check"] as! String)
                    }
                }
            }
        }
    }
}

/// A vault uid's 16 bytes from its lower-case Crockford base32 text, for the vectors.
enum Uid32Test {
    static func bytes(_ text: String) -> Data? {
        let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
        var n: [UInt8] = []
        var acc = 0, bits = 0
        for ch in text {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            acc = (acc << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                n.append(UInt8((acc >> bits) & 0xff))
            }
        }
        return n.count == 16 ? Data(n) : nil
    }
}
