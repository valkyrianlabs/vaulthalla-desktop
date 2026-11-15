public import CryptoKit
public import Foundation
public import VHContract
public import VHTransport

/// This Mac's **approval key** for one node (server #361, docs/reference/device-approvals.md): a second P-256 key,
/// in the Secure Enclave, every signature asking for Touch ID or the Mac's password. It answers a command's
/// `step_up_required` for the families the server lets it (`keys`, `device.trust`): `cloud.key.confirm`,
/// `vault.keys.recipients.add`, `vault.remote.attach` and the like. CryptoKit signs; the payload is the server's and is
/// checked byte for byte against what this Mac knows before anything is signed.
public protocol ApprovalSigner: Sendable {
    /// The key's SubjectPublicKeyInfo (91 bytes of DER).
    var publicKeySPKI: Data { get }
    /// ECDSA P-256 over SHA-256 of `payload`, DER. May ask for Touch ID.
    func sign(_ payload: Data) throws -> Data
}

/// A Secure Enclave approval key.
public struct EnclaveApprovalKey: ApprovalSigner {
    public let key: SecureEnclave.P256.Signing.PrivateKey
    public var publicKeySPKI: Data { key.publicKey.derRepresentation }
    public var storedRepresentation: Data { key.dataRepresentation }

    /// A new key; with `userPresence` every signature asks for Touch ID or the password (a signed build only: an
    /// unsigned process can't make a key with an explicit access control).
    public static func create(userPresence: Bool) throws -> EnclaveApprovalKey {
        guard userPresence else { return EnclaveApprovalKey(key: try SecureEnclave.P256.Signing.PrivateKey()) }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence], &error)
        else { throw DeviceApprovalError.keyUnavailable }
        return EnclaveApprovalKey(key: try SecureEnclave.P256.Signing.PrivateKey(accessControl: access))
    }

    public init(storedRepresentation: Data) throws {
        key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: storedRepresentation)
    }

    init(key: SecureEnclave.P256.Signing.PrivateKey) { self.key = key }

    public func sign(_ payload: Data) throws -> Data { try key.signature(for: payload).derRepresentation }
}

/// A software approval key (tests; Macs without a Secure Enclave).
public struct SoftwareApprovalKey: ApprovalSigner {
    public let key: P256.Signing.PrivateKey
    public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) { self.key = key }
    public var publicKeySPKI: Data { key.publicKey.derRepresentation }
    public func sign(_ payload: Data) throws -> Data { try key.signature(for: payload).derRepresentation }
}

public enum DeviceApprovalError: Error, Hashable, Sendable {
    /// The node's challenge isn't for this node, server key, device, family, target or expiry.
    case payloadMismatch
    /// The node wants a console approval: a person approves in the web console with a passkey.
    case consoleApprovalRequired(WsStepUp)
    /// The console approval was denied or expired.
    case notApproved(String)
    case keyUnavailable
}

/// What this Mac knows about a paired node, which the approval payload must name.
public struct ApprovalContext: Hashable, Sendable {
    /// The node id `device.pair.status` reported (`Node.serverNodeID`).
    public var nodeID: String
    /// SHA-256 of the SPKI of the node's device listener certificate: the pin.
    public var serverSPKISHA256: Data
    /// SHA-256 of this Mac's own mTLS key SPKI (its device id).
    public var deviceSPKISHA256: Data

    public init(nodeID: String, serverSPKISHA256: Data, deviceSPKISHA256: Data) {
        self.nodeID = nodeID
        self.serverSPKISHA256 = serverSPKISHA256
        self.deviceSPKISHA256 = deviceSPKISHA256
    }
}

public enum DeviceApproval {
    /// The payload an approval key signs, byte for byte (device-approvals.md, "Challenge and signature"):
    /// "vh-device-approval-v1" 0 node_id 0 server_spki_sha256[32] approving_device_spki_sha256[32] challenge[32]
    /// family 0 target 0 UInt64BE(expires_at). nil when a field can't be written (a NUL in a text, a wrong length).
    public static func payload(_ context: ApprovalContext, challenge: Data, family: String, target: String,
                               expiresAt: Int64) -> Data? {
        let texts = [context.nodeID, family, target]
        guard texts.allSatisfy({ !$0.utf8.contains(0) }), !context.nodeID.isEmpty, !family.isEmpty, !target.isEmpty,
              context.serverSPKISHA256.count == 32,
              context.deviceSPKISHA256.count == 32, challenge.count == 32, expiresAt >= 0
        else { return nil }
        var out = Data("vh-device-approval-v1".utf8)
        out.append(0)
        out.append(Data(context.nodeID.utf8))
        out.append(0)
        out.append(context.serverSPKISHA256)
        out.append(context.deviceSPKISHA256)
        out.append(challenge)
        out.append(Data(family.utf8))
        out.append(0)
        out.append(Data(target.utf8))
        out.append(0)
        withUnsafeBytes(of: UInt64(expiresAt).bigEndian) { out.append(contentsOf: $0) }
        return out
    }

