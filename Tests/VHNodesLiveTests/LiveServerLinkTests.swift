import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
import VHIdentity
import VHNodes
import VHTransport

/// Desktop-brokered server linking (the server's design/peers/link.md) against two live daemons with
/// `peers.experimental: true` (docs/interop-testing.md, "Linked servers"): this Mac pairs with both as their super
/// admin, then ``ServerLinking`` links them through this Mac's real Device sessions, both ways round, and unlinks them.
/// Skipped unless `VH_LIVE_LINK_A` and `VH_LIVE_LINK_B` are set.
@Suite(.enabled(if: LiveLink.isConfigured, "set VH_LIVE_LINK_A and VH_LIVE_LINK_B=<host:port> to run"),
       .serialized, .timeLimit(.minutes(10)))
struct LiveServerLinkTests {
    @Test func linksTwoServersBothWaysAndUnlinksThem() async throws {
        let (endpointA, endpointB) = try LiveLink.requireEndpoints()
        try await LiveKeychain.withKeys { keys in
            let a = try await LiveLink.pair(keys, tag: "live-link-a", name: "link-a", endpoint: endpointA,
                                            run: LiveLink.runA)
            let b = try await LiveLink.pair(keys, tag: "live-link-b", name: "link-b", endpoint: endpointB,
                                            run: LiveLink.runB)
            var sessions: [NodeSession] = []
            defer {
                let stopping = sessions
                Task { for session in stopping { await session.stop() } }
            }
            for node in [a.node, b.node] {
                var settings = NodeSession.Configuration()
                settings.reconnect = ReconnectPolicy(base: .milliseconds(200), cap: .seconds(2))
                let session = NodeSession(node: node, keys: keys, configuration: settings)
                let events = Recorder(session.events)
                await session.start()
                try #require(await events.first(within: .seconds(20)) { $0.status == .online } != nil,
                             "\(node.displayName) never came online: \(events.all)")
                sessions.append(session)
            }
            let sideA = ServerLinking.Side(node: a.node, transport: sessions[0])
            let sideB = ServerLinking.Side(node: b.node, transport: sessions[1])

            // Both report the feature on, and nothing linked yet.
            #expect(await LinkedServers.availability(on: sessions[0], name: "link-a") == .on([]))
            #expect(await LinkedServers.availability(on: sessions[1], name: "link-b") == .on([]))

            // 1. A dials B (equal reachability: the first dials), with one confirmation and no code shown.
            let steps = StepLog()
            let first = await ServerLinking().link(sideA, sideB) { steps.add($0) }
            let linked = try first.get()
            #expect(linked.dialler == a.node.id && linked.acceptor == b.node.id)
            print("[live] linked: \(steps.all)")
            try await LiveLink.expectLinked(dialler: a, acceptor: b)

            // Desktop's own view: each side lists the other, connected, with its health.
            let rowsA = await LinkedServers.availability(on: sessions[0], name: "link-a").links
            let rowA = try #require(rowsA.first { $0.serverSPKISHA256 == b.node.serverPin })
            #expect(rowA.comparedBy == "desktop")
            print("[live] link-a sees \(rowA.name): connected \(rowA.health.connected), dialled by "
                + "\(String(describing: rowA.health.dialedBy)), rtt \(String(describing: rowA.health.roundTrip))")

            // Linking again is refused before anything is opened.
            #expect(await ServerLinking().link(sideA, sideB) == .failure(.alreadyLinked("link-a", "link-b")))

            // 2. Rename on one side only, then unlink from A: B is told and revokes its side too.
            try await LinkedServers.rename(rowA.id, to: "Linked B", on: sessions[0])
            #expect(try await LiveLink.live(on: LiveLink.runA).first?["name"]?.stringValue == "Linked B")
            try await LinkedServers.unlink(rowA.id, on: sessions[0])
            try await LiveLink.waitUntilUnlinked()
            print("[live] unlinked through Desktop; both sides revoked")

            // 3. The other way round: B dials A.
            var bFirst = sideB.node
            bFirst.endpoints = []
            var aMoreReachable = sideA.node
            aMoreReachable.endpoints = [AdvertisedEndpoint(host: endpointA.host, port: endpointA.port, kind: .wan)]
            let second = try await ServerLinking().link(ServerLinking.Side(node: aMoreReachable, transport: sessions[0]),
                                                        ServerLinking.Side(node: bFirst, transport: sessions[1])).get()
            #expect(second.dialler == b.node.id && second.acceptor == a.node.id)
            try await LiveLink.expectLinked(dialler: b, acceptor: a)
            let rowB = try #require(await LinkedServers.availability(on: sessions[1], name: "link-b").links.first)
            try await LinkedServers.unlink(rowB.id, on: sessions[1])
            try await LiveLink.waitUntilUnlinked()
            print("[live] linked the other way round and unlinked again")

            // Nothing left: no window, no request.
            for run in [LiveLink.runA, LiveLink.runB] {
                let pending = try await LiveLink.vhJSON(["peer", "pending"], run: run)
                #expect(pending["requests"]?.arrayValue?.isEmpty ?? true)
                #expect(pending["window"] == nil || pending["window"] == .null)
            }

            for session in sessions { await session.stop() }
            sessions = []
            for paired in [a, b] {
                try await LiveLink.vh(["device", "revoke", paired.deviceID], run: paired.run)
            }
        }
    }
}

final class StepLog: Sendable {
    private let steps = Mutex<[ServerLinking.Step]>([])
    func add(_ step: ServerLinking.Step) { steps.withLock { $0.append(step) } }
    var all: [ServerLinking.Step] { steps.withLock { $0 } }
}

