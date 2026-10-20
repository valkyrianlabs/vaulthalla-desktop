public import Foundation
import CryptoKit

/// The short authentication string (SAS) both sides show during pairing (docs/pairing.md §3).
///
/// ```
/// digest = SHA-256("vh-pair-v1" ‖ server_spki_sha256 ‖ device_spki_sha256 ‖ nonce_device ‖ nonce_server)
/// code   = UInt64(big-endian digest[0..<8]) mod 1_000_000, zero-padded to 6 digits
/// ```
///
/// Every input has a fixed length (32 bytes), so the concatenation is unambiguous without length prefixes. The
/// device commits to its nonce before it learns the server's (``commitment(deviceSPKISHA256:deviceNonce:)``); without
/// that, a man in the middle could grind its own nonce until the two legs' codes collide.
public struct PairingCode: Sendable, Hashable, CustomStringConvertible {
    /// Domain separator for the SAS digest.
    public static let domain = Data("vh-pair-v1".utf8)
    /// Domain separator for the device's nonce commitment.
    public static let commitmentDomain = Data("vh-pair-commit-v1".utf8)
    /// Length of `nonce_device` and `nonce_server`.
    public static let nonceLength = 32

    /// Exactly six ASCII digits, e.g. `"482913"`.
    public let digits: String

    /// Computes the code from the four protocol values (each 32 bytes).
    public init(serverSPKISHA256: Data, deviceSPKISHA256: Data, deviceNonce: Data, serverNonce: Data) throws {
        try Self.check(serverSPKISHA256, "server_spki_sha256", SPKI.hashLength)
        try Self.check(deviceSPKISHA256, "device_spki_sha256", SPKI.hashLength)
        try Self.check(deviceNonce, "nonce_device", Self.nonceLength)
        try Self.check(serverNonce, "nonce_server", Self.nonceLength)

        var hasher = SHA256()
        hasher.update(data: Self.domain)
        hasher.update(data: serverSPKISHA256)
        hasher.update(data: deviceSPKISHA256)
        hasher.update(data: deviceNonce)
        hasher.update(data: serverNonce)
        let digest = Array(hasher.finalize())

        // 2^64 mod 10^6 = 551616, so the modulo bias is about 3e-14 per code: irrelevant for a 6-digit SAS.
        let value = digest[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        let text = String(value)
        digits = String(repeating: "0", count: 6 - text.count) + text
    }

    /// The code as people read it: `"482 913"`.
    public var formatted: String {
        "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    public var description: String { formatted }

    /// 32 bytes from the system CSPRNG, for `nonce_device`.
    public static func makeNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = generator.next() }
        return Data(bytes)
    }

    /// `SHA-256("vh-pair-commit-v1" ‖ device_spki_sha256 ‖ nonce_device)`, sent in `device.pair.request` before
    /// the server reveals `nonce_server`.
    public static func commitment(deviceSPKISHA256: Data, deviceNonce: Data) throws -> Data {
        try check(deviceSPKISHA256, "device_spki_sha256", SPKI.hashLength)
        try check(deviceNonce, "nonce_device", nonceLength)
        var hasher = SHA256()
        hasher.update(data: commitmentDomain)
        hasher.update(data: deviceSPKISHA256)
        hasher.update(data: deviceNonce)
        return Data(hasher.finalize())
    }

    static func check(_ value: Data, _ field: String, _ length: Int) throws {
        guard value.count == length else {
            throw IdentityError.invalidLength(field: field, expected: length, actual: value.count)
        }
    }
}
