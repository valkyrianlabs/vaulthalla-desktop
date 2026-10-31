import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
import VHIdentity
@testable import VHNodes
import VHTransport

/// A real TLS probe whose outcome or reported address a test can override per host, so routes classify as LAN or WAN
/// while every connection still goes to the mock daemon on loopback.
final class ScriptedRoutes: Sendable {
    enum Override: Sendable {
        case refuse
        /// Probe for real, then report this address as the one reached.
        case address(String)
    }

    let overrides = Mutex<[String: Override]>([:])
    let probes = Mutex(0)

    func set(_ host: String, _ override: Override?) {
        overrides.withLock { $0[host] = override }
    }

    func settings(_ base: RouteSettings = Fast.routes()) -> RouteSettings {
        var settings = base
        settings.prober = { identity, pins in
            Prober(real: TLSEndpointProber(identity: identity?.secIdentity, pins: pins), script: self)
        }
        return settings
    }

    struct Prober: EndpointProbing {
        let real: TLSEndpointProber
        let script: ScriptedRoutes

        func probe(_ endpoint: NodeEndpoint, timeout: Duration) async -> EndpointProbeResult {
            script.probes.withLock { $0 += 1 }
            switch script.overrides.withLock({ $0[endpoint.host] }) {
            case .refuse?:
                return EndpointProbeResult(outcome: .refused)
            case .address(let address)?:
                var result = await real.probe(endpoint, timeout: timeout)
                if result.outcome == .ok { result.remoteAddress = address }
                return result
            case nil:
                return await real.probe(endpoint, timeout: timeout)
            }
        }
    }
}

/// `NodeSession` endpoint selection against the mock daemon (the server's transfer protocol §2).
extension KeychainSuite {
@Suite struct NodeSessionRouteTests {
    private struct Fixture {
        let daemon: MockDaemon
        let shared: KeychainFixture
        let registry: TestRegistry

        func node(_ endpoint: NodeEndpoint, advertised: [AdvertisedEndpoint] = []) -> Node {
            Node(id: NodeID(rawValue: "node-a"), displayName: "vh-test", endpoint: endpoint,
                 pairing: .paired(serverSPKISHA256: shared.server.spkiSHA256, deviceID: shared.device.deviceID,
                                  since: .now),
                 serverNodeID: MockDaemon.nodeID, endpoints: advertised)
        }
    }

    private func withDaemon(_ body: (Fixture) async throws -> Void) async throws {
        let shared = try KeychainFixture.require()
        let daemon = try await MockDaemon.start(identity: shared.server)
        defer { daemon.stop() }
        daemon.register(shared.device.spkiSHA256)
        let registry = try TestRegistry()
        defer { registry.remove() }
        try await body(Fixture(daemon: daemon, shared: shared, registry: registry))
    }

    private func start(_ node: Node, keys: DeviceKeys, routes: RouteSettings = Fast.routes())
        async -> (NodeSession, Recorder<NodeSession.Event>)
    {
        var configuration = Fast.session()
        configuration.routes = routes
        let session = NodeSession(node: node, keys: keys, configuration: configuration)
        let events = Recorder(session.events)
        await session.start()
        return (session, events)
    }

    private func online(_ events: Recorder<NodeSession.Event>, after skipping: Int = 0) async -> Bool {
        await events.first(after: skipping) { $0.status == .online } != nil
    }

    private func routes(_ events: Recorder<NodeSession.Event>) -> [NodeRoute] {
        events.all.compactMap { if case .route(let route) = $0 { route } else { nil } }
    }

    @Test func connectsOverTheBestVerifiedEndpoint() async throws {
        try await withDaemon { fixture in
            // The configured address is dead; the node advertised another one that proves the pin.
            let dead = try await TestPorts.unused()
            let node = fixture.node(NodeEndpoint(host: "127.0.0.1", port: dead), advertised: [
                AdvertisedEndpoint(host: "localhost", port: fixture.daemon.port, kind: .lan, source: "config"),
            ])
            let (session, events) = await start(node, keys: fixture.registry.ownerKeys(fixture.shared.store))
            #expect(await online(events))
            let route = try #require(await session.route)
            #expect(route.endpoint == NodeEndpoint(host: "localhost", port: fixture.daemon.port))
            #expect(route.transportClass == .loopback)  // classified by the address reached, not the server's word
            #expect(route.verifiedKey == .current && route.isConnected && !route.isFallback)
            #expect(route.selection?.report(for: node.endpoint)?.outcome == .refused)
            #expect(await session.laneConfiguration()?.endpoint == route.endpoint)
            #expect(await session.laneEndpoint == route.endpoint)
            #expect(!events.all.contains { if case .pairingRequired = $0 { true } else { false } })
            await session.stop()
        }
    }

