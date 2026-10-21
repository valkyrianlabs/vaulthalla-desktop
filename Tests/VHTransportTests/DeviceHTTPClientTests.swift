import Foundation
import Synchronization
import Testing
import VHContract
import VHCore
@testable import VHTransport

/// `DeviceHTTPClient` against a TLS 1.3 loopback server that requires a client certificate: the identities and pins
/// of `WsClientTLSTests`, the request shapes of the daemon's device listener (`/download/content`, `/mcp`).
@Suite struct DeviceHTTPClientTests {
    static let blob = Data((0..<4096).map { UInt8(($0 * 7 + 3) % 256) })

    /// Serves `blob` at `/download/content` (honouring one `bytes=a-b` range) and echoes `/mcp` calls.
    static let handler: HTTPTestServer.Handler = { request in
        if request.target.hasPrefix("/download/content") {
            guard let range = request.header("Range") else {
                return .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: blob)
            }
            let bounds = range.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
            guard bounds.count == 2, bounds[0] <= bounds[1], bounds[1] < blob.count else {
                return .init(status: 416)
            }
            return .init(status: 206, headers: ["Content-Range": "bytes \(bounds[0])-\(bounds[1])/\(blob.count)"],
                         body: blob[bounds[0]...bounds[1]])
        }
        if request.target == "/mcp", request.method == "POST" {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: request.body),
                  let id = message["id"]
            else { return .init(status: 202) }
            let answer: JSONValue = ["jsonrpc": "2.0", "id": id, "result": ["echo": message["method"] ?? .null]]
            return .init(status: 200, headers: ["Content-Type": "application/json"],
                         body: try! JSONEncoder().encode(answer))
        }
        return .init(status: 404)
    }

    private static func client(port: UInt16, pin: Data, next: Data? = nil) throws -> DeviceHTTPClient {
        try DeviceHTTPClient(configuration: .init(
            endpoint: NodeEndpoint(host: "127.0.0.1", port: port),
            identity: try WsClientTLSTests.identity(WsClientTLSTests.clientP12),
            serverSPKIPin: pin, nextServerSPKIPin: next, timeout: .seconds(5)))
    }

    private static var serverPin: Data { WsClientTLSTests.data(hex: WsClientTLSTests.serverSPKI) }

    @Test func downloadsARangeOverMutualTLS() async throws {
        let clientSPKI = Recorded<String>()
        let server = try await HTTPTestServer.start(tls: try WsClientTLSTests.serverTLS(clientSPKI: clientSPKI),
                                                    handler: Self.handler)
        defer { server.stop() }
        let http = try Self.client(port: server.port, pin: Self.serverPin)
        defer { http.invalidate() }

        let (whole, full) = try await http.download(vaultID: 7, path: "/docs/blob.bin")
        #expect(full.statusCode == 200)
        #expect(whole == Self.blob)

        let (part, partial) = try await http.download(vaultID: 7, path: "/docs/blob.bin", range: 100...1123)
        #expect(partial.statusCode == 206)
        #expect(partial.value(forHTTPHeaderField: "Content-Range") == "bytes 100-1123/4096")
        #expect(part == Self.blob[100...1123])

        // The device's certificate was presented, and the daemon's query shape arrived.
        #expect(clientSPKI.value == WsClientTLSTests.clientSPKI)
        #expect(server.requests.last?.target == "/download/content?vault_id=7&path=/docs/blob.bin")
        #expect(server.requests.last?.header("Range") == "bytes=100-1123")
    }

    @Test func encodesPlusAndSpacesInTheQuery() async throws {
        let server = try await HTTPTestServer.start(tls: try WsClientTLSTests.serverTLS(clientSPKI: Recorded()),
                                                    handler: Self.handler)
        defer { server.stop() }
        let http = try Self.client(port: server.port, pin: Self.serverPin)
        defer { http.invalidate() }

        _ = try await http.download(vaultID: 1, path: "/a+b c.txt")
        #expect(server.requests.last?.target == "/download/content?vault_id=1&path=/a%2Bb%20c.txt")
    }

    @Test func postsMCPMessagesAsJSON() async throws {
        let server = try await HTTPTestServer.start(tls: try WsClientTLSTests.serverTLS(clientSPKI: Recorded()),
                                                    handler: Self.handler)
        defer { server.stop() }
        let http = try Self.client(port: server.port, pin: Self.serverPin)
        defer { http.invalidate() }

        let (status, body) = try await http.mcp(["jsonrpc": "2.0", "id": 1, "method": "tools/list"],
                                                protocolVersion: "2025-11-25")
        #expect(status == 200)
        #expect(body?["result"]?["echo"] == "tools/list")
        let request = try #require(server.requests.last)
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("Accept")?.contains("application/json") == true)
        #expect(request.header("MCP-Protocol-Version") == "2025-11-25")

        let notified = try await http.mcp(["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(notified.status == 202)
        #expect(notified.body == nil)
    }

    /// Every request on a new TLS connection (the server closes each one): the identity is presented every time.
    @Test func presentsTheIdentityOnEveryConnection() async throws {
        let clientSPKI = Recorded<String>()
        let server = try await HTTPTestServer.start(tls: try WsClientTLSTests.serverTLS(clientSPKI: clientSPKI)) {
            var response = Self.handler($0)
            response.headers["Connection"] = "close"
            return response
        }
        defer { server.stop() }
        let http = try Self.client(port: server.port, pin: Self.serverPin)
        defer { http.invalidate() }

        for _ in 0..<3 {
            clientSPKI.record(nil)
            let (data, response) = try await http.download(vaultID: 7, path: "/docs/blob.bin", range: 0...15)
            #expect(response.statusCode == 206)
            #expect(data == Self.blob[0...15])
            #expect(clientSPKI.value == WsClientTLSTests.clientSPKI)
        }
        #expect(server.requests.count == 3)
    }

    /// The daemon's 403 (an unpaired or revoked key on the lanes, an RBAC refusal) is a typed refusal, whether the
    /// server keeps the connection or closes it, and the client keeps working afterwards.
    @Test(arguments: [false, true])
    func reportsAForbiddenAnswer(closing: Bool) async throws {
        let server = try await HTTPTestServer.start(tls: try WsClientTLSTests.serverTLS(clientSPKI: Recorded())) {
            guard $0.target.contains("secret") else { return Self.handler($0) }
            return .init(status: 403, headers: closing ? ["Connection": "close", "Content-Type": "text/plain"] : [:],
                         body: Data("device_unknown".utf8))
        }
        defer { server.stop() }
        let http = try Self.client(port: server.port, pin: Self.serverPin)
        defer { http.invalidate() }

        await #expect(throws: DeviceHTTPError.forbidden) {
            _ = try await http.download(vaultID: 1, path: "/secret.txt")
        }
        let (_, after) = try await http.download(vaultID: 1, path: "/docs/blob.bin", range: 0...3)
        #expect(after.statusCode == 206)
    }

    @Test func refusesAServerThatDoesNotMatchThePin() async throws {
        let server = try await HTTPTestServer.start(tls: try WsClientTLSTests.serverTLS(clientSPKI: Recorded()),
                                                    handler: Self.handler)
        defer { server.stop() }
        let http = try Self.client(port: server.port, pin: Data(repeating: 0xAB, count: 32))
        defer { http.invalidate() }

        await #expect(throws: DeviceHTTPError.pinMismatch(observedSPKISHA256: Self.serverPin)) {
            _ = try await http.download(vaultID: 1, path: "/x")
        }
        #expect(server.requests.isEmpty)
    }

    @Test func acceptsTheAnnouncedNextKey() async throws {
        let server = try await HTTPTestServer.start(tls: try WsClientTLSTests.serverTLS(clientSPKI: Recorded()),
                                                    handler: Self.handler)
        defer { server.stop() }
        let http = try Self.client(port: server.port, pin: Data(repeating: 0xAB, count: 32), next: Self.serverPin)
        defer { http.invalidate() }

        let (_, response) = try await http.download(vaultID: 1, path: "/docs/blob.bin", range: 0...9)
        #expect(response.statusCode == 206)
    }
}
