import Foundation
import Testing
import VHContract
import VHCore
import VHKeyBackup
import VHNodes
import VHTransport

/// ``KeyStatusPoll``, Recovery Keys' poll across nodes.
///
/// Regression (Desktop 0.6.0 crashed seconds after launch once two remote nodes were paired): the poll's task-group
/// child was `do { return (id, .success(try await …)) } catch { return (id, .failure(error)) }`. Swift 6.4's optimizer
/// stores the tuple's `id` only on the catch path, so every successful answer reached the caller with an uninitialized
/// `NodeID`, and the app crashed in the concurrency runtime (`swift::TaskGroup::offer`). Only optimized code shows it:
/// CI runs this suite with `swift test -c release` as well.
@MainActor
@Suite struct KeyStatusPollTests {
    @Test func everyAnswerArrivesUnderItsOwnNode() async {
        // Like the app's three nodes: this Mac's answering at once, two remote ones later; and one that refuses.
        let replies: [(delay: Duration, refuse: Bool)] = [(.zero, false), (.milliseconds(3), false),
                                                         (.milliseconds(12), false), (.milliseconds(6), true)]
        let nodes = replies.enumerated().map { index, reply in
            KeyBackupNode(id: NodeID(rawValue: "node-\(index)-\(UUID().uuidString.lowercased())"), backupID: "b\(index)",
                          name: "node \(index)", transport: StatusNode(delay: reply.delay, refuses: reply.refuse))
        }
        let expected = Set(nodes.map(\.id))
        let refusing = nodes[3].id

        for _ in 0..<40 {
            var answers: [(NodeID, KeyStatusPoll.Outcome)] = []
            await KeyStatusPoll.run(nodes) { id, outcome in answers.append((id, outcome)) }
            #expect(answers.count == nodes.count)
            #expect(Set(answers.map(\.0)) == expected)
            for (id, outcome) in answers {
                switch outcome {
                case .success(let vaults): #expect(id != refusing && vaults.isEmpty)
                case .failure(let error): #expect(id == refusing && error == .denied("not allowed"))
                }
            }
        }
    }

    @Test func noNodesNoAnswers() async {
        var count = 0
        await KeyStatusPoll.run([]) { _, _ in count += 1 }
        #expect(count == 0)
    }
}

/// A node answering `vault.keys.status` with no vaults after `delay`, or refusing it.
private struct StatusNode: NodeTransport {
    let delay: Duration
    let refuses: Bool

    func send<R: WsRequest>(_ request: R.Type, payload: R.Payload) async throws(WsError) -> R.Response {
        if delay > .zero { try? await Task.sleep(for: delay) }
        if refuses { throw .denied("not allowed") }
        guard let response = Ws.Vault.Keys.Status.Response(vaults: []) as? R.Response else {
            throw .error("unexpected \(R.command.rawValue)")
        }
        return response
    }
}
