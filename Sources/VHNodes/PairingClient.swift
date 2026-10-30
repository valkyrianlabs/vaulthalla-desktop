public import Foundation
public import VHCore
public import VHIdentity
import VHTransport
import VHContract
import Synchronization
import os

/// Why a pairing attempt stopped without an answer from the owner. `message` is written for the person pairing.
public enum PairingFailure: Error, Hashable, Sendable {
    /// No pairing window is open on the node (`no_pairing_window`): open one in the web console or with
    /// `vh device pair`, then try again.
    case noPairingWindow
    /// Too many attempts (`rate_limited`).
    case rateLimited
    /// The node already has this Mac's key as a live device (`conflict`).
    case alreadyPaired
    /// The node's check of this Mac's request failed (`invalid`), e.g. the nonce didn't match the commitment.
    case rejected
    /// The node doesn't know the request (`device_unknown` on the pairing connection).
    case requestUnknown
    /// The server presented a different key during the attempt. Pairing stops: that is what an interception
    /// looks like.
    case serverIdentityChanged
    /// The listener couldn't be reached at all.
    case unreachable(endpoint: String)
    /// The connection kept dropping after the first contact.
    case connectionLost
    /// A request got no answer in time.
    case noAnswer
    /// The server answered something docs/pairing.md doesn't allow.
    case protocolViolation(String)
    /// Any other refusal, with the server's text.
    case server(String)
    /// This Mac couldn't do its part (keys, randomness).
    case local(String)

    public var message: String {
        switch self {
        case .noPairingWindow:
            "No pairing window is open on the server."
        case .rateLimited:
            "Too many pairing attempts. Wait a minute, then try again."
        case .alreadyPaired:
            "The server already has this Mac's key as a paired device."
        case .rejected:
            "The server couldn't verify this Mac's pairing request. Try again."
        case .requestUnknown:
            "The server doesn't know this pairing request any more. Try again."
        case .serverIdentityChanged:
            "The server's identity changed during pairing, so pairing stopped. Someone on the network may be "
                + "intercepting the connection."
        case .unreachable(let endpoint):
            "Can't reach the Vaulthalla device listener at \(endpoint)."
        case .connectionLost:
            "The connection to the server kept dropping."
        case .noAnswer:
            "The server didn't answer in time."
        case .protocolViolation(let detail):
            "The server answered in a way this version of Vaulthalla doesn't understand (\(detail))."
        case .server(let text):
            text
        case .local(let text):
            text
        }
    }
}

/// Pairs this Mac with one node (docs/pairing.md §3) on a pairing-only TLS connection.
///
/// The server's key is trusted on first use and recorded; if the connection drops, the client reconnects pinned to
/// that key, so a different server makes the handshake fail and the attempt stops (`.serverIdentityChanged`).
/// Nothing is ever sent to a second key. The device commits to its nonce (`device.pair.request`), learns the
/// server's, reveals its own (`device.pair.confirm`), shows the SAS, and long-polls `device.pair.status` until the
/// owner decides.
///
/// Each ``start()`` runs one attempt with fresh nonces (the device key is reused); starting again cancels the previous
/// attempt, and so does ``cancel()`` or dropping the stream.
public final class PairingClient: Sendable {
    public enum State: Hashable, Sendable {
        case connecting
        /// Show `code` ("Approve on <node>: 482 913") until the owner decides.
        case awaitingApproval(code: PairingCode)
        /// Pin `serverSPKI`, record the node as paired, and reconnect as a Device session.
        case approved(nodeID: String, nodeName: String, deviceID: String, serverSPKI: Data)
        case denied
        case expired
        case failed(PairingFailure)

        public var isFinal: Bool {
            switch self {
            case .connecting, .awaitingApproval: false
            case .approved, .denied, .expired, .failed: true
            }
        }
    }

    public struct Configuration: Sendable {
        public var endpoint: NodeEndpoint
        /// The name the owner sees in the approval list (the Mac's name), at most 64 characters.
        public var deviceName: String
        public var appVersion: String
        public var platform = "macOS"
        /// Wait after an immediate `pending` before asking again (docs/pairing.md §3).
        public var statusPause: Duration = .seconds(2)
        /// A `pending` that came back faster than this was not held by the daemon (no long poll).
        public var immediateReply: Duration = .seconds(1)
        /// How long one `device.pair.status` may be held (the daemon holds up to 20 s).
        public var statusTimeout: Duration = .seconds(25)
        public var requestTimeout: Duration = .seconds(15)
        public var connectTimeout: Duration = .seconds(8)
        /// Reconnects after a drop before the attempt gives up.
        public var maxReconnects = 5
        public var reconnectDelay: Duration = .milliseconds(500)

        public init(endpoint: NodeEndpoint, deviceName: String, appVersion: String) {
            self.endpoint = endpoint
            self.deviceName = deviceName
            self.appVersion = appVersion
        }
    }

    public let identity: DeviceIdentity
    public let configuration: Configuration

    private let task = Mutex<Task<Void, Never>?>(nil)
    private let log = Logger(subsystem: "sh.vaulthalla.app", category: "pairing")

