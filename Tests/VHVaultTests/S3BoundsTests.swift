import Foundation
import Testing
@testable import VHVaultEngine

/// A local URLProtocol in place of the provider: answers at once, after a delay, or never.
final class StubProvider: URLProtocol, @unchecked Sendable {
    enum Behaviour { case answer(delay: TimeInterval), never }
    nonisolated(unsafe) static var behaviour: Behaviour = .answer(delay: 0)
    nonisolated(unsafe) static var cancelled = 0
    nonisolated(unsafe) static var started = 0
    private var cancelledHere = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.started += 1
        guard case .answer(let delay) = Self.behaviour else { return }  // never: the request just hangs
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard !cancelledHere else { return }
            let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                    headerFields: ["ETag": "\"e1\"", "x-amz-version-id": "v1"])!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        cancelledHere = true
        Self.cancelled += 1
    }
}

/// S3Store's bounds (vl-vaultfmt 0.4.0's store duty, vaulthalla-server's values): the root PUT's total deadline, the
/// connect bound, no total bound on content uploads, and a write cut short reported as "outcome unknown", never
/// "failed".
@Suite(.serialized) struct S3BoundsTests {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "vh-bounds-\(UUID().uuidString)")

    func store(_ bounds: S3Store.Bounds) -> S3Store {
        S3Store(credentials: StaticS3Credentials(accessKeyID: "AKIAEXAMPLE", secret: Data("s".utf8), bucket: "b",
                                                 endpoint: "https://s3.test", region: "r"),
                scratch: scratch, bounds: bounds, protocolClasses: [StubProvider.self])
    }

    func bounds(connect: TimeInterval = 30, root: TimeInterval = 60, noProgress: TimeInterval = 60) -> S3Store.Bounds {
        var b = S3Store.Bounds()
        b.connect = connect
        b.rootTotal = root
        b.noProgress = noProgress
        return b
    }

    @Test func theDefaultsAreTheServers() {
        let b = S3Store.Bounds()
        #expect(b.rootTotal == 60 && b.connect == 30 && b.noProgress == 60 && b.smallTotal == nil)
        #expect(store(b).session.configuration.timeoutIntervalForRequest == 60)  // below 1 byte/s for 60 s fails
    }

    @Test func aRootPutPastItsDeadlineIsCutAndUnknown() throws {
        StubProvider.behaviour = .never
        StubProvider.cancelled = 0
        let s = store(bounds(connect: 30, root: 0.4))
        let start = Date()
        let body = Data("root".utf8)
        #expect {
            try body.withUnsafeBytes { try s.put(".vaulthalla/root", $0, condition: .none) }
        } throws: { e in
            guard case .outcomeUnknown(let why)? = e as? StoreError else { return false }
            return why.contains("total")
        }
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(StubProvider.cancelled == 1)  // the task was cancelled: its connection closes
    }

    @Test func aWriteThatNeverConnectsIsUnknownNotFailed() throws {
        StubProvider.behaviour = .never
        let s = store(bounds(connect: 0.3, root: 60))
        #expect {
            try Data("segment".utf8).withUnsafeBytes { try s.put(".vaulthalla/seg/x", $0, condition: .none) }
        } throws: { e in
            guard case .outcomeUnknown(let why)? = e as? StoreError else { return false }
            return why.contains("connect")
        }
    }

    @Test func aContentUploadHasNoTotalDeadline() throws {
        StubProvider.behaviour = .answer(delay: 1.0)  // longer than the root's deadline below
        let s = store(bounds(connect: 5, root: 0.3))
        let upload = try s.beginContent("o/abc", size: 4)
        try Data("abcd".utf8).withUnsafeBytes { try upload.write($0) }
        #expect(try upload.finish().versionID == "v1")
    }

    @Test func aRootPutAnsweredInTimeSucceeds() throws {
        StubProvider.behaviour = .answer(delay: 0)
        let s = store(bounds(root: 2))
        let o = try Data("root".utf8).withUnsafeBytes { try s.put(".vaulthalla/root", $0, condition: .none) }
        #expect(o.versionID == "v1" && o.etag == "\"e1\"")
    }
}
