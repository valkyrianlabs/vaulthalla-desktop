import Foundation
public import VHContract
public import VHCore
import VHTransport
import Synchronization
import os

/// Links two servers this Mac is paired with, with one confirmation from the person and no number shown: the
/// Desktop-brokered path of the server's design/peers/link.md ("Desktop-brokered, in full"). This Mac already pins
/// both servers' keys, so nothing here trusts a key on first use:
///
/// 1. `peer.pairing.open` on the accepting server;
/// 2. `peer.link.start` on the dialling server with the accepting server's endpoints and `expect_spki` = this Mac's pin
///    for it (the dialling server refuses any other key at the handshake);
/// 3. the dialling server's code (`peer.link.status`) and the accepting server's pending request
///    (`peer.pairing.pending`), whose key must be this Mac's pin for the dialling server and whose three choices must
///    include that code;
/// 4. `peer.pairing.approve` with the request, the code and `expect_spki` = that pin;
/// 5. the dialling server reports the link; `peer.pairing.close`.
///
/// Which server dials: the accepting one must be reachable from the dialling one. The more reachable one (by what each
/// advertises) accepts first; when the dial reaches nothing, everything is undone and the other direction is tried.
///
/// Only a person can do this, through the app, on this Mac's own full-access, directly connected Device session, as a
/// super admin on both servers: the servers decide that on RBAC alone (no step-up for such a device), and refuse
/// agents, scoped (AI app) pairings and relayed sessions (`peer_forbidden`). No agent tool reaches this.
///
/// Every failure leaves both servers as they were: the window closed, a dial in progress cancelled, a request denied.
/// One thing can't be undone from here: if the accepting server approved and the dialling one then failed to record
/// the link, the accepting server keeps a row the other lacks. That is detected and returned (``Failure/halfLinked``)
/// so the person can unlink it.
public struct ServerLinking: Sendable {
    /// One of the two servers: its record (name, pin, server id, advertised endpoints) and this Mac's session there.
    public struct Side: Sendable {
        public var node: Node
        public var transport: any NodeTransport

        public init(node: Node, transport: any NodeTransport) {
            self.node = node
            self.transport = transport
        }

        var name: String { node.displayName }
    }

    /// Where the attempt is, for the sheet.
    public enum Step: Hashable, Sendable {
        case checking
        /// `acceptor` waits for `dialler` to dial it.
        case connecting(dialler: String, acceptor: String)
        /// The dialling server reached the other: the code is being compared and the link approved.
        case approving(dialler: String, acceptor: String)
        case finishing
        case cleaningUp
    }

    /// Both servers record the link.
    public struct Linked: Hashable, Sendable {
        public var dialler: NodeID
        public var acceptor: NodeID
        /// Each side's row (`peer.list` id) for the other.
        public var diallerPeerID: Int64?
        public var acceptorPeerID: Int64
    }

    /// One server records a link to another that has none back.
    public struct HalfLink: Hashable, Sendable, Identifiable, CustomStringConvertible {
        /// The node holding the leftover row.
        public var node: NodeID
        public var nodeName: String
        /// The leftover row there (what `peer.unlink` names).
        public var peerID: Int64
        /// What `node` calls the other server.
        public var peerName: String
        /// The other server, as this Mac calls it.
        public var otherName: String

        public var id: String { "\(node.rawValue)#\(peerID)" }

        public var description: String {
            "\(nodeName) records a link to \(otherName) that \(otherName) doesn't have. Unlink it on \(nodeName), "
                + "then link them again."
        }
    }