    public init(identity: DeviceIdentity, configuration: Configuration) {
        self.identity = identity
        self.configuration = configuration
    }

    deinit {
        task.withLock { $0?.cancel() }
    }

    /// Runs a new attempt and streams its states. The stream ends after a final state (`State.isFinal`).
    public func start() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .unbounded)
        let attempt = Task { [identity, configuration, log] in
            let run = Attempt(identity: identity, configuration: configuration, log: log)
            await run.run { continuation.yield($0) }
            continuation.finish()
        }
        continuation.onTermination = { _ in attempt.cancel() }
        task.withLock { previous in
            previous?.cancel()
            previous = attempt
        }
        return stream
    }

    /// Stops the attempt in progress and closes its connection. The node keeps nothing from it.
    public func cancel() {
        task.withLock { $0?.cancel() }
    }
}

// MARK: - One attempt

/// The server SPKI seen on the pairing connection(s). The TLS verify block reports it on a Network.framework queue.
private final class ServerKeyRecord: Sendable {
    private let state = Mutex<(first: Data?, changed: Bool)>((nil, false))

    func observe(_ spki: Data) {
        state.withLock { state in
            if let first = state.first {
                if first != spki { state.changed = true }
            } else {
                state.first = spki
            }
        }
    }

    var spki: Data? { state.withLock { $0.first } }
    var changed: Bool { state.withLock { $0.changed } }
}

private struct Attempt {
    let identity: DeviceIdentity
    let configuration: PairingClient.Configuration
    let log: Logger

    /// Thrown inside the attempt to restart the exchange from `device.pair.request` on a new connection.
    private struct Reconnect: Error {}

    func run(_ emit: (PairingClient.State) -> Void) async {
        emit(.connecting)
        let link = Link(identity: identity, configuration: configuration)
        let final: PairingClient.State?
        do {
            final = try await exchange(link, emit)
        } catch let failure as PairingFailure {
            log.info("pairing stopped: \(String(describing: failure), privacy: .public)")
            final = .failed(failure)
        } catch is CancellationError {
            final = nil  // cancelled: no final state, the stream just ends
        } catch {
            final = .failed(.local(String(describing: error)))
        }
        // Close before reporting, so an approved Mac never holds the pairing connection open beside its session.
        await link.close()
        if let final { emit(final) }
    }

    private func exchange(_ link: Link, _ emit: (PairingClient.State) -> Void) async throws -> PairingClient.State {
        while true {
            // Commit, then reveal. A drop before the code is shown starts over with fresh nonces on a pinned
            // connection; after that, only the status poll is repeated.
            let nonce = PairingCode.makeNonce()
            let commitment: Data
            do {
                commitment = try PairingCode.commitment(deviceSPKISHA256: identity.spkiSHA256, deviceNonce: nonce)
            } catch {
                throw PairingFailure.local("Couldn't prepare the pairing request: \(error)")
            }

            let request: Ws.Device.Pair.Request.Response
            let confirm: Ws.Device.Pair.Confirm.Response
            do {
                request = try await link.call { client in
                    try await client.send(
                        Ws.Device.Pair.Request.self,
                        payload: .init(
                            name: String(configuration.deviceName.prefix(64)), platform: configuration.platform,
                            appVersion: configuration.appVersion, commitment: Hex.encode(commitment)),
                        timeout: configuration.requestTimeout)
                }
                guard let serverNonce = Hex.decode(request.nonceServer, length: PairingCode.nonceLength) else {
                    throw PairingFailure.protocolViolation("nonce_server is not 32 bytes of hex")
                }
                confirm = try await link.call { client in
                    try await client.send(
                        Ws.Device.Pair.Confirm.self,
                        payload: .init(requestID: request.requestID, nonceDevice: Hex.encode(nonce)),
                        timeout: configuration.requestTimeout)
                }
                guard confirm.state == Ws.Device.Pair.Confirm.Response.State.pending else {
                    throw PairingFailure.protocolViolation("confirm answered \(confirm.state)")
                }

                guard let serverSPKI = link.serverKey.spki else {
                    throw PairingFailure.protocolViolation("no server certificate was seen")
                }
                let code = try PairingCode(
                    serverSPKISHA256: serverSPKI, deviceSPKISHA256: identity.spkiSHA256, deviceNonce: nonce,
                    serverNonce: serverNonce)
                emit(.awaitingApproval(code: code))
                return try await awaitDecision(link, requestID: request.requestID, serverSPKI: serverSPKI)
            } catch is Reconnect {
                continue
            }
        }
    }

