import Foundation
public import VHContract
public import VHCore
public import VHNodes
public import VHTransport
import os

/// How a replica reaches its node: ws commands and the HTTP lanes, both presenting this Mac's device identity.
public protocol ReplicaLink: Sendable {
    /// Sends one command on the node's Device session, waiting (briefly) for the session to come up.
    func send<R: WsRequest>(_ request: R.Type, payload: R.Payload, during operation: FinderError.Operation)
        async throws(FinderError) -> R.Response

    /// Runs `operation` on the node's HTTP lanes. A 403 is told apart here: a key the node no longer accepts after a
    /// reload is ``FinderError/notAuthenticated(_:)``; otherwise the 403 is the account's access and comes back as
    /// `TransferError.forbidden` mapped for `operation`.
    func withLanes<T: Sendable>(during operation: FinderError.Operation,
                                _ body: @Sendable (VaultLanes) async throws(TransferError) -> T)
        async throws(FinderError) -> T

    /// Closes the connections.
    func close() async
}

/// The File Provider extension's connection to one node, as a credential consumer (docs/architecture.md §3): it
/// reads the registry and the Keychain the app (the owner) keeps, presents what is saved, and never rotates, deletes or
/// writes anything.
///
/// - **ws:** one ``NodeSession`` in the consumer role. It reconnects on its own; after `device_unknown` it reloads
///   the credentials once (the owner may have rotated the key) and reports `.revoked` when the refusal survives.
/// - **Lanes:** a ``VaultLanes`` for the identity the session presents, made again when that identity changes. A 403
///   reloads the credentials and retries once; a 403 that survives is checked with the node directly
///   (``CredentialReader/check(_:timeout:)``): a refused key is a revocation, an accepted one an access refusal.
/// - **Fail closed:** after a revocation, a missing key or an unpaired record, every call throws
///   ``FinderError/notAuthenticated(_:)`` until the extension starts again.
public actor NodeLink: ReplicaLink {
    public struct Configuration: Sendable {
        /// How long a call waits for the Device session to come online before reporting the node unreachable.
        public var onlineTimeout: Duration = .seconds(15)
        /// The same wait while the session already reports the node offline (Finder shouldn't hang on each call).
        public var offlineTimeout: Duration = .seconds(3)
        /// Silence a lane request may wait through.
        public var laneTimeout: Duration = .seconds(60)
        public var session = NodeSession.Configuration()
        /// Where the lanes answer; nil: the node's endpoint (the device listener serves both). Tests point it elsewhere.
        public var laneEndpoint: NodeEndpoint?

        public init() {}
    }

    public nonisolated let nodeID: NodeID
    private let reader: CredentialReader
    private let configuration: Configuration
    private let log = Logger(subsystem: "sh.vaulthalla.app", category: "fileprovider-link")

    private var session: NodeSession?
    private var events: Task<Void, Never>?
    private var status: NodeSession.Status = .connecting
    /// Counts the session's status reports.
    private var epoch = 0
    /// Set once the node can't be acted for: every later call fails closed with it.
    private var failure: FinderError?
    /// The lanes, for the identity and the endpoint they were made with (a new selection may move the endpoint).
    private var lanes: (client: VaultLanes, deviceID: String, endpoint: NodeEndpoint)?

    public init(nodeID: NodeID, reader: CredentialReader, configuration: Configuration = Configuration()) {
        self.nodeID = nodeID
        self.reader = reader
        self.configuration = configuration
    }

    /// Why the link fails closed, if it does.
    public var closedReason: FinderError? { failure }

    public func close() async {
        events?.cancel()
        events = nil
        if let session { await session.stop() }
        session = nil
        lanes?.client.invalidate()
        lanes = nil
    }

    // MARK: - ws

    public func send<R: WsRequest>(_ request: R.Type, payload: R.Payload, during operation: FinderError.Operation)
        async throws(FinderError) -> R.Response
    {
        let session = try await online()
        let before = epoch
        do throws(WsError) {
            return try await session.send(request, payload: payload)
        } catch {
            // Retried once, after the session settled: a refusal of this key (the session reloads the credentials
            // and reconnects, or reports the revocation; the request never ran), or a read whose connection dropped
            // (the node revoking this Mac closes its connections first). A write that lost its connection isn't
            // repeated here: the system retries it.
            let refused = CredentialReader.refusal(in: error) == .deviceUnknown
            guard refused || (error == .disconnected && operation == .read) else {
                throw FinderError(error, during: operation)
            }
            await settle(after: before)
            let again = try await online()
            do throws(WsError) {
                return try await again.send(request, payload: payload)
            } catch {
                throw failure ?? FinderError(error, during: operation)
            }
        }
    }

    /// Waits (briefly) until the session reported something after status number `epoch`.
    private func settle(after epoch: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while self.epoch == epoch, failure == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The session once it is a Device session, or why there is none.
    private func online() async throws(FinderError) -> NodeSession {
        if let failure { throw failure }
        let session = try await startIfNeeded()
        let wait = if case .offline = status { configuration.offlineTimeout } else { configuration.onlineTimeout }
        let deadline = ContinuousClock.now + wait
        while true {
            if let failure { throw failure }
            if status == .online { return session }
            if ContinuousClock.now >= deadline { break }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                throw .cancelled
            }
        }
        if case .offline(let reason) = status { throw .serverUnreachable(reason) }
        throw .serverUnreachable("The node didn't answer within \(wait.components.seconds) s.")
    }

    private func startIfNeeded() async throws(FinderError) -> NodeSession {
        if let session { return session }
        let record: Node
        do throws(CredentialFailure) {
            guard let found = try reader.record(nodeID) else { throw .registry("no registry to read") }
            record = found
        } catch {
            throw fail(FinderError(error))
        }
        guard case .paired = record.pairing else {
            throw fail(.notAuthenticated(record.pairing == .unpaired ? "This Mac isn't paired with the node."
                                         : "The node no longer accepts this Mac. Pair it again in Vaulthalla."))
        }
        let made = NodeSession(node: record, keys: reader.keys, registry: reader.registry,
                               configuration: configuration.session)
        session = made
        status = .connecting
        let stream = made.events
        events = Task { [weak self] in
            for await event in stream {
                await self?.observe(event)
            }
        }
        await made.start()
        return made
    }

    private func observe(_ event: NodeSession.Event) {
        switch event {
        case .status(let next):
            status = next
            epoch += 1
            if next == .revoked {
                _ = fail(.notAuthenticated("The node no longer accepts this Mac. Pair it again in Vaulthalla."))
            }
        case .pairingRequired:
            let reason = if case .offline(let why) = status { why } else { "Pair this Mac with the node again." }
            _ = fail(.notAuthenticated(reason))
        case .identity, .recordChanged, .protocolNegotiated, .route, .endpointsChanged:
            // A consumer: routes are the session's to choose and never saved from here.
            // ws calls on an incompatible node are refused by the session itself; lanes check it in `withLanes`.
            break
        }
    }

    private func fail(_ error: FinderError) -> FinderError {
        if failure == nil {
            failure = error
            log.error("failing closed: \(error.description, privacy: .public)")
        }
        return error
    }

    // MARK: - Lanes

    public func withLanes<T: Sendable>(during operation: FinderError.Operation,
                                       _ body: @Sendable (VaultLanes) async throws(TransferError) -> T)
        async throws(FinderError) -> T
    {
        let first = try await currentLanes()
        if let mismatch = await session?.nodeProtocol?.mismatch {
            // The lanes belong to a protocol this build doesn't speak with the node either: nothing is sent.
            throw FinderError(TransferError.protocolUnsupported(mismatch.message), during: operation)
        }
        do throws(TransferError) {
            return try await body(first.client)
        } catch .forbidden {
            // The owner may have rotated the key since the lanes were made: reload, and try once more.
        } catch {
            if case .connection = error { await session?.laneConnectionFailed() }
            throw FinderError(error, during: operation)
        }
        let fresh = try await reloadedLanes(refusing: first.deviceID)
        do throws(TransferError) {
            return try await body(fresh.lanes)
        } catch .forbidden {
            switch await reader.check(fresh.credentials) {
            case .refused:
                throw fail(.notAuthenticated("The node no longer accepts this Mac. Pair it again in Vaulthalla."))
            case .accepted, .inconclusive:
                // The key is good: the account may not do this.
                throw FinderError(TransferError.forbidden, during: operation)
            }
        } catch {
            throw FinderError(error, during: operation)
        }
    }

    /// The lanes for the identity the session presents now.
    private func currentLanes() async throws(FinderError) -> (client: VaultLanes, deviceID: String) {
        let session = try await online()
        guard let deviceID = await session.laneIdentityID,
              let configuration = await session.laneConfiguration(timeout: self.configuration.laneTimeout)
        else { throw .serverUnreachable("The node's session has no identity yet.") }
        if let lanes, lanes.deviceID == deviceID, lanes.endpoint == configuration.endpoint {
            return (lanes.client, deviceID)
        }
        let made = try makeLanes(configuration)
        lanes?.client.invalidate()
        lanes = (made, deviceID, configuration.endpoint)
        return (made, deviceID)
    }

    /// Lanes made from the credentials as saved now, past the key the node refused.
    private func reloadedLanes(refusing deviceID: String) async throws(FinderError)
        -> (lanes: VaultLanes, credentials: NodeCredentials)
    {
        let record: Node
        do throws(CredentialFailure) {
            guard let found = try reader.record(nodeID) else { throw .registry("no registry to read") }
            record = found
        } catch {
            throw fail(FinderError(error))
        }
        var credentials: NodeCredentials
        do throws(CredentialFailure) {
            credentials = try await reader.reload(record, refusing: deviceID)
        } catch {
            throw fail(FinderError(error))
        }
        // The endpoint the session selected (read-only: the extension never saves routes).
        credentials = credentials.routed(to: await session?.activeEndpoint)
        let lane = credentials.laneConfiguration(timeout: configuration.laneTimeout)
        let made = try makeLanes(lane)
        lanes?.client.invalidate()
        lanes = (made, credentials.identity.deviceID, lane.endpoint)
        return (made, credentials)
    }

    private func makeLanes(_ lane: DeviceHTTPClient.Configuration) throws(FinderError) -> VaultLanes {
        var lane = lane
        if let endpoint = configuration.laneEndpoint { lane.endpoint = endpoint }
        do {
            var policy = VaultLanes.Policy()
            policy.retries = 2
            return try VaultLanes(transfers: DeviceTransferClient(configuration: lane), policy: policy)
        } catch {
            throw .notAuthenticated("The node's address can't be used.")
        }
    }
}
