import Testing
import VHCore

@Suite struct NodeEndpointTests {
    @Test(arguments: [
        ("vh-storage", "vh-storage", NodeEndpoint.defaultDevicePort),
        ("10.0.0.33:4443", "10.0.0.33", 4443),
        ("https://vault.example.com:36972/ws", "vault.example.com", 36972),
        ("[fe80::1]:9000", "fe80::1", 9000),
        ("fe80::1", "fe80::1", NodeEndpoint.defaultDevicePort),
        ("  host.local  ", "host.local", NodeEndpoint.defaultDevicePort),
    ])
    func parses(input: String, host: String, port: UInt16) throws {
        let endpoint = try #require(NodeEndpoint(parsing: input))
        #expect(endpoint.host == host)
        #expect(endpoint.port == port)
    }

    @Test(arguments: ["", "host:", "host:0", "host:70000", "[fe80::1", "[]:80", ":443"])
    func rejects(input: String) {
        #expect(NodeEndpoint(parsing: input) == nil)
    }

    @Test func describesIPv6WithBrackets() {
        #expect(NodeEndpoint(host: "fe80::1", port: 1).description == "[fe80::1]:1")
        #expect(NodeEndpoint(host: "a", port: 2).description == "a:2")
    }
}

@Suite struct SecretBytesTests {
    @Test func neverPrintsItsContents() {
        let secret = SecretBytes([1, 2, 3, 4])
        #expect(String(describing: secret) == "SecretBytes(4 bytes, redacted)")
        #expect(secret.withUnsafeBytes { Array($0) } == [1, 2, 3, 4])
    }

    @Test func decodesBase64() throws {
        let secret = try #require(SecretBytes(base64: "AAEC"))
        #expect(secret.withUnsafeBytes { Array($0) } == [0, 1, 2])
        #expect(SecretBytes(base64: "not base64!") == nil)
    }
}
