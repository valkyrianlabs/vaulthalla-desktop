public import Foundation
public import VHContract
public import VHCore
public import VHTransport

/// Two of this Mac's nodes that link servers and aren't linked with each other: All Nodes' quiet "A and B are not
/// linked" row. Only a suggestion: nothing happens until the person confirms in the Link Servers sheet, and the two
/// servers still shake hands there.
public struct LinkSuggestion: Identifiable, Hashable, Sendable {
    public var first: NodeID
    public var second: NodeID
    public var firstName: String
    public var secondName: String

    public var id: String { "\(first.rawValue)|\(second.rawValue)" }

    public var description: String { "\(firstName) and \(secondName) are not linked" }
}

/// What the Link Servers sheet can offer for two picks, by where this Mac's account is a super admin. The servers
/// still decide: every linking command is refused unless the caller is a super admin there.
public enum LinkPlan: Hashable, Sendable {
    /// A super admin on both: the one-screen handshake (``ServerLinking``), confirmed once.
    case handshake
    /// A super admin only on `from` (or the other server isn't paired here, `to` nil): `from` asks the other server,
    /// whose own admin approves it there.
    case request(from: NodeID, to: NodeID?)
    /// A super admin on neither: nothing can be started from this Mac.
    case neither
}

extension LinkedServers {
    /// Pairs of `nodes` (in order) that both link servers, where this Mac may act on at least one, and that neither
    /// side this Mac can read records as linked. A link only one side records isn't suggested (it is offered for
    /// unlinking instead), and nor is a pair whose readable side lists the other.
    public static func suggestions(nodes: [Node], availability: [NodeID: ServerLinkAvailability]) -> [LinkSuggestion] {
        let linkable = nodes.filter { $0.serverPin != nil && availability[$0.id]?.supportsLinking == true }
        var out: [LinkSuggestion] = []
        for (i, a) in linkable.enumerated() {
            for b in linkable[(i + 1)...] where a.serverPin != b.serverPin {
                let readable = [(a, b), (b, a)].filter { if case .on = availability[$0.0.id] { true } else { false } }
                guard !readable.isEmpty else { continue }
                let linked = readable.contains { side, other in
                    availability[side.id]?.links.contains { !$0.revoked && $0.serverSPKISHA256 == other.serverPin } == true
                }
                if !linked {
                    out.append(LinkSuggestion(first: a.id, second: b.id, firstName: a.displayName,
                                              secondName: b.displayName))
                }
            }
        }
        return out
    }

    /// What can be done for `first` and `second` (nil: a server this Mac isn't paired with, given by its address).
    public static func plan(_ first: NodeID, _ second: NodeID?, availability: [NodeID: ServerLinkAvailability])
        -> LinkPlan
    {
        func permitted(_ id: NodeID) -> Bool { if case .on = availability[id] { true } else { false } }
        guard let second else { return permitted(first) ? .request(from: first, to: nil) : .neither }
        switch (permitted(first), permitted(second)) {
        case (true, true): return .handshake
        case (true, false): return .request(from: first, to: second)
        case (false, true): return .request(from: second, to: first)
        case (false, false): return .neither
        }
    }
}

// MARK: - Default roles

/// A linked server's default role on vaults mirrored with it (`peer.policy.set`), chosen per direction in the Link
/// Servers sheet. "No role" is the server's own default: the link grants nothing on a vault without its own
/// assignment.
public enum LinkRoles {
    /// One choice: a vault role of the server that sets it, or none.
    public struct Option: Identifiable, Hashable, Sendable {
        /// The role's id; nil: no role.
        public var roleID: Int64?
        public var name: String

        public var id: String { roleID.map(String.init) ?? "none" }

        public static let noRole = Option(roleID: nil, name: "No role")

        public init(roleID: Int64?, name: String) {
            self.roleID = roleID
            self.name = name
        }
    }

    /// What became of one direction's choice after the link.
    public enum Outcome: Hashable, Sendable {
        /// "No role" was chosen: nothing was sent.
        case notChosen
        case set(role: String)
        /// The node refused (it needs `vault.roles.assign` on every vault), in its words. The link stays.
        case refused(role: String, why: String)
    }

    /// One direction's result: what `nodeName` gives `otherName`.
    public struct Applied: Identifiable, Hashable, Sendable, CustomStringConvertible {
        public var node: NodeID
        public var nodeName: String
        public var otherName: String
        public var outcome: Outcome

        public var id: String { node.rawValue }

        public var description: String {
            switch outcome {
            case .notChosen:
                "On \(nodeName), \(otherName) holds no role on vaults mirrored with it."
            case .set(let role):
                "On \(nodeName), \(otherName) holds the role “\(role)” on vaults mirrored with it."
            case .refused(let role, let why):
                "\(nodeName) didn't give \(otherName) the role “\(role)” (\(why)). The link stays, and \(otherName) "
                    + "holds no role there until a super admin of \(nodeName) sets one."
            }
        }
    }