    private func awaitDecision(_ link: Link, requestID: String, serverSPKI: Data) async throws -> PairingClient.State {
        let clock = ContinuousClock()
        while true {
            let started = clock.now
            let (decision, status): (PairDecision, Ws.Device.Pair.Status.Response)
            do {
                (decision, status) = try await link.call(retryingAfterDrop: true) { client in
                    try await client.pairStatus(requestID: requestID, timeout: configuration.statusTimeout)
                }
            } catch PairingFailure.noAnswer {
                continue  // a held poll that outlived our timeout: ask again
            }
            switch decision {
            case .pending:
                if clock.now - started < configuration.immediateReply {
                    try await Task.sleep(for: configuration.statusPause)
                }
            case .denied:
                return .denied
            case .expired:
                return .expired
            case .approved:
                guard let nodeID = status.nodeID, !nodeID.isEmpty, let deviceID = status.deviceID else {
                    throw PairingFailure.protocolViolation("approved without node_id or device_id")
                }
                // The daemon names the key it approved; it must be the one this connection presented.
                guard deviceID.lowercased() == identity.deviceID else {
                    throw PairingFailure.protocolViolation("the server approved a different device id")
                }
                return .approved(nodeID: nodeID, nodeName: status.nodeName ?? "", deviceID: identity.deviceID,
                                 serverSPKI: serverSPKI)
            }
        }
    }

    /// The pairing connection. The first `WsClient` trusts on first use; after a drop it is replaced by one pinned
    /// to the recorded key. The `WsClient`'s own reconnects are pushed out of the way (a very long backoff), so every
    /// reconnect goes through here.
    actor Link {
        let identity: DeviceIdentity
        let configuration: PairingClient.Configuration
        nonisolated let serverKey = ServerKeyRecord()
        private var client: WsClient?
        private var reconnects = 0
        private var everConnected = false

        init(identity: DeviceIdentity, configuration: PairingClient.Configuration) {
            self.identity = identity
            self.configuration = configuration
        }

        func close() async {
            await client?.close()
            client = nil
        }

        /// Runs `body` on the current connection, mapping refusals to `PairingFailure`. After a drop it reconnects
        /// (pinned) and either retries `body` (`retryingAfterDrop`) or throws `Reconnect` so the caller restarts.
        func call<R: Sendable>(retryingAfterDrop: Bool = false,
                               _ body: @Sendable (WsClient) async throws -> R) async throws -> R {
            while true {
                try Task.checkCancellation()
                let client = try current()
                let outcome: Result<R, WsError>
                do {
                    outcome = .success(try await body(client))
                } catch let error as WsError {
                    outcome = .failure(error)
                }
                try Task.checkCancellation()
                try checkServerKey()
                switch outcome {
                case .success(let result):
                    everConnected = true
                    return result
                case .failure(let error):
                    switch error {
                    case .disconnected:
                        try await reconnect(after: client)
                        if !retryingAfterDrop { throw Reconnect() }
                    case .timeout:
                        throw PairingFailure.noAnswer
                    case .cancelled:
                        throw CancellationError()
                    default:
                        throw PairingFailure(error)
                    }
                }
            }
        }

        private func checkServerKey() throws {
            if serverKey.changed { throw PairingFailure.serverIdentityChanged }
        }

        private func current() throws -> WsClient {
            if let client { return client }
            let record = serverKey
            let pin = record.spki
            let made = try Self.makeClient(identity: identity, configuration: configuration, pin: pin,
                                           record: record)
            client = made
            return made
        }

        private func reconnect(after failed: WsClient) async throws {
            let state = await failed.connectionState
            await failed.close()
            client = nil
            // A pinned connection that failed its handshake: the server now has another key.
            if case .failed = state, serverKey.spki != nil { throw PairingFailure.serverIdentityChanged }
            // Never reached at all: report the address rather than retrying an unreachable host.
            guard everConnected || serverKey.spki != nil else {
                throw PairingFailure.unreachable(endpoint: configuration.endpoint.description)
            }
            reconnects += 1
            guard reconnects <= configuration.maxReconnects else { throw PairingFailure.connectionLost }
            try await Task.sleep(for: configuration.reconnectDelay * reconnects)
        }

        private static func makeClient(identity: DeviceIdentity, configuration: PairingClient.Configuration,
                                       pin: Data?, record: ServerKeyRecord) throws -> WsClient {
            do {
                return try WsClient(configuration: .init(
                    endpoint: configuration.endpoint,
                    security: .mutualTLS(identity: identity.secIdentity, serverSPKIPin: pin,
                                         onServerSPKI: { record.observe($0) }),
                    reconnect: ReconnectPolicy(base: .seconds(3600), cap: .seconds(3600)),
                    connectTimeout: configuration.connectTimeout))
            } catch {
                throw PairingFailure.local("Invalid node address \(configuration.endpoint.description).")
            }
        }
    }
}

extension PairingFailure {
    /// The failure a refusal on the pairing connection stands for.
    init(_ error: WsError) {
        switch DeviceRefusal(error) {
        case .noPairingWindow: self = .noPairingWindow
        case .rateLimited: self = .rateLimited
        case .conflict: self = .alreadyPaired
        case .invalid: self = .rejected
        case .deviceUnknown: self = .requestUnknown
        case nil:
            switch error {
            case .contractMismatch(let detail): self = .protocolViolation(detail)
            case .timeout: self = .noAnswer
            case .disconnected: self = .connectionLost
            default: self = .server(error.message)
            }
        }
    }
}
