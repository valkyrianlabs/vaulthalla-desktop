import Foundation
import Synchronization
import Testing
import VHCore
@testable import VHTransport

/// The transfer engine (`DeviceTransferClient`, `VaultLanes`) against the loopback mutual-TLS server, speaking the
/// device listener's lanes: `/download/content` with Range/If-Range, `/download` ZIPs, the upload session flow,
/// `/preview/batch`, cancellation and the 403 that URLSession hides.
@Suite struct VaultLanesTests {
    static let blob = Data((0..<200_000).map { UInt8(($0 * 31 + 7) % 251) })
    static let etag = "\"g42-0123456789abcdef\""

    /// `/download/content` as the daemon serves it (handler/Common.cpp `serve`): strong ETag, one Range, If-Range.
    static func serve(_ request: HTTPTestServer.Request, body: Data = blob, etag: String = etag) -> HTTPTestServer.Response {
        var headers = ["Content-Type": "application/octet-stream", "ETag": etag, "Accept-Ranges": "bytes"]
        guard let range = request.header("Range"), request.header("If-Range").map({ $0 == etag }) ?? true else {
            return .init(status: 200, headers: headers, body: body)
        }
        let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard let start = Int(bounds.first ?? ""), start < body.count else {
            return .init(status: 416, headers: ["Content-Range": "bytes */\(body.count)"])
        }
        headers["Content-Range"] = "bytes \(start)-\(body.count - 1)/\(body.count)"
        return .init(status: 206, headers: headers, body: body[start...])
    }

    private static func lanes(port: UInt16, policy: VaultLanes.Policy = fastPolicy) throws -> VaultLanes {
        let configuration = DeviceHTTPClient.Configuration(
            endpoint: NodeEndpoint(host: "127.0.0.1", port: port),
            identity: try WsClientTLSTests.identity(WsClientTLSTests.clientP12),
            serverSPKIPin: WsClientTLSTests.data(hex: WsClientTLSTests.serverSPKI), timeout: .seconds(5))
        return VaultLanes(transfers: try DeviceTransferClient(configuration: configuration), policy: policy)
    }

    static var fastPolicy: VaultLanes.Policy {
        var policy = VaultLanes.Policy()
        policy.backoff = .milliseconds(20)
        return policy
    }

    private static func start(_ handler: @escaping HTTPTestServer.Handler) async throws -> HTTPTestServer {
        try await HTTPTestServer.start(tls: try WsClientTLSTests.serverTLS(clientSPKI: Recorded()), handler: handler)
    }

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "vh-lanes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Downloads

    @Test func downloadsAFileToItsDestination() async throws {
        let server = try await Self.start { Self.serve($0) }
        defer { server.stop() }
        let lanes = try Self.lanes(port: server.port)
        defer { lanes.invalidate() }
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let destination = folder.appending(path: "blob.bin")
        let seen = Mutex<[Int64]>([])
        let length = try await lanes.download(vaultID: 3, path: "/docs/blob.bin", isDirectory: false,
                                              to: destination) { done, _ in seen.withLock { $0.append(done) } }
        #expect(length == Int64(Self.blob.count))
        #expect(try Data(contentsOf: destination) == Self.blob)
        #expect(seen.withLock { $0.last } == Int64(Self.blob.count))
        #expect(server.requests.last?.target == "/download/content?vault_id=3&path=/docs/blob.bin&disposition=attachment")
        // No partial file is left next to it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["blob.bin"])
    }