/// The two instances: `vh-instance.sh` run dirs on the box (`VH_LIVE_LINK_RUN_A`, `_B`), their device listeners as this
/// Mac reaches them (`VH_LIVE_LINK_A`, `_B`), each started with `peers: {experimental: true}` in its config.yaml.
enum LiveLink {
    private static let environment = ProcessInfo.processInfo.environment
    static let endpointA = environment["VH_LIVE_LINK_A"].flatMap(NodeEndpoint.init(parsing:))
    static let endpointB = environment["VH_LIVE_LINK_B"].flatMap(NodeEndpoint.init(parsing:))
    static let runA = environment["VH_LIVE_LINK_RUN_A"] ?? "/tmp/vhi_link_a"
    static let runB = environment["VH_LIVE_LINK_RUN_B"] ?? "/tmp/vhi_link_b"
    static var isConfigured: Bool { endpointA != nil && endpointB != nil }

    static func requireEndpoints() throws -> (NodeEndpoint, NodeEndpoint) {
        guard let endpointA, let endpointB else { throw LiveFailure("VH_LIVE_LINK_A/B are not set") }
        return (endpointA, endpointB)
    }

    struct Paired {
        var node: Node
        var deviceID: String
        var run: String
    }

    @discardableResult
    static func vh(_ arguments: [String], run: String) async throws -> String {
        try await LiveNode.remote(["\(run)/vh-admin"] + arguments)
    }

    static func vhJSON(_ arguments: [String], run: String) async throws -> JSONValue {
        let text = try await vh(arguments + ["--json"], run: run)
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Pairs this Mac's test key with the instance as its super admin (`vh-admin`: the window is theirs, so the device
    /// acts as them), comparing the code through `vh` as ``LocalPairing`` does.
    static func pair(_ keys: DeviceKeys, tag: String, name: String, endpoint: NodeEndpoint, run: String)
        async throws -> Paired
    {
        let admin = LocalPairing { arguments in
            do {
                return .init(status: 0, stdout: try await vh(arguments, run: run))
            } catch {
                return .init(status: 1, stdout: "", stderr: String(describing: error))
            }
        }
        let identity = try await keys.identityForPairing(nodeTag: tag, deviceName: "Link Test Mac",
                                                         replacingExisting: true)
        try await admin.openWindow()
        let client = PairingClient(identity: identity, configuration: .init(
            endpoint: endpoint, deviceName: "Link Test Mac", appVersion: "0.0.0-interop"))
        let states = Recorder(client.start())
        defer { client.cancel() }
        let waiting = await states.first(within: .seconds(30)) { if case .awaitingApproval = $0 { true } else { false } }
        guard case .awaitingApproval(let code) = waiting else { throw LiveFailure("no code shown: \(states.all)") }
        try await admin.approve(deviceID: identity.deviceID, code: code.digits)
        let final = await states.first(within: .seconds(30)) { $0.isFinal }
        await admin.closeWindow()
        guard case .approved(let serverNodeID, _, let deviceID, let serverSPKI) = final else {
            throw LiveFailure("pairing with \(name) ended \(String(describing: final))")
        }
        print("[live] paired with \(name) as its super admin")
        let node = Node(id: NodeID(rawValue: tag), displayName: name, endpoint: endpoint,
                        pairing: .paired(serverSPKISHA256: serverSPKI, deviceID: deviceID, since: .now),
                        isNamedByUser: true, serverNodeID: serverNodeID)
        return Paired(node: node, deviceID: deviceID, run: run)
    }

    /// The live rows `vh peer list` reports.
    static func live(on run: String) async throws -> [JSONValue] {
        let list = try await vhJSON(["peer", "list"], run: run)
        return (list["peers"]?.arrayValue ?? []).filter { $0["revoked"] != true }
    }

    /// `vh peer list` on both: one live row each for the other's key, compared by Desktop, connected.
    static func expectLinked(dialler: Paired, acceptor: Paired) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        var last: (JSONValue?, JSONValue?) = (nil, nil)
        while ContinuousClock.now < deadline {
            let rowD = try await live(on: dialler.run).first {
                $0["spki_sha256"]?.stringValue == acceptor.node.serverPin?.hex
            }
            let rowA = try await live(on: acceptor.run).first {
                $0["spki_sha256"]?.stringValue == dialler.node.serverPin?.hex
            }
            last = (rowD, rowA)
            if rowD?["health"]?["connected"] == true, rowA?["health"]?["connected"] == true {
                #expect(rowD?["compared_by"] == "desktop" && rowA?["compared_by"] == "desktop")
                #expect(rowD?["node_id"]?.stringValue == acceptor.node.serverNodeID)
                #expect(rowA?["node_id"]?.stringValue == dialler.node.serverNodeID)
                print("[live] vh peer list: \(dialler.node.displayName) -> \(rowD?["name"]?.stringValue ?? "?") "
                    + "connected, compared_by desktop, dialed_by \(rowD?["health"]?["dialed_by"]?.stringValue ?? "?"); "
                    + "\(acceptor.node.displayName) -> \(rowA?["name"]?.stringValue ?? "?") connected, "
                    + "rtt \(rowA?["health"]?["rtt_ms"]?.integerValue.map(String.init) ?? "?") ms")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw LiveFailure("the link never came up on both: \(String(describing: last))")
    }

    static func waitUntilUnlinked() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if try await live(on: runA).isEmpty, try await live(on: runB).isEmpty { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw LiveFailure("still linked: \(try await live(on: runA)) / \(try await live(on: runB))")
    }
}
