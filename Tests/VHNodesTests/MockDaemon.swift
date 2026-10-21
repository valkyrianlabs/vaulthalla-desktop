import CryptoKit
import Foundation
import Network
import Security
import Synchronization
import VHContract
import VHIdentity

/// The daemon's device listener as docs/pairing.md describes it, on 127.0.0.1, built like VHTransportTests'
/// `TestServer` but answering by itself: TLS 1.3 that requires a client certificate and accepts any, then per
/// connection, at handshake time, a Device session (the client SPKI is a live device's current or previous key) or a
/// pairing-only connection. Pairing-only connections accept `device.pair.*` and refuse everything else with
/// `device_unknown`.
///
/// It computes the SAS, the commitment check and the rotation checks on its own (CryptoKit and Security, not
/// `PairingCode`/`RotationProof`), so the tests compare two implementations. Faults are scripted per test.
final class MockDaemon: Sendable {
    enum Decision: String, Sendable { case approved, denied, expired }

    /// A scripted answer to a contract command.
    enum Reply: Sendable {
        case ok(JSONValue)
        case refuse(String, code: String)
    }

    typealias Responder = @Sendable (JSONValue) -> Reply

    enum RotateFault: Sendable {
        /// Drop the connection before looking at the request (the daemon never saw it).
        case dropBeforeProcessing
        /// Apply the rotation, then drop the connection instead of answering (the reply is lost).
        case dropAfterProcessing
    }

    struct Device: Sendable {
        var spki: Data
        var previous: Data?
        var revoked = false
    }

    struct PairRequest: Sendable {
        var id: String
        var spki: Data
        var commitment: Data
        var nonceServer: Data
        /// The daemon's SAS, set by confirm.
        var code: String?
        var decision: Decision?
    }

    struct State {
        var serverIdentity: DeviceIdentity
        var epoch = 0
        var windowOpen = true
        var devices: [Device] = []
        var requests: [String: PairRequest] = [:]
        var heldStatus: [String: [Inbound]] = [:]
        /// Answer `device.pair.status` at once instead of holding it (no long poll).
        var immediateStatus = false
        var corruptCommitments = false
        /// On the next `device.pair.confirm`: switch to this identity (dropping every connection) instead of answering.
        var swapOnConfirm: DeviceIdentity?
        var rotateFaults: [RotateFault] = []
        var announcedNext: Data?
        /// Commands as (epoch, session kind, command).
        var log: [(epoch: Int, device: Bool, command: String)] = []
        var connections = 0
        var rotations: [Data] = []
        /// Scripted answers to contract commands on Device sessions (``answer(_:after:_:)``); others get `{}`.
        var responders: [String: (delay: Duration?, respond: Responder)] = [:]
        /// Every payload a Device session sent, per command.
        var payloads: [String: [JSONValue]] = [:]
        var peers: [ObjectIdentifier: Peer] = [:]
        var listener: NWListener?
    }

    let state: Mutex<State>
    private let queue = DispatchQueue(label: "vh.test.daemon")
    private let portValue = Mutex<UInt16>(0)
    var port: UInt16 { portValue.withLock { $0 } }

    static let nodeID = "node-7f3a"
    static let nodeName = "vh-test"

    // MARK: Lifecycle

    static func start(identity: DeviceIdentity) async throws -> MockDaemon {
        let daemon = MockDaemon(identity: identity)
        let port = try await daemon.listen(identity: identity, port: nil)
        daemon.portValue.withLock { $0 = port }
        return daemon
    }

    private init(identity: DeviceIdentity) {
        state = Mutex(State(serverIdentity: identity))
    }

    func stop() {
        let (listener, peers) = state.withLock { state in
            defer { state.peers.removeAll(); state.listener = nil }
            return (state.listener, Array(state.peers.values))
        }
        peers.forEach { $0.connection.cancel() }
        listener?.cancel()
    }

    var serverSPKI: Data { state.withLock { $0.serverIdentity.spkiSHA256 } }

