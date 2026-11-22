public import Foundation
public import VHCore
public import VHIdentity
public import VHTransport
public import VHContract
import Synchronization
import os

/// The device side of pairing one new key with a node: ``PairingClient`` in the app, a fake in tests.
public protocol AgentPairingDevice: Sendable {
    /// Pairs `identity` over a pairing-only connection pinned to `serverPin` from the first byte, and streams the
    /// states until a final one. Dropping the stream cancels the attempt.
    func pair(identity: DeviceIdentity, endpoint: NodeEndpoint, serverPin: Data, deviceName: String,
              appVersion: String) -> AsyncStream<PairingClient.State>
}

/// The real device side: ``PairingClient`` with the pin as a pairing link's (`expectedServerSPKI`), so a server
/// presenting any other key is refused before anything is sent, and with no approval key.
public struct PairingClientDevice: AgentPairingDevice {
    public init() {}

    public func pair(identity: DeviceIdentity, endpoint: NodeEndpoint, serverPin: Data, deviceName: String,
                     appVersion: String) -> AsyncStream<PairingClient.State> {
        var configuration = PairingClient.Configuration(endpoint: endpoint, deviceName: deviceName,
                                                        appVersion: appVersion)
        configuration.expectedServerSPKI = serverPin
        configuration.approvalKeySPKI = nil
        let client = PairingClient(identity: identity, configuration: configuration)
        let inner = client.start()
        return AsyncStream { continuation in
            // The task keeps the client alive (its deinit cancels the attempt) until the stream ends.
            let relay = Task {
                for await state in inner { continuation.yield(state) }
                continuation.finish()
                withExtendedLifetime(client) {}
            }
            continuation.onTermination = { _ in
                relay.cancel()
                client.cancel()
            }
        }
    }
}

/// Gives an AI app its own pairing with a node (docs/architecture.md §3, "AI apps' own pairings"), entirely from this
/// Mac and with the server as released: this Mac's Device session opens a pairing window, a new key asks to pair over
/// a pairing-only connection pinned to the node's known key, this Mac finds the request by the new key's device id
/// and matches the code itself (the node's three choices against the code the new key computed: a relay on either
/// leg gives a different code, and the request is denied), then approves it. The approval is a `device.trust` step-up
/// the Mac's approval key answers: one Touch ID or the Mac's password, and nothing typed.
///
/// The new device belongs to the account this Mac was paired by, with its permissions; it carries no approval key, so
/// it can never answer a step-up. Only the credential owner runs this (the key is created under the lease).
///
/// Any failure leaves nothing behind: a request still pending is denied, a device the node already approved is
/// revoked, the window this opened is closed, and the new key is deleted. The failure says what happened.
public struct AgentPairing: Sendable {
    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        /// This process isn't the credential owner.
        case notOwner
        /// This Mac isn't paired with the node (or its record lacks the node id the approval names).
        case macNotPaired
        /// This Mac has no approval key on the node: set up approvals for it once (a web console approval).
        case noApprovalKey
        /// The node doesn't have what this needs (an older server).
        case olderServer(String)
        /// Another user's pairing window is open on the node.
        case windowConflict
        /// None of the node's choices is the code the new key computed: something sits between them. Denied.
        case codeMismatch
        /// The node's request for the new key isn't the one this Mac expects (it carries an approval key, or never
        /// showed up).
        case unexpectedRequest(String)
        /// The approval wasn't given (Touch ID cancelled, the node refused it).
        case notApproved(String)
        case unreachable(String)
        case timedOut
        /// The new key's side stopped.
        case pairing(PairingFailure)
        case denied
        case expired
        case keychain(String)
        /// A refusal in the node's words.
        case refused(String)