    /// The choices on one node: "No role", then its vault roles (`roles.vault.list`) except `implicit_deny`, which is
    /// one vault's "no access" and never a link's default (the server refuses it).
    public static func options(on transport: any NodeTransport) async -> Result<[Option], WsError> {
        do {
            let roles = try await transport.send(Ws.Roles.Vault.List.self, payload: WsNoPayload()).roles
            return .success([.noRole] + roles.filter { $0.name != "implicit_deny" }
                .map { Option(roleID: $0.id, name: $0.name) })
        } catch {
            return .failure(error)
        }
    }

    /// Gives `other` the default role `option` on the node behind `side` (`peer.policy.set`, the peer named by the
    /// key this Mac pins for it). "No role" sends nothing. A refusal leaves the link as it is.
    public static func apply(_ option: Option, on side: ServerLinking.Side, for other: Node) async -> Applied {
        var applied = Applied(node: side.node.id, nodeName: side.node.displayName, otherName: other.displayName,
                              outcome: .notChosen)
        guard let roleID = option.roleID else { return applied }
        guard let pin = other.serverPin else {
            applied.outcome = .refused(role: option.name, why: "this Mac isn't paired with \(other.displayName)")
            return applied
        }
        do {
            let policy = try await side.transport.send(Ws.Peer.Policy.Set.self, payload: .init(
                peer: Hex.encode(pin), role: .integer(roleID))).policy
            applied.outcome = .set(role: policy.role?.name ?? option.name)
        } catch {
            applied.outcome = .refused(role: option.name, why: error.message)
        }
        return applied
    }
}

// MARK: - Asking another server

/// The one-sided path: this Mac is a super admin on one server only, so that server asks the other (`peer.link.start`)
/// and the other server's admin approves it there, comparing the code, as in the console's Link a server. Nothing
/// is approved from here.
public enum LinkRequest {
    /// Where an attempt stands (`peer.link.status`).
    public enum Phase: Hashable, Sendable {
        case connecting
        /// The other server has the request: its admin picks this code to approve.
        case awaitingApproval(code: String)
        case linked
        /// The other server has no window open for linking.
        case noWindow
        case denied
        case expired
        case cancelled
        /// The dialling server's words.
        case failed(String)

        public var isFinished: Bool {
            switch self {
            case .connecting, .awaitingApproval: false
            default: true
            }
        }
    }

    /// What the dialling server reported.
    public struct Status: Hashable, Sendable {
        public var phase: Phase
        /// The server it reached, by its own name, once it answered.
        public var peerName: String?
    }

    /// Where `from` should dial: the address as typed (`host`, `host:port`), its device port by default.
    public static func endpoint(_ text: String) -> NodeEndpoint? {
        NodeEndpoint(parsing: text)
    }

    /// `from` dials `endpoint` and asks to link; `expect` (this Mac's pin for the other server, when it is paired
    /// here) means only that key completes the handshake. The attempt's id.
    public static func start(on from: ServerLinking.Side, to endpoint: NodeEndpoint, expect: Data?)
        async -> Result<String, ServerLinking.Failure>
    {
        do {
            let link = try await from.transport.send(Ws.Peer.Link.Start.self, payload: .init(
                endpoints: [.init(host: endpoint.host, port: Int64(endpoint.port), kind: nil)],
                expectSpki: expect.map { .value(Hex.encode($0)) })).link
            return .success(link.linkID)
        } catch {
            return .failure(.precondition(error, name: from.node.displayName))
        }
    }

    public static func status(_ linkID: String, on from: ServerLinking.Side) async -> Result<Status, ServerLinking.Failure> {
        do {
            let link = try await from.transport.send(Ws.Peer.Link.Status.self, payload: .init(linkID: linkID)).link
            return .success(Status(phase: phase(state: link.state, code: link.code, error: link.error),
                                   peerName: link.peer?.name))
        } catch {
            return .failure(.precondition(error, name: from.node.displayName))
        }
    }

    /// Stops an attempt that hasn't finished (`peer.link.cancel`).
    public static func cancel(_ linkID: String, on from: ServerLinking.Side) async {
        _ = try? await from.transport.send(Ws.Peer.Link.Cancel.self, payload: .init(linkID: linkID))
    }

