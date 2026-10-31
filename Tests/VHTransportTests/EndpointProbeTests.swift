import Foundation
import Network
import Testing
import VHCore
@testable import VHTransport

/// The endpoint probe (the server's transfer protocol §2): a TLS 1.3 handshake with the device identity against the
/// node's pins, never TCP alone; and the client-side address classification.
@Suite struct EndpointProbeTests {
    private func server() async throws -> TestServer {
        try await TestServer.start(tls: WsClientTLSTests.serverTLS(clientSPKI: Recorded<String>()))
    }

    private var pin: Data { WsClientTLSTests.data(hex: WsClientTLSTests.serverSPKI) }

    @Test func pinnedHandshakeSucceedsWithRTTAndAddress() async throws {
        let server = try await server()
        defer { server.stop() }
        let prober = TLSEndpointProber(identity: try WsClientTLSTests.identity(WsClientTLSTests.clientP12),
                                       pins: [Data(repeating: 9, count: 32), pin])
        let result = await prober.probe(NodeEndpoint(host: "127.0.0.1", port: server.port), timeout: .seconds(15))
        #expect(result.outcome == .ok)
        #expect(result.matchedPin == pin)
        #expect(result.remoteAddress == "127.0.0.1")
        #expect(try #require(result.rtt) < .seconds(1))
    }

    @Test func anotherServerKeyIsAnIdentityMismatch() async throws {
        let server = try await server()
        defer { server.stop() }
        let prober = TLSEndpointProber(identity: try WsClientTLSTests.identity(WsClientTLSTests.clientP12),
                                       pins: [Data(repeating: 7, count: 32)])
        let result = await prober.probe(NodeEndpoint(host: "127.0.0.1", port: server.port), timeout: .seconds(15))
        #expect(result.outcome == .identityMismatch)
        #expect(result.matchedPin == nil)
    }

    @Test func aClosedPortIsRefused() async throws {
        let port = try await TestServer.unusedPort()
        let prober = TLSEndpointProber(identity: try WsClientTLSTests.identity(WsClientTLSTests.clientP12), pins: [pin])
        let result = await prober.probe(NodeEndpoint(host: "127.0.0.1", port: port), timeout: .seconds(3))
        #expect(result.outcome == .refused)
    }

    @Test func aPlainTCPListenerIsNotASuccess() async throws {
        // Accepts TCP and never speaks TLS: the probe must time out, not count the connect.
        let server = try await TestServer.start()
        defer { server.stop() }
        let prober = TLSEndpointProber(identity: try WsClientTLSTests.identity(WsClientTLSTests.clientP12), pins: [pin])
        let result = await prober.probe(NodeEndpoint(host: "127.0.0.1", port: server.port), timeout: .milliseconds(600))
        #expect(result.outcome != .ok)
    }

    @Test func withoutAnIdentityTheServerKeyDecides() async throws {
        let server = try await server()
        defer { server.stop() }
        let endpoint = NodeEndpoint(host: "127.0.0.1", port: server.port)
        // A pairing link's expected key, or any key (trust on first use) when the link has none.
        #expect(await TLSEndpointProber(identity: nil, pins: [pin]).probe(endpoint, timeout: .seconds(15)).outcome == .ok)
        #expect(await TLSEndpointProber(identity: nil, pins: []).probe(endpoint, timeout: .seconds(15)).outcome == .ok)
        let wrong = await TLSEndpointProber(identity: nil, pins: [Data(repeating: 1, count: 32)])
            .probe(endpoint, timeout: .seconds(15))
        #expect(wrong.outcome == .identityMismatch)
    }

    @Test func anUnresolvableNameIsUnresolved() async throws {
        let prober = TLSEndpointProber(identity: nil, pins: [pin])
        let result = await prober.probe(NodeEndpoint(host: "no-such-host.invalid", port: 36972), timeout: .seconds(3))
        #expect(result.outcome == .unresolved || result.outcome == .timeout)
    }

    // MARK: Classification

    @Test(arguments: [
        ("127.0.0.1", EndpointClass.loopback), ("127.8.9.1", .loopback), ("::1", .loopback),
        ("10.0.0.11", .lan), ("172.16.4.2", .lan), ("172.31.255.1", .lan), ("192.168.1.20", .lan),
        ("169.254.3.3", .lan), ("fd00::11", .lan), ("fc12::1", .lan), ("fe80::1%en0", .lan),
        ("100.64.0.1", .vpn), ("100.101.1.2", .vpn), ("100.127.255.254", .vpn),
        ("172.32.0.1", .wan), ("100.128.0.1", .wan), ("203.0.113.7", .wan), ("2001:db8::7", .wan),
        ("::ffff:10.0.0.11", .lan), ("::ffff:8.8.8.8", .wan),
    ])
    func classifiesByRange(address: String, expected: EndpointClass) {
        #expect(EndpointClassifier.classify(address: address) == expected)
    }

    @Test func tunnelInterfacesAreVPNExceptLoopback() {
        #expect(EndpointClassifier.classify(address: "10.0.0.11", interfaceName: "utun4") == .vpn)
        #expect(EndpointClassifier.classify(address: "203.0.113.7", interfaceName: "wg0") == .vpn)
        #expect(EndpointClassifier.classify(address: "203.0.113.7", interfaceName: "en0") == .wan)
        #expect(EndpointClassifier.classify(address: "127.0.0.1", interfaceName: "utun4") == .loopback)
        #expect(EndpointClassifier.classify(address: "nas.home.arpa") == nil)
    }

    @Test func estimatesHostNamesBeforeResolution() {
        #expect(EndpointClassifier.estimate(host: "localhost") == .loopback)
        #expect(EndpointClassifier.estimate(host: "vh-storage.local") == .lan)
        #expect(EndpointClassifier.estimate(host: "nas.home.arpa") == .lan)
        #expect(EndpointClassifier.estimate(host: "100.101.1.2") == .vpn)
        #expect(EndpointClassifier.estimate(host: "device.example.com") == nil)
    }
}

extension TestServer {
    /// A loopback port nothing listens on (a server's, after it stopped).
    static func unusedPort() async throws -> UInt16 {
        let server = try await start()
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(50))
        return port
    }
}