    @Test func anotherServerAtAnotherAddressNeverAsksToPairAgain() async throws {
        try await withDaemon { fixture in
            // Another Vaulthalla with its own key answers at an advertised loopback address.
            let impostor = try await MockDaemon.start(identity: fixture.shared.otherServer)
            defer { impostor.stop() }
            let node = fixture.node(NodeEndpoint(host: "127.0.0.1", port: fixture.daemon.port), advertised: [
                AdvertisedEndpoint(host: "127.0.0.1", port: impostor.port, kind: .loopback),
            ])
            let (session, events) = await start(node, keys: fixture.registry.ownerKeys(fixture.shared.store))
            #expect(await online(events))
            let route = try #require(await session.route)
            #expect(route.endpoint == node.endpoint)
            let impostorReport = route.selection?.report(for: NodeEndpoint(host: "127.0.0.1", port: impostor.port))
            #expect(impostorReport?.outcome == .identityMismatch)
            #expect(route.selection?.betterRoutesNotUsed.isEmpty == true)  // same class: nothing better was missed
            #expect(!events.all.contains { if case .pairingRequired = $0 { true } else { false } })
            #expect(impostor.commands.isEmpty, "nothing was sent to the other server")
            await session.stop()
        }
    }

    @Test func theOwnerSavesAdvertisedEndpointsAndTheLastGoodOne() async throws {
        try await withDaemon { fixture in
            let advertised: JSONValue = [
                "node_id": .string(MockDaemon.nodeID), "port": .integer(Int64(fixture.daemon.port)), "remote": true,
                "listening": true, "generated_at": 1_793_453_809,
                "candidates": [
                    ["host": "127.0.0.1", "port": .integer(Int64(fixture.daemon.port)), "kind": "loopback",
                     "source": "interface", "interface": "lo"],
                    ["host": "10.0.0.11", "port": 36972, "kind": "lan", "source": "interface", "interface": "enp3s0"],
                ],
            ]
            fixture.daemon.answer("meta.hello") { _ in
                .ok(NodeSessionTests.hello(capabilities: ["device.endpoints", "device.server.identity"],
                                           commands: ["device.endpoints", "device.server.identity", "meta.hello"]))
            }
            fixture.daemon.answer("device.endpoints") { _ in .ok(advertised) }
            let node = fixture.node(NodeEndpoint(host: "127.0.0.1", port: fixture.daemon.port))

            let (owner, ownerEvents) = await start(node, keys: fixture.registry.ownerKeys(fixture.shared.store))
            let saved = await ownerEvents.first { event in
                if case .endpointsChanged(let endpoints, _, _) = event { !endpoints.isEmpty } else { false }
            }
            guard case .endpointsChanged(let endpoints, let at, let lastGood)? = saved else {
                Issue.record("no endpointsChanged with the advertised list")
                return
            }
            #expect(endpoints.map(\.endpoint.description) == ["127.0.0.1:\(fixture.daemon.port)", "10.0.0.11:36972"])
            #expect(endpoints[1].kind == .lan && endpoints[1].interface == "enp3s0")
            #expect(at == Date(timeIntervalSince1970: 1_793_453_809))
            #expect(lastGood?.endpoint == node.endpoint && lastGood?.transportClass == .loopback)
            #expect(await owner.node.endpoints == endpoints)
            await owner.stop()

            // A consumer keeps them in memory and reports nothing for the registry.
            let consumerKeys = TestRegistry.consumerKeys(fixture.shared.store)
            let (consumer, consumerEvents) = await start(node, keys: consumerKeys)
            #expect(await online(consumerEvents))
            try await Task.sleep(for: .milliseconds(200))
            #expect(!consumerEvents.all.contains { if case .endpointsChanged = $0 { true } else { false } })
            #expect(await consumer.node.endpoints.count == 2)
            await consumer.stop()
        }
    }

    @Test func aNodeWithoutTheCapabilityIsNotAsked() async throws {
        try await withDaemon { fixture in
            fixture.daemon.answer("meta.hello") { _ in .ok(NodeSessionTests.hello()) }
            let node = fixture.node(NodeEndpoint(host: "127.0.0.1", port: fixture.daemon.port))
            let (session, events) = await start(node, keys: fixture.registry.ownerKeys(fixture.shared.store))
            #expect(await online(events))
            try await Task.sleep(for: .milliseconds(100))
            #expect(fixture.daemon.count(of: "device.endpoints") == 0)
            await session.stop()
        }
    }

