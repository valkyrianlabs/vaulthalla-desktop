import CryptoKit
import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
@testable import VHNodes
import VHTransport

/// Two servers as `peer.*` answers them (the server's core/src/ops/Peers.cpp and peer/Links.cpp), each behind a
/// `ScriptedNode` standing for this Mac's Device session: windows, link attempts that dial, requests with three code
/// choices, approvals checked against the code and `expect_spki`, rows on both sides. `reach[i][j]` says whether server
/// i can dial server j.
final class FakeLinkLab: Sendable {
    struct Request: Sendable {
        var id: String
        var nodeID: String
        var spki: Data
        var code: String
        var choices: [String]
        var state = "pending"
    }

    struct Row: Sendable {
        var id: Int64
        var nodeID: String
        var name: String
        var spki: Data
        var comparedBy: String
        var revoked = false
    }

    struct Attempt: Sendable {
        var id: String
        var endpoints: [String]
        var expect: String?
        var state = "connecting"
        var code: String?
        var address: String?
        var error: String?
        var peerID: Int64?
        var requestID: String?
    }

    struct Server: Sendable {
        var name: String
        var nodeID: String
        var pin: Data
        var experimental = true
        var superAdmin = true
        var forbidden = false
        var tooOld = false
        var windowBusy = false
        var window = false
        var requests: [Request] = []
        var rows: [Row] = []
        var attempts: [Attempt] = []
        var nextRow: Int64 = 1
    }

    struct State: Sendable {
        var servers: [Server]
        var reach = [[false, true], [true, false]]
        /// The accepting server's choices miss the dialling server's code (something in between).
        var relay = false
        /// The request on the accepting server comes from another key, in the dialling server's name.
        var impostor = false
        /// The accepting server lists no request (the dial is still on its way).
        var holdRequests = false
        /// The dialling server fails to record the link after the approval.
        var failAfterApproval = false
        /// How many more times the dialling server still reports `awaiting_approval` after the approval.
        var stallAfterApproval = 0
    }

    let state: Mutex<State>
    let sessions = [ScriptedNode(), ScriptedNode()]