    /// Restarts the listener on the same port with another server key, dropping every connection: a reinstalled
    /// server, or someone else answering at the address.
    func swapIdentity(_ identity: DeviceIdentity) async throws {
        stop()
        state.withLock { $0.serverIdentity = identity; $0.epoch += 1 }
        // The old socket lets go of the port asynchronously: retry the bind briefly.
        var attempts = 0
        while true {
            do {
                _ = try await listen(identity: identity, port: port)
                return
            } catch let error as NWError where attempts < 100 {
                guard case .posix(.EADDRINUSE) = error else { throw error }
                attempts += 1
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// Drops every connection, as a daemon restart would.
    func dropConnections() {
        let peers = state.withLock { state in defer { state.peers.removeAll() }; return Array(state.peers.values) }
        peers.forEach { $0.connection.cancel() }
    }

    // MARK: Test controls

    func register(_ spki: Data) {
        state.withLock { $0.devices.append(Device(spki: spki)) }
    }

    /// `device.revoke`: the key gets pairing-only connections from now on, and its live sessions close.
    func revoke(_ spki: Data) {
        let peers = state.withLock { state -> [Peer] in
            for index in state.devices.indices where state.devices[index].spki == spki {
                state.devices[index].revoked = true
            }
            return state.peers.values.filter { $0.session.withLock { $0?.device } == spki }
        }
        peers.forEach { $0.connection.cancel() }
    }

    /// The live device row with `spki` as its current or previous key.
    func device(matching spki: Data) -> Device? {
        state.withLock { $0.devices.first { !$0.revoked && ($0.spki == spki || $0.previous == spki) } }
    }

    /// Waits for a confirmed request and returns its id and the daemon's SAS.
    func confirmedRequest(within timeout: Duration = .seconds(5)) async -> (id: String, code: String)? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let found = state.withLock({ $0.requests.values.first { $0.code != nil } }) {
                return (found.id, found.code!)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// The owner's decision (approve with the right code, deny, or the window closing): answers held polls.
    func decide(_ requestID: String, _ decision: Decision) {
        let held = state.withLock { state -> [Inbound] in
            guard var request = state.requests[requestID] else { return [] }
            request.decision = decision
            state.requests[requestID] = request
            if decision == .approved { state.devices.append(Device(spki: request.spki)) }
            return state.heldStatus.removeValue(forKey: requestID) ?? []
        }
        for inbound in held { answerStatus(inbound, requestID: requestID) }
    }

    var commands: [(epoch: Int, device: Bool, command: String)] { state.withLock { $0.log } }

    /// Answers `command` on Device sessions with `respond(payload)`, after `delay` when given.
    func answer(_ command: String, after delay: Duration? = nil, _ respond: @escaping Responder) {
        state.withLock { $0.responders[command] = (delay, respond) }
    }

    /// The payloads Device sessions sent with `command`, in order.
    func payloads(of command: String) -> [JSONValue] {
        state.withLock { $0.payloads[command] ?? [] }
    }

    /// How often Device sessions sent `command`.
    func count(of command: String) -> Int {
        state.withLock { state in state.log.filter { $0.device && $0.command == command }.count }
    }
    var connectionCount: Int { state.withLock { $0.connections } }

    // MARK: Listener

    private func listen(identity: DeviceIdentity, port: UInt16?) async throws -> UInt16 {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_local_identity(security, sec_identity_create(identity.secIdentity)!)
        sec_protocol_options_set_peer_authentication_required(security, true)
        // Like the daemon's verify callback: no chains, no dates. Authorization is by SPKI, after the handshake.
        sec_protocol_options_set_verify_block(security, { _, _, complete in complete(true) }, queue)

        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
        let listener = try NWListener(using: parameters)
        let epoch = state.withLock { $0.epoch }

        let once = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { update in
                let result: Result<Void, any Error>? = switch update {
                case .ready: .success(())
                case .failed(let error): .failure(error)
                default: nil
                }
                guard let result, once.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.newConnectionHandler = { [self] connection in
                accept(connection, epoch: epoch)
            }
            listener.start(queue: queue)
        }
        state.withLock { $0.listener = listener }
        return listener.port?.rawValue ?? 0
    }

    private func accept(_ connection: NWConnection, epoch: Int) {
        let peer = Peer(connection, epoch: epoch)
        state.withLock { $0.peers[ObjectIdentifier(connection)] = peer; $0.connections += 1 }
        connection.start(queue: queue)
        receive(peer)
    }

    private func receive(_ peer: Peer) {
        peer.connection.receiveMessage { [self] content, context, _, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            // The client went away (error, close frame, or end of stream): close our side too.
            if error != nil || metadata?.opcode == .close || (content == nil && metadata == nil) {
                state.withLock { _ = $0.peers.removeValue(forKey: ObjectIdentifier(peer.connection)) }
                return peer.connection.cancel()
            }
            if let content, let frame = try? JSONDecoder().decode(JSONValue.self, from: content) {
                handle(Inbound(frame: frame, peer: peer))
            }
            receive(peer)
        }
    }

    /// Connections the daemon still has open.
    var openConnections: Int { state.withLock { $0.peers.count } }

    // MARK: Commands

    private func handle(_ inbound: Inbound) {
        let session = inbound.peer.authorize(daemon: self)
        state.withLock { $0.log.append((inbound.peer.epoch, session.device != nil, inbound.command)) }
        let payload = inbound.frame["payload"] ?? .null

        switch (inbound.command, session.device) {
        case ("device.pair.request", nil): pairRequest(inbound, payload, session)
        case ("device.pair.request", .some): inbound.refuse("This key is already a paired device.", code: "conflict")
        case ("device.pair.confirm", nil): pairConfirm(inbound, payload, session)
        case ("device.pair.status", nil): pairStatus(inbound, payload, session)
        case ("device.server.identity", .some):
            let (spki, next) = state.withLock { ($0.serverIdentity.spkiSHA256, $0.announcedNext) }
            var data: JSONObject = ["spki_sha256": .string(spki.hex)]
            if let next { data["next_spki_sha256"] = .string(next.hex); data["switch_after"] = 1_900_000_000 }
            inbound.ok(.object(data))
        case ("device.identity.rotate", .some(let device)): rotate(inbound, payload, device, session)
        case (_, nil): inbound.refuse("Unknown device.", code: "device_unknown")
        case (let command, .some):
            let responder = state.withLock { state in
                state.payloads[command, default: []].append(payload)
                return state.responders[command]
            }
            guard let responder else { return inbound.ok(.object([:])) }
            let reply = { @Sendable in
                switch responder.respond(payload) {
                case .ok(let data): inbound.ok(data)
                case .refuse(let message, let code): inbound.refuse(message, code: code)
                }
            }
            if let delay = responder.delay {
                let (seconds, attoseconds) = delay.components
                queue.asyncAfter(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18, execute: reply)
            } else {
                reply()
            }
        }
    }

    private func pairRequest(_ inbound: Inbound, _ payload: JSONValue, _ session: Session) {
        guard state.withLock({ $0.windowOpen }) else {
            return inbound.refuse("No pairing window is open.", code: "no_pairing_window")
        }
        guard let commitment = payload["commitment"]?.stringValue.flatMap(Data.init(hex:)), commitment.count == 32,
              payload["platform"]?.stringValue == "macOS", let name = payload["name"]?.stringValue,
              !name.isEmpty, name.count <= 64
        else { return inbound.refuse("Malformed request.", code: "invalid") }

        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let request = PairRequest(id: UUID().uuidString.lowercased(), spki: session.spki, commitment: commitment,
                                  nonceServer: nonce)
        state.withLock { state in
            // One live request per client key: a new one replaces it.
            state.requests = state.requests.filter { $0.value.spki != session.spki }
            state.requests[request.id] = request
        }
        inbound.ok(["request_id": .string(request.id), "nonce_server": .string(nonce.hex),
                    "expires_at": .integer(Int64(Date.now.timeIntervalSince1970) + 600)])
    }

    private func pairConfirm(_ inbound: Inbound, _ payload: JSONValue, _ session: Session) {
        if let swap = state.withLock({ state in defer { state.swapOnConfirm = nil }; return state.swapOnConfirm }) {
            // Whoever answers next has another key. The confirm is never answered.
            Task { try? await swapIdentity(swap) }
            return
        }
        guard let id = payload["request_id"]?.stringValue,
              let nonceDevice = payload["nonce_device"]?.stringValue.flatMap(Data.init(hex:)), nonceDevice.count == 32
        else { return inbound.refuse("Malformed confirm.", code: "invalid") }

        let refusal = state.withLock { state -> String? in
            guard var request = state.requests[id], request.spki == session.spki else {
                return "device_unknown"
            }
            var commitment = request.commitment
            if state.corruptCommitments { commitment[0] ^= 0x01 }
            let expected = Data(SHA256.hash(data: Data("vh-pair-commit-v1".utf8) + session.spki + nonceDevice))
            guard expected == commitment else {
                state.requests[id] = nil
                return "invalid"
            }
            let digest = Array(SHA256.hash(data: Data("vh-pair-v1".utf8) + state.serverIdentity.spkiSHA256
                + session.spki + nonceDevice + request.nonceServer))
            let value = digest[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
            request.code = String(format: "%06llu", value)
            state.requests[id] = request
            return nil
        }
        if let refusal { return inbound.refuse("Pairing request refused.", code: refusal) }
        inbound.ok(["state": "pending", "expires_at": .integer(Int64(Date.now.timeIntervalSince1970) + 300)])
    }

    private func pairStatus(_ inbound: Inbound, _ payload: JSONValue, _ session: Session) {
        guard let id = payload["request_id"]?.stringValue else {
            return inbound.refuse("Malformed status.", code: "invalid")
        }
        let action = state.withLock { state -> String in
            guard let request = state.requests[id], request.spki == session.spki else { return "unknown" }
            if request.decision != nil || state.immediateStatus { return "answer" }
            state.heldStatus[id, default: []].append(inbound)
            return "held"
        }
        switch action {
        case "unknown": inbound.refuse("Unknown pairing request.", code: "device_unknown")
        case "answer": answerStatus(inbound, requestID: id)
        default: break
        }
    }

    private func answerStatus(_ inbound: Inbound, requestID: String) {
        let request = state.withLock { $0.requests[requestID] }
        guard let request else { return inbound.refuse("Unknown pairing request.", code: "device_unknown") }
        switch request.decision {
        case .approved:
            inbound.ok(["state": "approved", "node_id": .string(Self.nodeID), "node_name": .string(Self.nodeName),
                        "device_id": .string(request.spki.hex)])
        case .denied: inbound.ok(["state": "denied"])
        case .expired: inbound.ok(["state": "expired"])
        case nil: inbound.ok(["state": "pending"])
        }
    }

    private func rotate(_ inbound: Inbound, _ payload: JSONValue, _ device: Data, _ session: Session) {
        let fault = state.withLock { state in state.rotateFaults.isEmpty ? nil : state.rotateFaults.removeFirst() }
        if fault == .dropBeforeProcessing { return inbound.peer.connection.cancel() }

        guard let certificateDER = payload["certificate"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
              let signature = payload["signature"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
              let timestamp = payload["timestamp"]?.integerValue,
              let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let newSPKI = try? spkiSHA256(certificate)
        else { return inbound.refuse("Malformed rotation.", code: "invalid") }

        let outcome = state.withLock { state -> String? in
            guard let index = state.devices.firstIndex(where: { !$0.revoked && $0.spki == device }) else {
                // A retry from the previous key naming the same new key succeeds; another key is a conflict.
                if state.devices.contains(where: { $0.previous == session.spki && $0.spki == newSPKI }) { return nil }
                return "conflict"
            }
            guard session.spki == state.devices[index].spki else { return "conflict" }
            if state.devices.contains(where: { $0.spki == newSPKI || $0.previous == newSPKI }) { return "conflict" }
            guard abs(Int64(Date.now.timeIntervalSince1970) - timestamp) <= 300 else { return "invalid" }
            var message = Data("vh-device-rotate-v1".utf8) + newSPKI + state.serverIdentity.spkiSHA256
            withUnsafeBytes(of: UInt64(timestamp).bigEndian) { message.append(contentsOf: $0) }
            guard let peerKey = session.publicKey,
                  SecKeyVerifySignature(peerKey, .ecdsaSignatureMessageX962SHA256, message as CFData,
                                        signature as CFData, nil)
            else { return "invalid" }
            state.devices[index].previous = state.devices[index].spki
            state.devices[index].spki = newSPKI
            state.rotations.append(newSPKI)
            return nil
        }
        if let outcome { return inbound.refuse("Rotation refused.", code: outcome) }
        if fault == .dropAfterProcessing { return inbound.peer.connection.cancel() }
        inbound.ok(["device_id": .string(newSPKI.hex)])
    }
}

// MARK: - Connections

/// How a connection was authorized at its handshake. `@unchecked`: `SecKey` is an immutable CF object.
struct Session: @unchecked Sendable {
    var spki: Data
    var publicKey: SecKey?
    /// The device row's current key when this is a Device session; nil for pairing-only.
    var device: Data?
}

final class Peer: Sendable {
    let connection: NWConnection
    let epoch: Int
    let session = Mutex<Session?>(nil)

    init(_ connection: NWConnection, epoch: Int) {
        self.connection = connection
        self.epoch = epoch
    }

    /// The connection's authorization, decided once from the client certificate (docs/pairing.md §2, step 3). A
    /// handshake with a device's current key ends its previous key's grace (§4).
    func authorize(daemon: MockDaemon) -> Session {
        if let known = session.withLock({ $0 }) { return known }
        var leaf: SecCertificate?
        if let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            _ = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
                if leaf == nil { leaf = sec_certificate_copy_ref(certificate).takeRetainedValue() }
            }
        }
        let spki = leaf.flatMap { try? spkiSHA256($0) } ?? Data()
        let device = daemon.state.withLock { state -> Data? in
            if let index = state.devices.firstIndex(where: { !$0.revoked && $0.spki == spki }) {
                state.devices[index].previous = nil
                return spki
            }
            return state.devices.first { !$0.revoked && $0.previous == spki }?.spki
        }
        let decided = Session(spki: spki, publicKey: leaf.flatMap(SecCertificateCopyKey), device: device)
        session.withLock { $0 = decided }
        return decided
    }

    func send(_ value: JSONValue) {
        let data = try! JSONEncoder().encode(value)
        let context = NWConnection.ContentContext(identifier: "daemon",
                                                  metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

struct Inbound: Sendable {
    let frame: JSONValue
    let peer: Peer

    var command: String { frame["command"]?.stringValue ?? "" }
    var requestId: String { frame["requestId"]?.stringValue ?? "" }

    func ok(_ data: JSONValue) {
        peer.send(["command": .string(command + ".response"), "status": "OK", "requestId": .string(requestId),
                   "data": data])
    }

    func refuse(_ message: String, code: String) {
        peer.send(["command": .string(command + ".response"), "status": "ERROR", "requestId": .string(requestId),
                   "error": .string(message), "data": ["code": .string(code)]])
    }
}

extension Data {
    init?(hex: String) {
        let utf8 = Array(hex.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = 0
        while index < utf8.count {
            guard let byte = UInt8(String(decoding: utf8[index..<index + 2], as: UTF8.self), radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index += 2
        }
        self.init(bytes)
    }
}
