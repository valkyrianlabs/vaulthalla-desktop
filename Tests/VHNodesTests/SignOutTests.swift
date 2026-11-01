import Foundation
import Testing
import VHCore
@testable import VHNodes

/// Sign-out fails closed (desktop#7): keys go and nodes return to unpaired whatever the nodes answer.
@Suite struct SignOutTests {
    private struct Refused: Error, CustomStringConvertible {
        var description: String { "refused" }
    }

    private static func node(_ id: String, paired deviceID: String? = nil) -> Node {
        Node(id: NodeID(rawValue: id), displayName: id, endpoint: NodeEndpoint(host: "\(id).local"),
             pairing: deviceID.map { .paired(serverSPKISHA256: Data(repeating: 1, count: 32), deviceID: $0, since: .now) }
                ?? .unpaired)
    }

    @MainActor private final class Log {
        var revoked: [String] = []
        var forgotten: [NodeID] = []
        var domainsRemoved = 0
    }

    @Test @MainActor func revokesPairedNodesAndForgetsEveryNode() async {
        let log = Log()
        let nodes = [Self.node("a", paired: "dev-a"), Self.node("b"), Self.node("c", paired: "dev-c")]
        let report = await SignOut.run(nodes) { target in
            await MainActor.run { log.revoked.append(target.deviceID) }
        } removeDomains: {
            await MainActor.run { log.domainsRemoved += 1 }
        } forget: { id in
            await MainActor.run { log.forgotten.append(id) }
        }
        #expect(Set(log.revoked) == ["dev-a", "dev-c"])
        #expect(Set(report.revoked) == [NodeID(rawValue: "a"), NodeID(rawValue: "c")])
        #expect(report.notRevoked.isEmpty)
        #expect(log.domainsRemoved == 1)
        #expect(log.forgotten == nodes.map(\.id), "unpaired nodes too: they may keep an earlier attempt's key")
    }

    @Test @MainActor func aRefusingOrSilentNodeStillLosesItsKey() async {
        let log = Log()
        let nodes = [Self.node("refuses", paired: "dev-r"), Self.node("silent", paired: "dev-s")]
        // The silent node ignores cancellation too: sign-out must not wait for it.
        let report = await SignOut.run(nodes, revokeTimeout: .milliseconds(50)) { target in
            if target.deviceID == "dev-r" { throw Refused() }
            await Task.detached { try? await Task.sleep(for: .seconds(600)) }.value // an unstructured task's value ignores cancellation
        } removeDomains: {
            throw Refused()
        } forget: { id in
            await MainActor.run { log.forgotten.append(id) }
        }
        #expect(report.revoked.isEmpty)
        #expect(report.notRevoked[NodeID(rawValue: "refuses")] == "refused")
        #expect(report.notRevoked[NodeID(rawValue: "silent")] == SignOut.TimedOut().description)
        #expect(report.domainProblem == "refused")
        #expect(log.forgotten == nodes.map(\.id))
    }

    @Test func targetsAreThePairedNodes() {
        let revoked = Node(id: NodeID(rawValue: "r"), displayName: "r", endpoint: NodeEndpoint(host: "r"),
                           pairing: .revoked(at: .now))
        #expect(SignOut.targets([Self.node("a", paired: "dev-a"), Self.node("b"), revoked])
                == [SignOut.Target(node: NodeID(rawValue: "a"), deviceID: "dev-a")])
    }
}
