import Foundation
import Synchronization
import Testing
import VHCore
import VHIdentity
import VHTransport
@testable import VHNodes

/// Single-owner credential management (docs/architecture.md §3, "Credential ownership") against the mock daemon:
/// only the lease holder rotates, consumers can't, a consumer survives the owner's rotation by reloading, and a
/// refusal that survives the reload is a revocation.
extension KeychainSuite {
@Suite struct CredentialOwnershipTests {
    /// A daemon that knows `identity`, and a registry (the test holds its lease) with the node paired to it.
    private struct Fixture: Sendable {
        let daemon: MockDaemon
        let registry: TestRegistry
        let store: DeviceIdentityStore
        let identity: DeviceIdentity
        let node: Node

        var ownerKeys: DeviceKeys { registry.ownerKeys(store) }
        var consumerKeys: DeviceKeys { TestRegistry.consumerKeys(store) }
        var reader: CredentialReader { CredentialReader(registry: registry.consumer, keys: consumerKeys) }
    }

    /// With `keyAge`, the node gets its own key ("node-r") issued that long ago, deleted afterwards; otherwise the
    /// shared "node-a" key.
    private func withNode(keyAge: TimeInterval? = nil, _ body: (Fixture) async throws -> Void) async throws {
        let shared = try KeychainFixture.require()
        let daemon = try await MockDaemon.start(identity: shared.server)
        defer { daemon.stop() }
        let tag = keyAge == nil ? "node-a" : "node-r"
        let identity = if let keyAge {
            try await shared.store.createIdentity(for: tag, deviceName: "Test Mac", backend: .software,
                                                  now: Date.now.addingTimeInterval(-keyAge))
        } else {
            shared.device
        }
        daemon.register(identity.spkiSHA256)
        let node = Node(
            id: NodeID(rawValue: tag), displayName: "vh-test",
            endpoint: NodeEndpoint(host: "127.0.0.1", port: daemon.port),
            pairing: .paired(serverSPKISHA256: shared.server.spkiSHA256, deviceID: identity.deviceID, since: .now))
        try await TestRegistry.with { registry in
            try registry.owner.add(node)
            let fixture = Fixture(daemon: daemon, registry: registry, store: shared.store, identity: identity, node: node)
            do {
                try await body(fixture)
                if keyAge != nil { try await shared.store.deleteIdentity(for: tag) }
            } catch {
                if keyAge != nil { try? await shared.store.deleteIdentity(for: tag) }
                throw error
            }
        }
    }

    private func start(_ node: Node, keys: DeviceKeys, registry: NodeStore) async
        -> (NodeSession, Recorder<NodeSession.Event>)
    {
        let session = NodeSession(node: node, keys: keys, registry: registry, configuration: Fast.session())
        let events = Recorder(session.events)
        await session.start()
        return (session, events)
    }

    private func online(_ events: Recorder<NodeSession.Event>, after skipping: Int = 0) async -> Bool {
        await events.first(after: skipping, within: .seconds(8)) { $0.status == .online } != nil
    }

    private func recordChanges(_ events: Recorder<NodeSession.Event>) -> Int {
        events.all.filter { if case .recordChanged = $0 { true } else { false } }.count
    }

    // MARK: One owner