    /// Why a direction's dial reached nothing: the dialling server's words.
    public struct Unreached: Hashable, Sendable {
        public var dialler: String
        public var acceptor: String
        public var reason: String
    }

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        /// This Mac isn't paired with the node.
        case notPaired(String)
        /// Both picks are the same server.
        case sameServer
        case offline(String)
        /// The node's Vaulthalla is older than ``ServerLinking/minimumVersion`` (no linked servers).
        case olderServer(String)
        /// This Mac's account there isn't a super admin (the node's words).
        case notSuperAdmin(String, String)
        /// The node accepts linking only from a person or a full-access, directly connected device (`peer_forbidden`).
        case notTrusted(String, String)
        /// The account is in its recovery cooldown there (`recovery_cooldown`).
        case recoveryCooldown(String, String)
        /// The node asked for an approval this Mac's session can't give (a step-up).
        case needsApproval(String, String)
        /// Another pairing window is open there (device or server pairing; one at a time per node).
        case windowBusy(String)
        case alreadyLinked(String, String)
        case halfLinked(HalfLink)
        /// Neither direction reached the other server.
        case noRoute(Unreached, Unreached)
        /// The accepting server's request came from a key that isn't this Mac's pin for the dialling server.
        case wrongKey(dialler: String, acceptor: String)
        /// The dialling server reached a server that isn't the one this Mac knows.
        case unexpectedServer(dialler: String, acceptor: String)
        /// None of the accepting server's choices is the dialling server's code: something sits between them.
        case codeMismatch(dialler: String, acceptor: String)
        /// The request never showed up on the accepting server, or wasn't the expected one.
        case unexpectedRequest(String, String)
        case denied(String)
        case expired
        /// The dialling server's attempt failed (its words).
        case linkFailed(String, String)
        case timedOut
        case cancelled
        /// Another refusal, in the node's words.
        case refused(String, String)

        public var description: String {
            switch self {
            case .notPaired(let node): "This Mac isn't paired with \(node). Pair it first."
            case .sameServer: "Those are the same server. Pick two different servers."
            case .offline(let node): "\(node) isn't connected. Try again once it is."
            case .olderServer(let node):
                "\(node) needs Vaulthalla \(ServerLinking.minimumVersion) or newer to link servers."
            case .notSuperAdmin(let node, let why):
                "Linking servers needs a super admin on both, and the account this Mac is paired by on \(node) isn't "
                    + "one (\(why))."
            case .notTrusted(let node, let why):
                "\(node) lets only a person or a fully trusted, directly connected device link servers, and won't take "
                    + "it from this connection (\(why))."
            case .recoveryCooldown(let node, let why):
                "\(node) doesn't allow linking servers while your account there is recovering (\(why)). Try again "
                    + "once the recovery cooldown ends."
            case .needsApproval(let node, let why):
                "\(node) asked for an extra approval this Mac can't give for linking servers (\(why))."
            case .windowBusy(let node):
                "\(node) has another pairing window open (a device or a server being paired). Try again when it closes."
            case .alreadyLinked(let a, let b): "\(a) and \(b) are already linked."
            case .halfLinked(let half): half.description
            case .noRoute(let first, let second):
                "Neither server could reach the other: \(first.dialler) couldn't reach \(first.acceptor) "
                    + "(\(first.reason)), and \(second.dialler) couldn't reach \(second.acceptor) (\(second.reason)). "
                    + "They need a route to each other: the same network, a VPN, or a forwarded port on one of them."
            case .wrongKey(let dialler, let acceptor):
                "The request \(acceptor) received didn't come from the key this Mac knows for \(dialler), so it was "
                    + "declined and nothing was linked."
            case .unexpectedServer(let dialler, let acceptor):
                "\(dialler) reached a server that isn't the \(acceptor) this Mac knows, so nothing was linked."
            case .codeMismatch(let dialler, let acceptor):
                "\(acceptor) saw a different code from \(dialler), so something may sit between them. The request was "
                    + "declined and nothing was linked."
            case .unexpectedRequest(let node, let why): "\(node)'s link request wasn't the expected one (\(why))."
            case .denied(let node): "\(node) declined the link."
            case .expired: "The link request expired before it was approved."
            case .linkFailed(let node, let why): "\(node) couldn't finish the link: \(why)"
            case .timedOut: "Linking didn't finish in time, so it was undone."
            case .cancelled: "Linking was cancelled and undone."
            case .refused(let node, let text): "\(node): \(text)"
            }
        }

        /// A refusal about who may link, rather than about the server or the network.
        var isPermission: Bool {
            switch self {
            case .notSuperAdmin, .notTrusted, .recoveryCooldown, .needsApproval: true
            default: false
            }
        }

