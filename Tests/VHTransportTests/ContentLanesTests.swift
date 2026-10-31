import Foundation
import Testing
import VHCore
@testable import VHTransport

/// The replica's lanes (vaulthalla/desktop#4) against the loopback mutual-TLS server: a version-guarded byte range of
/// `/download/content` (`Range` + `If-Range`), and `PUT /upload/content` (vaulthalla/server#258) with its
/// preconditions and every answer the daemon gives.
@Suite struct ContentLanesTests {
    static let blob = VaultLanesTests.blob
    static let etag = VaultLanesTests.etag

    private static func lanes(port: UInt16) throws -> VaultLanes {
        let configuration = DeviceHTTPClient.Configuration(
            endpoint: NodeEndpoint(host: "127.0.0.1", port: port),
            identity: try WsClientTLSTests.identity(WsClientTLSTests.clientP12),
            serverSPKIPin: WsClientTLSTests.data(hex: WsClientTLSTests.serverSPKI), timeout: .seconds(5))
        return VaultLanes(transfers: try DeviceTransferClient(configuration: configuration))
    }

    private static func start(_ handler: @escaping HTTPTestServer.Handler) async throws -> HTTPTestServer {
        try await HTTPTestServer.start(tls: try WsClientTLSTests.serverTLS(clientSPKI: Recorded()), handler: handler)
    }

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "vh-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `/download/content` with exact ranges: `bytes=a-b` answered 206 with exactly those bytes while `If-Range`
    /// matches; the whole file (200) when it doesn't; 416 past the end.
    static func serveRange(_ request: HTTPTestServer.Request, etag: String = etag) -> HTTPTestServer.Response {
        var headers = ["Content-Type": "application/octet-stream", "ETag": etag, "Accept-Ranges": "bytes"]
        guard let range = request.header("Range"), request.header("If-Range").map({ $0 == etag }) ?? true else {
            return .init(status: 200, headers: headers, body: blob)
        }
        let bounds = range.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
        guard bounds.count == 2, bounds[0] < blob.count else {
            return .init(status: 416, headers: ["Content-Range": "bytes */\(blob.count)"])
        }
        let end = min(bounds[1], blob.count - 1)
        headers["Content-Range"] = "bytes \(bounds[0])-\(end)/\(blob.count)"
        return .init(status: 206, headers: headers, body: blob[bounds[0]...end])
    }

    // MARK: Ranges

    @Test func writesARangeAtItsOffset() async throws {
        let server = try await Self.start { Self.serveRange($0) }
        defer { server.stop() }
        let lanes = try Self.lanes(port: server.port)
        defer { lanes.invalidate() }
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = folder.appending(path: "sparse")
        let answer = try await lanes.downloadRange(vaultID: 3, path: "/big.bin", range: 65536...(65536 + 16383),
                                                   contentVersion: Self.etag, into: file, acceptWhole: false)
        #expect(answer == .partial(offset: 65536, length: 16384, total: Int64(Self.blob.count), etag: Self.etag))
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: 65536)
        #expect(try handle.read(upToCount: 16384) == Self.blob[65536..<(65536 + 16384)])
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int == 65536 + 16384)
        let sent = try #require(server.requests.last)
        #expect(sent.header("Range") == "bytes=65536-81919")
        #expect(sent.header("If-Range") == Self.etag)
    }

    /// The file changed since the version asked for: the node sends it whole. Only that version would do, so nothing
    /// is kept; when any version does, the new one is written whole.
    @Test func aChangedFileIsRefusedOrFetchedWhole() async throws {
        let server = try await Self.start { Self.serveRange($0, etag: "\"g42-newer\"") }
        defer { server.stop() }
        let lanes = try Self.lanes(port: server.port)
        defer { lanes.invalidate() }
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let strict = folder.appending(path: "strict")
        let refused = try await lanes.downloadRange(vaultID: 3, path: "/big.bin", range: 0...4095,
                                                    contentVersion: Self.etag, into: strict, acceptWhole: false)
        #expect(refused == .changed(etag: "\"g42-newer\""))
        #expect(!FileManager.default.fileExists(atPath: strict.path))

        let loose = folder.appending(path: "loose")
        let whole = try await lanes.downloadRange(vaultID: 3, path: "/big.bin", range: 0...4095,
                                                  contentVersion: Self.etag, into: loose, acceptWhole: true)
        #expect(whole == .whole(length: Int64(Self.blob.count), etag: "\"g42-newer\""))
        #expect(try Data(contentsOf: loose) == Self.blob)

        // Past the end: 416.
        let past = try await lanes.downloadRange(vaultID: 3, path: "/big.bin", range: 900_000...900_100,
                                                 contentVersion: "\"g42-newer\"", into: loose, acceptWhole: false)
        #expect(past == .unsatisfiable(total: Int64(Self.blob.count)))
    }

    // MARK: Conditional writes

    /// Status mapping for `/upload/content`, one scripted answer per path. The precondition semantics themselves are
    /// the server's (core/src/protocols/http/upload); this checks the client sends one and reads the answers.
    @Test func mapsTheLanesRefusals() async throws {
        let server = try await Self.start { request in
            if request.target.contains("toolarge") {
                return .init(status: 413, headers: ["Content-Type": "application/json"],
                             body: Data(#"{"error":"Not enough space in the vault","code":"limit_exceeded"}"#.utf8))
            }
            if request.target.contains("huge") {
                return .init(status: 413, headers: ["Content-Type": "application/json"],
                             body: Data(#"{"error":"The file exceeds the maximum upload size","code":"limit_exceeded"}"#.utf8))
            }
            guard request.header("If-None-Match") == "*" else { return .init(status: 428) }
            return .init(status: 409, headers: ["Content-Type": "application/json"],
                         body: Data(#"{"error":"Something that is not a file exists at that path","code":"conflict"}"#.utf8))
        }
        defer { server.stop() }
        let lanes = try Self.lanes(port: server.port)
        defer { lanes.invalidate() }
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let body = folder.appending(path: "body")
        try Data("x".utf8).write(to: body)

        // A folder in the way: 409.
        await #expect(throws: TransferError.alreadyExists) {
            _ = try await lanes.putContent(vaultID: 3, path: "/docs", from: body, precondition: .create)
        }
        await #expect(throws: TransferError.quotaExceeded) {
            _ = try await lanes.putContent(vaultID: 3, path: "/toolarge.bin", from: body, precondition: .create)
        }
        await #expect(throws: TransferError.status(413, "The file exceeds the maximum upload size")) {
            _ = try await lanes.putContent(vaultID: 3, path: "/huge.bin", from: body, precondition: .create)
        }
        // Without a precondition the daemon answers 428; this client always sends one, so read the answer directly.
        #expect(throws: TransferError.status(428, "Send If-Match or If-None-Match: *")) {
            _ = try VaultLanes.contentWrite(status: 428, body: Data(#"{"error":"Send If-Match or If-None-Match: *"}"#.utf8),
                                            etag: nil)
        }
        #expect(throws: TransferError.forbidden) {
            _ = try VaultLanes.contentWrite(status: 403, body: Data(), etag: nil)
        }
        // A 412 without a body still carries the version in its ETag.
        #expect(try VaultLanes.contentWrite(status: 412, body: Data(), etag: "\"g1-2\"") == .conflict(currentVersion: "\"g1-2\""))
    }
}
