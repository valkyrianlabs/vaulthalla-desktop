public import Foundation
public import VHTransport
import VHContract

// The `device.*` commands of docs/pairing.md, typed by hand. They aren't in the vendored contract yet, so they travel
// as raw JSON through `WsClient.send(command:payload:)`. When the contract is refreshed, replace the bodies below with
// the generated `Ws.Device.*` requests; the call sites only see these wrappers.

/// Command names (docs/pairing.md §3–§5).
enum DeviceCommand {
    static let pairRequest = "device.pair.request"
    static let pairConfirm = "device.pair.confirm"
    static let pairStatus = "device.pair.status"
    static let serverIdentity = "device.server.identity"
    static let identityRotate = "device.identity.rotate"
}

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

    /// The code a ws error carries, if it is one of ours. `WsError` keeps codes it has no case for in
    /// `.needsConfirmation(code:message:)`; conflict and invalid have their own cases.
    public init?(_ error: WsError) {
        switch error {
        case .conflict: self = .conflict
        case .invalid: self = .invalid
        case .needsConfirmation(let code, _): self.init(rawValue: code)
        default: return nil
        }
    }
}

// MARK: - Payloads and answers

struct PairRequestPayload: Encodable {
    var name: String
    var platform: String
    var appVersion: String
    /// Lowercase hex of `SHA-256("vh-pair-commit-v1" ‖ device_spki_sha256 ‖ nonce_device)`.
    var commitment: String

    enum CodingKeys: String, CodingKey {
        case name, platform, commitment
        case appVersion = "app_version"
    }
}

struct PairRequestReply: Decodable {
    var requestID: String
    var nonceServer: String
    var expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case nonceServer = "nonce_server"
        case expiresAt = "expires_at"
    }
}

struct PairConfirmPayload: Encodable {
    var requestID: String
    var nonceDevice: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case nonceDevice = "nonce_device"
    }
}

struct PairConfirmReply: Decodable {
    var state: String
    var expiresAt: Int64?

    enum CodingKeys: String, CodingKey {
        case state
        case expiresAt = "expires_at"
    }
}

struct PairStatusPayload: Encodable {
    var requestID: String

    enum CodingKeys: String, CodingKey { case requestID = "request_id" }
}

struct PairStatusReply: Decodable {
    enum State: String, Decodable {
        case pending, approved, denied, expired
    }

    var state: State
    var nodeID: String?
    var nodeName: String?
    var deviceID: String?

    enum CodingKeys: String, CodingKey {
        case state
        case nodeID = "node_id"
        case nodeName = "node_name"
        case deviceID = "device_id"
    }
}

struct ServerIdentityReply: Decodable {
    var spkiSHA256: String
    var nextSPKISHA256: String?
    var switchAfter: Int64?

    enum CodingKeys: String, CodingKey {
        case spkiSHA256 = "spki_sha256"
        case nextSPKISHA256 = "next_spki_sha256"
        case switchAfter = "switch_after"
    }
}

struct RotatePayload: Encodable {
    /// Standard base64 of the new certificate's DER.
    var certificate: String
    var timestamp: UInt64
    /// Standard base64 of the DER ECDSA signature.
    var signature: String
}

struct RotateReply: Decodable {
    var deviceID: String

    enum CodingKeys: String, CodingKey { case deviceID = "device_id" }
}

// MARK: - Calls

extension WsClient {
    func pairRequest(_ payload: PairRequestPayload, timeout: Duration) async throws(WsError) -> PairRequestReply {
        try await device(DeviceCommand.pairRequest, payload, timeout: timeout)
    }

    func pairConfirm(_ payload: PairConfirmPayload, timeout: Duration) async throws(WsError) -> PairConfirmReply {
        try await device(DeviceCommand.pairConfirm, payload, timeout: timeout)
    }

    func pairStatus(_ payload: PairStatusPayload, timeout: Duration) async throws(WsError) -> PairStatusReply {
        try await device(DeviceCommand.pairStatus, payload, timeout: timeout)
    }

    func serverIdentity(timeout: Duration) async throws(WsError) -> ServerIdentityReply {
        try await device(DeviceCommand.serverIdentity, EmptyPayload(), timeout: timeout)
    }

    func rotateIdentity(_ payload: RotatePayload, timeout: Duration) async throws(WsError) -> RotateReply {
        try await device(DeviceCommand.identityRotate, payload, timeout: timeout)
    }

    private func device<P: Encodable, R: Decodable>(_ command: String, _ payload: P, timeout: Duration)
        async throws(WsError) -> R
    {
        let raw: JSONValue
        do {
            raw = try DeviceCoding.decoder.decode(JSONValue.self, from: DeviceCoding.encoder.encode(payload))
        } catch {
            throw .error("The \(command) request could not be encoded.")
        }
        let answer = try await send(command: command, payload: raw, timeout: timeout)
        do {
            return try DeviceCoding.decoder.decode(R.self, from: DeviceCoding.encoder.encode(answer))
        } catch {
            throw .contractMismatch("\(command): the answer doesn't have the fields docs/pairing.md specifies")
        }
    }
}

private struct EmptyPayload: Encodable {}

private enum DeviceCoding {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
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