    @Test func aSecondOwnerGetsNeitherTheLeaseNorRotation() async throws {
        try await withNode { fixture in
            // The test holds the registry's lease; another would-be owner (the agent, a second app) can't take it.
            let second = CredentialLease(forRegistry: fixture.registry.fileURL, holder: "agent")
            #expect {
                try second.acquire()
            } throws: { error in
                guard case CredentialOwnershipError.held(let holder?) = error else { return false }
                return holder.name == "test"
            }
            let keys = DeviceKeys(primary: fixture.store, development: nil, preferredBackend: .software, lease: second)
            #expect(keys.role == .consumer)
            await #expect(throws: CredentialOwnershipError.notOwner(operation: "rotate a device key")) {
                _ = try await keys.rotate(for: "node-a", serverSPKISHA256: fixture.daemon.serverSPKI)
            }
            #expect(NodeStore(fileURL: fixture.registry.fileURL, lease: second).role == .consumer)
            let session = NodeSession(node: fixture.node, keys: keys, configuration: Fast.session())
            #expect(session.role == .consumer)
            #expect(fixture.ownerKeys.role == .owner)
        }
    }

    @Test func consumerKeysRefuseEveryChange() async throws {
        try await withNode { fixture in
            let keys = fixture.consumerKeys
            let tag = "node-a"
            await #expect(throws: CredentialOwnershipError.self) {
                _ = try await keys.identityForPairing(nodeTag: tag, deviceName: "Test Mac", replacingExisting: true)
            }
            await #expect(throws: CredentialOwnershipError.self) {
                _ = try await keys.rotate(for: tag, serverSPKISHA256: fixture.daemon.serverSPKI)
            }
            await #expect(throws: CredentialOwnershipError.self) { _ = try await keys.completeRotation(for: tag) }
            await #expect(throws: CredentialOwnershipError.self) { try await keys.cancelRotation(for: tag) }
            await #expect(throws: CredentialOwnershipError.self) { try await keys.deleteIdentity(for: tag) }
            // Nothing changed in the Keychain, and reading still works.
            let current = try await keys.identity(for: tag)
            let pending = try await keys.pendingRotation(for: tag)
            #expect(current?.deviceID == fixture.identity.deviceID)
            #expect(pending == nil)
        }
    }

    @Test func aConsumerSessionNeverRotatesOrWritesTheRecord() async throws {
        // A key past the rotation interval, and a server announcing its next key: an owner would rotate and record.
        try await withNode(keyAge: 91 * 24 * 3600) { fixture in
            let next = try KeychainFixture.require().otherServer
            fixture.daemon.state.withLock { $0.announcedNext = next.spkiSHA256 }
            let (session, events) = await start(fixture.node, keys: fixture.consumerKeys,
                                                registry: fixture.registry.consumer)
            #expect(session.role == .consumer)
            #expect(await online(events))
            await #expect(throws: CredentialOwnershipError.notOwner(operation: "rotate a device key")) {
                try await session.rotateDeviceKey()
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(fixture.daemon.count(of: "device.identity.rotate") == 0)
            #expect(recordChanges(events) == 0)
            #expect(try await fixture.store.identity(for: "node-r")?.deviceID == fixture.identity.deviceID)
            #expect(try await fixture.store.pendingRotation(for: "node-r") == nil)
            await session.stop()
        }
    }

    // MARK: Consumers survive the owner's rotation

    @Test func aConsumerSurvivesTheOwnersRotationByReloading() async throws {
        try await withNode(keyAge: 3600) { fixture in
            let (owner, ownerEvents) = await start(fixture.node, keys: fixture.ownerKeys,
                                                   registry: fixture.registry.owner)
            let (consumer, consumerEvents) = await start(fixture.node, keys: fixture.consumerKeys,
                                                         registry: fixture.registry.consumer)
            #expect(owner.role == .owner && consumer.role == .consumer)
            #expect(await online(ownerEvents))
            #expect(await online(consumerEvents))

            // The owner rotates and records the new device id, as the app saves its sessions' record changes.
            try await owner.rotateDeviceKey()
            let recorded = try #require(await ownerEvents.first(within: .seconds(8)) {
                if case .recordChanged(.paired(_, let id, _), _) = $0 { id != fixture.identity.deviceID } else { false }
            })
            guard case .recordChanged(let pairing, let next) = recorded, case .paired(_, let rotated, _) = pairing
            else { return }
            var saved = fixture.node
            saved.pairing = pairing
            saved.nextServerSPKISHA256 = next
            try fixture.registry.owner.update(saved)

            // Once the owner's first handshake with the new key ends the old key's grace, the old key is refused.
            let index = ownerEvents.all.firstIndex { if case .identity(rotated, _) = $0 { true } else { false } } ?? 0
            #expect(await online(ownerEvents, after: index))
            // The mock authorizes a connection on its first message, which can come after the owner reports online:
            // wait (bounded) for that handshake to have ended the old key's grace, rather than assume the order.
            let graceEnded = ContinuousClock.now + .seconds(8)
            while fixture.daemon.device(matching: fixture.identity.spkiSHA256) != nil, ContinuousClock.now < graceEnded {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(fixture.daemon.device(matching: fixture.identity.spkiSHA256) == nil)

            // The consumer reconnects with the old key, is refused, reloads, and is back with the owner's key.
            let seen = consumerEvents.all.count
            fixture.daemon.dropConnections()
            let switched = await consumerEvents.first(after: seen, within: .seconds(8)) {
                if case .identity(rotated, _) = $0 { true } else { false }
            }
            #expect(switched != nil)
            let switchedAt = consumerEvents.all.firstIndex { if case .identity(rotated, _) = $0 { true } else { false } }
            #expect(await online(consumerEvents, after: switchedAt ?? seen))
            #expect(await consumer.identity?.deviceID == rotated)
            #expect(fixture.daemon.commands.contains { $0.command == "device.server.identity" && !$0.device },
                    "the consumer presented the refused key once")

            // One rotation, the owner's; the consumer wrote nothing and is no revocation.
            #expect(fixture.daemon.state.withLock { $0.rotations.map(\.hex) } == [rotated])
            #expect(fixture.daemon.count(of: "device.identity.rotate") == 1)
            #expect(recordChanges(consumerEvents) == 0)
            #expect(!consumerEvents.all.contains { $0.status == .revoked })
            await owner.stop()
            await consumer.stop()
        }
    }

    @Test func aConsumerFollowsAServerKeyTheOwnerPromoted() async throws {
        try await withNode { fixture in
            let next = try KeychainFixture.require().otherServer
            let (consumer, events) = await start(fixture.node, keys: fixture.consumerKeys,
                                                 registry: fixture.registry.consumer)
            #expect(await online(events))

            // The owner saw the switch first and saved the new pin; the consumer's record still has the old one.
            var promoted = fixture.node
            promoted.pairing = .paired(serverSPKISHA256: next.spkiSHA256, deviceID: fixture.identity.deviceID,
                                       since: .now)
            try fixture.registry.owner.update(promoted)
            let seen = events.all.count
            try await fixture.daemon.swapIdentity(next)

            #expect(await online(events, after: seen))
            guard case .paired(let pin, _, _) = await consumer.node.pairing else {
                Issue.record("the consumer's record isn't paired")
                return
            }
            #expect(pin == next.spkiSHA256)
            #expect(!events.all.contains { if case .pairingRequired = $0 { true } else { false } })
            #expect(recordChanges(events) == 0)
            await consumer.stop()
        }
    }

    @Test func aReloadPrefersTheOwnersNewerKey() async throws {
        try await withNode(keyAge: 3600) { fixture in
            // An unfinished rotation in the owner: the replacement waits in the pending slot.
            let rotation = try await fixture.ownerKeys.rotate(for: "node-r", serverSPKISHA256: fixture.daemon.serverSPKI)
            let pending = rotation.replacement
            let reader = fixture.reader

            // Refused with the current key: the owner may already have moved to the pending one.
            let afterCurrent = try await reader.reload(fixture.node, refusing: fixture.identity.deviceID)
            #expect(afterCurrent.identity.deviceID == pending.deviceID)
            // Refused with the pending key, or no refused key known: the current one.
            #expect(try await reader.reload(fixture.node, refusing: pending.deviceID).identity.deviceID
                == fixture.identity.deviceID)
            #expect(try await reader.load(fixture.node.id).identity.deviceID == fixture.identity.deviceID)

            // The consumer read without changing anything; the owner cancels its rotation.
            #expect(try await fixture.store.pendingRotation(for: "node-r")?.deviceID == pending.deviceID)
            try await fixture.ownerKeys.cancelRotation(for: "node-r")
        }
    }

    // MARK: Revocation reaches every consumer

    @Test func aPersistentDeviceUnknownIsReportedRevoked() async throws {
        try await withNode { fixture in
            let (consumer, events) = await start(fixture.node, keys: fixture.consumerKeys,
                                                 registry: fixture.registry.consumer)
            #expect(await online(events))
            fixture.daemon.revoke(fixture.identity.spkiSHA256)
            #expect(await events.first(within: .seconds(8)) { $0.status == .revoked } != nil)
            #expect(await consumer.status == .revoked)
            // It reloaded and asked once more before concluding; then it stops.
            let refusals = fixture.daemon.commands.filter { $0.command == "device.server.identity" && !$0.device }
            #expect(refusals.count == 2)
            let connections = fixture.daemon.connectionCount
            try await Task.sleep(for: .milliseconds(300))
            #expect(fixture.daemon.connectionCount == connections)
            // The owner records revocations; a consumer only reports them.
            #expect(recordChanges(events) == 0)
            let saved = try fixture.registry.consumer.reload().first?.pairing
            guard case .paired(_, let deviceID, _)? = saved else {
                Issue.record("the consumer changed the record: \(String(describing: saved))")
                return
            }
            #expect(deviceID == fixture.identity.deviceID)
            await consumer.stop()
        }
    }

    @Test func aRevocationTheOwnerRecordedEndsEveryConsumer() async throws {
        try await withNode { fixture in
            var revoked = fixture.node
            revoked.pairing = .revoked(at: .now)
            try fixture.registry.owner.update(revoked)
            await #expect(throws: CredentialFailure.revoked) { _ = try await fixture.reader.load(fixture.node.id) }
            let ran = Counter()
            await #expect(throws: CredentialFailure.revoked) {
                try await fixture.reader.withCredentials(for: fixture.node.id) { _ in ran.bump() }
            }
            #expect(ran.count == 0, "nothing is presented to the node")
        }
    }

    @Test func theConsumerRoundRetriesOnceThenFailsClosed() async throws {
        try await withNode { fixture in
            let reader = fixture.reader
            let calls = Counter()
            /// A ws operation, as the File Provider extension would run one: refused keys throw `device_unknown`.
            let wsOperation: (NodeCredentials) async throws -> String = { credentials in
                calls.bump()
                switch await reader.check(credentials, timeout: .seconds(3)) {
                case .accepted: return credentials.identity.deviceID
                case .refused: throw WsError.needsConfirmation(code: "device_unknown", message: "Unknown device.")
                case .inconclusive(let reason): throw WsError.error(reason)
                }
            }

            let presented = try await reader.withCredentials(for: fixture.node.id, wsOperation)
            #expect(presented == fixture.identity.deviceID)
            #expect(calls.count == 1)

            // A lane's 403 while the node accepts the key is the account's refusal, not a revocation.
            calls.reset()
            await #expect(throws: DeviceHTTPError.forbidden) {
                try await reader.withCredentials(for: fixture.node.id, checkTimeout: .seconds(3)) { _ in
                    calls.bump()
                    throw DeviceHTTPError.forbidden
                }
            }
            #expect(calls.count == 2)

            // Revoked: refused, reloaded, refused again: revoked, on the ws and on the lanes alike.
            fixture.daemon.revoke(fixture.identity.spkiSHA256)
            calls.reset()
            await #expect(throws: CredentialFailure.revoked) {
                try await reader.withCredentials(for: fixture.node.id, wsOperation)
            }
            #expect(calls.count == 2)
            await #expect(throws: CredentialFailure.revoked) {
                try await reader.withCredentials(for: fixture.node.id, checkTimeout: .seconds(3)) { _ in
                    throw DeviceHTTPError.forbidden
                }
            }
        }
    }

    // MARK: Takeover

    @Test func takingTheLeaseOverRestartsTheSessionsAsOwners() async throws {
        try await withNode { fixture in try await takeoverScenario(fixture) }
    }

    @MainActor private func takeoverScenario(_ fixture: Fixture) async throws {
        // This process waits as a consumer while the test (another owner) holds the lease.
        let local = CredentialLease(forRegistry: fixture.registry.fileURL, holder: "app")
        defer { local.release() }
        #expect(throws: CredentialOwnershipError.self) { try local.acquire() }
        let keys = DeviceKeys(primary: fixture.store, development: nil, preferredBackend: .software, lease: local)
        let sessions = NodeSessions(keys: keys, registry: fixture.registry.consumer, configuration: Fast.session()) { _, _ in }
        sessions.sync([fixture.node])
        let before = try #require(sessions.session(for: fixture.node.id))
        #expect(sessions.role == .consumer && before.role == .consumer)

        // The owner exits; this process takes the lease over and resyncs: its sessions are owners now.
        fixture.registry.lease.release()
        try await local.acquire(waitingUpTo: .seconds(2), checkingEvery: .milliseconds(20))
        sessions.sync([fixture.node])
        let after = try #require(sessions.session(for: fixture.node.id))
        #expect(after !== before)
        #expect(sessions.role == .owner && after.role == .owner)
        #expect(NodeStore(fileURL: fixture.registry.fileURL, lease: local).role == .owner)
        sessions.stopAll()
        try await Task.sleep(for: .milliseconds(200))
    }
}
}

/// How often an operation ran.
private final class Counter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func bump() { value.withLock { $0 += 1 } }
    func reset() { value.withLock { $0 = 0 } }
}
