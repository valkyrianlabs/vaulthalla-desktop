import Foundation
import Testing
import VHCore
import VHIdentity
import VHTransport
@testable import VHNodes

/// `PairingClient` against the mock daemon over loopback TLS 1.3 (docs/pairing.md §3).
extension KeychainSuite {
@Suite struct PairingClientTests {
    /// A daemon with a software server key, the device keys, and this Mac's identity for "node-a".
    private func withDaemon(
        _ body: (MockDaemon, DeviceKeys, DeviceIdentity, DeviceIdentityStore) async throws -> Void
    ) async throws {
        let fixture = try KeychainFixture.require()
        let daemon = try await MockDaemon.start(identity: fixture.server)
        defer { daemon.stop() }
        try await TestRegistry.with { registry in
            // Pairing is the credential owner's.
            let keys = registry.ownerKeys(fixture.store)
            let identity = try await keys.identityForPairing(nodeTag: "node-a", deviceName: "Test Mac",
                                                             replacingExisting: false)
            try await body(daemon, keys, identity, fixture.store)
        }
    }

    private func finalState(_ states: Recorder<PairingClient.State>) async -> PairingClient.State? {
        await states.first(within: .seconds(8)) { $0.isFinal }
    }

    @Test func approvedWithMatchingCodes() async throws {
        try await withDaemon { daemon, keys, identity, _ in
            let client = PairingClient(identity: identity, configuration: Fast.pairing(port: daemon.port))
            let states = Recorder(client.start())

            let request = try #require(await daemon.confirmedRequest())
            let shown = try #require(await states.first { if case .awaitingApproval = $0 { true } else { false } })
            guard case .awaitingApproval(let code) = shown else { return }
            // Both sides computed the SAS on their own and got the same six digits.
            #expect(code.digits == request.code)
            #expect(states.all.first == .connecting)

            daemon.decide(request.id, .approved)
            let final = await finalState(states)
            #expect(final == .approved(nodeID: MockDaemon.nodeID, nodeName: MockDaemon.nodeName,
                                       deviceID: identity.deviceID, serverSPKI: daemon.serverSPKI))
            #expect(daemon.device(matching: identity.spkiSHA256) != nil)
            // Reusing the identity for a retry keeps the key (docs/pairing.md §3).
            let again = try await keys.identityForPairing(nodeTag: "node-a", deviceName: "Test Mac",
                                                          replacingExisting: false)
            #expect(again.spkiSHA256 == identity.spkiSHA256)
        }
    }

    @Test func aPairingLinksKeyPinsTheFirstConnection() async throws {
        try await withDaemon { daemon, _, identity, _ in
            let fixture = try KeychainFixture.require()
            // The link names another server's key: refused at the handshake, nothing is sent.
            var configuration = Fast.pairing(port: daemon.port)
            configuration.expectedServerSPKI = fixture.otherServer.spkiSHA256
            let impostorLink = PairingClient(identity: identity, configuration: configuration)
            let refused = Recorder(impostorLink.start())
            #expect(await finalState(refused) == .failed(.unexpectedServerIdentity))
            #expect(daemon.commands.isEmpty)

            // The link's key is the server's: it pairs as usual, and the code still decides.
            configuration.expectedServerSPKI = daemon.serverSPKI
            let client = PairingClient(identity: identity, configuration: configuration)
            let states = Recorder(client.start())
            let request = try #require(await daemon.confirmedRequest())
            daemon.decide(request.id, .approved)
            #expect(await finalState(states) == .approved(nodeID: MockDaemon.nodeID, nodeName: MockDaemon.nodeName,
                                                          deviceID: identity.deviceID, serverSPKI: daemon.serverSPKI))
        }
    }

    @Test(arguments: [MockDaemon.Decision.denied, .expired])
    func ownerDecidesAgainst(_ decision: MockDaemon.Decision) async throws {
        try await withDaemon { daemon, _, identity, _ in
            let client = PairingClient(identity: identity, configuration: Fast.pairing(port: daemon.port))
            let states = Recorder(client.start())
            let request = try #require(await daemon.confirmedRequest())
            daemon.decide(request.id, decision)
            #expect(await finalState(states) == (decision == .denied ? .denied : .expired))
            #expect(daemon.device(matching: identity.spkiSHA256) == nil)
        }
    }

    @Test func immediatePendingPollsWithAPause() async throws {
        try await withDaemon { daemon, _, identity, _ in
            daemon.state.withLock { $0.immediateStatus = true }
            let client = PairingClient(identity: identity, configuration: Fast.pairing(port: daemon.port))
            let states = Recorder(client.start())
            let request = try #require(await daemon.confirmedRequest())
            try await Task.sleep(for: .milliseconds(300))
            // Without a long poll the client paused between polls (50 ms here), so a handful, not hundreds.
            let polls = daemon.commands.filter { $0.command == "device.pair.status" }.count
            #expect(polls >= 2 && polls <= 8)
            daemon.decide(request.id, .approved)
            #expect(await finalState(states)?.isApproved == true)
        }
    }

    @Test func wrongCommitmentIsRejected() async throws {
        try await withDaemon { daemon, _, identity, _ in
            daemon.state.withLock { $0.corruptCommitments = true }
            let client = PairingClient(identity: identity, configuration: Fast.pairing(port: daemon.port))
            let states = Recorder(client.start())
            #expect(await finalState(states) == .failed(.rejected))
            // The daemon dropped the request and never showed a code.
            let requests = daemon.state.withLock { $0.requests.count }
            #expect(requests == 0)
            #expect(!states.all.contains { if case .awaitingApproval = $0 { true } else { false } })
        }
    }

    @Test func noPairingWindow() async throws {
        try await withDaemon { daemon, _, identity, _ in
            daemon.state.withLock { $0.windowOpen = false }
            let client = PairingClient(identity: identity, configuration: Fast.pairing(port: daemon.port))
            #expect(await finalState(Recorder(client.start())) == .failed(.noPairingWindow))
        }
    }

    @Test func serverKeyChangeMidPairingAborts() async throws {
        try await withDaemon { daemon, _, identity, _ in
            let impostor = try KeychainFixture.require().otherServer
            daemon.state.withLock { $0.swapOnConfirm = impostor }
            let client = PairingClient(identity: identity, configuration: Fast.pairing(port: daemon.port))
            let states = Recorder(client.start())
            #expect(await finalState(states) == .failed(.serverIdentityChanged))
            // The reconnect was pinned to the first key, so the second server never received a frame.
            #expect(!daemon.commands.contains { $0.epoch > 0 })
            #expect(!states.all.contains { if case .awaitingApproval = $0 { true } else { false } })
        }
    }

    @Test func cancelEndsTheAttempt() async throws {
        try await withDaemon { daemon, _, identity, _ in
            let client = PairingClient(identity: identity, configuration: Fast.pairing(port: daemon.port))
            let states = Recorder(client.start())
            _ = try #require(await daemon.confirmedRequest())
            client.cancel()
            try await Task.sleep(for: .milliseconds(200))
            let ended = states.all.contains { $0.isFinal }
            #expect(!ended)
            #expect(daemon.openConnections == 0)
        }
    }

    @Test func unreachableEndpoint() async throws {
        try await withDaemon { daemon, _, identity, _ in
            let port = daemon.port
            daemon.stop()
            var configuration = Fast.pairing(port: port)
            configuration.connectTimeout = .milliseconds(300)
            let client = PairingClient(identity: identity, configuration: configuration)
            let final = await finalState(Recorder(client.start()))
            #expect(final == .failed(.unreachable(endpoint: "127.0.0.1:\(port)")))
        }
    }

    // MARK: Protocol negotiation before the request

    @Test func legacyServerPairsAsBefore() async throws {
        try await withDaemon { daemon, _, identity, _ in
            // Unscripted, the mock refuses meta.hello on the pairing connection as a daemon ≤ 1.18.0 does.
            let client = PairingClient(identity: identity, configuration: Fast.pairing(port: daemon.port))
            let states = Recorder(client.start())
            let request = try #require(await daemon.confirmedRequest())
            daemon.decide(request.id, .approved)
            #expect(await finalState(states)?.isApproved == true)
            #expect(states.all.contains(.negotiated(.legacy)))
            // The hello went first, then the request.
            let order = daemon.commands.map(\.command)
            #expect(order.firstIndex(of: "meta.hello")! < order.firstIndex(of: "device.pair.request")!)
        }
    }

    @Test func negotiatedServerPairsAndReportsItsRelease() async throws {
        try await withDaemon { daemon, _, identity, _ in
            daemon.answer("meta.hello") { _ in .ok(NodeSessionTests.hello(release: "1.19.0")) }
            let client = PairingClient(identity: identity, configuration: Fast.pairing(port: daemon.port))
            let states = Recorder(client.start())
            let request = try #require(await daemon.confirmedRequest())
            daemon.decide(request.id, .approved)
            #expect(await finalState(states)?.isApproved == true)
            let settled = states.all.compactMap { if case .negotiated(let p) = $0 { p } else { nil } }.first
            #expect(settled?.state == .negotiated && settled?.productLabel == "Vaulthalla 1.19.0 · protocol 1")
            let sent = try #require(daemon.payloads(of: "meta.hello").first)
            #expect(sent["client"]?["name"] == "vaulthalla-desktop" && sent["client"]?["version"] == "0.1.0-test")
        }
    }

    @Test func incompatibleServerStopsBeforeTheRequest() async throws {
        try await withDaemon { daemon, _, identity, _ in
            daemon.answer("meta.hello") { _ in
                .refuseWith("No common protocol version.", data: [
                    "code": "protocol_unsupported", "server_min": 2, "server_max": 3, "server_version": "2.0.0",
                ])
            }
            let client = PairingClient(identity: identity, configuration: Fast.pairing(port: daemon.port))
            let states = Recorder(client.start())
            let mismatch = ProtocolMismatch(serverMin: 2, serverMax: 3, serverVersion: "2.0.0")
            let final = await finalState(states)
            #expect(final == .failed(.incompatible(mismatch)))
            #expect(PairingFailure.incompatible(mismatch).message.contains("needs a newer Vaulthalla Desktop"))
            // Nothing was requested: no pairing request exists on the node.
            #expect(!daemon.commands.contains { $0.command == "device.pair.request" })
            #expect(daemon.state.withLock { $0.requests.isEmpty })
        }
    }

    @Test func refusalCodesMapToFailures() {
        #expect(PairingFailure(WsError.refused(code: "rate_limited", message: "x")) == .rateLimited)
        #expect(PairingFailure(WsError.refused(code: "no_pairing_window", message: "x")) == .noPairingWindow)
        #expect(PairingFailure(WsError.refused(code: "device_unknown", message: "x")) == .requestUnknown)
        #expect(PairingFailure(WsError.conflict("x")) == .alreadyPaired)
        #expect(PairingFailure(WsError.invalid("x")) == .rejected)
        #expect(PairingFailure(WsError.error("boom")) == .server("boom"))
    }
}

}

extension PairingClient.State {
    var isApproved: Bool {
        if case .approved = self { return true }
        return false
    }
}
