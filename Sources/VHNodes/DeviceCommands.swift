public import Foundation
public import VHTransport
import VHContract

// The `device.*` commands of docs/pairing.md travel as the generated `Ws.Device.*` requests. What lives here is the
// little the contract doesn't say: the refusal codes the device listener uses, the pairing states as a closed set,
// and the next-key announcement of §5 on `device.server.identity`.

/// The refusal codes the device listener uses (`data.code` of an error answer).
public enum DeviceRefusal: String, Sendable, Hashable {
    /// `device.pair.request` while no pairing window is open on the node.
    case noPairingWindow = "no_pairing_window"
    /// Too many requests from this address or in this window.
    case rateLimited = "rate_limited"
    /// The key is already a live device (pairing), or a rotation names a different new key.
    case conflict
    /// A check failed: the commitment didn't match, a field is malformed, the timestamp is stale.
    case invalid
    /// The connection isn't a Device session: the key is unknown or revoked (the daemon doesn't say which).
    case deviceUnknown = "device_unknown"

    /// The code a ws error carries, if it is one of ours: conflict and invalid have their own `WsError` cases, the
    /// others arrive as `.refused(code:message:)` (no `device.*` command declares them as confirmations).
    public init?(_ error: WsError) {
        guard let code = error.code else { return nil }
        self.init(rawValue: code)
    }
}

/// Where a pairing request stands (`device.pair.status`, §3). The contract types the state as a string.
enum PairDecision: String, Sendable {
    case pending, approved, denied, expired
}

/// `device.server.identity` with the next-key announcement of docs/pairing.md §5. The vendored contract types only
/// `spki_sha256` (the daemon doesn't announce a rotation yet); this is the generated command and payload with the two
/// announcement members as optionals, so both answers decode.
enum ServerIdentityAnnouncement: WsRequest {
    static let command = Ws.Device.Server.Identity.command
    typealias Payload = Ws.Device.Server.Identity.Payload

    struct Response: Decodable, Sendable {
        var spkiSHA256: String
        var nextSPKISHA256: String?
        var switchAfter: Int64?

        enum CodingKeys: String, CodingKey {
            case spkiSHA256 = "spki_sha256"
            case nextSPKISHA256 = "next_spki_sha256"
            case switchAfter = "switch_after"
        }
    }
}

extension WsClient {
    /// `device.pair.status`, with a state outside the contract's set reported as a contract mismatch.
    func pairStatus(requestID: String, timeout: Duration) async throws(WsError)
        -> (decision: PairDecision, reply: Ws.Device.Pair.Status.Response)
    {
        let reply = try await send(Ws.Device.Pair.Status.self, payload: .init(requestID: requestID), timeout: timeout)
        guard let decision = PairDecision(rawValue: reply.state) else {
            throw .contractMismatch("\(WsCommand.devicePairStatus.rawValue): unknown state \(reply.state)")
        }
        return (decision, reply)
    }
}

// MARK: - Encodings (docs/pairing.md §1)

enum Hex {
    /// Lowercase hex, two characters per byte. Only for public values: hashes, nonces, commitments.
    static func encode(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Decodes hex of exactly `length` bytes (either case); nil for anything else.
    static func decode(_ text: String, length: Int) -> Data? {
        let utf8 = Array(text.utf8)
        guard utf8.count == length * 2 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        var index = 0
        while index < utf8.count {
            guard let high = nibble(utf8[index]), let low = nibble(utf8[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        return Data(bytes)
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

extension Data {
    /// A short, readable form of a hash for people (`3ac2baf6…8fc1`); the full value is the identity.
    public var shortFingerprint: String {
        let hex = Hex.encode(self)
        guard hex.count > 12 else { return hex }
        return "\(hex.prefix(8))…\(hex.suffix(4))"
    }
}