    /// A partial file and its ETag: the client asks for the rest only while the file is unchanged (If-Range).
    @Test func resumesWithARange() async throws {
        let server = try await Self.start { Self.serve($0) }
        defer { server.stop() }
        let lanes = try Self.lanes(port: server.port)
        defer { lanes.invalidate() }
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let partial = folder.appending(path: "part")
        try Self.blob.prefix(70_000).write(to: partial)
        let request = URLRequest(url: try lanes.transfers.http.url(path: "/download/content", query: [
            .init(name: "vault_id", value: "3"), .init(name: "path", value: "/blob.bin"),
        ]))
        let resume = try #require(DeviceTransferClient.resumeState(of: partial, etag: Self.etag))
        #expect(resume.offset == 70_000)
        let done = try await lanes.transfers.download(request, to: partial, resume: resume) { _, _ in }
        #expect(done.resumed)
        #expect(done.length == Int64(Self.blob.count))
        #expect(try Data(contentsOf: partial) == Self.blob)
        let sent = try #require(server.requests.last)
        #expect(sent.header("Range") == "bytes=70000-")
        #expect(sent.header("If-Range") == Self.etag)

        // The file changed on the node (another ETag): the node sends it whole and the client starts over.
        try Data(repeating: 0xEE, count: 90_000).write(to: partial)
        let stale = DeviceTransferClient.Resume(offset: 90_000, etag: "\"g42-old\"")
        let restarted = try await lanes.transfers.download(request, to: partial, resume: stale) { _, _ in }
        #expect(!restarted.resumed)
        #expect(try Data(contentsOf: partial) == Self.blob)

        // Everything is already there: 416 with the full length means done.
        let complete = DeviceTransferClient.Resume(offset: Int64(Self.blob.count), etag: Self.etag)
        let nothingLeft = try await lanes.transfers.download(request, to: partial, resume: complete) { _, _ in }
        #expect(nothingLeft.length == Int64(Self.blob.count))
        #expect(try Data(contentsOf: partial) == Self.blob)
    }

    /// The connection drops mid-body: the next attempt asks for the rest of the same file and completes it.
    @Test func resumesAfterTheConnectionDrops() async throws {
        let attempts = Mutex(0)
        let server = try await Self.start { request in
            var response = Self.serve(request)
            if attempts.withLock({ count in defer { count += 1 }; return count == 0 }) {
                response.truncateAfter = 50_000
            }
            return response
        }
        defer { server.stop() }
        let lanes = try Self.lanes(port: server.port)
        defer { lanes.invalidate() }
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let destination = folder.appending(path: "blob.bin")
        try await lanes.download(vaultID: 1, path: "/blob.bin", isDirectory: false, to: destination) { _, _ in }
        #expect(try Data(contentsOf: destination) == Self.blob)
        let ranges = server.requests.map { $0.header("Range") }
        #expect(ranges.first == .some(nil))
        let resumedFrom = try #require(ranges.last.flatMap { $0 })
        #expect(resumedFrom.hasPrefix("bytes=") && resumedFrom != "bytes=0-")
        #expect(server.requests.last?.header("If-Range") == Self.etag)
    }

    @Test func downloadsAFolderAsTheNodesZIP() async throws {
        let zip = Data("PK\u{3}\u{4}fake zip body".utf8)
        let server = try await Self.start { request in
            guard request.target.hasPrefix("/download?") else { return .init(status: 404) }
            return .init(status: 200, headers: ["Content-Type": "application/zip"], body: zip)
        }
        defer { server.stop() }
        let lanes = try Self.lanes(port: server.port)
        defer { lanes.invalidate() }
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let destination = folder.appending(path: "Photos.zip")
        try await lanes.download(vaultID: 2, path: "/Photos", isDirectory: true, to: destination) { _, _ in }
        #expect(try Data(contentsOf: destination) == zip)
        #expect(server.requests.last?.target == "/download?vault_id=2&path=/Photos&disposition=attachment")
    }

