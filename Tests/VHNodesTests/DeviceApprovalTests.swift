import CryptoKit
import Foundation
import Testing
import VHContract
import VHCore
@testable import VHNodes
@testable import VHTransport

/// The device approval payload against the server's shared vectors (core/test-assets/device/approval-vectors.json,
/// vendored verbatim), and the step-up round trip: challenge, the payload check, the signature, the resent request.
struct DeviceApprovalTests {
    static var vectors: [String: Any] {
        let url = Bundle.module.url(forResource: "approval-vectors", withExtension: "json", subdirectory: "Resources")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    static func hex(_ s: Any?) -> Data { DeviceApproval.hex(s as! String)! }

    static func build(_ fields: [String: Any]) -> Data? {
        DeviceApproval.payload(ApprovalContext(nodeID: fields["node_id"] as! String,
                                               serverSPKISHA256: hex(fields["server_spki_sha256"]),
                                               deviceSPKISHA256: hex(fields["approving_device_spki_sha256"])),
                               challenge: hex(fields["challenge"]), family: fields["family"] as! String,
                               target: fields["target"] as! String, expiresAt: (fields["expires_at"] as! NSNumber).int64Value)
    }

    @Test func buildsThePayloadByteForByte() throws {
        let positive = Self.vectors["positive"] as! [String: Any]
        let payload = try #require(Self.build(positive["fields"] as! [String: Any]))
        #expect(payload == Self.hex(positive["payload_hex"]))
        // The vector's signature verifies under the vector's key, over exactly these bytes.
        let key = Self.vectors["approval_key"] as! [String: Any]
        let signing = try P256.Signing.PrivateKey(rawRepresentation: Self.hex(key["private_scalar_hex"]))
        #expect(signing.publicKey.derRepresentation.base64EncodedString() == key["spki_der_b64"] as? String)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded: positive["signature_der_b64"] as! String)!)
        #expect(signing.publicKey.isValidSignature(signature, for: payload))
        for n in Self.vectors["negative"] as! [[String: Any]] {
            #expect(Self.build(n["fields"] as! [String: Any]) == Self.hex(n["payload_hex"]), "\(n["name"]!)")
            #expect(Self.build(n["fields"] as! [String: Any]) != payload, "\(n["name"]!)")
        }
        for n in Self.vectors["no_payload"] as! [[String: Any]] {
            #expect(Self.build(n["fields"] as! [String: Any]) == nil, "\(n["name"]!)")
        }
    }

    @Test func answersAStepUpAndResends() async throws {
        let positive = Self.vectors["positive"] as! [String: Any]
        let fields = positive["fields"] as! [String: Any]
        let context = ApprovalContext(nodeID: fields["node_id"] as! String, serverSPKISHA256: Self.hex(fields["server_spki_sha256"]),
                                      deviceSPKISHA256: Self.hex(fields["approving_device_spki_sha256"]))
        let signer = SoftwareApprovalKey()
        let node = ScriptedNode()
        let target = fields["target"] as! String
        let challengeHex = fields["challenge"] as! String
        let stepUp = WsStepUp(family: "keys", target: target, methods: ["device_approval", "console_approval"])
        let confirmed = Shared(false)
        let granted = Shared(false)
        node.answer("cloud.key.confirm") { _ in
            if granted.value {
                confirmed.value = true
                return .ok(["generation": ["generation": 1, "fingerprint": "f", "state": "pinned", "reason": "initial",
                                           "link": "initial", "x25519_public": "x", "confirmed_by": .null, "confirmed_at": .null],
                            "replacement": false, "vaults": []])
            }
            return .fail(.stepUpRequired(stepUp, message: "approve"))
        }
        let payload = DeviceApproval.payload(context, challenge: Self.hex(fields["challenge"]), family: "keys", target: target,
                                             expiresAt: 1798761600)!
        node.answer("device.approval.challenge") { _ in
            .ok(["challenge_id": "c1", "challenge": .string(challengeHex),
                 "payload_b64": .string(payload.base64EncodedString()), "family": "keys", "target": .string(target),
                 "expires_at": 1798761600])
        }
        node.answer("device.approval.submit") { json in
            guard case .string(let b64) = json["signature_b64"], let der = Data(base64Encoded: b64),
                  let sig = try? P256.Signing.ECDSASignature(derRepresentation: der),
                  signer.key.publicKey.isValidSignature(sig, for: payload)
            else { return .refuse("bad signature", code: "invalid") }
            granted.value = true
            return .ok(["family": "keys", "target": .string(target), "expires_at": 1798761900])
        }
        _ = try await DeviceApproval.send(Ws.Cloud.Key.Confirm.self, payload: .init(fingerprint: "f"), signer: signer,
                                           context: context, via: node)
        #expect(confirmed.value)
        #expect(node.count(of: "cloud.key.confirm") == 2)

        // A payload for another node is never signed.
        granted.value = false
        let other = ApprovalContext(nodeID: "another-node", serverSPKISHA256: context.serverSPKISHA256,
                                    deviceSPKISHA256: context.deviceSPKISHA256)
        await #expect(throws: DeviceApprovalError.payloadMismatch) {
            try await DeviceApproval.approve(stepUp, signer: signer, context: other, via: node)
        }
        #expect(node.count(of: "device.approval.submit") == 1)
        // A family the key can't approve goes to the console.
        await #expect(throws: DeviceApprovalError.self) {
            try await DeviceApproval.approve(WsStepUp(family: "secrets", target: nil, methods: ["console_approval"]),
                                             signer: signer, context: context, via: node)
        }
    }
}
