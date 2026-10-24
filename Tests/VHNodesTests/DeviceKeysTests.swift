import Foundation
import Testing
import VHCore
import VHIdentity
@testable import VHNodes

extension KeychainSuite {
    /// Backend choice: Secure Enclave first, a software key in the file keychain when the build lacks entitlements,
    /// and never a silent change for a node that has a key.
    @Suite struct DeviceKeysTests {
        @Test(.enabled(if: !TestKeychain.dataProtectionKeychainAvailable, "needs a runner without entitlements"))
        func fallsBackToASoftwareKeyWithoutEntitlements() async throws {
            let fixture = try KeychainFixture.require()
            let namespace = await fixture.store.configuration.namespace
            let registry = try TestRegistry()
            defer { registry.remove() }
            let keys = DeviceKeys(
                primary: DeviceIdentityStore(configuration: .init(namespace: namespace, keychain: .dataProtection)),
                development: fixture.store, lease: registry.lease)
            #expect(keys.preferredBackend == .secureEnclave)

            let created = try await keys.identityForPairing(nodeTag: "node-r", deviceName: "Test Mac",
                                                            replacingExisting: false)
            #expect(created.backend == .software)
            #expect(created.backend.displayName == "Software key (development build)")
            #expect(try await fixture.store.identity(for: "node-r")?.spkiSHA256 == created.spkiSHA256)

            // An existing key is found and reused wherever it lives; only pairing again replaces it.
            #expect(try await keys.identity(for: "node-r")?.spkiSHA256 == created.spkiSHA256)
            let reused = try await keys.identityForPairing(nodeTag: "node-r", deviceName: "Test Mac",
                                                           replacingExisting: false)
            #expect(reused.spkiSHA256 == created.spkiSHA256)
            let fresh = try await keys.identityForPairing(nodeTag: "node-r", deviceName: "Test Mac",
                                                          replacingExisting: true)
            #expect(fresh.spkiSHA256 != created.spkiSHA256)

            try await keys.deleteIdentity(for: "node-r")
            #expect(try await keys.identity(for: "node-r") == nil)
        }

        @Test func aMissingKeyIsReportedNotRecreated() async throws {
            let fixture = try KeychainFixture.require()
            let keys = DeviceKeys(primary: fixture.store, development: nil, preferredBackend: .software)
            let node = Node(
                id: NodeID(rawValue: "node-r"), displayName: "vh-test", endpoint: NodeEndpoint(host: "127.0.0.1", port: 9),
                pairing: .paired(serverSPKISHA256: fixture.server.spkiSHA256, deviceID: "gone", since: .now))
            let session = NodeSession(node: node, keys: keys, configuration: Fast.session())
            let events = Recorder(session.events)
            await session.start()
            let offline = await events.first {
                if case .offline(let reason) = $0.status { reason.contains("missing") } else { false }
            }
            #expect(offline != nil)
            #expect(await events.first { if case .pairingRequired = $0 { true } else { false } } != nil)
            #expect(try await keys.identity(for: "node-r") == nil)
            await session.stop()
        }
    }
}