        /// What a refusal of a management command means for `name`.
        static func precondition(_ error: WsError, name: String) -> Failure {
            if error.isUnknownCommand { return .olderServer(name) }
            switch error {
            case .refused("peer_forbidden", let text): return .notTrusted(name, text)
            case .refused("recovery_cooldown", let text): return .recoveryCooldown(name, text)
            case .denied(let text): return .notSuperAdmin(name, text)
            case .stepUpRequired(_, let text): return .needsApproval(name, text)
            case .disconnected, .timeout: return .offline(name)
            case .protocolUnsupported(let mismatch): return .refused(name, mismatch.message)
            case .cancelled: return .cancelled
            default: return .refused(name, error.message)
            }
        }
    }

    /// The oldest Vaulthalla that links servers (the first with `peer.*`), as the app names it.
    public static let minimumVersion = "1.27"

    /// The whole attempt, both directions and the clean-up included.
    public var timeout: Duration = .seconds(300)
    /// How often the attempt's state is read.
    public var pollInterval: Duration = .milliseconds(500)
    /// How long to look for the request on the accepting server once the dialling one shows its code.
    public var requestWait: Duration = .seconds(20)
    /// How long the dialling server may take per endpoint it tries (it waits 10 s on each).
    public var dialWaitPerEndpoint: Duration = .seconds(11)
    /// After the approval, how long the dialling server has to record the link (it asks every 2 s).
    public var recordWait: Duration = .seconds(30)

    private let log = Logger(subsystem: "sh.vaulthalla.app", category: "server-link")

    public init() {}

    /// Links `first` and `second`. `progress` hears where it is.
    public func link(_ first: Side, _ second: Side, progress: @escaping @Sendable (Step) -> Void = { _ in })
        async -> Result<Linked, Failure>
    {
        progress(.checking)
        let checked: (first: [LinkedServer], second: [LinkedServer])
        switch await check(first, second) {
        case .success(let lists): checked = lists
        case .failure(let failure): return .failure(failure)
        }
        if let existing = Self.existing(first, second, checked.first, checked.second) { return .failure(existing) }

        let state = Attempt()
        let outcome: Result<Linked, Failure> = await withTaskGroup { group in
            group.addTask {
                await self.bothWays(first, second, state: state, progress: progress)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .failure(Task.isCancelled ? .cancelled : .timedOut)
            }
            let first = await group.next() ?? .failure(.timedOut)
            group.cancelAll()
            return first
        }
        guard case .failure(let failure) = outcome else { return outcome }
        log.info("linking servers stopped: \(failure.description, privacy: .public)")
        if case .halfLinked = failure { return outcome }
        // Not inheriting the caller's cancellation: the clean-up must still reach both servers.
        progress(.cleaningUp)
        switch await Task(operation: { await self.cleanUp(state, first, second) }).value {
        case .undone: return .failure(failure)
        case .halfLinked(let half): return .failure(.halfLinked(half))
        case .completed(let linked): return .success(linked)
        }
    }

    /// The preconditions, on both servers before anything is opened. Their live links on success.
    public func check(_ first: Side, _ second: Side) async -> Result<([LinkedServer], [LinkedServer]), Failure> {
        for side in [first, second] where side.node.serverPin == nil {
            return .failure(.notPaired(side.name))
        }
        if first.node.serverPin == second.node.serverPin
            || (first.node.serverNodeID != nil && first.node.serverNodeID == second.node.serverNodeID)
        {
            return .failure(.sameServer)
        }
        async let a = Self.precheck(first)
        async let b = Self.precheck(second)
        let (lists, other) = await (a, b)
        switch (lists, other) {
        case (.success(let x), .success(let y)): return .success((x, y))
        case (.failure(let failure), _), (_, .failure(let failure)): return .failure(failure)
        }
    }

    private static func precheck(_ side: Side) async -> Result<[LinkedServer], Failure> {
        if await LinkedServers.supportsLinking(on: side.transport) == false { return .failure(.olderServer(side.name)) }
        do {
            let answer = try await side.transport.send(Ws.Peer.List.self, payload: .init())
            return .success(answer.peers.map(LinkedServer.init).filter { !$0.revoked })
        } catch {
            return .failure(.precondition(error, name: side.name))
        }
    }

    /// Already linked both ways, or one side holding a link the other lacks.
    private static func existing(_ a: Side, _ b: Side, _ aLinks: [LinkedServer], _ bLinks: [LinkedServer]) -> Failure? {
        let aHasB = aLinks.first { $0.serverSPKISHA256 == b.node.serverPin }
        let bHasA = bLinks.first { $0.serverSPKISHA256 == a.node.serverPin }
        switch (aHasB, bHasA) {
        case (.some, .some): return .alreadyLinked(a.name, b.name)
        case (let row?, nil):
            return .halfLinked(HalfLink(node: a.node.id, nodeName: a.name, peerID: row.id, peerName: row.name,
                                        otherName: b.name))
        case (nil, let row?):
            return .halfLinked(HalfLink(node: b.node.id, nodeName: b.name, peerID: row.id, peerName: row.name,
                                        otherName: a.name))
        case (nil, nil): return nil
        }
    }

    // MARK: - Directions

    /// The more reachable server accepts first; if that dial reaches nothing, the other way round.
    private func bothWays(_ first: Side, _ second: Side, state: Attempt, progress: @escaping @Sendable (Step) -> Void)
        async -> Result<Linked, Failure>
    {
        let (dialler, acceptor) = Self.reachability(second.node) >= Self.reachability(first.node)
            ? (first, second) : (second, first)
        let tried: Unreached
        switch await direction(dialler: dialler, acceptor: acceptor, state: state, progress: progress) {
        case .done(let result): return result
        case .unreached(let why): tried = why
        }
        if Task.isCancelled { return .failure(.cancelled) }
        await undo(state, dialler: dialler, acceptor: acceptor)
        state.reset()
        switch await direction(dialler: acceptor, acceptor: dialler, state: state, progress: progress) {
        case .done(let result): return result
        case .unreached(let why): return .failure(.noRoute(tried, why))
        }
    }

    enum DirectionOutcome {
        case done(Result<Linked, Failure>)
        /// The dial never reached the accepting server.
        case unreached(Unreached)
    }

    private func direction(dialler: Side, acceptor: Side, state: Attempt,
                           progress: @escaping @Sendable (Step) -> Void) async -> DirectionOutcome
    {
        guard let diallerPin = dialler.node.serverPin, let acceptorPin = acceptor.node.serverPin else {
            return .done(.failure(.notPaired(dialler.node.serverPin == nil ? dialler.name : acceptor.name)))
        }
        progress(.connecting(dialler: dialler.name, acceptor: acceptor.name))

        // 1. The window, on the accepting server.
        let window: Ws.Peer.Pairing.Open.Response
        do {
            window = try await acceptor.transport.send(Ws.Peer.Pairing.Open.self, payload: WsNoPayload())
            state.update { $0.window = acceptor.node.id }
        } catch {
            if case .conflict = error { return .done(.failure(.windowBusy(acceptor.name))) }
            return .done(.failure(Self.failure(error, on: acceptor.name)))
        }
        if Hex.decode(window.spkiSha256, length: 32) != acceptorPin
            || (acceptor.node.serverNodeID.map { $0 != window.nodeID } ?? false)
        {
            return .done(.failure(.refused(acceptor.name, "it answered with another server's identity")))
        }

        // 2. The dial, pinned to this Mac's key for the accepting server.
        let endpoints = Self.endpoints(for: acceptor.node, advertised: window.endpoints.candidates)
        guard !endpoints.isEmpty else {
            return .unreached(Unreached(dialler: dialler.name, acceptor: acceptor.name,
                                        reason: "\(acceptor.name) advertises no address"))
        }
        let link: Ws.Peer.Link.Start.Response.Link
        do {
            link = try await dialler.transport.send(Ws.Peer.Link.Start.self, payload: .init(
                endpoints: endpoints, expectSpki: .value(Hex.encode(acceptorPin)))).link
            state.update { $0.link = (dialler.node.id, link.linkID) }
        } catch {
            return .done(.failure(Self.failure(error, on: dialler.name)))
        }

        // 3. Until the dialling server shows its code (or gives up).
        let dialDeadline = ContinuousClock.now + dialWaitPerEndpoint * endpoints.count + .seconds(5)
        var status: LinkStatus
        while true {
            switch await linkStatus(link.linkID, on: dialler) {
            case .failure(let failure): return .done(.failure(failure))
            case .success(let read): status = read
            }
            if status.state != Ws.Peer.Link.Status.Response.Link.State.connecting { break }
            guard ContinuousClock.now < dialDeadline else { return .done(.failure(.timedOut)) }
            do { try await Task.sleep(for: pollInterval) } catch { return .done(.failure(.cancelled)) }
        }
        switch status.state {
        case Ws.Peer.Link.Status.Response.Link.State.awaitingApproval: break
        case Ws.Peer.Link.Status.Response.Link.State.failed where status.address == nil:
            state.update { $0.linkFinished = true }
            return .unreached(Unreached(dialler: dialler.name, acceptor: acceptor.name,
                                        reason: status.error ?? "no answer"))
        default:
            state.update { $0.linkFinished = true }
            return .done(.failure(Self.finished(status, dialler: dialler, acceptor: acceptor)))
        }
        guard let code = status.code.map(Self.digits), code.count == 6 else {
            return .done(.failure(.linkFailed(dialler.name, "it showed no code")))
        }
        if let peer = status.peer, Hex.decode(peer.spkiSha256, length: 32) != acceptorPin
            || (acceptor.node.serverNodeID.map { $0 != peer.nodeID } ?? false)
        {
            return .done(.failure(.unexpectedServer(dialler: dialler.name, acceptor: acceptor.name)))
        }
        progress(.approving(dialler: dialler.name, acceptor: acceptor.name))

        // 4. The request on the accepting server: from the dialling server's key, with its code among the choices.
        let request: Ws.Peer.Pairing.Pending.Response.Request
        switch await findRequest(on: acceptor, from: dialler, pin: diallerPin, state: state) {
        case .success(let found): request = found
        case .failure(let failure): return .done(.failure(failure))
        }
        guard request.codeChoices.contains(where: { Self.digits($0) == code }) else {
            return .done(.failure(.codeMismatch(dialler: dialler.name, acceptor: acceptor.name)))
        }

        // 5. The approval: the request, the code, and the key it must come from.
        let row: Ws.Peer.Pairing.Approve.Response.Peer
        do {
            row = try await acceptor.transport.send(Ws.Peer.Pairing.Approve.self, payload: .init(
                requestID: request.requestID, code: code, expectSpki: .value(Hex.encode(diallerPin)))).peer
            state.update { $0.approved = (acceptor.node.id, row.id, row.name) }
        } catch {
            // The node denies the request itself on a wrong code or key.
            if case .invalid = error { return .done(.failure(.codeMismatch(dialler: dialler.name, acceptor: acceptor.name))) }
            return .done(.failure(Self.failure(error, on: acceptor.name)))
        }

        // 6. The dialling server records it.
        progress(.finishing)
        let recordDeadline = ContinuousClock.now + recordWait
        while true {
            switch await linkStatus(link.linkID, on: dialler) {
            case .failure(let failure): return .done(.failure(failure))
            case .success(let read): status = read
            }
            if status.state == Ws.Peer.Link.Status.Response.Link.State.linked { break }
            if status.state != Ws.Peer.Link.Status.Response.Link.State.awaitingApproval {
                state.update { $0.linkFinished = true }
                return .done(.failure(Self.finished(status, dialler: dialler, acceptor: acceptor)))
            }
            guard ContinuousClock.now < recordDeadline else { return .done(.failure(.timedOut)) }
            do { try await Task.sleep(for: pollInterval) } catch { return .done(.failure(.cancelled)) }
        }
        state.update { $0.linkFinished = true; $0.linked = true }
        // The node closes its window when it approves; closing again is harmless.
        _ = try? await acceptor.transport.send(Ws.Peer.Pairing.Close.self, payload: WsNoPayload())
        state.update { $0.window = nil }
        return .done(.success(Linked(dialler: dialler.node.id, acceptor: acceptor.node.id,
                                     diallerPeerID: status.peerID, acceptorPeerID: row.id)))
    }

    struct LinkStatus {
        var state: String
        var code: String?
        var peer: Ws.Peer.Link.Status.Response.Link.Peer?
        var peerID: Int64?
        var address: String?
        var error: String?
    }

    private func linkStatus(_ id: String, on side: Side) async -> Result<LinkStatus, Failure> {
        do {
            let link = try await side.transport.send(Ws.Peer.Link.Status.self, payload: .init(linkID: id)).link
            return .success(LinkStatus(state: link.state, code: link.code, peer: link.peer, peerID: link.peerID,
                                       address: link.address, error: link.error))
        } catch {
            return .failure(Self.failure(error, on: side.name))
        }
    }

    private static func finished(_ status: LinkStatus, dialler: Side, acceptor: Side) -> Failure {
        switch status.state {
        case Ws.Peer.Link.Status.Response.Link.State.denied: .denied(acceptor.name)
        case Ws.Peer.Link.Status.Response.Link.State.expired: .expired
        case Ws.Peer.Link.Status.Response.Link.State.cancelled: .cancelled
        default: .linkFailed(dialler.name, status.error ?? "state \(status.state)")
        }
    }

    private func findRequest(on acceptor: Side, from dialler: Side, pin: Data, state: Attempt)
        async -> Result<Ws.Peer.Pairing.Pending.Response.Request, Failure>
    {
        let deadline = ContinuousClock.now + requestWait
        while true {
            let pending: Ws.Peer.Pairing.Pending.Response
            do {
                pending = try await acceptor.transport.send(Ws.Peer.Pairing.Pending.self, payload: WsNoPayload())
            } catch {
                return .failure(Self.failure(error, on: acceptor.name))
            }
            if let request = pending.requests.first(where: { Hex.decode($0.spkiSha256, length: 32) == pin }) {
                state.update { $0.request = request.requestID }
                if let nodeID = dialler.node.serverNodeID, request.nodeID != nodeID {
                    return .failure(.unexpectedRequest(acceptor.name, "it names another server id"))
                }
                return .success(request)
            }
            // A request in the dialling server's name from another key: declined, and nothing is linked.
            if let nodeID = dialler.node.serverNodeID,
               let impostor = pending.requests.first(where: { $0.nodeID == nodeID })
            {
                state.update { $0.request = impostor.requestID }
                return .failure(.wrongKey(dialler: dialler.name, acceptor: acceptor.name))
            }
            guard ContinuousClock.now < deadline else {
                return .failure(.unexpectedRequest(acceptor.name, "\(acceptor.name) never listed it"))
            }
            do { try await Task.sleep(for: pollInterval) } catch { return .failure(.cancelled) }
        }
    }

    // MARK: - Clean-up

    /// What the attempt got to, for undoing it.
    final class Attempt: Sendable {
        struct State {
            /// The node whose window this opened.
            var window: NodeID?
            /// The dialling node and its attempt.
            var link: (node: NodeID, id: String)?
            var linkFinished = false
            /// The request on the accepting node.
            var request: String?
            /// The accepting node approved: its row.
            var approved: (node: NodeID, peerID: Int64, name: String)?
            var linked = false
        }

        private let state = Mutex(State())
        func update(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
        var snapshot: State { state.withLock { $0 } }
        func reset() { state.withLock { $0 = State() } }
    }

    /// Undoes one direction: the dial cancelled, the request denied, the window closed. After an approval the dial
    /// is left to finish: cancelling it then is what would leave the accepting server's row alone.
    private func undo(_ attempt: Attempt, dialler: Side, acceptor: Side) async {
        let state = attempt.snapshot
        if let link = state.link, !state.linkFinished, state.approved == nil {
            _ = try? await dialler.transport.send(Ws.Peer.Link.Cancel.self, payload: .init(linkID: link.id))
        }
        if let request = state.request, state.approved == nil {
            _ = try? await acceptor.transport.send(Ws.Peer.Pairing.Deny.self, payload: .init(requestID: request))
        }
        if state.window != nil {
            _ = try? await acceptor.transport.send(Ws.Peer.Pairing.Close.self, payload: WsNoPayload())
        }
    }

    enum CleanUp {
        case undone
        /// Approved, and the dialling server didn't record it.
        case halfLinked(HalfLink)
        /// Approved, and the dialling server recorded it after all (late).
        case completed(Linked)
    }

    /// Undoes what the last direction got to; after an approval, finds out whether the dialling server recorded it.
    private func cleanUp(_ attempt: Attempt, _ first: Side, _ second: Side) async -> CleanUp {
        let state = attempt.snapshot
        guard !state.linked else { return .undone }
        let (dialler, acceptor): (Side, Side)
        if let link = state.link {
            (dialler, acceptor) = link.node == first.node.id ? (first, second) : (second, first)
        } else if let window = state.window {
            (dialler, acceptor) = window == first.node.id ? (second, first) : (first, second)
        } else {
            return .undone
        }
        await undo(attempt, dialler: dialler, acceptor: acceptor)
        guard let approved = state.approved else { return .undone }
        // Approved there: the dialling server may still record it (it asks every 2 s), or may have failed to.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let rows = try? await dialler.transport.send(Ws.Peer.List.self, payload: .init()).peers,
               let row = rows.first(where: { !$0.revoked && Hex.decode($0.spkiSha256, length: 32) == acceptor.node.serverPin })
            {
                _ = try? await acceptor.transport.send(Ws.Peer.Pairing.Close.self, payload: WsNoPayload())
                return .completed(Linked(dialler: dialler.node.id, acceptor: acceptor.node.id, diallerPeerID: row.id,
                                         acceptorPeerID: approved.peerID))
            }
            // The dial ended without recording it: what the accepting server holds is all there is.
            if let link = state.link, case .success(let status) = await linkStatus(link.id, on: dialler),
               status.state != Ws.Peer.Link.Status.Response.Link.State.awaitingApproval,
               status.state != Ws.Peer.Link.Status.Response.Link.State.linked
            {
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return .halfLinked(HalfLink(node: approved.node, nodeName: acceptor.name, peerID: approved.peerID,
                                    peerName: approved.name, otherName: dialler.name))
    }

    // MARK: - Helpers

    /// How reachable a node looks from elsewhere, by the best kind it advertises (loopback never counts): the more
    /// reachable one accepts.
    static func reachability(_ node: Node) -> Int {
        node.endpoints.compactMap(\.kind).filter { $0 != .loopback }.map(\.rank).max() ?? 0
    }

    /// Where the dialling server should look for `acceptor`: this Mac's own configured address for it first (unless it
    /// is this Mac), then what the accepting server advertises, the same network first and loopback last (it reaches
    /// the other server only when both run on one host), at most 32, each once.
    static func endpoints(for acceptor: Node, advertised: [Ws.Peer.Pairing.Open.Response.Endpoints.Candidate])
        -> [Ws.Peer.Link.Start.Payload.Endpoint]
    {
        let order = ["lan", "vpn", "passthrough", "wan", "manual"]
        func rank(_ kind: String?) -> Int {
            guard let kind else { return order.count }
            return kind == "loopback" ? order.count + 1 : order.firstIndex(of: kind) ?? order.count
        }
        var out: [(host: String, port: Int64, kind: String?)] = []
        if !Self.isLoopback(acceptor.endpoint.host) {
            out.append((acceptor.endpoint.host, Int64(acceptor.endpoint.port), nil))
        }
        let saved = acceptor.endpoints.map { (host: $0.host, port: Int64($0.port), kind: $0.kind?.rawValue) }
        let fresh = advertised.map { (host: $0.host, port: $0.port, kind: Optional($0.kind)) }
        let candidates = (fresh + saved).enumerated().sorted {
            rank($0.element.kind) != rank($1.element.kind) ? rank($0.element.kind) < rank($1.element.kind)
                : $0.offset < $1.offset
        }.map(\.element)
        for candidate in candidates
            where !out.contains(where: { $0.host.lowercased() == candidate.host.lowercased() && $0.port == candidate.port })
        {
            out.append(candidate)
        }
        return out.prefix(32).map { .init(host: $0.host, port: $0.port, kind: $0.kind.map { .value($0) }) }
    }

    static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered == "::1" || lowered.hasPrefix("127.")
    }

    static func digits(_ text: String) -> String { text.filter(\.isNumber) }

    static func failure(_ error: WsError, on name: String) -> Failure {
        .precondition(error, name: name)
    }
}