    @Test func movesToABetterRouteWhenThePathChanges() async throws {
        try await withDaemon { fixture in
            let script = ScriptedRoutes()
            // At first the configured address looks like the internet, and the LAN name doesn't answer.
            script.set("127.0.0.1", .address("203.0.113.7"))
            script.set("::1", .refuse)
            script.set("localhost", .refuse)
            let (changes, changed) = AsyncStream.makeStream(of: Void.self)
            var routes = script.settings()
            routes.pathChanges = { changes }
            let node = fixture.node(NodeEndpoint(host: "127.0.0.1", port: fixture.daemon.port), advertised: [
                AdvertisedEndpoint(host: "localhost", port: fixture.daemon.port, kind: .lan),
            ])
            let (session, events) = await start(node, keys: fixture.registry.ownerKeys(fixture.shared.store),
                                                routes: routes)
            #expect(await online(events))
            #expect(await session.route?.transportClass == .wan)
            let connections = fixture.daemon.connectionCount

            // Joined the LAN: the network path changes and the LAN address answers.
            script.set("localhost", .address("10.0.0.11"))
            let seen = events.all.count
            changed.yield()
            let moved = await events.first(after: seen, within: .seconds(5)) { event in
                if case .route(let route) = event { route.endpoint.host == "localhost" && route.isConnected } else { false }
            }
            #expect(moved != nil)
            #expect(await session.route?.transportClass == .lan)
            #expect(fixture.daemon.connectionCount > connections)
            #expect(await session.status == .online)
            await session.stop()
        }
    }

    @Test func consumersWithoutASessionSelectReadOnlyAndReuseTheRoute() async throws {
        try await withDaemon { fixture in
            let script = ScriptedRoutes()
            let dead = try await TestPorts.unused()
            let node = fixture.node(NodeEndpoint(host: "127.0.0.1", port: dead), advertised: [
                AdvertisedEndpoint(host: "localhost", port: fixture.daemon.port, kind: .lan),
            ])
            let cache = RouteCache(settings: script.settings(), maximumAge: .seconds(60))
            let credentials = NodeCredentials(node: node, identity: fixture.shared.device)
            #expect(await cache.endpoint(for: credentials) == NodeEndpoint(host: "localhost", port: fixture.daemon.port))
            let probes = script.probes.withLock { $0 }
            // Fresh: reused without probing.
            _ = await cache.endpoint(for: credentials)
            #expect(script.probes.withLock { $0 } == probes)
            // After a failure: selected again.
            await cache.invalidate(node.id)
            _ = await cache.endpoint(for: credentials)
            #expect(script.probes.withLock { $0 } > probes)
            // The lanes and one-off connections use it.
            let routed = credentials.routed(to: await cache.endpoint(for: credentials))
            #expect(routed.laneConfiguration().endpoint.host == "localhost")
            #expect(await CredentialReader(registry: nil, keys: TestRegistry.consumerKeys(fixture.shared.store))
                .check(routed) == .accepted)
        }
    }

    @Test func testRouteSelectsAgainButKeepsAWorkingRouteOfTheSameClass() async throws {
        try await withDaemon { fixture in
            let script = ScriptedRoutes()
            let node = fixture.node(NodeEndpoint(host: "127.0.0.1", port: fixture.daemon.port))
            let (session, events) = await start(node, keys: fixture.registry.ownerKeys(fixture.shared.store),
                                                routes: script.settings())
            #expect(await online(events))
            let before = script.probes.withLock { $0 }
            let client = try #require(await session.client)
            let selection = try #require(await session.testRoute())
            #expect(selection.chosen?.candidate.endpoint == node.endpoint)
            #expect(script.probes.withLock { $0 } > before)
            try await Task.sleep(for: .milliseconds(100))
            // Probes connect and close; the session's own connection stays.
            #expect(await session.route?.isConnected == true)
            #expect(await session.client === client)
            await session.stop()
        }
    }
}
}

enum TestPorts {
    /// A loopback port nothing listens on.
    static func unused() async throws -> UInt16 {
        let shared = try KeychainFixture.require()
        let daemon = try await MockDaemon.start(identity: shared.server)
        let port = daemon.port
        daemon.stop()
        try await Task.sleep(for: .milliseconds(50))
        return port
    }
}
