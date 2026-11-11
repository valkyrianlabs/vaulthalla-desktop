public import CryptoKit
public import Foundation

/// Vaulthalla Cloud's installation request signatures, VHC1-Ed25519 (valkyrianlabs/vaulthalla-cloud
/// docs/design/installation-requests.md). Every request Desktop makes as a linked installation carries
///
///     Authorization: VHC1-Ed25519 Installation=<id>, Timestamp=<unix s>, Nonce=<base64url>, Signature=<base64url>
///     X-VHC-Content-SHA256: <hex SHA-256 of the body>
///
/// signed over the nine lines of `stringToSign`. CryptoKit's Ed25519 signatures are randomized, so the documented
/// vector's signature is checked by verifying it, and Desktop's own by the cloud's verifier (both are valid Ed25519).
public enum VHC1 {
    public static let contentHashHeader = "X-VHC-Content-SHA256"

    public struct Fields: Sendable, Equatable {
        public var method: String        // upper case
        public var path: String          // as sent, still percent-encoded
        public var query: String         // as sent, without "?"
        public var host: String          // lower case, without :443
        public var installation: String
        public var timestamp: Int64
        public var nonce: String         // base64url of 16 random bytes
        public var bodySHA256: String    // lower-case hex

        public init(method: String, path: String, query: String, host: String, installation: String, timestamp: Int64,
                    nonce: String, bodySHA256: String) {
            self.method = method
            self.path = path
            self.query = query
            self.host = host
            self.installation = installation
            self.timestamp = timestamp
            self.nonce = nonce
            self.bodySHA256 = bodySHA256
        }
    }

    public static func stringToSign(_ f: Fields) -> String {
        ["VHC1-Ed25519", f.method, f.path, f.query, f.host, f.installation, String(f.timestamp), f.nonce, f.bodySHA256]
            .joined(separator: "\n")
    }

    /// The two headers for `f`, signed with the installation's key.
    public static func headers(_ f: Fields, key: Curve25519.Signing.PrivateKey) throws -> [String: String] {
        let signature = try key.signature(for: Data(stringToSign(f).utf8))
        return ["Authorization": "VHC1-Ed25519 Installation=\(f.installation), Timestamp=\(f.timestamp), "
                    + "Nonce=\(f.nonce), Signature=\(Base64URL.encode(signature))",
                contentHashHeader: f.bodySHA256]
    }

    public static func sha256Hex(_ data: some DataProtocol) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func newNonce() -> String { Base64URL.encode(Data(SymmetricKey(size: .init(bitCount: 128)).withUnsafeBytes { Data($0) })) }

    /// The first 8 bytes of SHA-256(public key) as xxxx-xxxx-xxxx-xxxx: what the installation and the approver compare.
    public static func fingerprint(_ publicKey: some DataProtocol) -> String {
        groups(sha256Hex(publicKey))
    }

    static func groups(_ hex: String) -> String {
        let h = Array(hex)
        return [0, 4, 8, 12].map { String(h[$0 ..< $0 + 4]) }.joined(separator: "-")
    }
}

/// RFC 4648 §5 base64url without padding, strict on decode (the alphabet only, no padding, zero trailing bits).
public enum Base64URL {
    public static func encode(_ data: some DataProtocol) -> String {
        Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), encode(data) == text else { return nil }
        return data
    }
}

/// The restore code both devices show for a Vaulthalla Cloud restore (the cloud's docs/design/recovery-restore.md):
/// SHA-256("vhc-restore-v1\n" + vault uid + "\n" + base64(temporary public key)), the first 8 bytes as four groups of
/// four hex digits. Desktop computes it itself: the cloud's `restore_code` field is a convenience, never trusted.
public enum RestoreCode {
    public static func of(vaultUid: String, temporaryPublicKey: Data) -> String {
        VHC1.groups(VHC1.sha256Hex(Data(("vhc-restore-v1\n" + vaultUid + "\n" + temporaryPublicKey.base64EncodedString()).utf8)))
    }
}
