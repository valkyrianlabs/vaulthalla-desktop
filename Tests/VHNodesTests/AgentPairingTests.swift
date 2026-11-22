import CryptoKit
import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
import VHIdentity
@testable import VHNodes
@testable import VHTransport

/// A node for an AI app's own pairing: this Mac's Device session (`ScriptedNode` answering `device.pairing.*`,
/// `device.approval.*`, `device.revoke` as docs/reference/device-approvals.md describes), and the new key's side
/// (``FakeDevice``), which computes its code with the real `PairingCode` from the nonces and the server key it sees.
final class FakePairingNode: Sendable {
    struct Request: Sendable {
        var id: String
        var deviceID: String
        var name: String
        /// The code the node shows, from the node's own view of both keys.
        var code: String
        var approvalKey: Bool
        var state: String = "pending"
    }

    struct State: Sendable {
        var window = false
        var requests: [Request] = []
        var devices: [String: Bool] = [:]  // device id → revoked
        var granted = false
        /// A relay on the new key's leg: it sees another server key, so its code differs.
        var relay = false
        /// The step-up offers a console approval only (no approval key registered for this Mac).
        var consoleOnly = false
        /// The new key's side never hears of the approval (the node stops answering after it).
        var silentAfterApproval = false
        /// `device.revoke` can't reach the node.
        var offline = false
        var requestsCarryApprovalKey = false
    }

    let session = ScriptedNode()
    let state = Mutex(State())
    let serverPin = Data(SHA256.hash(data: Data("server key".utf8)))
    let serverNodeID = "srv-node-1"
    let macDeviceID: String
    let approvalKey = SoftwareApprovalKey()

