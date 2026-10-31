import Foundation
import Synchronization
import Testing
import VHCore
import VHIdentity
@testable import VHNodes

/// Single-owner credential management (docs/architecture.md §3, "Credential ownership"), on this Mac only: only the
/// lease holder rotates, consumers can't, a consumer's reload prefers the owner's newer key, and a revocation the
/// owner recorded ends every consumer. What a node does with a refused key is the live suite's (docs/interop-testing.md).
extension KeychainSuite {
@Suite struct CredentialOwnershipTests {
    /// A registry (the test holds its lease) with a node paired to the shared server key. Nothing listens on the
    /// endpoint: these tests never connect.
    private struct Fixture: Sendable {
        let registry: TestRegistry
        let store: DeviceIdentityStore
        let identity: DeviceIdentity
        let node: Node
        let serverSPKI: Data

        var ownerKeys: DeviceKeys { registry.ownerKeys(store) }
        var consumerKeys: DeviceKeys { TestRegistry.consumerKeys(store) }
        var reader: CredentialReader { CredentialReader(registry: registry.consumer, keys: consumerKeys) }
    }

    /// With `keyAge`, the node gets its own key ("node-r") issued that long ago, deleted afterwards; otherwise the
    /// shared "node-a" key.
    private func withNode(keyAge: TimeInterval? = nil, _ body: (Fixture) async throws -> Void) async throws {
        let shared = try KeychainFixture.require()
        let tag = keyAge == nil ? "node-a" : "node-r"
        let identity = if let keyAge {
            try await shared.store.createIdentity(for: tag, deviceName: "Test Mac", backend: .software,
                                                  now: Date.now.addingTimeInterval(-keyAge))
        } else {
            shared.device
        }
        let node = Node(
            id: NodeID(rawValue: tag), displayName: "vh-test", endpoint: NodeEndpoint(host: "127.0.0.1", port: 9),
            pairing: .paired(serverSPKISHA256: shared.server.spkiSHA256, deviceID: identity.deviceID, since: .now))
        try await TestRegistry.with { registry in
            try registry.owner.add(node)
            let fixture = Fixture(registry: registry, store: shared.store, identity: identity, node: node,
                                  serverSPKI: shared.server.spkiSHA256)
            do {
                try await body(fixture)
                if keyAge != nil { try await shared.store.deleteIdentity(for: tag) }
            } catch {
                if keyAge != nil { try? await shared.store.deleteIdentity(for: tag) }
                throw error
            }
        }
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
                _ = try await keys.rotate(for: "node-a", serverSPKISHA256: fixture.serverSPKI)
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
                _ = try await keys.rotate(for: tag, serverSPKISHA256: fixture.serverSPKI)
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

    @Test func aReloadPrefersTheOwnersNewerKey() async throws {
        try await withNode(keyAge: 3600) { fixture in
            // An unfinished rotation in the owner: the replacement waits in the pending slot.
            let rotation = try await fixture.ownerKeys.rotate(for: "node-r", serverSPKISHA256: fixture.serverSPKI)
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

    // MARK: Revocation

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
}
}

/// How often an operation ran.
private final class Counter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func bump() { value.withLock { $0 += 1 } }
}
