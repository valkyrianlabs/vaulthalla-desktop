import Foundation
import Testing
import VHCore
import VHIdentity
@testable import VHNodes

/// `NodeSession` and `NodeSessions` against the mock daemon: Device sessions by client SPKI, revocation, reconnects,
/// server key announcements and device key rotation (docs/pairing.md §4–§6).
extension KeychainSuite {
@Suite struct NodeSessionTests {
    private struct Fixture: Sendable {
        let daemon: MockDaemon
        /// The credential owner's keys (they rotate).
        let keys: DeviceKeys
        let store: DeviceIdentityStore
        let identity: DeviceIdentity
        let node: Node
    }

    /// A daemon and a node it already knows (the device row exists). With `keyAge`, the node gets its own key
    /// ("node-r"), issued that long ago and deleted afterwards; otherwise the shared "node-a" key.
    private func withPairedNode(keyAge: TimeInterval? = nil, _ body: (Fixture) async throws -> Void) async throws {
        let shared = try KeychainFixture.require()
        let store = shared.store
        let daemon = try await MockDaemon.start(identity: shared.server)
        defer { daemon.stop() }
        let tag = keyAge == nil ? "node-a" : "node-r"
        let identity = if let keyAge {
            try await store.createIdentity(for: tag, deviceName: "Test Mac", backend: .software,
                                           now: Date.now.addingTimeInterval(-keyAge))
        } else {
            shared.device
        }
        daemon.register(identity.spkiSHA256)
        let node = Node(
            id: NodeID(rawValue: tag), displayName: "vh-test",
            endpoint: NodeEndpoint(host: "127.0.0.1", port: daemon.port),
            pairing: .paired(serverSPKISHA256: shared.server.spkiSHA256, deviceID: identity.deviceID, since: .now))
        let registry = try TestRegistry()
        defer { registry.remove() }
        let keys = registry.ownerKeys(store)
        do {
            try await body(Fixture(daemon: daemon, keys: keys, store: store, identity: identity, node: node))
            if keyAge != nil { try await store.deleteIdentity(for: tag) }
        } catch {
            if keyAge != nil { try? await store.deleteIdentity(for: tag) }
            throw error
        }
    }

    private func start(_ fixture: Fixture) async -> (NodeSession, Recorder<NodeSession.Event>) {
        let session = NodeSession(node: fixture.node, keys: fixture.keys, configuration: Fast.session())
        let events = Recorder(session.events)
        await session.start()
        return (session, events)
    }

    private func online(_ events: Recorder<NodeSession.Event>, after skipping: Int = 0) async -> Bool {
        await events.first(after: skipping) { $0.status == .online } != nil
    }

    @Test func connectsAsADeviceSession() async throws {
        try await withPairedNode { fixture in
            let (session, events) = await start(fixture)
            #expect(await online(events))
            #expect(events.all.first?.status == .connecting)
            #expect(fixture.daemon.commands.contains { $0.command == "device.server.identity" && $0.device })
            #expect(await session.identity?.deviceID == fixture.identity.deviceID)
            let client = try #require(await session.client)
            // Feature code uses the same connection.
            #expect(try await client.send(command: "meta.contract.get", payload: .null) == [:])
            await session.stop()
        }
    }

    @Test func reconnectsAfterADrop() async throws {
        try await withPairedNode { fixture in
            let (session, events) = await start(fixture)
            #expect(await online(events))
            let seen = events.all.count
            fixture.daemon.dropConnections()
            #expect(await events.first(after: seen) { $0.status == .connecting } != nil)
            #expect(await online(events, after: seen))
            #expect(fixture.daemon.commands.filter { $0.command == "device.server.identity" }.count == 2)
            await session.stop()
        }
    }

    @Test func revokedDeviceStopsReconnecting() async throws {
        try await withPairedNode { fixture in
            let (session, events) = await start(fixture)
            #expect(await online(events))
            fixture.daemon.revoke(fixture.identity.spkiSHA256)
            #expect(await events.first { $0.status == .revoked } != nil)
            let pairing = await events.first { $0.pairing != nil }?.pairing
            guard case .revoked = pairing else {
                Issue.record("expected a revoked record, got \(String(describing: pairing))")
                return
            }
            let connections = fixture.daemon.connectionCount
            try await Task.sleep(for: .milliseconds(300))
            #expect(fixture.daemon.connectionCount == connections)
            #expect(await session.status == .revoked)
            await session.stop()
        }
    }

    @Test func storesAnAnnouncedServerKeyAndPromotesItAfterTheSwitch() async throws {
        try await withPairedNode { fixture in
            let next = try KeychainFixture.require().otherServer
            fixture.daemon.state.withLock { $0.announcedNext = next.spkiSHA256 }
            let (session, events) = await start(fixture)
            let announced = await events.first {
                if case .recordChanged(_, let pin) = $0 { pin == next.spkiSHA256 } else { false }
            }
            #expect(announced != nil)

            // The daemon switches keys (and stops announcing). The old pin fails; the announced one is tried.
            let seen = events.all.count
            fixture.daemon.state.withLock { $0.announcedNext = nil }
            try await fixture.daemon.swapIdentity(next)
            let promoted = await events.first(after: seen) {
                if case .recordChanged(.paired(let pin, _, _), nil) = $0 { pin == next.spkiSHA256 } else { false }
            }
            #expect(promoted != nil)
            #expect(await online(events, after: seen))
            await session.stop()
        }
    }