    func set(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
    var snapshot: State { state.withLock { $0 } }
    func server(_ i: Int) -> Server { snapshot.servers[i] }

    static func pin(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }

    init() {
        state = Mutex(State(servers: [
            Server(name: "vps", nodeID: "node-id-vps", pin: Self.pin("vps key")),
            Server(name: "Mac Studio", nodeID: "node-id-mac", pin: Self.pin("mac key")),
        ]))
        for i in 0..<2 { script(i) }
    }

    /// This Mac's record of server `i`, with what it advertised.
    func node(_ i: Int, kinds: [EndpointClass] = [.lan]) -> Node {
        let s = server(i)
        return Node(id: NodeID(rawValue: "node-\(i)"), displayName: s.name, endpoint: NodeEndpoint(host: "host-\(i)"),
                    pairing: .paired(serverSPKISHA256: s.pin, deviceID: "mac-device", since: .now),
                    isNamedByUser: true, serverNodeID: s.nodeID,
                    endpoints: kinds.map { AdvertisedEndpoint(host: "host-\(i)", port: 36972, kind: $0) })
    }

    func side(_ i: Int, kinds: [EndpointClass] = [.lan]) -> ServerLinking.Side {
        ServerLinking.Side(node: node(i, kinds: kinds), transport: sessions[i])
    }

    private func edit(_ i: Int, _ change: (inout Server) -> Void) { set { change(&$0.servers[i]) } }

    private func row(_ r: Row) -> JSONValue {
        ["id": .integer(r.id), "node_id": .string(r.nodeID), "name": .string(r.name),
         "spki_sha256": .string(Hex.encode(r.spki)), "next_spki_sha256": .null, "attest_public_keys": [],
         "wrap_public_key": "AAAA", "endpoints": [], "sharing": "identities", "approved_by": 1,
         "compared_by": .string(r.comparedBy), "peer_protocol": 1, "product_version": "1.27.0",
         "linked_at": 1_790_000_000, "last_seen_at": .null, "revoked_at": r.revoked ? 1_790_000_100 : .null,
         "revoked": .bool(r.revoked),
         "health": ["connected": true, "since": 1_790_000_000, "dialed_by": "this_server", "address": "host:36972",
                    "rtt_ms": 4, "peer_protocol": 1, "peer_version": "1.27.0", "protocol_compatible": true,
                    "last_error": .null, "last_error_at": .null, "next_attempt_at": .null]]
    }

    private func attempt(_ a: Attempt, peer other: Server?) -> JSONValue {
        let peer: JSONValue = a.state == "connecting" || other == nil ? .null
            : ["node_id": .string(other!.nodeID), "name": .string(other!.name), "product_version": "1.27.0",
               "spki_sha256": .string(Hex.encode(other!.pin))]
        return ["link": ["link_id": .string(a.id), "state": .string(a.state), "code": a.code.map(JSONValue.string) ?? .null,
                         "peer": peer, "peer_id": a.peerID.map(JSONValue.integer) ?? .null,
                         "expect_spki": a.expect.map(JSONValue.string) ?? .null,
                         "address": a.address.map(JSONValue.string) ?? .null,
                         "error": a.error.map(JSONValue.string) ?? .null, "created_at": 1_790_000_000,
                         "updated_at": 1_790_000_000]]
    }

    private func guarded(_ i: Int, _ body: @escaping @Sendable (JSONValue) -> ScriptedNode.Reply)
        -> @Sendable (JSONValue) -> ScriptedNode.Reply
    {
        { [self] json in
            let s = server(i)
            if s.tooOld { return .fail(.unknownCommand("Unknown command")) }
            if !s.experimental {
                return .refuse("linked servers are experimental and off on this server: set peers.experimental: true "
                    + "in config.yaml and restart the daemon", code: "peers_experimental")
            }
            if !s.superAdmin { return .refuse("only super admins may link servers", code: "denied") }
            if s.forbidden {
                return .refuse("only a person, or a fully trusted device connected directly, may link servers",
                               code: "peer_forbidden")
            }
            return body(json)
        }
    }

    private func script(_ i: Int) {
        let session = sessions[i]
        let other = 1 - i
        session.answer("peer.list", guarded(i) { [self] _ in
            .ok(["peers": .array(server(i).rows.map(row))])
        })
        session.answer("peer.pairing.open", guarded(i) { [self] _ in
            if server(i).windowBusy { return .refuse("a pairing window is already open", code: "conflict") }
            edit(i) { $0.window = true }
            let s = server(i)
            return .ok(["window": ["owner_id": 1, "opened_at": 1_790_000_000, "expires_at": 1_790_000_600],
                        "server_time": 1_790_000_000, "node_id": .string(s.nodeID), "name": .string(s.name),
                        "spki_sha256": .string(Hex.encode(s.pin)),
                        "endpoints": ["port": 36972, "remote": true, "listening": true, "generated_at": 1_790_000_000,
                                      "candidates": [["host": "127.0.0.1", "port": 36972, "kind": "loopback"],
                                                     ["host": .string("host-\(i)"), "port": 36972, "kind": "lan"]]]])
        })
        session.answer("peer.pairing.close", guarded(i) { [self] _ in
            edit(i) { s in
                s.window = false
                for r in s.requests.indices where s.requests[r].state == "pending" { s.requests[r].state = "expired" }
            }
            return .ok(["closed": true])
        })
        session.answer("peer.pairing.pending", guarded(i) { [self] _ in
            let held = snapshot.holdRequests
            let requests = held ? [] : server(i).requests.filter { $0.state == "pending" }.map { r -> JSONValue in
                ["request_id": .string(r.id), "node_id": .string(r.nodeID), "name": "dialler",
                 "product_version": "1.27.0", "peer_protocol": 1, "spki_sha256": .string(Hex.encode(r.spki)),
                 "source_ip": "10.0.0.2", "code_choices": .array(r.choices.map(JSONValue.string)),
                 "created_at": 1_790_000_000, "expires_at": 1_790_000_300]
            }
            return .ok(["window": server(i).window ? ["owner_id": 1, "opened_at": 1_790_000_000,
                                                      "expires_at": 1_790_000_600] : .null,
                        "requests": .array(requests), "server_time": 1_790_000_000])
        })
        session.answer("peer.pairing.deny", guarded(i) { [self] json in
            let id = json["request_id"]?.stringValue
            edit(i) { s in for r in s.requests.indices where s.requests[r].id == id { s.requests[r].state = "denied" } }
            return .ok(["denied": true])
        })
        session.answer("peer.pairing.approve", guarded(i) { [self] json in
            let id = json["request_id"]?.stringValue
            guard let request = server(i).requests.first(where: { $0.id == id && $0.state == "pending" }) else {
                return .refuse("no such request", code: "not_found")
            }
            let deny = { self.edit(i) { s in for r in s.requests.indices where s.requests[r].id == id { s.requests[r].state = "denied" } } }
            if let expect = json["expect_spki"]?.stringValue, expect != Hex.encode(request.spki) {
                deny()
                return .refuse("the requesting server's key is not the expected one", code: "invalid")
            }
            guard json["code"]?.stringValue == request.code else {
                deny()
                return .refuse("wrong code", code: "invalid")
            }
            let added = state.withLock { st -> Row in
                let o = st.servers[other]
                let r = Row(id: st.servers[i].nextRow, nodeID: request.nodeID, name: o.name, spki: request.spki,
                            comparedBy: json["expect_spki"] == nil ? "person" : "desktop")
                st.servers[i].nextRow += 1
                st.servers[i].rows.append(r)
                st.servers[i].window = false
                for k in st.servers[i].requests.indices where st.servers[i].requests[k].id == id {
                    st.servers[i].requests[k].state = "approved"
                }
                return r
            }
            var answer = row(added)
            if case .object(var object) = answer { object["health"] = nil; answer = .object(object) }
            return .ok(["peer": answer])
        })
        session.answer("peer.link.start", guarded(i) { [self] json in
            let hosts = json["endpoints"]?.arrayValue?.compactMap { $0["host"]?.stringValue } ?? []
            let a = Attempt(id: "link-\(i)-\(server(i).attempts.count + 1)", endpoints: hosts,
                            expect: json["expect_spki"]?.stringValue)
            edit(i) { $0.attempts.append(a) }
            return .ok(attempt(a, peer: nil))
        })
        session.answer("peer.link.status", guarded(i) { [self] json in
            let id = json["link_id"]?.stringValue
            let (a, target) = state.withLock { st -> (Attempt?, Server?) in
                guard let k = st.servers[i].attempts.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
                var a = st.servers[i].attempts[k]
                let o = st.servers[other]
                switch a.state {
                case "connecting":
                    if !st.reach[i][other] || !a.endpoints.contains("host-\(other)") {
                        a.state = "failed"
                        a.error = "host-\(other):36972: Connection timed out"
                    } else if let expect = a.expect, expect != Hex.encode(o.pin) {
                        a.state = "failed"
                        a.error = "the server's key is not the expected one"
                    } else if !o.window {
                        a.state = "failed"
                        a.address = "host-\(other):36972"
                        a.error = "no pairing window is open"
                    } else {
                        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
                        let decoys = ["111111", "222222"]
                        let choices = st.relay ? decoys + ["333333"] : [decoys[0], code, decoys[1]]
                        let spki = st.impostor ? Self.pin("impostor") : st.servers[i].pin
                        let request = Request(id: "req-\(other)-\(o.requests.count + 1)", nodeID: st.servers[i].nodeID,
                                              spki: spki, code: code, choices: choices)
                        st.servers[other].requests.append(request)
                        a.state = "awaiting_approval"
                        a.code = code
                        a.address = "host-\(other):36972"
                        a.requestID = request.id
                    }
                case "awaiting_approval":
                    let request = o.requests.first { $0.id == a.requestID }
                    switch request?.state {
                    case "approved" where st.stallAfterApproval > 0:
                        st.stallAfterApproval -= 1
                    case "approved" where st.failAfterApproval:
                        a.state = "failed"
                        a.error = "the other server approved, but this side could not record the link"
                    case "approved":
                        let r = Row(id: st.servers[i].nextRow, nodeID: o.nodeID, name: o.name, spki: o.pin,
                                    comparedBy: a.expect == nil ? "person" : "desktop")
                        st.servers[i].nextRow += 1
                        st.servers[i].rows.append(r)
                        a.state = "linked"
                        a.peerID = r.id
                    case "denied": a.state = "denied"
                    case "expired": a.state = "expired"
                    default: break
                    }
                default: break
                }
                st.servers[i].attempts[k] = a
                return (a, o)
            }
            guard let a else { return .refuse("no link attempt", code: "not_found") }
            return .ok(attempt(a, peer: target))
        })
        session.answer("peer.link.cancel", guarded(i) { [self] json in
            let id = json["link_id"]?.stringValue
            let a = state.withLock { st -> Attempt? in
                guard let k = st.servers[i].attempts.firstIndex(where: { $0.id == id }) else { return nil }
                if ["connecting", "awaiting_approval"].contains(st.servers[i].attempts[k].state) {
                    st.servers[i].attempts[k].state = "cancelled"
                }
                return st.servers[i].attempts[k]
            }
            guard let a else { return .refuse("no link attempt", code: "not_found") }
            return .ok(attempt(a, peer: nil))
        })
        session.answer("peer.unlink", guarded(i) { [self] json in
            let ref = Int64(json["peer"]?.stringValue ?? "") ?? -1
            guard let index = server(i).rows.firstIndex(where: { $0.id == ref && !$0.revoked }) else {
                return .refuse("no linked server", code: "not_found")
            }
            edit(i) { $0.rows[index].revoked = true }
            var answer = row(server(i).rows[index])
            if case .object(var object) = answer { object["health"] = nil; answer = .object(object) }
            return .ok(["peer": answer])
        })
        session.answer("peer.rename", guarded(i) { [self] json in
            let ref = Int64(json["peer"]?.stringValue ?? "") ?? -1
            guard let index = server(i).rows.firstIndex(where: { $0.id == ref }) else {
                return .refuse("no linked server", code: "not_found")
            }
            edit(i) { $0.rows[index].name = json["name"]?.stringValue ?? "" }
            var answer = row(server(i).rows[index])
            if case .object(var object) = answer { object["health"] = nil; answer = .object(object) }
            return .ok(["peer": answer])
        })
    }

    /// Nothing left behind: no window open, no request pending, no dial in progress.
    func expectNothingPending(sourceLocation: SourceLocation = #_sourceLocation) {
        for i in 0..<2 {
            let s = server(i)
            #expect(!s.window, "\(s.name) still has a window open", sourceLocation: sourceLocation)
            #expect(!s.requests.contains { $0.state == "pending" }, "\(s.name) has a pending request",
                    sourceLocation: sourceLocation)
            #expect(!s.attempts.contains { ["connecting", "awaiting_approval"].contains($0.state) },
                    "\(s.name) is still dialling", sourceLocation: sourceLocation)
        }
    }

    /// And no link either.
    func expectClean(sourceLocation: SourceLocation = #_sourceLocation) {
        expectNothingPending(sourceLocation: sourceLocation)
        for i in 0..<2 {
            #expect(!server(i).rows.contains { !$0.revoked }, "\(server(i).name) records a link",
                    sourceLocation: sourceLocation)
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct ServerLinkingTests {
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

    // MARK: - Happy paths

    @Test func linksWithTheFirstDialling() async throws {
        let steps = Mutex<[ServerLinking.Step]>([])
        let result = await linking.link(lab.side(0), lab.side(1)) { step in steps.withLock { $0.append(step) } }
        let linked = try result.get()
        #expect(linked.dialler == NodeID(rawValue: "node-0") && linked.acceptor == NodeID(rawValue: "node-1"))

        // Each side records the other's pinned key; the accepting side records that Desktop compared the code.
        let vps = lab.server(0), mac = lab.server(1)
        #expect(vps.rows.map(\.spki) == [mac.pin] && mac.rows.map(\.spki) == [vps.pin])
        #expect(mac.rows.first?.comparedBy == "desktop" && vps.rows.first?.comparedBy == "desktop")
        #expect(linked.acceptorPeerID == mac.rows.first?.id && linked.diallerPeerID == vps.rows.first?.id)
        lab.expectNothingPending()

        // The dial is pinned to this Mac's key for the accepting server, this Mac's address for it first and loopback
        // last; the approval names the dialling server's key and carries its code.
        let start = try #require(lab.sessions[0].payloads(of: "peer.link.start").first)
        #expect(start["expect_spki"]?.stringValue == Hex.encode(mac.pin))
        #expect(start["endpoints"]?.arrayValue?.compactMap { $0["host"]?.stringValue } == ["host-1", "127.0.0.1"])
        let approve = try #require(lab.sessions[1].payloads(of: "peer.pairing.approve").first)
        #expect(approve["expect_spki"]?.stringValue == Hex.encode(vps.pin))
        #expect(approve["code"]?.stringValue == vps.attempts.first?.code)
        #expect(lab.sessions[0].count(of: "peer.pairing.open") == 0)
        #expect(steps.withLock { $0 }.first == .checking)
        #expect(steps.withLock { $0 }.contains(.approving(dialler: "vps", acceptor: "Mac Studio")))
    }

    @Test func theMoreReachableServerAccepts() async throws {
        // vps advertises a public address, Mac Studio only its LAN: Mac Studio dials vps.
        let linked = try await linking.link(lab.side(0, kinds: [.wan, .lan]), lab.side(1, kinds: [.lan])).get()
        #expect(linked.dialler == NodeID(rawValue: "node-1") && linked.acceptor == NodeID(rawValue: "node-0"))
        #expect(lab.sessions[1].count(of: "peer.pairing.open") == 0)
    }

    @Test func anUnreachableDirectionIsUndoneAndTheOtherTried() async throws {
        lab.set { $0.reach = [[false, false], [true, false]] }  // only Mac Studio reaches vps
        let linked = try await linking.link(lab.side(0), lab.side(1)).get()
        #expect(linked.dialler == NodeID(rawValue: "node-1") && linked.acceptor == NodeID(rawValue: "node-0"))
        // The first try opened Mac Studio's window and dialled from vps; both were undone before the second.
        #expect(lab.server(0).attempts.map(\.state) == ["failed"])
        #expect(lab.sessions[1].count(of: "peer.pairing.close") >= 1)
        #expect(lab.server(0).rows.count == 1 && lab.server(1).rows.count == 1)
        lab.expectNothingPending()
    }

    // MARK: - Preconditions, before anything is opened

    @Test func eachPreconditionNamesTheNodeAndOpensNothing() async throws {
        typealias Case = (change: @Sendable (inout FakeLinkLab.State) -> Void, expect: (ServerLinking.Failure) -> Bool)
        let cases: [Case] = [
            ({ $0.servers[1].experimental = false }, { $0 == .switchedOff("Mac Studio") }),
            ({ $0.servers[0].tooOld = true }, { $0 == .olderServer("vps") }),
            ({ $0.servers[1].superAdmin = false }, { if case .notSuperAdmin("Mac Studio", _) = $0 { true } else { false } }),
            ({ $0.servers[0].forbidden = true }, { if case .notTrusted("vps", _) = $0 { true } else { false } }),
        ]
        for (change, expect) in cases {
            let lab = FakeLinkLab()
            lab.set(change)
            let result = await linking.link(lab.side(0), lab.side(1))
            guard case .failure(let failure) = result else { Issue.record("linked anyway"); continue }
            #expect(expect(failure), "\(failure)")
            for i in 0..<2 {
                #expect(lab.sessions[i].count(of: "peer.pairing.open") == 0)
                #expect(lab.sessions[i].count(of: "peer.link.start") == 0)
            }
        }
        // The switch's explanation says what to do.
        #expect(ServerLinking.Failure.switchedOff("Mac Studio").description
            .contains("set `peers.experimental: true` in that server's config.yaml and restart it"))
    }

    @Test func anOlderServerIsKnownWithoutAsking() async throws {
        lab.sessions[1].commands.withLock { $0["peer.list"] = .no }
        #expect(await linking.link(lab.side(0), lab.side(1)) == .failure(.olderServer("Mac Studio")))
        #expect(lab.sessions[1].count(of: "peer.list") == 0)
    }

    @Test func offlineUnpairedAndTheSameServer() async throws {
        lab.sessions[0].stop()
        #expect(await linking.link(lab.side(0), lab.side(1)) == .failure(.offline("vps")))

        var unpaired = lab.side(1)
        unpaired.node.pairing = .unpaired
        #expect(await linking.link(FakeLinkLab().side(0), unpaired) == .failure(.notPaired("Mac Studio")))

        let fresh = FakeLinkLab()
        #expect(await linking.link(fresh.side(0), fresh.side(0)) == .failure(.sameServer))
        #expect(fresh.sessions[0].count(of: "peer.list") == 0)
    }

    @Test func anExistingLinkIsReportedAndAOneSidedOneOffered() async throws {
        _ = try await linking.link(lab.side(0), lab.side(1)).get()
        #expect(await linking.link(lab.side(0), lab.side(1)) == .failure(.alreadyLinked("vps", "Mac Studio")))

        // vps forgets its side: Mac Studio's row is left over, offered for unlinking, and nothing is opened.
        lab.set { $0.servers[0].rows = [] }
        let opened = lab.sessions[1].count(of: "peer.pairing.open")
        guard case .failure(.halfLinked(let half)) = await linking.link(lab.side(0), lab.side(1)) else {
            Issue.record("not reported")
            return
        }
        #expect(half.node == NodeID(rawValue: "node-1") && half.peerID == lab.server(1).rows.first?.id)
        #expect(lab.sessions[1].count(of: "peer.pairing.open") == opened)
    }

    @Test func aBusyWindowIsExplained() async throws {
        lab.set { $0.servers[1].windowBusy = true }
        #expect(await linking.link(lab.side(0), lab.side(1)) == .failure(.windowBusy("Mac Studio")))
        lab.expectClean()
    }

    // MARK: - The request and the code

    @Test func aRequestFromAnotherKeyIsDeclined() async throws {
        lab.set { $0.impostor = true }
        #expect(await linking.link(lab.side(0), lab.side(1))
            == .failure(.wrongKey(dialler: "vps", acceptor: "Mac Studio")))
        #expect(lab.server(1).requests.map(\.state) == ["denied"])
        #expect(lab.sessions[1].count(of: "peer.pairing.approve") == 0)
        #expect(lab.server(0).attempts.map(\.state) == ["cancelled"])
        lab.expectClean()
    }

    @Test func aCodeMissingFromTheChoicesIsDeclined() async throws {
        lab.set { $0.relay = true }
        #expect(await linking.link(lab.side(0), lab.side(1))
            == .failure(.codeMismatch(dialler: "vps", acceptor: "Mac Studio")))
        #expect(lab.server(1).requests.map(\.state) == ["denied"])
        #expect(lab.sessions[1].count(of: "peer.pairing.approve") == 0)
        lab.expectClean()
    }

    // MARK: - Reachability

    @Test func neitherWayReachesAndBothAreUndone() async throws {
        lab.set { $0.reach = [[false, false], [false, false]] }
        let result = await linking.link(lab.side(0), lab.side(1))
        guard case .failure(.noRoute(let first, let second)) = result else {
            Issue.record("\(result)")
            return
        }
        #expect(first.dialler == "vps" && first.acceptor == "Mac Studio" && first.reason.contains("timed out"))
        #expect(second.dialler == "Mac Studio" && second.acceptor == "vps")
        #expect(ServerLinking.Failure.noRoute(first, second).description
            .contains("the same network, a VPN, or a forwarded port on one of them"))
        lab.expectClean()
    }

    // MARK: - Stopping midway

    @Test func cancellingMidwayUndoesEverything() async throws {
        lab.set { $0.holdRequests = true }
        var slow = linking
        slow.requestWait = .seconds(30)
        let task = Task { await slow.link(lab.side(0), lab.side(1)) }
        let deadline = ContinuousClock.now + .seconds(5)
        while lab.server(0).attempts.first?.state != "awaiting_approval" {
            guard ContinuousClock.now < deadline else { throw TestFailure("never awaited approval") }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        #expect(await task.value == .failure(.cancelled))
        #expect(lab.server(0).attempts.map(\.state) == ["cancelled"])
        // This Mac never saw the request, so it couldn't deny it: closing the window expired it.
        #expect(lab.server(1).requests.map(\.state) == ["expired"])
        lab.expectClean()
    }

    @Test func runningOutOfTimeUndoesEverything() async throws {
        lab.set { $0.holdRequests = true }
        var slow = linking
        slow.requestWait = .seconds(30)
        slow.timeout = .milliseconds(300)
        #expect(await slow.link(lab.side(0), lab.side(1)) == .failure(.timedOut))
        lab.expectClean()
    }

    // MARK: - One side records it

    @Test func aLinkOnlyTheAcceptingSideRecordsIsFoundAndCanBeUnlinked() async throws {
        lab.set { $0.failAfterApproval = true }
        let result = await linking.link(lab.side(0), lab.side(1))
        guard case .failure(.halfLinked(let half)) = result else {
            Issue.record("\(result)")
            return
        }
        #expect(half.node == NodeID(rawValue: "node-1") && half.nodeName == "Mac Studio" && half.otherName == "vps")
        #expect(half.description.contains("Unlink it on Mac Studio"))
        lab.expectNothingPending()

        // The All Nodes list finds the same from both nodes' reports.
        let nodes = [lab.node(0), lab.node(1)]
        var links: [NodeID: [LinkedServer]] = [:]
        for i in 0..<2 { links[nodes[i].id] = await LinkedServers.availability(on: lab.sessions[i], name: "x").links }
        #expect(LinkedServers.oneSided(nodes: nodes, links: links) == [half])

        try await LinkedServers.unlink(half.peerID, on: lab.sessions[1])
        lab.expectClean()
        #expect(await LinkedServers.availability(on: lab.sessions[1], name: "Mac Studio") == .on([]))
    }

    @Test func aDiallerThatRecordsLateIsNotCancelled() async throws {
        // Past the wait for the record, but approved: the dial is left alone, and once it records, it is linked.
        var short = linking
        short.recordWait = .milliseconds(20)
        lab.set { $0.stallAfterApproval = 8 }
        let linked = try await short.link(lab.side(0), lab.side(1)).get()
        #expect(linked.dialler == NodeID(rawValue: "node-0"))
        #expect(lab.server(0).attempts.map(\.state) == ["linked"])
        #expect(lab.server(0).rows.count == 1 && lab.server(1).rows.count == 1)
        lab.expectNothingPending()
    }

    // MARK: - Per node

    @Test func availabilityHidesASwitchedOffNode() async throws {
        #expect(await LinkedServers.availability(on: lab.sessions[0], name: "vps") == .on([]))
        lab.set { $0.servers[0].experimental = false }
        #expect(await LinkedServers.availability(on: lab.sessions[0], name: "vps") == .off)
        #expect(!ServerLinkAvailability.off.isOn)
        lab.set { $0.servers[0].tooOld = true }
        #expect(await LinkedServers.availability(on: lab.sessions[0], name: "vps") == .unsupported)
        lab.set { $0.servers[1].superAdmin = false }
        let refused = await LinkedServers.availability(on: lab.sessions[1], name: "Mac Studio")
        #expect(refused.isOn && refused.links.isEmpty)
        lab.sessions[1].stop()
        #expect(await !LinkedServers.availability(on: lab.sessions[1], name: "Mac Studio").isOn)
    }

    @Test func linkedServersCarryHealthAndCanBeRenamed() async throws {
        _ = try await linking.link(lab.side(0), lab.side(1)).get()
        let rows = await LinkedServers.availability(on: lab.sessions[0], name: "vps").links
        let row = try #require(rows.first)
        #expect(row.name == "Mac Studio" && row.comparedBy == "desktop" && row.serverSPKISHA256 == lab.server(1).pin)
        #expect(row.health.connected && row.health.dialedBy == .thisServer && row.health.roundTrip == .milliseconds(4))
        try await LinkedServers.rename(row.id, to: "studio", on: lab.sessions[0])
        #expect(await LinkedServers.availability(on: lab.sessions[0], name: "vps").links.first?.name == "studio")
    }
}