    func set(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
    var snapshot: State { state.withLock { $0 } }

    var record: Node {
        Node(id: NodeID(rawValue: "node-a"), displayName: "nas", endpoint: NodeEndpoint(host: "127.0.0.1", port: 9),
             pairing: .paired(serverSPKISHA256: serverPin, deviceID: macDeviceID, since: .now), isNamedByUser: true,
             serverNodeID: serverNodeID)
    }

    init(macDeviceID: String) {
        self.macDeviceID = macDeviceID
        let window: JSONValue = ["owner_id": 1, "opened_at": 1_790_000_000, "expires_at": 1_790_000_600]
        session.answer("device.pairing.open") { [self] _ in
            set { $0.window = true }
            return .ok(["window": window, "server_time": 1_790_000_000, "port": 36972, "remote": true])
        }
        session.answer("device.pairing.close") { [self] _ in
            set { $0.window = false }
            return .ok(["closed": true])
        }
        session.answer("device.pairing.pending") { [self] _ in
            let requests = snapshot.requests.filter { $0.state == "pending" }.map { request -> JSONValue in
                let choices = ["111111", request.code, "222222"].map(JSONValue.string)
                return ["request_id": .string(request.id), "name": .string(request.name), "platform": "macOS",
                        "app_version": "test", "source_ip": "127.0.0.1", "device_id": .string(request.deviceID),
                        "code_choices": .array(choices), "approval_key_present": .bool(request.approvalKey),
                        "created_at": 1_790_000_000, "expires_at": 1_790_000_600]
            }
            return .ok(["window": snapshot.window ? window : .null, "requests": .array(requests),
                        "server_time": 1_790_000_000])
        }
        session.answer("device.pairing.deny") { [self] json in
            let id = json["request_id"]?.stringValue
            set { state in for i in state.requests.indices where state.requests[i].id == id { state.requests[i].state = "denied" } }
            return .ok(["denied": true])
        }
        session.answer("device.approval.challenge") { [self] json in
            guard let target = json["target"]?.stringValue, let family = json["family"]?.stringValue,
                  let payload = DeviceApproval.payload(approvalContext, challenge: Self.challenge, family: family,
                                                       target: target, expiresAt: 1_790_000_120)
            else { return .refuse("bad challenge", code: "invalid") }
            return .ok(["challenge_id": "c1", "challenge": .string(Hex.encode(Self.challenge)),
                        "payload_b64": .string(payload.base64EncodedString()), "family": .string(family),
                        "target": .string(target), "expires_at": 1_790_000_120])
        }
        session.answer("device.approval.submit") { [self] json in
            guard let target = snapshot.requests.last.map({ Self.target($0) }),
                  let payload = DeviceApproval.payload(approvalContext, challenge: Self.challenge, family: "device.trust",
                                                       target: target, expiresAt: 1_790_000_120),
                  let der = json["signature_b64"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
                  let signature = try? P256.Signing.ECDSASignature(derRepresentation: der),
                  approvalKey.key.publicKey.isValidSignature(signature, for: payload)
            else { return .refuse("the signature doesn't verify", code: "invalid") }
            set { $0.granted = true }
            return .ok(["family": "device.trust", "target": .string(target), "expires_at": 1_790_000_420])
        }
        session.answer("device.pairing.approve") { [self] json in
            let id = json["request_id"]?.stringValue ?? ""
            guard let request = snapshot.requests.first(where: { $0.id == id && $0.state == "pending" }) else {
                return .refuse("no such request", code: "not_found")
            }
            let current = snapshot
            guard current.granted else {
                let methods: [String] = current.consoleOnly ? ["console_approval"] : ["device_approval", "console_approval"]
                return .fail(.stepUpRequired(WsStepUp(family: "device.trust", target: Self.target(request),
                                                      methods: methods), message: "approve"))
            }
            set { $0.granted = false }  // a target-bound grant is spent by one use
            guard json["code"]?.stringValue == request.code else {
                set { state in for i in state.requests.indices where state.requests[i].id == id { state.requests[i].state = "denied" } }
                return .refuse("wrong code", code: "invalid")
            }
            set { state in
                for i in state.requests.indices where state.requests[i].id == id { state.requests[i].state = "approved" }
                state.devices[request.deviceID] = false
            }
            return .ok(["device": Self.device(request.deviceID, name: request.name)])
        }
        session.answer("device.revoke") { [self] json in
            let id = json["device_id"]?.stringValue ?? ""
            if snapshot.offline { return .fail(.disconnected) }
            guard snapshot.devices[id] == false else { return .refuse("no such device", code: "not_found") }
            set { $0.devices[id] = true }
            return .ok(["device": Self.device(id, name: "x", revoked: true)])
        }
    }

    var approvalContext: ApprovalContext {
        ApprovalContext(nodeID: serverNodeID, serverSPKISHA256: serverPin,
                        deviceSPKISHA256: DeviceApproval.hex(macDeviceID)!)
    }

    static let challenge = Data(repeating: 0x42, count: 32)
    static func target(_ request: Request) -> String { "device.pairing.approve:\(request.id):\(request.deviceID):digest" }

    static func device(_ id: String, name: String, revoked: Bool = false) -> JSONValue {
        ["id": 7, "device_id": .string(id), "user_id": 1, "user_name": "cooper", "name": .string(name),
         "platform": "macOS", "app_version": "test", "previous_device_id": .null, "approved_by": 1,
         "created_at": 1_790_000_000, "last_seen_at": .null, "last_ip": .null,
         "revoked_at": revoked ? 1_790_000_100 : .null, "revoked": .bool(revoked)]
    }

    /// The new key's request, as `device.pair.request` + `device.pair.confirm` leave it.
    func addRequest(deviceID: String, name: String, code: String) {
        set { state in
            state.requests.append(Request(id: "req-\(state.requests.count + 1)", deviceID: deviceID, name: name,
                                          code: code, approvalKey: state.requestsCarryApprovalKey))
        }
    }

    func requestState(_ deviceID: String) -> String? {
        snapshot.requests.last { $0.deviceID == deviceID }?.state
    }
}

/// The new key's side of pairing against ``FakePairingNode``.
struct FakeDevice: AgentPairingDevice {
    let node: FakePairingNode

    func pair(identity: DeviceIdentity, endpoint: NodeEndpoint, serverPin: Data, deviceName: String,
              appVersion: String) -> AsyncStream<PairingClient.State> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.connecting)
                let deviceNonce = PairingCode.makeNonce(), serverNonce = PairingCode.makeNonce()
                let seen = node.snapshot.relay ? Data(repeating: 1, count: 32) : serverPin
                let shown = try! PairingCode(serverSPKISHA256: seen, deviceSPKISHA256: identity.spkiSHA256,
                                             deviceNonce: deviceNonce, serverNonce: serverNonce)
                let nodes = try! PairingCode(serverSPKISHA256: node.serverPin, deviceSPKISHA256: identity.spkiSHA256,
                                             deviceNonce: deviceNonce, serverNonce: serverNonce)
                node.addRequest(deviceID: identity.deviceID, name: deviceName, code: nodes.digits)
                continuation.yield(.awaitingApproval(code: shown))
                while !Task.isCancelled {
                    switch node.requestState(identity.deviceID) {
                    case "approved" where !node.snapshot.silentAfterApproval:
                        continuation.yield(.approved(nodeID: node.serverNodeID, nodeName: "nas",
                                                     deviceID: identity.deviceID, serverSPKI: serverPin))
                        continuation.finish()
                        return
                    case "denied":
                        continuation.yield(.denied)
                        continuation.finish()
                        return
                    default:
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension KeychainSuite {
@Suite struct AgentPairingTests {
    let client = AgentClient.claudeCode
    var tag: String { AgentIdentity.keyTag(node: NodeID(rawValue: "node-a"), client: client) }

    private func run(_ setup: (FakePairingNode) -> Void = { _ in }, timeout: Duration = .seconds(20),
                     _ check: (FakePairingNode, TestRegistry, DeviceKeys, Result<AgentIdentity, AgentPairing.Failure>)
                         async throws -> Void) async throws {
        let shared = try KeychainFixture.require()
        try await TestRegistry.with { registry in
            let fake = FakePairingNode(macDeviceID: shared.device.deviceID)
            setup(fake)
            _ = try registry.owner.add(fake.record)
            let keys = registry.ownerKeys(shared.store)
            var pairing = AgentPairing(keys: keys, session: fake.session, signer: fake.approvalKey,
                                       device: FakeDevice(node: fake))
            pairing.timeout = timeout
            pairing.requestWait = .seconds(3)
            pairing.pollInterval = .milliseconds(20)
            let outcome = await AgentPairings(store: registry.owner, keys: keys)
                .pair(fake.record.id, client: client, using: pairing, macName: "Cooper's Mac", appVersion: "test")
            // Deleted before the next test makes a key under the same tag (the file keychain fails under overlap).
            do {
                try await check(fake, registry, keys, outcome)
            } catch {
                try? await keys.deleteIdentity(for: tag)
                throw error
            }
            try? await keys.deleteIdentity(for: tag)
        }
    }

    static func pairings(_ registry: TestRegistry, _ keys: DeviceKeys) -> AgentPairings {
        var pairings = AgentPairings(store: registry.owner, keys: keys)
        pairings.ownSessionTimeout = .milliseconds(500)
        return pairings
    }

    /// Nothing left on this Mac or the node: no key, no record, no live request or device, the window closed.
    private func expectNothingLeft(_ fake: FakePairingNode, _ registry: TestRegistry, _ keys: DeviceKeys) async throws {
        #expect(try await keys.identity(for: tag) == nil, "the new key is deleted")
        #expect(try registry.consumer.reload().first?.agentIdentities.isEmpty == true)
        let state = fake.snapshot
        #expect(!state.window, "the window is closed")
        #expect(!state.requests.contains { $0.state == "pending" }, "no request is left pending")
        #expect(!state.devices.values.contains(false), "no device of the new key is left live")
    }

    @Test func theWholeExchangeMakesADeviceOfItsOwn() async throws {
        try await run { fake, registry, keys, outcome in
            let identity = try outcome.get()
            #expect(identity.deviceName == "Claude Code on Cooper's Mac")
            #expect(identity.serverSPKISHA256 == fake.serverPin)
            let key = try #require(try await keys.identity(for: tag))
            #expect(key.deviceID == identity.deviceID && key.deviceID != fake.macDeviceID)
            #expect(identity.certificate == key.certificateDER)
            let saved = try #require(try registry.consumer.reload().first)
            #expect(saved.agentIdentities["claude-code"] == identity)
            #expect(fake.snapshot.devices[identity.deviceID] == false)
            #expect(!fake.snapshot.window)
            // One approval key signature, on the step-up; the request carried no approval key.
            #expect(fake.session.count(of: "device.approval.submit") == 1)
            #expect(fake.session.count(of: "device.pairing.approve") == 2)
            #expect(fake.snapshot.requests.allSatisfy { !$0.approvalKey })
        }
    }

    @Test func aCodeMismatchIsDeniedAndLeavesNothing() async throws {
        try await run({ $0.set { $0.relay = true } }) { fake, registry, keys, outcome in
            #expect(outcome == .failure(.codeMismatch))
            #expect(fake.session.count(of: "device.pairing.approve") == 0, "nothing was approved")
            #expect(fake.snapshot.requests.last?.state == "denied")
            try await expectNothingLeft(fake, registry, keys)
        }
    }

    @Test func noApprovalKeyOnTheNodeLeavesNothing() async throws {
        try await run({ $0.set { $0.consoleOnly = true } }) { fake, registry, keys, outcome in
            #expect(outcome == .failure(.noApprovalKey))
            #expect(fake.snapshot.requests.last?.state == "denied")
            try await expectNothingLeft(fake, registry, keys)
        }
    }

    @Test func aRequestCarryingAnApprovalKeyIsRefused() async throws {
        try await run({ $0.set { $0.requestsCarryApprovalKey = true } }) { fake, registry, keys, outcome in
            guard case .failure(.unexpectedRequest) = outcome else { Issue.record("\(outcome)"); return }
            try await expectNothingLeft(fake, registry, keys)
        }
    }

    @Test func aTimedOutApprovalRevokesWhatTheNodeApproved() async throws {
        try await run({ $0.set { $0.silentAfterApproval = true } }, timeout: .seconds(2)) { fake, registry, keys, outcome in
            #expect(outcome == .failure(.timedOut))
            #expect(fake.session.count(of: "device.revoke") == 1, "the device the node approved is revoked")
            try await expectNothingLeft(fake, registry, keys)
        }
    }

    @Test func aConsumerCantPair() async throws {
        let shared = try KeychainFixture.require()
        let fake = FakePairingNode(macDeviceID: shared.device.deviceID)
        let pairing = AgentPairing(keys: TestRegistry.consumerKeys(shared.store), session: fake.session,
                                   signer: fake.approvalKey, device: FakeDevice(node: fake))
        #expect(await pairing.pair(fake.record, client: client, macName: "Mac", appVersion: "t") == .failure(.notOwner))
        #expect(fake.session.count(of: "device.pairing.open") == 0)
    }

    @Test func removalRevokesOrQueuesAndRetries() async throws {
        try await run { fake, registry, keys, outcome in
            let identity = try outcome.get()
            let pairings = Self.pairings(registry, keys)
            fake.set { $0.offline = true }
            let removal = await pairings.remove(client, from: fake.record.id, macSession: fake.session)
            guard case .queued = removal else { Issue.record("\(removal)"); return }
            // The key is gone now; the revocation waits in the record.
            #expect(try await keys.identity(for: tag) == nil)
            var saved = try #require(try registry.consumer.reload().first)
            #expect(saved.agentIdentities.isEmpty)
            #expect(saved.pendingAgentRevocations.map(\.deviceID) == [identity.deviceID])
            #expect(await pairings.retryPending(on: fake.record.id, macSession: fake.session).count == 1)

            fake.set { $0.offline = false }
            #expect(await pairings.retryPending(on: fake.record.id, macSession: fake.session).isEmpty)
            saved = try #require(try registry.consumer.reload().first)
            #expect(saved.pendingAgentRevocations.isEmpty)
            #expect(fake.snapshot.devices[identity.deviceID] == true, "revoked on the node")
            #expect(await pairings.remove(client, from: fake.record.id, macSession: fake.session) == .nothingToRemove)
        }
    }

    @Test func removalOnAReachableNodeRevokesAtOnce() async throws {
        try await run { fake, registry, keys, outcome in
            let identity = try outcome.get()
            let pairings = Self.pairings(registry, keys)
            #expect(await pairings.remove(client, from: fake.record.id, macSession: fake.session) == .revoked)
            #expect(fake.snapshot.devices[identity.deviceID] == true)
            #expect(try await keys.identity(for: tag) == nil)
            #expect(try registry.consumer.reload().first?.pendingAgentRevocations.isEmpty == true)
        }
    }

    @Test func removingTheNodeNamesWhatCouldntBeRevoked() async throws {
        try await run { fake, registry, keys, outcome in
            let identity = try outcome.get()
            fake.set { $0.offline = true }
            let last = try #require(try registry.consumer.reload().first)
            let left = await Self.pairings(registry, keys).revokeAll(of: last, macSession: fake.session)
            #expect(left == [identity.deviceName])
            #expect(try await keys.identity(for: tag) == nil)
        }
    }

    /// The bridge's side, as a consumer: its own key where it has one, this Mac's only by choice, never this Mac's
    /// because its own was refused.
    @Test func theReaderPresentsTheIdentityForItsClient() async throws {
        try await run { fake, registry, keys, outcome in
            let identity = try outcome.get()
            let consumer = TestRegistry.consumerKeys(try KeychainFixture.require().store)
            var access = AgentAccess()
            let reader = { (client: AgentClient?) in
                CredentialReader(registry: registry.consumer, keys: consumer, client: client, access: { [access] in access })
            }
            let node = try #require(try registry.consumer.reload().first)

            // Its own pairing.
            let own = try await reader(.claudeCode).load(node)
            #expect(own.identity.deviceID == identity.deviceID && own.serverPin == fake.serverPin)
            // No client: this Mac's, as before.
            #expect(try await reader(nil).load(node).identity.deviceID == fake.macDeviceID)
            // Codex has none; by default (no choice recorded) it uses this Mac's.
            #expect(try await reader(.codex).load(node).identity.deviceID == fake.macDeviceID)
            // With own pairing chosen for Codex and none made, the node is unavailable to it.
            access.setOwnPairing(true, for: .codex)
            await #expect(throws: CredentialFailure.self) { try await reader(.codex).load(node) }
            access.setMacPairing(true, on: node.id, for: .codex)
            #expect(try await reader(.codex).load(node).identity.deviceID == fake.macDeviceID)

            // The node revoked Claude Code's own pairing: unavailable, even with this Mac's pairing chosen for it.
            var refused = node
            refused.agentIdentities["claude-code"]?.refusedAt = .now
            _ = try registry.owner.update(refused)
            access.setOwnPairing(false, for: .claudeCode)
            do {
                _ = try await reader(.claudeCode).load(refused)
                Issue.record("a refused own pairing must not fall back")
            } catch let error as CredentialFailure {
                guard case .unavailable(let reason) = error else { Issue.record("\(error)"); return }
                #expect(reason.contains("no longer accepts"))
            }
        }
    }
}
}

/// Records written before AI apps had their own pairings still decode, and one without them encodes as before.
@Suite struct AgentRecordCompatibilityTests {
    @Test func previousRecordsDecodeAndRoundTripUnchanged() throws {
        let previous = Data(#"""
            {"version":1,"nodes":[{"id":"node-a","displayName":"nas","endpoint":{"host":"10.0.0.2","port":36972},
            "pairing":{"paired":{"serverSPKISHA256":"WlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlo=",
            "deviceID":"abab","since":0}},"isNamedByUser":true,"serverNodeID":"srv"}]}
            """#.utf8)
        struct Envelope: Codable { var version: Int; var nodes: [Node] }
        let decoded = try JSONDecoder().decode(Envelope.self, from: previous)
        let node = try #require(decoded.nodes.first)
        #expect(node.agentIdentities.isEmpty && node.pendingAgentRevocations.isEmpty)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any]
        #expect(encoded?["agentIdentities"] == nil && encoded?["pendingAgentRevocations"] == nil)

        var paired = node
        paired.agentIdentities["codex"] = AgentIdentity(deviceID: "cd", deviceName: "Codex on Mac", certificate: Data([1]),
                                                        serverSPKISHA256: Data(repeating: 1, count: 32), pairedAt: .now)
        paired.pendingAgentRevocations = [PendingAgentRevocation(client: .claudeDesktop, deviceID: "ef",
                                                                 deviceName: "Claude on Mac", since: .now)]
        let again = try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(paired))
        #expect(again == paired)
    }

    @Test func accessFilesFromTheOneClickVersionStillMeanThisMacsPairing() throws {
        let previous = try JSONDecoder().decode(AgentAccess.self, from: Data(#"{"version":1,"excluded":{"codex":["b"]}}"#.utf8))
        #expect(previous.usesMacPairing(NodeID(rawValue: "a"), for: .codex))
        #expect(!previous.prefersOwnPairing(.codex))
        var access = previous
        access.setOwnPairing(true, for: .codex)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(access)) as? [String: Any]
        #expect(written?["version"] as? Int == 2, "an older bridge refuses it instead of ignoring the choice")
        #expect(!access.usesMacPairing(NodeID(rawValue: "a"), for: .codex))
    }
}