    /// The phase for a `peer.link.status` answer. The other server's `no_pairing_window` refusal reaches the dialling
    /// server as its words, so it is recognised by them.
    static func phase(state: String, code: String?, error: String?) -> Phase {
        typealias State = Ws.Peer.Link.Status.Response.Link.State
        switch state {
        case State.connecting: return .connecting
        case State.awaitingApproval:
            let digits = code.map(ServerLinking.digits) ?? ""
            return digits.count == 6 ? .awaitingApproval(code: digits) : .connecting
        case State.linked: return .linked
        case State.denied: return .denied
        case State.expired: return .expired
        case State.cancelled: return .cancelled
        default:
            let text = error ?? "state \(state)"
            return isNoWindow(text) ? .noWindow : .failed(text)
        }
    }

    public static func isNoWindow(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("no_pairing_window") || lowered.contains("no window for linking")
            || lowered.contains("no pairing window")
    }

    /// A six-digit code as people read it: `418 207`.
    public static func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }
}

extension ServerLinking.Failure {
    /// `no_pairing_window` refused at once, in a plain sentence naming the other server.
    public static func noWindow(_ other: String) -> String {
        "\(other) has no window open for linking. Ask its admin to open Accept a link there first, then request again."
    }
}

// MARK: - Accepting a request

/// The accepting side, on a node where this Mac is a super admin: its window (`peer.pairing.open`), the requests that
/// reach it (`peer.pairing.pending`), each approved with the code its admin picks and the key it showed
/// (`peer.pairing.approve` with `expect_spki`), or denied; the window closed when the person is done.
public enum LinkAcceptance {
    public struct Window: Hashable, Sendable {
        public var name: String
        public var key: Data?
        /// Where the other server can dial, as this one advertises it (loopback left out).
        public var addresses: [String]
        public var expiresAt: Date
    }

    public struct Request: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var key: Data?
        public var keyHex: String
        public var sourceIP: String
        public var codeChoices: [String]
    }

    public enum Opened: Hashable, Sendable {
        case open(Window)
        /// Another window (a device or a server being paired) is open there.
        case busy
    }

    public static func open(on side: ServerLinking.Side) async -> Result<Opened, ServerLinking.Failure> {
        do {
            let answer = try await side.transport.send(Ws.Peer.Pairing.Open.self, payload: WsNoPayload())
            let addresses = answer.endpoints.candidates.filter { $0.kind != "loopback" }.map { "\($0.host):\($0.port)" }
            return .success(.open(Window(name: answer.name, key: Hex.decode(answer.spkiSha256, length: 32),
                                         addresses: addresses,
                                         expiresAt: Date(timeIntervalSince1970: TimeInterval(answer.window.expiresAt)))))
        } catch {
            if case .conflict = error { return .success(.busy) }
            return .failure(.precondition(error, name: side.node.displayName))
        }
    }

    /// The requests waiting; nil when the window has closed (expired, or another approval closed it).
    public static func pending(on side: ServerLinking.Side) async -> Result<[Request]?, ServerLinking.Failure> {
        do {
            let answer = try await side.transport.send(Ws.Peer.Pairing.Pending.self, payload: WsNoPayload())
            guard answer.window != nil else { return .success(nil) }
            return .success(answer.requests.map {
                Request(id: $0.requestID, name: $0.name, key: Hex.decode($0.spkiSha256, length: 32),
                        keyHex: $0.spkiSha256, sourceIP: $0.sourceIP, codeChoices: $0.codeChoices.map(ServerLinking.digits))
            })
        } catch {
            return .failure(.precondition(error, name: side.node.displayName))
        }
    }

    public enum Decision: Hashable, Sendable {
        case linked(name: String)
        /// The code didn't match (the server declined the request).
        case wrongCode
        case expired
        case declined(name: String)
    }

    /// Approves `request` with `code`, accepting only the key it showed.
    public static func approve(_ request: Request, code: String, on side: ServerLinking.Side)
        async -> Result<Decision, ServerLinking.Failure>
    {
        do {
            let peer = try await side.transport.send(Ws.Peer.Pairing.Approve.self, payload: .init(
                requestID: request.id, code: ServerLinking.digits(code), expectSpki: .value(request.keyHex))).peer
            return .success(.linked(name: peer.name))
        } catch {
            switch error {
            case .invalid: return .success(.wrongCode)
            case .notFound: return .success(.expired)
            default: return .failure(.precondition(error, name: side.node.displayName))
            }
        }
    }

    public static func deny(_ request: Request, on side: ServerLinking.Side) async -> Result<Decision, ServerLinking.Failure> {
        do {
            _ = try await side.transport.send(Ws.Peer.Pairing.Deny.self, payload: .init(requestID: request.id))
            return .success(.declined(name: request.name))
        } catch {
            if case .notFound = error { return .success(.expired) }
            return .failure(.precondition(error, name: side.node.displayName))
        }
    }

    public static func close(on side: ServerLinking.Side) async {
        _ = try? await side.transport.send(Ws.Peer.Pairing.Close.self, payload: WsNoPayload())
    }
}