    /// Answers `stepUp` with the approval key: asks for a challenge, checks the node's payload is exactly the one
    /// this Mac builds from what it knows, signs it and submits. The grant is then on this session for one use.
    public static func approve(_ stepUp: WsStepUp, signer: any ApprovalSigner, context: ApprovalContext,
                               via transport: any NodeTransport) async throws {
        guard stepUp.approvalKeyMayAnswer, let target = stepUp.target,
              let family = Ws.Device.Approval.Challenge.Payload.Family(rawValue: stepUp.family)
        else { throw DeviceApprovalError.consoleApprovalRequired(stepUp) }
        let c = try await transport.send(Ws.Device.Approval.Challenge.self, payload: .init(family: family, target: target))
        guard c.family == stepUp.family, c.target == target, let challenge = hex(c.challenge),
              let expected = payload(context, challenge: challenge, family: c.family, target: c.target, expiresAt: c.expiresAt),
              Data(base64Encoded: c.payloadB64) == expected
        else { throw DeviceApprovalError.payloadMismatch }
        let signature = try signer.sign(expected)
        _ = try await transport.send(Ws.Device.Approval.Submit.self,
                                     payload: .init(challengeID: c.challengeID, signatureB64: signature.base64EncodedString()))
    }

    /// Sends `request`; a `step_up_required` the approval key may answer is answered (one Touch ID) and the request
    /// sent once more. Any other refusal is the caller's.
    public static func send<R: WsRequest>(_ request: R.Type, payload: R.Payload, signer: (any ApprovalSigner)?,
                                          context: ApprovalContext?, via transport: any NodeTransport) async throws -> R.Response {
        do {
            return try await transport.send(request, payload: payload)
        } catch .stepUpRequired(let stepUp, _) {
            guard let signer, let context else { throw DeviceApprovalError.consoleApprovalRequired(stepUp) }
            try await approve(stepUp, signer: signer, context: context, via: transport)
            return try await transport.send(request, payload: payload)
        }
    }

    public enum Registration: Sendable, Equatable {
        case registered
        /// A person approves it in the web console with a passkey; poll ``finishRegistration(_:signer:via:)``.
        case waitingForConsole(approvalID: String)
    }

    /// Registers the approval key with the node: the first answer is a `device.trust` step-up a person approves in
    /// the web console (`device.approval.request`); once approved, ``finishRegistration`` sends it again.
    public static func register(_ signer: any ApprovalSigner, summary: String = "Register this Mac's approval key",
                                via transport: any NodeTransport) async throws -> Registration {
        do {
            _ = try await transport.send(Ws.Device.Approval.Key.Register.self,
                                         payload: .init(publicKeySpkiB64: signer.publicKeySPKI.base64EncodedString()))
            return .registered
        } catch .stepUpRequired(let stepUp, _) {
            let r = try await transport.send(Ws.Device.Approval.Request.self,
                                             payload: .init(family: .deviceTrust, target: stepUp.target.map { .value($0) },
                                                            summary: summary))
            return .waitingForConsole(approvalID: r.approvalID)
        }
    }

    /// Checks the console approval; approved, sends the registration again (the grant is on this session).
    public static func finishRegistration(_ approvalID: String, signer: any ApprovalSigner,
                                          via transport: any NodeTransport) async throws -> Registration {
        let s = try await transport.send(Ws.Device.Approval.Status.self, payload: .init(approvalID: approvalID))
        switch s.state {
        case "pending": return .waitingForConsole(approvalID: approvalID)
        case "approved":
            _ = try await transport.send(Ws.Device.Approval.Key.Register.self,
                                         payload: .init(publicKeySpkiB64: signer.publicKeySPKI.base64EncodedString()))
            return .registered
        default: throw DeviceApprovalError.notApproved(s.state)
        }
    }

    static func hex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var out = Data()
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 2)
            guard let b = UInt8(text[i ..< j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}