    @Test func unannouncedServerKeyIsAPinFailure() async throws {
        try await withPairedNode { fixture in
            let other = try KeychainFixture.require().otherServer
            let (session, events) = await start(fixture)
            #expect(await online(events))
            let seen = events.all.count
            try await fixture.daemon.swapIdentity(other)
            let offline = await events.first(after: seen) {
                if case .offline(let reason) = $0.status { reason.contains("different server key") } else { false }
            }
            #expect(offline != nil)
            #expect(await events.first { if case .pairingRequired = $0 { true } else { false } } != nil)
            // Never trusts a new key on its own: no request reached the other server.
            #expect(!fixture.daemon.commands.contains { $0.epoch > 0 })
            await session.stop()
        }
    }

    @Test func rotatesAnOldKey() async throws {
        try await withPairedNode(keyAge: 91 * 24 * 3600) { fixture in
            let (session, events) = await start(fixture)
            let rotated = try #require(await rotatedDeviceID(events, from: fixture.identity.deviceID))
            try await expectRotated(fixture, events: events, to: rotated, rotations: 1)
            await session.stop()
        }
    }

    @Test func rotatesAFreshKeyOnDemand() async throws {
        // A key well inside the rotation interval: only rotateDeviceKey() rotates it, once.
        try await withPairedNode(keyAge: 3600) { fixture in
            let (session, events) = await start(fixture)
            #expect(await online(events))
            try await session.rotateDeviceKey()
            let rotated = try #require(await rotatedDeviceID(events, from: fixture.identity.deviceID))
            try await expectRotated(fixture, events: events, to: rotated, rotations: 1)
            await session.stop()
        }
    }

    @Test func rotationAnswerLostThenCompletedWithThePendingKey() async throws {
        try await withPairedNode(keyAge: 91 * 24 * 3600) { fixture in
            fixture.daemon.state.withLock { $0.rotateFaults = [.dropAfterProcessing] }
            let (session, events) = await start(fixture)
            let rotated = try #require(await rotatedDeviceID(events, from: fixture.identity.deviceID))
            // The daemon applied it once; the reconnect presented the pending key, which it already knew.
            try await expectRotated(fixture, events: events, to: rotated, rotations: 1)
            await session.stop()
        }
    }

    @Test func rotationNeverArrivedThenRetriedWithTheSameKey() async throws {
        try await withPairedNode(keyAge: 91 * 24 * 3600) { fixture in
            fixture.daemon.state.withLock { $0.rotateFaults = [.dropBeforeProcessing] }
            let (session, events) = await start(fixture)
            let rotated = try #require(await rotatedDeviceID(events, from: fixture.identity.deviceID))
            try await expectRotated(fixture, events: events, to: rotated, rotations: 1)
            // The pending key was refused (device_unknown) on reconnect, then the current key re-sent the proof.
            let commands = fixture.daemon.commands.map(\.command)
            #expect(commands.filter { $0 == "device.identity.rotate" }.count == 2)
            #expect(fixture.daemon.commands.contains { $0.command == "device.server.identity" && !$0.device })
            await session.stop()
        }
    }

    @Test func registryStartsAndStopsSessions() async throws {
        try await withPairedNode { fixture in try await registryScenario(fixture) }
    }

    @MainActor private func registryScenario(_ fixture: Fixture) async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: NodeSession.Status.self)
        let statuses = Recorder(stream)
        let sessions = NodeSessions(keys: fixture.keys, configuration: Fast.session()) { _, event in
            if let status = event.status { continuation.yield(status) }
        }
        var unpaired = fixture.node
        unpaired.id = NodeID(rawValue: "node-unpaired")
        unpaired.pairing = .unpaired
        sessions.sync([fixture.node, unpaired])
        #expect(sessions.nodeIDs == [fixture.node.id])
        #expect(await statuses.first { $0 == .online } != nil)

        // Saving what the session reported doesn't restart it; removing the node stops it.
        sessions.sync([fixture.node, unpaired])
        #expect(sessions.session(for: fixture.node.id) != nil)
        sessions.sync([unpaired])
        #expect(sessions.nodeIDs.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.daemon.openConnections == 0)
    }

    // MARK: Helpers

    /// The device id the session reports after rotating away from the fixture's key.
    private func rotatedDeviceID(_ events: Recorder<NodeSession.Event>, from original: String) async -> String? {
        let event = await events.first(within: .seconds(8)) {
            if case .identity(let id, _) = $0 { id != original } else { false }
        }
        if case .identity(let id, _) = event { return id }
        return nil
    }

    /// Waits until the session is online with the rotated key, then checks both sides agree.
    private func expectRotated(_ fixture: Fixture, events: Recorder<NodeSession.Event>, to deviceID: String,
                               rotations: Int) async throws {
        let index = events.all.firstIndex { if case .identity(deviceID, _) = $0 { true } else { false } } ?? 0
        #expect(await online(events, after: index))
        let current = try #require(try await fixture.keys.identity(for: fixture.node.id.rawValue))
        #expect(current.deviceID == deviceID)
        #expect(try await fixture.keys.pendingRotation(for: fixture.node.id.rawValue) == nil)
        let applied = fixture.daemon.state.withLock { $0.rotations.map(\.hex) }
        #expect(applied == Array(repeating: deviceID, count: rotations))
        // The first handshake with the new key ended the old key's grace.
        let row = try #require(fixture.daemon.device(matching: current.spkiSHA256))
        #expect(row.previous == nil)
        #expect(fixture.daemon.device(matching: fixture.identity.spkiSHA256) == nil)
    }
}
}