    /// The node's refusals in plain words: 403 (which URLSession hides behind a client-certificate error), 404, 413.
    @Test func mapsRefusals() async throws {
        let server = try await Self.start { request in
            if request.target.contains("secret") || String(decoding: request.body, as: UTF8.self).contains("secret") {
                return .init(status: 403, body: Data("Forbidden".utf8))
            }
            if request.target.contains("huge") { return .init(status: 413, body: Data("limit_exceeded".utf8)) }
            return .init(status: 404, body: Data("Not found".utf8))
        }
        defer { server.stop() }
        let lanes = try Self.lanes(port: server.port)
        defer { lanes.invalidate() }
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        await #expect(throws: TransferError.forbidden) {
            try await lanes.download(vaultID: 1, path: "/secret.txt", isDirectory: false,
                                     to: folder.appending(path: "a")) { _, _ in }
        }
        await #expect(throws: TransferError.notFound) {
            try await lanes.download(vaultID: 1, path: "/gone.txt", isDirectory: false,
                                     to: folder.appending(path: "b")) { _, _ in }
        }
        await #expect(throws: TransferError.tooManyEntries) {
            try await lanes.download(vaultID: 1, path: "/huge", isDirectory: true,
                                     to: folder.appending(path: "c.zip")) { _, _ in }
        }
        await #expect(throws: TransferError.forbidden) {
            try await lanes.upload([.init(source: folder, relativePath: "x", size: 1)], vaultID: 1,
                                   into: "/secret") { _ in }
        }
        #expect(TransferError.forbidden.message.contains("Not allowed"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func cancellingADownloadStopsIt() async throws {
        // The answer is held for 30 s: a download that ignored the cancellation would wait it out, far past any
        // scheduling delay, so the bound below can be loose.
        let server = try await Self.start { request in
            var response = Self.serve(request)
            response.delay = .seconds(30)
            return response
        }
        defer { server.stop() }
        let lanes = try Self.lanes(port: server.port)
        defer { lanes.invalidate() }
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        let destination = folder.appending(path: "slow.bin")
        let task = Task {
            try await lanes.download(vaultID: 1, path: "/slow.bin", isDirectory: false, to: destination) { _, _ in }
        }
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: TransferError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: Uploads

    @Test func splitsLargeDropsIntoSessions() {
        func file(_ size: Int64) -> VaultLanes.UploadFile {
            .init(source: URL(filePath: "/tmp/x"), relativePath: "x", size: size)
        }
        let byCount = VaultLanes.sessions((0..<7).map { _ in file(1) }, maxFiles: 3, maxBytes: 100)
        #expect(byCount.map(\.count) == [3, 3, 1])
        let bySize = VaultLanes.sessions([file(60), file(30), file(20), file(500), file(1)], maxFiles: 10, maxBytes: 100)
        #expect(bySize.map { $0.map(\.size) } == [[60, 30], [20], [500], [1]])
        #expect(VaultLanes.sessions([], maxFiles: 3, maxBytes: 100).isEmpty)
    }

    // MARK: Thumbnails

    @Test func asksForThumbnailReadiness() async throws {
        let server = try await Self.start { request in
            guard request.target == "/preview/batch", request.method == "POST" else {
                return .init(status: 200, headers: ["Content-Type": "image/jpeg"], body: Data([0xFF, 0xD8, 0xFF]))
            }
            let body = #"{"size":256,"items":[{"key":"a","status":"ready","url":"/preview?x"},{"key":"b","status":"queued"},{"key":"c","status":"later"}]}"#
            return .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
        defer { server.stop() }
        let lanes = try Self.lanes(port: server.port)
        defer { lanes.invalidate() }

        let statuses = try await lanes.thumbnailStatus(vaultID: 4, items: [
            .init(key: "a", path: "/a.jpg"), .init(key: "b", path: "/b.png"), .init(key: "c", path: "/c.pdf"),
        ], size: 256)
        #expect(statuses == ["a": .ready, "b": .queued, "c": .error])
        let sent = try #require(JSONSerialization.jsonObject(with: server.requests[0].body) as? [String: Any])
        #expect(sent["size"] as? Int == 256)
        #expect(sent["vault_id"] as? Int == 4)
        #expect((sent["items"] as? [[String: Any]])?.map { $0["path"] as? String } == ["/a.jpg", "/b.png", "/c.pdf"])

        let jpeg = try await lanes.thumbnail(vaultID: 4, path: "/a b.jpg", size: 256)
        #expect(jpeg == Data([0xFF, 0xD8, 0xFF]))
        #expect(server.requests.last?.target == "/preview?vault_id=4&path=/a%20b.jpg&size=256")
    }
}
