import Foundation
import Testing
import VHCore
@testable import VHNodes

/// `vaulthalla://pair` links (the server's transfer protocol §1.2): untrusted input, parsed defensively.
@Suite struct PairLinkTests {
    private static let key = String(repeating: "ab", count: 32)

    @Test func parsesTheSpecShape() throws {
        let link = try PairLink(string:
            "vaulthalla://pair?node=node-7f3a&spki=\(Self.key)&endpoints=10.0.0.11:36972,%5Bfd00::11%5D:36972,vh.local")
        #expect(link.nodeID == "node-7f3a")
        #expect(link.serverSPKISHA256 == Data(repeating: 0xAB, count: 32))
        #expect(link.endpoints == [NodeEndpoint(host: "10.0.0.11", port: 36972), NodeEndpoint(host: "fd00::11", port: 36972),
                                   NodeEndpoint(host: "vh.local", port: NodeEndpoint.defaultDevicePort)])
    }

    @Test func acceptsAnEncodedListAndUppercaseKey() throws {
        let link = try PairLink(string:
            "VAULTHALLA://PAIR?endpoints=10.0.0.11%3A36972%2Cdevice.example.com%3A443&spki=\(Self.key.uppercased())")
        #expect(link.endpoints.map(\.description) == ["10.0.0.11:36972", "device.example.com:443"])
        #expect(link.serverSPKISHA256?.count == 32)
        #expect(link.nodeID == nil)
    }

    @Test func dropsBadEntriesAndDuplicates() throws {
        let link = try PairLink(string:
            "vaulthalla://pair?endpoints=10.0.0.11:36972,10.0.0.11:36972,evil.example/x:1,a%20b:1,x@y:2,h:0,h:99999,ok.example:1")
        #expect(link.endpoints.map(\.description) == ["10.0.0.11:36972", "ok.example:1"])
        let many = (0..<50).map { "10.0.1.\($0)" }.joined(separator: ",")
        #expect(try PairLink(string: "vaulthalla://pair?endpoints=\(many)").endpoints.count == PairLink.maxEndpoints)
    }

    @Test(arguments: [
        ("https://pair?endpoints=a:1", PairLink.Problem.notAPairLink),
        ("vaulthalla://other?endpoints=a:1", .notAPairLink),
        ("vaulthalla://pair/x?endpoints=a:1", .notAPairLink),
        ("vaulthalla://user@pair?endpoints=a:1", .notAPairLink),
        ("vaulthalla://pair?endpoints=a:1&endpoints=b:2", .duplicateParameter("endpoints")),
        ("vaulthalla://pair?endpoints=a:1&spki=abcd", .malformedKey),
        ("vaulthalla://pair?endpoints=a:1&spki=\(String(repeating: "zz", count: 32))", .malformedKey),
        ("vaulthalla://pair?endpoints=a:1&spki=+\(String(repeating: "a", count: 63))", .malformedKey),
        ("vaulthalla://pair?endpoints=a:1&node=a/b", .malformedNodeID),
        ("vaulthalla://pair?node=n", .noEndpoints),
        ("vaulthalla://pair?endpoints=,,", .noEndpoints),
    ])
    func refuses(_ text: String, problem: PairLink.Problem) {
        #expect(throws: problem) { try PairLink(string: text) }
    }

    @Test func refusesHugeLinksUnread() {
        let text = "vaulthalla://pair?endpoints=" + String(repeating: "a", count: PairLink.maxLength)
        #expect(throws: PairLink.Problem.tooLong) { try PairLink(string: text) }
    }
}

extension PairLinkTests {
    @Test func probesTheLinksEndpointsAndPicksTheBestVerified() async throws {
        let link = try PairLink(string: "vaulthalla://pair?endpoints=device.example.com:443,10.0.0.11:36972,127.0.0.1:36972")
        let prober = FakeProber([
            "device.example.com": FakeProber.ok(address: "203.0.113.7"),
            "10.0.0.11": FakeProber.ok(address: "10.0.0.11"),
            "127.0.0.1": FakeProber.fail(.identityMismatch),
        ])
        let selection = await link.probe(prober: prober)
        #expect(selection.chosen?.candidate.endpoint == NodeEndpoint(host: "10.0.0.11", port: 36972))
        #expect(selection.chosen?.candidate.sources == [.link])
        #expect(selection.report(for: NodeEndpoint(host: "127.0.0.1"))?.outcome == .identityMismatch)
        #expect(link.advertisedEndpoints.map(\.source) == ["link", "link", "link"])
    }
}
