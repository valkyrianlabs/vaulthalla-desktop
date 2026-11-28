import Foundation
import Testing
import VHContract
import VHCore
@testable import VHNodes
import VHTransport

/// The handshake around linking: which pairs All Nodes suggests, what the sheet offers when this Mac is a super admin
/// on one side only, the request and acceptance on each side, and the default roles chosen per direction.
@Suite(.timeLimit(.minutes(1))) struct LinkHandshakeTests {
    let lab = FakeLinkLab()

    var linking: ServerLinking {
        var linking = ServerLinking()
        linking.pollInterval = .milliseconds(5)
        linking.requestWait = .milliseconds(400)
        linking.dialWaitPerEndpoint = .milliseconds(300)
        linking.recordWait = .milliseconds(400)
        linking.timeout = .seconds(10)
        return linking
    }

    private static func node(_ i: Int, pin: UInt8) -> Node {
        Node(id: NodeID(rawValue: "n\(i)"), displayName: "server \(i)", endpoint: NodeEndpoint(host: "host-\(i)"),
             pairing: .paired(serverSPKISHA256: Data(repeating: pin, count: 32), deviceID: "mac", since: .now))
    }

    private static func row(to node: Node, id: Int64 = 1) -> LinkedServer {
        LinkedServer(id: id, serverNodeID: "id-\(node.id.rawValue)", name: node.displayName,
                     serverSPKISHA256: node.serverPin, comparedBy: "desktop", linkedAt: .now, productVersion: "1.27.1")
    }

    // MARK: - Suggestions

    @Test func twoUnlinkedNodesAreSuggestedOnceAndNothingElse() {
        let a = Self.node(0, pin: 0xA0), b = Self.node(1, pin: 0xB0), c = Self.node(2, pin: 0xC0)
        let older = Self.node(3, pin: 0xD0)
        var unpaired = Self.node(4, pin: 0xE0)
        unpaired.pairing = .unpaired
        let nodes = [a, b, c, older, unpaired]
        var availability: [NodeID: ServerLinkAvailability] = [a.id: .on([]), b.id: .on([]), older.id: .unsupported,
                                                               unpaired.id: .on([])]
        // c answered nothing yet: only a and b, in sidebar order, and only once.
        let found = LinkedServers.suggestions(nodes: nodes, availability: availability)
        #expect(found.map(\.id) == ["n0|n1"])
        #expect(found.first?.description == "server 0 and server 1 are not linked")

        // Linked both ways: no suggestion.
        availability[a.id] = .on([Self.row(to: b)])
        availability[b.id] = .on([Self.row(to: a)])
        #expect(LinkedServers.suggestions(nodes: nodes, availability: availability).isEmpty)

        // Only one side records it: offered for unlinking, never suggested.
        availability[b.id] = .on([])
        #expect(LinkedServers.suggestions(nodes: nodes, availability: availability).isEmpty)
        #expect(LinkedServers.oneSided(nodes: [a, b], links: [a.id: [Self.row(to: b)], b.id: []]).count == 1)

        // A revoked row is no link.
        var revoked = Self.row(to: b)
        revoked.revoked = true
        availability[a.id] = .on([revoked])
        #expect(LinkedServers.suggestions(nodes: nodes, availability: availability).map(\.id) == ["n0|n1"])
    }

    @Test func aOneSidedPairIsSuggestedOnlyWhenTheReadableSideHasNoLink() {
        let a = Self.node(0, pin: 0xA0), b = Self.node(1, pin: 0xB0)
        let refused = ServerLinking.Failure.notSuperAdmin("server 1", "only super admins may link servers")
        // A super admin on a only: b can't be read, a lists nothing, so they are not linked as far as this Mac knows.
        #expect(LinkedServers.suggestions(nodes: [a, b], availability: [a.id: .on([]), b.id: .notPermitted(refused)])
            .map(\.id) == ["n0|n1"])
        // a records a link to b: linked, as far as this Mac can tell.
        #expect(LinkedServers.suggestions(nodes: [a, b], availability: [a.id: .on([Self.row(to: b)]),
                                                                         b.id: .notPermitted(refused)]).isEmpty)
        // A super admin on neither: nothing this Mac could start, so nothing is suggested.
        #expect(LinkedServers.suggestions(nodes: [a, b], availability: [a.id: .notPermitted(refused),
                                                                         b.id: .notPermitted(refused)]).isEmpty)
    }

    @Test func thePlanFollowsWhereThisMacIsASuperAdmin() {
        let a = NodeID(rawValue: "a"), b = NodeID(rawValue: "b")
        let refused = ServerLinkAvailability.notPermitted(.notSuperAdmin("b", "no"))
        #expect(LinkedServers.plan(a, b, availability: [a: .on([]), b: .on([])]) == .handshake)
        #expect(LinkedServers.plan(a, b, availability: [a: .on([]), b: refused]) == .request(from: a, to: b))
        // The side that may ask is the one that dials, whichever was picked first.
        #expect(LinkedServers.plan(b, a, availability: [a: .on([]), b: refused]) == .request(from: a, to: b))
        #expect(LinkedServers.plan(a, nil, availability: [a: .on([])]) == .request(from: a, to: nil))
        #expect(LinkedServers.plan(b, nil, availability: [b: refused]) == LinkPlan.neither)
        #expect(LinkedServers.plan(a, b, availability: [a: refused, b: refused]) == LinkPlan.neither)
    }

    // MARK: - Requesting a link (one side)

    @Test func aRequestWithoutAWindowThereIsAPlainSentence() async throws {
        let id = try await LinkRequest.start(on: lab.side(0), to: NodeEndpoint(host: "host-1"), expect: nil).get()
        let status = try await LinkRequest.status(id, on: lab.side(0)).get()
        #expect(status.phase == .noWindow)
        #expect(LinkRequest.phase(state: "failed", code: nil,
                                  error: "no window for linking a server is open on this server: open one") == .noWindow)
        #expect(LinkRequest.phase(state: "failed", code: nil, error: "Connection refused") == .failed("Connection refused"))
        #expect(ServerLinking.Failure.noWindow("Mac Studio")
            == "Mac Studio has no window open for linking. Ask its admin to open Accept a link there first, then request again.")
    }

    @Test func aRequestIsApprovedOnTheOtherSideWithTheCodeAndTheKeyItShowed() async throws {
        // The other side's admin opens the window (here, with Desktop's Accept a link request).
        guard case .open(let window) = try await LinkAcceptance.open(on: lab.side(1)).get() else {
            throw TestFailure("busy")
        }
        #expect(window.key == lab.server(1).pin && window.addresses == ["host-1:36972"])

        // Pinned to the key this Mac knows for it.
        let id = try await LinkRequest.start(on: lab.side(0), to: NodeEndpoint(host: "host-1"),
                                             expect: lab.server(1).pin).get()
        #expect(lab.sessions[0].payloads(of: "peer.link.start").first?["expect_spki"]?.stringValue
            == Hex.encode(lab.server(1).pin))
        guard case .awaitingApproval(let code) = try await LinkRequest.status(id, on: lab.side(0)).get().phase else {
            throw TestFailure("no code")
        }
        #expect(LinkRequest.spaced(code).count == 7)

        let request = try #require(try await LinkAcceptance.pending(on: lab.side(1)).get()?.first)
        #expect(request.key == lab.server(0).pin && request.codeChoices.contains(code))
        #expect(try await LinkAcceptance.approve(request, code: code, on: lab.side(1)).get() == .linked(name: "vps"))
        let approve = try #require(lab.sessions[1].payloads(of: "peer.pairing.approve").first)
        #expect(approve["expect_spki"]?.stringValue == Hex.encode(lab.server(0).pin))
        #expect(try await LinkRequest.status(id, on: lab.side(0)).get().phase == .linked)
        #expect(lab.server(0).rows.count == 1 && lab.server(1).rows.count == 1)
    }

    @Test func aWrongCodeDeclinesAndCancelStopsTheAttempt() async throws {
        _ = try await LinkAcceptance.open(on: lab.side(1)).get()
        let id = try await LinkRequest.start(on: lab.side(0), to: NodeEndpoint(host: "host-1"), expect: nil).get()
        guard case .awaitingApproval(let code) = try await LinkRequest.status(id, on: lab.side(0)).get().phase else {
            throw TestFailure("no code")
        }
        let request = try #require(try await LinkAcceptance.pending(on: lab.side(1)).get()?.first)
        let wrong = try #require(request.codeChoices.first { $0 != code })
        #expect(try await LinkAcceptance.approve(request, code: wrong, on: lab.side(1)).get() == .wrongCode)
        #expect(try await LinkRequest.status(id, on: lab.side(0)).get().phase == .denied)
        #expect(lab.server(1).requests.map(\.state) == ["denied"] && lab.server(1).rows.isEmpty)

        // A second attempt, stopped by the requester: cancelled, and the window closed when the sheet closes.
        let again = try await LinkRequest.start(on: lab.side(0), to: NodeEndpoint(host: "host-1"), expect: nil).get()
        _ = try await LinkRequest.status(again, on: lab.side(0)).get()
        await LinkRequest.cancel(again, on: lab.side(0))
        #expect(try await LinkRequest.status(again, on: lab.side(0)).get().phase == .cancelled)
        await LinkAcceptance.close(on: lab.side(1))
        lab.expectClean()
    }

    @Test func aBusyWindowAndARefusalAreTold() async throws {
        lab.set { $0.servers[1].windowBusy = true }
        #expect(try await LinkAcceptance.open(on: lab.side(1)).get() == .busy)
        lab.set { $0.servers[0].superAdmin = false }
        let refused = await LinkRequest.start(on: lab.side(0), to: NodeEndpoint(host: "host-1"), expect: nil)
        guard case .failure(.notSuperAdmin("vps", _)) = refused else {
            Issue.record("\(refused)")
            return
        }
    }

    // MARK: - Default roles

    private func answerRoles(_ i: Int, refuse: Bool) {
        lab.sessions[i].answer("roles.vault.list") { _ in
            .ok(["roles": [Self.role(1, "implicit_deny"), Self.role(3, "Viewer"), Self.role(4, "Editor")]])
        }
        lab.sessions[i].answer("peer.policy.set") { json in
            if refuse {
                return .refuse("a linked server's default vault role reaches every vault mirrored with it: it takes "
                                + "vault.roles.assign on every vault", code: "denied")
            }
            let role: JSONValue = json["role"]?.integerValue.map { Self.role($0, $0 == 3 ? "Viewer" : "Editor") } ?? .null
            return .ok(["policy": ["peer": ["id": 1, "node_id": "peer", "name": "peer", "revoked": false], "role": role,
                                   "set_by": 1, "set_by_name": "admin", "set_at": 1_790_000_000]])
        }
    }

    private static func role(_ id: Int64, _ name: String) -> JSONValue {
        ["id": .integer(id), "name": .string(name), "description": "", "created_at": 1_790_000_000,
         "updated_at": 1_790_000_000, "assigned_at": .null, "permissions": []]
    }

    @Test func theRoleOptionsStartWithNoRoleAndLeaveOutNoAccess() async throws {
        answerRoles(0, refuse: false)
        let options = try await LinkRoles.options(on: lab.sessions[0]).get()
        #expect(options.map(\.name) == ["No role", "Viewer", "Editor"])
        #expect(options.first == .noRole && options.first?.roleID == nil)
    }

    @Test func aChosenRoleIsSetOnEachSideAndARefusalLeavesTheLink() async throws {
        answerRoles(0, refuse: false)
        answerRoles(1, refuse: true)
        _ = try await linking.link(lab.side(0), lab.side(1)).get()
        let viewer = LinkRoles.Option(roleID: 3, name: "Viewer")

        // vps gives Mac Studio "Viewer": peer.policy.set names Mac Studio by the key this Mac pins for it.
        let set = await LinkRoles.apply(viewer, on: lab.side(0), for: lab.node(1))
        #expect(set.outcome == .set(role: "Viewer"))
        #expect(set.description == "On vps, Mac Studio holds the role “Viewer” on vaults mirrored with it.")
        let payload = try #require(lab.sessions[0].payloads(of: "peer.policy.set").first)
        #expect(payload["peer"]?.stringValue == Hex.encode(lab.server(1).pin) && payload["role"]?.integerValue == 3)

        // Mac Studio refuses (no vault.roles.assign on every vault): said, with its words, and the link stays.
        let refused = await LinkRoles.apply(viewer, on: lab.side(1), for: lab.node(0))
        guard case .refused("Viewer", let why) = refused.outcome else {
            Issue.record("\(refused.outcome)")
            return
        }
        #expect(why.contains("vault.roles.assign"))
        #expect(refused.description.hasPrefix("Mac Studio didn't give vps the role “Viewer”"))
        #expect(lab.server(0).rows.filter { !$0.revoked }.count == 1 && lab.server(1).rows.filter { !$0.revoked }.count == 1)
        #expect(lab.sessions[1].count(of: "peer.unlink") == 0)

        // "No role" sends nothing.
        let none = await LinkRoles.apply(.noRole, on: lab.side(1), for: lab.node(0))
        #expect(none.outcome == .notChosen && lab.sessions[1].count(of: "peer.policy.set") == 1)
    }
}
