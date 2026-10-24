import Foundation
import Testing
import VHContract
import VHCore

/// The `vaulthalla-mcp` binary over real pipes: stdout carries exactly one JSON-RPC message per line and nothing
/// else, diagnostics go to stderr without tool arguments, and closing stdin ends the process.
@Suite(.timeLimit(.minutes(1))) struct ExecutableTests {
    /// The helper next to the test bundle (`swift test` builds every product into the same directory).
    static var executable: URL? {
        let products = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
        let url = products.appending(path: "vaulthalla-mcp")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    @Test(.enabled(if: executable != nil, "vaulthalla-mcp isn't built next to the tests"))
    func speaksMCPOnStdoutOnly() async throws {
        let registry = TempRegistry()
        defer { registry.remove() }
        try registry.writer.add(Node(id: NodeID(rawValue: "node-u"), displayName: "Spare",
                                    endpoint: NodeEndpoint(host: "192.0.2.1")))

        let secret = "hunter2-\(UUID().uuidString)"
        let lines: [JSONValue] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "nodes_list", "arguments": [:]]],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
             "params": ["name": "vh_run", "arguments": ["node": "Spare", "command": .string("user create \(secret)")]]],
            // U+2028 is legal inside a JSON string and must not split the line.
            ["jsonrpc": "2.0", "id": "line\u{2028}separator", "method": "ping"],
        ]
        var input = Data()
        for line in lines { input += try JSONEncoder().encode(line) + Data([0x0A]) }

        let process = Process()
        guard let executable = Self.executable else { return }  // the trait skips the test then
        process.executableURL = executable
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["VAULTHALLA_MCP_REGISTRY": registry.store.fileURL.path, "VAULTHALLA_MCP_LOG": "debug"]) { $1 }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let out = try stdout.fileHandleForReading.readToEnd() ?? Data()
        let err = String(decoding: try stderr.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let messages = try out.split(separator: 0x0A).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }
        #expect(out.last == 0x0A)
        let byID = Dictionary(messages.compactMap { m in m["id"].map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
        #expect(messages.count == 5, "one answer per request, no notification without a change")
        #expect(byID[1]?["result"]?["serverInfo"]?["name"] == "vaulthalla-desktop")
        #expect(byID[2]?["result"]?["tools"]?.toolNames == ["nodes_list"])
        let rows = byID[3]?["result"]?["structuredContent"]?["nodes"]?.arrayValue
        #expect(rows?.first?["pairing"] == "unpaired" && rows?.first?["name"] == "Spare")
        #expect(byID[4]?["error"]?["code"] == -32602)  // no paired node offers vh_run
        #expect(byID["line\u{2028}separator"]?["result"] == [:])

        #expect(err.contains("vaulthalla-mcp:"))
        #expect(!err.contains(secret), "stderr never carries tool arguments")
    }
}

private final class BundleMarker {}
