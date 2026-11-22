import Foundation
import Testing
import VHCore

@Suite struct AgentAccessTests {
    @Test func recordsOnlyExclusionsPerClient() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vh-access-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = AgentAccess.fileURL(besideRegistry: directory.appending(path: "nodes.json"))
        #expect(url.lastPathComponent == "agent-access.json")
        #expect(try AgentAccess.load(from: url) == AgentAccess())  // missing: everything available

        var access = AgentAccess()
        let a = NodeID(rawValue: "a"), b = NodeID(rawValue: "b")
        access.set(b, available: false, to: .codex)
        access.set(a, available: false, to: .codex)
        access.set(a, available: false, to: .codex)
        #expect(access.excluded == ["codex": ["a", "b"]])
        #expect(!access.isAvailable(a, to: .codex) && access.isAvailable(a, to: .claudeCode))
        access.set(a, available: true, to: .codex)
        access.prune(keeping: [a])
        #expect(access.excluded.isEmpty)

        access.set(b, available: false, to: .claudeDesktop)
        try access.save(to: url)
        #expect(try AgentAccess.load(from: url) == access)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["agent-access.json"])

        // A later client's key is ignored; a newer version or garbage is refused.
        try Data(#"{"version":1,"excluded":{"future-app":["a"]}}"#.utf8).write(to: url)
        #expect(try AgentAccess.load(from: url).excludedNodes(for: .codex).isEmpty)
        try Data(#"{"version":2}"#.utf8).write(to: url)
        #expect(throws: AgentAccess.Failure.unsupportedVersion(2)) { try AgentAccess.load(from: url) }
        try Data("[]".utf8).write(to: url)
        #expect(throws: AgentAccess.Failure.self) { try AgentAccess.load(from: url) }
    }
}