        public var description: String {
            switch self {
            case .notOwner: "Only the copy of Vaulthalla that owns this Mac's keys can do this."
            case .macNotPaired: "This Mac isn't paired with the node."
            case .noApprovalKey:
                "This Mac can't approve devices on the node yet: set up approvals for it first (once, in the node's "
                    + "web console)."
            case .olderServer(let what): "The node's Vaulthalla is too old for this (\(what))."
            case .windowConflict: "Another user's pairing window is open on the node. Try again when it closes."
            case .codeMismatch:
                "The node showed a different code, so something may sit between this Mac and the node. The request "
                    + "was denied."
            case .unexpectedRequest(let why): "The node's pairing request wasn't the expected one (\(why))."
            case .notApproved(let why): "It wasn't approved: \(why)"
            case .unreachable(let why): "The node can't be reached: \(why)"
            case .timedOut: "The node didn't finish pairing in time."
            case .pairing(let failure): failure.message
            case .denied: "The node declined the pairing."
            case .expired: "The pairing request expired."
            case .keychain(let why): "The key couldn't be created: \(why)"
            case .refused(let text): text
            }
        }
    }

    public let keys: DeviceKeys
    /// This Mac's Device session with the node.
    public let session: any NodeTransport
    /// This Mac's approval key for the node.
    public let signer: (any ApprovalSigner)?
    public var device: any AgentPairingDevice
    /// The whole exchange, Touch ID included.
    public var timeout: Duration = .seconds(180)
    /// How long to look for the new key's request in `device.pairing.pending`.
    public var requestWait: Duration = .seconds(15)
    public var pollInterval: Duration = .milliseconds(300)

    private let log = Logger(subsystem: "sh.vaulthalla.app", category: "agent-pairing")

    public init(keys: DeviceKeys, session: any NodeTransport, signer: (any ApprovalSigner)?,
                device: any AgentPairingDevice = PairingClientDevice()) {
        self.keys = keys
        self.session = session
        self.signer = signer
        self.device = device
    }

    /// "Claude Code on Cooper's Mac Studio", at most 64 characters.
    public static func deviceName(for client: AgentClient, macName: String) -> String {
        String("\(client.displayName) on \(macName)".prefix(64))
    }

    /// Pairs the app's new key with `node`; the record to save under `node.agentIdentities[client]`.
    public func pair(_ node: Node, client: AgentClient, macName: String, appVersion: String) async
        -> Result<AgentIdentity, Failure>
    {
        guard keys.role == .owner else { return .failure(.notOwner) }
        guard case .paired(let pin, let macDeviceID, _) = node.pairing, let serverNodeID = node.serverNodeID,
              let macDevice = Hex.decode(macDeviceID, length: 32)
        else { return .failure(.macNotPaired) }
        guard let signer else { return .failure(.noApprovalKey) }
        for (command, what) in [(WsCommand.devicePairingOpen, "pairing from a paired device"),
                                (.deviceApprovalChallenge, "approval keys")]
            where await session.commandSupport(command) == .no {
            return .failure(.olderServer(what))
        }
        let context = ApprovalContext(nodeID: serverNodeID, serverSPKISHA256: pin, deviceSPKISHA256: macDevice)
        let tag = AgentIdentity.keyTag(node: node.id, client: client)
        let name = Self.deviceName(for: client, macName: macName)
        let progress = Progress()

        let outcome: Result<AgentIdentity, Failure> = await withTaskGroup { group in
            group.addTask {
                await exchange(node, pin: pin, tag: tag, name: name, appVersion: appVersion, signer: signer,
                               context: context, progress: progress)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .failure(.timedOut)
            }
            let first = await group.next() ?? .failure(.timedOut)
            group.cancelAll()
            return first
        }
        if case .failure(let failure) = outcome {
            log.info("an AI app's pairing stopped: \(failure.description, privacy: .public)")
            await cleanUp(progress, tag: tag)
        } else {
            await closeWindow(progress)
        }
        return outcome
    }

    /// What the exchange got to, for the cleanup.
    final class Progress: Sendable {
        struct State {
            var openedWindow = false
            var keyCreated = false
            var requestID: String?
            var approvedDeviceID: String?
        }
        let state = Mutex(State())
        func update(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
        var snapshot: State { state.withLock { $0 } }
    }

    private func exchange(_ node: Node, pin: Data, tag: String, name: String, appVersion: String,
                          signer: any ApprovalSigner, context: ApprovalContext, progress: Progress) async
        -> Result<AgentIdentity, Failure>
    {
        // 1. The window, on this Mac's session.
        do {
            _ = try await session.send(Ws.Device.Pairing.Open.self, payload: WsNoPayload())
            progress.update { $0.openedWindow = true }
        } catch {
            return .failure(Self.failure(error))
        }

        // 2. The new key, under the lease.
        let identity: DeviceIdentity
        do {
            identity = try await keys.identityForPairing(nodeTag: tag, deviceName: name, replacingExisting: true)
            progress.update { $0.keyCreated = true }
        } catch is CredentialOwnershipError {
            return .failure(.notOwner)
        } catch {
            return .failure(.keychain(String(describing: error)))
        }

        // 3. The new key's side, until it shows its code.
        let states = device.pair(identity: identity, endpoint: node.endpoint, serverPin: pin, deviceName: name,
                                 appVersion: appVersion)
        var iterator = states.makeAsyncIterator()
        var code: PairingCode?
        while code == nil {
            guard let state = await iterator.next() else {
                return .failure(Task.isCancelled ? .timedOut : .pairing(.connectionLost))
            }
            switch state {
            case .connecting, .negotiated: continue
            case .awaitingApproval(let shown): code = shown
            case .approved: return .failure(.unexpectedRequest("approved before this Mac approved it"))
            case .denied: return .failure(.denied)
            case .expired: return .failure(.expired)
            case .failed(let failure): return .failure(.pairing(failure))
            }
        }
        guard let code else { return .failure(.timedOut) }

        // 4. The request as the node lists it on this Mac's session, found by the new key's device id.
        let request: Ws.Device.Pairing.Pending.Response.Request
        switch await findRequest(deviceID: identity.deviceID) {
        case .success(let found): request = found
        case .failure(let failure): return .failure(failure)
        }
        progress.update { $0.requestID = request.requestID }
        guard request.approvalKeyPresent != true else {
            return .failure(.unexpectedRequest("it carries an approval key"))
        }
        guard request.codeChoices.contains(where: { Self.digits($0) == code.digits }) else {
            return .failure(.codeMismatch)
        }

        // 5. Approve with this Mac's approval key (the device.trust step-up: Touch ID or the Mac's password).
        do {
            _ = try await DeviceApproval.send(Ws.Device.Pairing.Approve.self,
                                              payload: .init(requestID: request.requestID, code: code.digits),
                                              signer: signer, context: context, via: session)
            progress.update { $0.approvedDeviceID = identity.deviceID }
        } catch let error as DeviceApprovalError {
            switch error {
            case .consoleApprovalRequired, .keyUnavailable: return .failure(.noApprovalKey)
            case .payloadMismatch: return .failure(.notApproved("the node's approval challenge didn't match this node"))
            case .notApproved(let state): return .failure(.notApproved(state))
            }
        } catch let error as WsError {
            if error.code == "approval_key_unavailable" { return .failure(.noApprovalKey) }
            if case .invalid = error { return .failure(.codeMismatch) }
            return .failure(Self.failure(error))
        } catch {
            // The signer's own error: Touch ID cancelled or failed.
            return .failure(.notApproved(String(describing: error)))
        }

        // 6. The new key's side learns the outcome; it must be this key, on this node, under this pin.
        while let state = await iterator.next() {
            switch state {
            case .approved(let nodeID, _, let deviceID, let serverSPKI):
                guard deviceID == identity.deviceID, serverSPKI == pin, nodeID == node.serverNodeID else {
                    return .failure(.unexpectedRequest("the node approved another device or answered as another node"))
                }
                return .success(AgentIdentity(deviceID: identity.deviceID, deviceName: name,
                                              certificate: identity.certificateDER, serverSPKISHA256: pin,
                                              pairedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))))
            case .denied: return .failure(.denied)
            case .expired: return .failure(.expired)
            case .failed(let failure): return .failure(.pairing(failure))
            case .connecting, .negotiated, .awaitingApproval: continue
            }
        }
        return .failure(Task.isCancelled ? .timedOut : .pairing(.connectionLost))
    }

    private func findRequest(deviceID: String) async -> Result<Ws.Device.Pairing.Pending.Response.Request, Failure> {
        let deadline = ContinuousClock.now + requestWait
        while true {
            do {
                let pending = try await session.send(Ws.Device.Pairing.Pending.self, payload: WsNoPayload())
                if let request = pending.requests.first(where: { $0.deviceID.lowercased() == deviceID }) {
                    return .success(request)
                }
            } catch {
                return .failure(Self.failure(error))
            }
            guard ContinuousClock.now < deadline else {
                return .failure(.unexpectedRequest("the node never listed the new key's request"))
            }
            do { try await Task.sleep(for: pollInterval) } catch { return .failure(.timedOut) }
        }
    }

    /// Undoes what the exchange got to. Runs outside the exchange's task, so a timeout or cancellation still cleans up.
    private func cleanUp(_ progress: Progress, tag: String) async {
        let state = progress.snapshot
        if let deviceID = state.approvedDeviceID {
            _ = try? await session.send(Ws.Device.Revoke.self, payload: .init(deviceID: deviceID))
        } else if let requestID = state.requestID {
            _ = try? await session.send(Ws.Device.Pairing.Deny.self, payload: .init(requestID: requestID))
        }
        await closeWindow(progress)
        if state.keyCreated {
            do {
                try await keys.deleteIdentity(for: tag)
            } catch {
                log.error("an AI app's unused key couldn't be deleted: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func closeWindow(_ progress: Progress) async {
        guard progress.snapshot.openedWindow else { return }
        _ = try? await session.send(Ws.Device.Pairing.Close.self, payload: .init(any: nil))
    }

    static func digits(_ text: String) -> String { text.filter(\.isNumber) }

    static func failure(_ error: any Error) -> Failure {
        guard let error = error as? WsError else { return .refused(String(describing: error)) }
        switch error {
        case .conflict: return .windowConflict
        case .disconnected, .timeout: return .unreachable(error.message)
        case .unknownCommand(let command): return .olderServer(command)
        case .protocolUnsupported(let mismatch): return .olderServer(mismatch.message)
        case .cancelled: return .timedOut
        default: return .refused(error.message)
        }
    }
}

/// Revoking an AI app's device on a node: on this Mac's session (the account's own device), else on the device's
/// own session while its key still exists (a device may revoke itself; this is what still works once the node has
/// revoked this Mac). `not_found` means it is already gone.
public enum AgentRevocation {
    public enum Outcome: Hashable, Sendable {
        case revoked
        /// The node no longer knows it (revoked there, or never approved).
        case alreadyGone
        /// Not reached: retry later. The reason, for the person.
        case pending(String)
    }

    /// `ownSession`: a Device session presenting the app's own key, when its key still exists.
    public static func revoke(deviceID: String, macSession: (any NodeTransport)?,
                              ownSession: (any NodeTransport)? = nil) async -> Outcome {
        var problem = "this Mac has no connection to the node"
        for transport in [macSession, ownSession].compactMap(\.self) {
            do {
                _ = try await transport.send(Ws.Device.Revoke.self, payload: .init(deviceID: deviceID))
                return .revoked
            } catch {
                switch error {
                case .notFound: return .alreadyGone
                default:
                    if DeviceRefusal(error) == .deviceUnknown {
                        problem = "the node no longer accepts this Mac: revoke the device in the node's web console"
                    } else {
                        problem = error.message
                    }
                }
            }
        }
        return .pending(problem)
    }
}

/// A one-shot Device session for a key that has no `NodeSession` of its own (an AI app's): one ws connection with
/// the identity, pinned, per request.
public struct OneShotDeviceTransport: NodeTransport {
    public let credentials: NodeCredentials
    public var timeout: Duration

    public init(credentials: NodeCredentials, timeout: Duration = .seconds(10)) {
        self.credentials = credentials
        self.timeout = timeout
    }

    public func send<R: WsRequest>(_ request: R.Type, payload: R.Payload) async throws(WsError) -> R.Response {
        let client: WsClient
        do {
            client = try WsClient(configuration: .init(
                endpoint: credentials.endpoint,
                security: .mutualTLS(identity: credentials.identity.secIdentity, serverSPKIPin: credentials.serverPin,
                                     onServerSPKI: { _ in }),
                reconnect: ReconnectPolicy(base: .seconds(3600), cap: .seconds(3600)),
                connectTimeout: timeout))
        } catch {
            throw .error("The node's address \(credentials.endpoint) can't be used.")
        }
        do {
            let answer = try await client.send(request, payload: payload, timeout: timeout)
            await client.close()
            return answer
        } catch {
            await client.close()
            throw error
        }
    }
}
