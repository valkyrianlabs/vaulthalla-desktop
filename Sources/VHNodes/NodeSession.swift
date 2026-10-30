public import Foundation
public import VHCore
public import VHIdentity
public import VHTransport
public import VHContract
import os

/// The live connection to one paired node: a `WsClient` presenting this Mac's device identity and pinning the
/// server's SPKI, kept up until ``stop()``.
///
/// After every connect it negotiates the protocol with `meta.hello` (``nodeProtocol``, docs/architecture.md §3,
/// "Protocol negotiation"): a node whose protocol range doesn't overlap this build's stays connected for display, but
/// feature calls through the session (``send(_:payload:)``, ``sendSensitive(_:payload:)``) are refused here with
/// `WsError.protocolUnsupported`. Then it asks `device.server.identity` (docs/pairing.md §5): that proves the
/// connection is a Device session (a revoked key gets `device_unknown`, and the session reports `.revoked` and stops
/// reconnecting), records an announced next server key, and promotes it once the server switched. It rotates the
/// device key when the certificate is older than ``Configuration/rotationInterval`` (§4), including the retry rules for
/// a lost reply.
///
/// **Role.** Only the credential owner rotates and reports record changes. A session is the owner when its
/// `DeviceKeys` hold the credential lease (``role``); otherwise it is a consumer (docs/architecture.md §3, "Credential
/// ownership"): it presents the identity the owner saved and never rotates (``rotateDeviceKey()`` throws), never
/// completes or cancels the owner's rotation, and reports no ``Event/recordChanged`` (it keeps an announced or
/// promoted server key in memory only). When the node refuses its key (`device_unknown`), the owner may have rotated
/// it: the session reloads the record and the Keychain (``CredentialReader``) and connects once more; a refusal that
/// survives that reload is reported as ``Status/revoked``. A server key that no longer matches the pin is retried once
/// with the reloaded record too, in case the owner promoted the announced key.
///
/// Isolation: an actor. Everything it reports (status, record changes, the identity in use) arrives in order on
/// ``events``; feature code reads ``client`` per operation, because a key rotation replaces it.
public actor NodeSession {
    public enum Status: Hashable, Sendable {
        case connecting
        case online
        case offline(reason: String)
        /// The node no longer accepts this Mac's key. Pairing again (with a new key) is the only way back.
        case revoked
    }

    public enum Event: Sendable {
        case status(Status)
        /// The node record changed and should be saved: a rotated device id (`pairing`), a revocation, or the server
        /// key pins. Owner sessions only: a consumer never writes the registry.
        case recordChanged(pairing: PairingState, nextServerSPKISHA256: Data?)
        /// The identity the session presents, once found, and after each rotation.
        case identity(deviceID: String, backend: KeyBackend)
        /// The session stopped for good and only pairing again helps: this Mac's key is missing, or the server
        /// presents a key it never announced. Reported after the `.offline` status that explains it.
        case pairingRequired
        /// What `meta.hello` settled after a connect, before that connection reports `.online`; nil when it decided
        /// nothing (no answer in time), in which case support stays unknown until the next connect.
        case protocolNegotiated(NodeProtocol?)
    }

    public struct Configuration: Sendable {
        public var reconnect = ReconnectPolicy()
        public var connectTimeout: Duration = .seconds(8)
        /// Timeout of the session's own requests (`device.server.identity`, `device.identity.rotate`).
        public var requestTimeout: Duration = .seconds(15)
        /// Device keys older than this are rotated on the next connect.
        public var rotationInterval: TimeInterval = 90 * 24 * 60 * 60
        /// The release `meta.hello` reports (`CFBundleShortVersionString`).
        public var clientVersion = Ws.Meta.Hello.clientVersion

        public init() {}
    }

    public nonisolated let nodeID: NodeID
    /// Everything the session reports, in order. One consumer; it ends when the session stops.
    public nonisolated let events: AsyncStream<Event>
    /// Owner (its keys held the credential lease when it was made) or consumer.
    public nonisolated let role: CredentialRole

    /// The node as the session knows it, including the changes it reported.
    public private(set) var node: Node
    public private(set) var status: Status = .connecting
    /// The identity the current connection presents.
    public private(set) var identity: DeviceIdentity?
    /// The connection for feature code. Replaced after a key rotation or a server key switch, so fetch it per
    /// operation rather than keeping it.
    public private(set) var client: WsClient?
    /// What `meta.hello` settled on the latest connection that answered it; nil before any did. Kept through a
    /// reconnect, replaced by the next negotiation.
    public private(set) var nodeProtocol: NodeProtocol?

    private let keys: DeviceKeys
    /// A consumer's reloads after a refusal.
    private let reader: CredentialReader
    private let configuration: Configuration
    private let eventSink: AsyncStream<Event>.Continuation
    private let log = Logger(subsystem: "sh.vaulthalla.app", category: "session")
    private var runTask: Task<Void, Never>?
    /// Rotation failed for a reason a retry won't fix (an older daemon, a refusal): don't try again this run.
    private var rotationSuppressed = false
    /// ``rotateDeviceKey()`` asked for a rotation that hasn't been attempted yet.
    private var rotationRequested = false
    /// Wakes the current connection's loop (a requested rotation); nil between connections.
    private var signals: AsyncStream<Signal>.Continuation?
    /// Consumer: the node refused a key and the credentials were reloaded since the last accepted connection.
    private var reloadedAfterRefusal = false
    /// Consumer: the server key didn't match and the record was reloaded since the last accepted connection.
    private var reloadedPins = false

    private var nodeTag: String { nodeID.rawValue }

    /// A session for `node`. Its role is `keys`' (``DeviceKeys/role``); a consumer reloads records from `registry`
    /// (nil: it keeps `node` and reloads only the Keychain).
    public init(node: Node, keys: DeviceKeys, registry: NodeStore? = nil, configuration: Configuration = Configuration()) {
        self.nodeID = node.id
        self.node = node
        self.keys = keys
        self.role = keys.role
        self.reader = CredentialReader(registry: registry, keys: keys)
        self.configuration = configuration
        (events, eventSink) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    /// Connects and keeps the connection up until ``stop()``, a revocation, or a server key mismatch.
    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    /// Rotates this Mac's key for the node now (docs/pairing.md §4, "on demand"), on the current connection or as
    /// soon as one is up, even if an earlier rotation failed. Progress is reported as usual: an ``Event/identity``
    /// with the new device id and a ``Event/recordChanged`` once the daemon took it.
    ///
    /// - Throws: ``CredentialOwnershipError/notOwner(operation:)`` on a consumer session, or once the owner let go of
    ///   the lease. Nothing is attempted.
    public func rotateDeviceKey() throws(CredentialOwnershipError) {
        guard role == .owner, keys.role == .owner else { throw .notOwner(operation: "rotate a device key") }
        rotationRequested = true
        signals?.yield(.rotate)
    }

    /// Closes the connection and ends ``events``.
    public func stop() async {
        runTask?.cancel()
        runTask = nil
        await client?.close()
        client = nil
        eventSink.finish()
    }

    // MARK: - Run loop

    /// What the connection loop reacts to: the client's states, and requests from outside.
    private enum Signal {
        case state(ConnectionState)
        case rotate
    }

    /// What ended one connection.
    private enum Ending {
        case stopped
        /// Connect again with this identity (after a rotation, or falling back from a refused pending key).
        case reconnect(DeviceIdentity, retryingRotation: Bool)
        /// A rotation's answer was lost: start over, pending key first.
        case restart
        case pinMismatch(reason: String)
        /// Consumer: the node refused this key (`device_unknown`).
        case refused(DeviceIdentity)
        case revoked
    }

    private func run() async {
        publish(.connecting)
        guard case .paired = node.pairing else {
            publish(.offline(reason: "This Mac isn't paired with the node."))
            return
        }
        var pin = currentPin
        var restartsLeft = 3
        while !Task.isCancelled {
            // Each pass starts from the Keychain: the pending replacement of an unfinished rotation goes first.
            let current: DeviceIdentity
            var pending: DeviceIdentity?
            do {
                guard let found = try await keys.identity(for: nodeTag) else {
                    publish(.offline(reason: "This Mac's key for the node is missing. Pair again."))
                    eventSink.yield(.pairingRequired)
                    return
                }
                current = found
                // Only the owner resumes its own unfinished rotation; a consumer presents what the owner saved.
                pending = role == .owner ? try await keys.pendingRotation(for: nodeTag) : nil
            } catch {
                log.error("device key lookup failed: \(String(describing: error), privacy: .public)")
                publish(.offline(reason: "This Mac's key for the node can't be read (\(error))."))
                return
            }

            var candidate = pending ?? current
            var fallback: DeviceIdentity? = pending == nil ? nil : current
            var retryRotation = false
            connections: while !Task.isCancelled {
                let ending = await connect(identity: candidate, pin: pin, isPending: fallback != nil,
                                           retryRotation: retryRotation)
                switch ending {
                case .stopped:
                    return
                case .reconnect(let identity, let retrying):
                    // A refused pending key falls back to the current one; a finished rotation moves to the new one.
                    candidate = identity
                    fallback = nil
                    retryRotation = retrying
                case .restart:
                    restartsLeft -= 1
                    if restartsLeft < 0 { rotationSuppressed = true }
                    break connections
                case .pinMismatch(let reason):
                    if role == .consumer, !reloadedPins {
                        // The owner may have promoted the announced key since this session read the record.
                        reloadedPins = true
                        if let fresh = try? reader.record(nodeID), case .paired = fresh.pairing,
                           fresh.pairing != node.pairing || fresh.nextServerSPKISHA256 != node.nextServerSPKISHA256 {
                            log.info("server key differs from the pin; retrying with the reloaded record")
                            node = fresh
                            pin = currentPin
                            continue
                        }
                    }
                    if let next = node.nextServerSPKISHA256, pin != next {
                        // The server may have switched to the key it announced: try that pin once.
                        log.info("server key differs from the pin; trying the announced next key")
                        pin = next
                        continue
                    }
                    publish(.offline(reason: reason))
                    eventSink.yield(.pairingRequired)
                    return
                case .refused(let refused):
                    guard !reloadedAfterRefusal else {
                        reportRevoked()
                        return
                    }
                    // The owner may have rotated the key: reload and connect once more with what it saved.
                    reloadedAfterRefusal = true
                    do {
                        let fresh = try await reader.reload(node, refusing: refused.deviceID)
                        log.info("device key refused; retrying with the reloaded credentials")
                        node = fresh.node
                        pin = currentPin
                        candidate = fresh.identity
                        fallback = nil
                        retryRotation = false
                    } catch {
                        switch error {
                        case .revoked:
                            reportRevoked()
                        case .missingKey:
                            publish(.offline(reason: error.description))
                            eventSink.yield(.pairingRequired)
                        default:
                            publish(.offline(reason: error.description))
                        }
                        return
                    }
                case .revoked:
                    reportRevoked()
                    return
                }
            }
        }
    }

    /// The node doesn't accept this Mac any more. The owner records it; a consumer only reports it.
    private func reportRevoked() {
        node.pairing = .revoked(at: .now)
        publish(.revoked)
        guard role == .owner else { return }
        eventSink.yield(.recordChanged(pairing: node.pairing, nextServerSPKISHA256: node.nextServerSPKISHA256))
    }

    private var currentPin: Data {
        if case .paired(let pin, _, _) = node.pairing { return pin }
        return Data()
    }

    /// Runs one `WsClient` until it has to be replaced.
    private func connect(identity: DeviceIdentity, pin: Data, isPending: Bool, retryRotation: Bool) async -> Ending {
        let made: WsClient
        do {
            made = try WsClient(configuration: .init(
                endpoint: node.endpoint,
                security: .mutualTLS(identity: identity.secIdentity, serverSPKIPin: pin, onServerSPKI: { _ in }),
                reconnect: configuration.reconnect,
                connectTimeout: configuration.connectTimeout))
        } catch {
            publish(.offline(reason: "The node's address \(node.endpoint) can't be used."))
            return .stopped
        }
        client = made
        self.identity = identity
        if !isPending { eventSink.yield(.identity(deviceID: identity.deviceID, backend: identity.backend)) }

        let states = await made.states()
        let (stream, sink) = AsyncStream.makeStream(of: Signal.self, bufferingPolicy: .unbounded)
        let relay = Task {
            for await state in states { sink.yield(.state(state)) }
            sink.finish()
        }
        signals = sink
        defer {
            relay.cancel()
            sink.finish()
        }
        await made.connect()
        var failedAttempts = 0
        var ending: Ending = .stopped
        var ready = false
        loop: for await signal in stream {
            guard case .state(let state) = signal else {
                // A requested rotation: now if this connection is a checked Device session, else after the next
                // connect (`connected` looks at the flag).
                guard rotationRequested, ready else { continue }
                rotationRequested = false
                if let result = await rotate(on: made, current: identity) {
                    ending = result
                    break loop
                }
                continue
            }
            if case .connected = state {} else { ready = false }
            switch state {
            case .idle:
                continue
            case .connecting:
                // Keep "offline" through the retries of a node that is down, instead of flickering.
                publish(failedAttempts >= 2 ? status : .connecting)
            case .reconnecting(let attempt, _):
                failedAttempts = attempt
                publish(attempt >= 2 ? .offline(reason: "Can't reach \(node.endpoint).") : .connecting)
            case .failed(let reason):
                ending = .pinMismatch(reason: "\(node.displayName) presented a different server key than the one "
                    + "this Mac paired with. If the server was reinstalled, pair again. (\(reason))")
                break loop
            case .connected:
                failedAttempts = 0
                if let result = await connected(made, identity: identity, pin: pin, isPending: isPending,
                                                retryRotation: retryRotation) {
                    ending = result
                    break loop
                }
                ready = true
            }
            if Task.isCancelled { break }
        }
        signals = nil
        await made.close()
        if client === made { client = nil }
        return Task.isCancelled ? .stopped : ending
    }

    // MARK: - Protocol

    /// Whether the node has the ws command (``NodeProtocol/supports(command:)``); unknown before a negotiation.
    public func supports(command: WsCommand) -> ProtocolSupport {
        nodeProtocol?.supports(command: command) ?? .unknown
    }

    /// Whether the node announced the capability (``NodeProtocol/supports(capability:)``); unknown before a
    /// negotiation.
    public func supports(capability: WsCapability) -> ProtocolSupport {
        nodeProtocol?.supports(capability: capability) ?? .unknown
    }

    /// The connection for a feature call, or why there is none: `.disconnected`, or `.protocolUnsupported` on a node
    /// this build can't speak to (nothing is sent).
    func featureClient() throws(WsError) -> WsClient {
        if let mismatch = nodeProtocol?.mismatch { throw .protocolUnsupported(mismatch) }
        guard let client else { throw .disconnected }
        return client
    }

    /// `meta.hello` on a fresh connection: records and reports the outcome. A legacy daemon's "Unknown command" is an
    /// outcome (``NodeProtocol/legacy``); no answer in time keeps what the last connection settled.
    private func negotiate(on client: WsClient) async {
        let settled = await client.negotiate(clientVersion: configuration.clientVersion,
                                             timeout: configuration.requestTimeout)
        if let settled {
            nodeProtocol = settled
            switch settled.state {
            case .negotiated:
                log.info("""
                    negotiated protocol \(settled.version ?? 0) with \(settled.serverVersion ?? "?", privacy: .public)
                    """)
            case .legacy:
                log.info("legacy daemon (no meta.hello): protocol \(WsProtocol.legacyVersion) assumed")
            case .incompatible:
                log.error("no common protocol: \(settled.mismatch?.message ?? "", privacy: .public)")
            }
        } else {
            log.info("meta.hello decided nothing; protocol support stays unknown")
        }
        eventSink.yield(.protocolNegotiated(settled ?? nodeProtocol))
    }

    // MARK: - Checks

    /// The checks after each connect. nil keeps the connection.
    private func connected(_ client: WsClient, identity: DeviceIdentity, pin: Data, isPending: Bool,
                           retryRotation: Bool) async -> Ending? {
        await negotiate(on: client)
        // A node that says it lacks `device.server.identity` has nothing to check; a legacy one is asked anyway.
        guard nodeProtocol?.supports(capability: .serverIdentity) != .no else {
            log.info("node announces no device.server.identity; skipping the identity check")
            publish(.online)
            return nil
        }
        let reply: ServerIdentityAnnouncement.Response
        do {
            reply = try await client.send(ServerIdentityAnnouncement.self, payload: WsNoPayload(),
                                          timeout: configuration.requestTimeout)
        } catch {
            if DeviceRefusal(error) == .deviceUnknown {
                if role == .consumer { return .refused(identity) }
                guard isPending, let current = try? await keys.identity(for: nodeTag) else { return .revoked }
                // The daemon never took the new key: fall back to the current one and send the rotation again.
                log.info("pending device key refused; falling back to the current key")
                return .reconnect(current, retryingRotation: true)
            }
            // An older daemon without the command (`isUnknownCommand`), or no answer yet: the connection itself is
            // fine.
            if error.isUnknownCommand {
                log.info("device.server.identity unknown to this daemon")
            } else {
                log.info("device.server.identity failed: \(error.message, privacy: .public)")
            }
            publish(.online)
            return nil
        }

        reloadedAfterRefusal = false
        reloadedPins = false
        var current = identity
        if isPending, role == .owner {
            // The daemon accepted the new key, so the rotation went through and only its answer was lost.
            do {
                current = try await keys.completeRotation(for: nodeTag)
                log.info("device key rotation completed after reconnect")
                recordDeviceID(current)
                eventSink.yield(.identity(deviceID: current.deviceID, backend: current.backend))
            } catch {
                log.error("completing the rotation failed: \(String(describing: error), privacy: .public)")
            }
        }
        recordServerKeys(reply, connectedWith: pin)
        publish(.online)

        guard role == .owner else { return nil }
        let age = Date.now.timeIntervalSince(current.notValidBefore)
        guard retryRotation || rotationRequested || (age >= configuration.rotationInterval && !rotationSuppressed)
        else { return nil }
        rotationRequested = false
        return await rotate(on: client, current: current)
    }

    /// docs/pairing.md §4: sign the new key with the current one, send it, and switch once the daemon took it.
    private func rotate(on client: WsClient, current: DeviceIdentity) async -> Ending? {
        guard role == .owner else { return nil }
        let rotation: IdentityRotation
        do {
            rotation = try await keys.rotate(for: nodeTag, serverSPKISHA256: currentPin)
        } catch {
            log.error("preparing the rotation failed: \(String(describing: error), privacy: .public)")
            rotationSuppressed = true
            return nil
        }
        let proof = rotation.proof
        do {
            _ = try await client.send(
                Ws.Device.Identity.Rotate.self,
                payload: .init(certificate: proof.newCertificateDER.base64EncodedString(),
                               timestamp: Int64(proof.timestamp), signature: proof.signature.base64EncodedString()),
                timeout: configuration.requestTimeout)
        } catch {
            switch error {
            case .timeout, .disconnected:
                // The daemon may or may not have taken it. The next connect tries the new key first.
                log.info("rotation answer lost; reconnecting with the pending key first")
                return .restart
            case .cancelled:
                return .stopped
            default:
                if DeviceRefusal(error) == .deviceUnknown { return .revoked }
                log.error("rotation refused: \(error.message, privacy: .public)")
                try? await keys.cancelRotation(for: nodeTag)
                rotationSuppressed = true
                return nil
            }
        }
        do {
            let rotated = try await keys.completeRotation(for: nodeTag)
            recordDeviceID(rotated)
            log.info("device key rotated")
            return .reconnect(rotated, retryingRotation: false)
        } catch {
            log.error("completing the rotation failed: \(String(describing: error), privacy: .public)")
            return .restart
        }
    }

    // MARK: - Record

    private func recordDeviceID(_ identity: DeviceIdentity) {
        guard role == .owner, case .paired(let pin, _, let since) = node.pairing else { return }
        node.pairing = .paired(serverSPKISHA256: pin, deviceID: identity.deviceID, since: since)
        eventSink.yield(.recordChanged(pairing: node.pairing, nextServerSPKISHA256: node.nextServerSPKISHA256))
    }

    /// Stores an announced next key, and promotes it once the server presents it.
    private func recordServerKeys(_ reply: ServerIdentityAnnouncement.Response, connectedWith pin: Data) {
        guard case .paired(let saved, let deviceID, let since) = node.pairing else { return }
        let serverKey = Hex.decode(reply.spkiSHA256, length: 32)
        let announced = reply.nextSPKISHA256.flatMap { Hex.decode($0, length: 32) }
        var pairing = node.pairing
        var next = node.nextServerSPKISHA256

        if pin != saved, serverKey == pin {
            // Connected with the announced key and the server confirms it is now current: promote it.
            pairing = .paired(serverSPKISHA256: pin, deviceID: deviceID, since: since)
            next = nil
            log.info("server key switched to the announced key")
        }
        if let announced, announced != serverKey {
            next = announced
        } else if serverKey != nil, next == serverKey {
            next = nil
        }
        guard pairing != node.pairing || next != node.nextServerSPKISHA256 else { return }
        node.pairing = pairing
        node.nextServerSPKISHA256 = next
        // A consumer keeps the pins in memory for its own reconnects; only the owner's reach the registry.
        guard role == .owner else { return }
        eventSink.yield(.recordChanged(pairing: pairing, nextServerSPKISHA256: next))
    }

    private func publish(_ new: Status) {
        guard new != status || !published else { return }
        published = true
        status = new
        eventSink.yield(.status(new))
    }

    private var published = false
}
