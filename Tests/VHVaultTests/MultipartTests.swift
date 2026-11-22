import Foundation
import Testing
import VHCore
import VHRecovery
@testable import VHVaultEngine

/// S3Store's multipart uploads against ``MemoryBucket``'s model of S3's multipart API, through ``S3Wire`` (the REST
/// API as a local URLProtocol: keys and payload hashes checked). Sizes are small: a 1 KiB minimum part in the bucket,
/// 1 KiB parts and a 4 KiB threshold in the store.
struct WireFixture {
    let bucket = MemoryBucket()
    let endpoint: S3Wire.Endpoint
    let credentials: RenewingCredentials
    let directory = FileManager.default.temporaryDirectory.appending(path: "vh-multipart-\(UUID().uuidString)")
    var scratch: URL { directory.appending(path: "scratch") }

    init(keys: Set<String> = ["AK1"]) {
        bucket.minimumPartSize = 1024
        endpoint = S3Wire.register(bucket: bucket, keys: keys)
        credentials = RenewingCredentials(keyID: "AK1", bucket: endpoint.name)
    }

    static var small: S3Store.Multipart {
        var m = S3Store.Multipart()
        m.threshold = 4096
        m.partSize = 1024
        m.chunk = 256
        m.concurrency = 3
        m.retryDelay = 0
        m.attempts = 3
        return m
    }

    func store(_ m: S3Store.Multipart = small, now: @escaping @Sendable () -> Date = { Date() }) -> S3Store {
        S3Store(credentials: credentials, scratch: scratch, bounds: S3Store.Bounds(), multipart: m,
                protocolClasses: [S3Wire.self], now: now)
    }

    func send(_ data: Data, key: String = "o/AAAAAAAAAAAAAAAAAAAAAAAAAA", to store: S3Store) throws -> StoredObject {
        let u = try store.beginContent(key, size: UInt64(data.count))
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 700)
            try data[offset ..< end].withUnsafeBytes { try u.write($0) }
            offset = end
        }
        return try u.finish()
    }

    var journal: [MultipartJournal.Record] { MultipartJournal(directory: scratch).records() }
    var leftoverFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path(percentEncoded: false))) ?? []).filter { $0 != "multipart" }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@Suite struct MultipartModelTests {
    let key = "o/K"

    func upload(_ b: MemoryBucket, _ parts: [Data]) throws -> (String, [(number: Int, etag: String)]) {
        let id = b.createMultipartUpload(key)
        let etags = try parts.enumerated().map { (number: $0 + 1, etag: try b.uploadPart(key, uploadID: id, partNumber: $0 + 1, $1)) }
        return (id, etags)
    }

    @Test func partsCompleteIntoOneVersionWithS3sETag() throws {
        let b = MemoryBucket()
        b.minimumPartSize = 4
        let (id, etags) = try upload(b, [Data("abcd".utf8), Data("ef".utf8)])
        #expect(etags[0].etag == "\"e2fc714c4727ee9395f324cd2e7f331f\"")  // MD5("abcd"), quoted
        let o = try b.completeMultipartUpload(key, uploadID: id, parts: etags)
        // MD5(MD5("abcd") || MD5("ef")) and the part count.
        let digests = MemoryBucket.md5(Data("abcd".utf8)) + MemoryBucket.md5(Data("ef".utf8))
        #expect(o.etag == "\"\(MemoryBucket.hex(MemoryBucket.md5(digests)))-2\"")
        #expect(try b.get(key, versionID: o.versionID).bytes == Data("abcdef".utf8))
        #expect(b.multipartUploads().isEmpty)
        #expect(throws: MemoryBucket.MultipartFailure.noSuchUpload) { try b.completeMultipartUpload(key, uploadID: id, parts: etags) }
    }

    @Test func refusalsAreS3s() throws {
        let b = MemoryBucket()  // the real 5 MiB minimum
        let (id, etags) = try upload(b, [Data("abcd".utf8), Data("ef".utf8)])
        #expect(throws: MemoryBucket.MultipartFailure.entityTooSmall) { try b.completeMultipartUpload(key, uploadID: id, parts: etags) }
        b.minimumPartSize = 1
        #expect(throws: MemoryBucket.MultipartFailure.invalidPart) {
            try b.completeMultipartUpload(key, uploadID: id, parts: [etags[0], (2, "\"0000\"")])
        }
        #expect(throws: MemoryBucket.MultipartFailure.invalidPart) {
            try b.completeMultipartUpload(key, uploadID: id, parts: [etags[0], (3, etags[1].etag)])
        }
        #expect(throws: MemoryBucket.MultipartFailure.invalidPartOrder) {
            try b.completeMultipartUpload(key, uploadID: id, parts: [etags[1], etags[0]])
        }
        #expect(throws: MemoryBucket.MultipartFailure.malformedXML) { try b.completeMultipartUpload(key, uploadID: id, parts: []) }
        #expect(throws: MemoryBucket.MultipartFailure.invalidArgument) { try b.uploadPart(key, uploadID: id, partNumber: 0, Data()) }
        #expect(throws: MemoryBucket.MultipartFailure.invalidArgument) { try b.uploadPart(key, uploadID: id, partNumber: 10_001, Data()) }
        #expect(throws: MemoryBucket.MultipartFailure.noSuchUpload) { try b.uploadPart("o/other", uploadID: id, partNumber: 1, Data()) }
        #expect(b.multipartUploads(prefix: "o/").map(\.uploadID) == [id])
        try b.abortMultipartUpload(key, uploadID: id)
        #expect(b.multipartUploads().isEmpty && b.currentKeys.isEmpty)
        #expect(throws: MemoryBucket.MultipartFailure.noSuchUpload) { try b.abortMultipartUpload(key, uploadID: id) }
    }

    @Test func aCompletedUploadTakesItsPlaceByItsStart() throws {
        // Backblaze orders a large file's version by when the upload started.
        let b = MemoryBucket()
        b.minimumPartSize = 1
        let id = b.createMultipartUpload(key)
        let e = try b.uploadPart(key, uploadID: id, partNumber: 1, Data("late".utf8))
        let later = try Data("later".utf8).withUnsafeBytes { try b.put(key, $0, condition: .none) }
        _ = try b.completeMultipartUpload(key, uploadID: id, parts: [(1, e)])
        #expect(try b.get(key, versionID: nil).object.versionID == later.versionID)
        #expect(try b.versions(key, stopAt: nil, underPrefix: false).count == 2)
    }
}

@Suite struct MultipartStoreTests {
    @Test func atTheThresholdOnePutAsBeforeAboveItParts() throws {
        let f = WireFixture()
        defer { f.cleanUp() }
        let s = f.store()
        let exact = content(4096, seed: 3)
        let one = try f.send(exact, key: "o/ONE", to: s)
        let put = try #require(f.endpoint.log.last)
        #expect(f.endpoint.log.count == 1)
        #expect(put.method == "PUT" && put.key == "o/ONE" && put.query.isEmpty && put.body == exact)
        // The headers the store sets (URLSession adds its own: Accept, User-Agent...).
        let own = Set(put.headers.keys.filter { $0.hasPrefix("x-amz") || $0.hasPrefix("if-") || $0.hasPrefix("content-md5") || $0 == "authorization" })
        #expect(own == ["authorization", "x-amz-content-sha256", "x-amz-date"])
        #expect(put.headers["authorization"]!.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date,"))
        #expect(try f.bucket.get("o/ONE", versionID: one.versionID).bytes == exact)

        let above = content(4097, seed: 5)
        let o = try f.send(above, key: "o/TWO", to: s)
        let log = f.endpoint.log.dropFirst()
        #expect(log.map(\.method) == ["POST"] + Array(repeating: "PUT", count: 5) + ["POST", "HEAD"])
        #expect(Set(log.compactMap(\.partNumber)) == [1, 2, 3, 4, 5])
        #expect(log.allSatisfy { $0.headers["if-match"] == nil && $0.headers["if-none-match"] == nil })  // never conditional
        #expect(o.etag?.hasSuffix("-5\"") == true && o.versionID != nil)
        #expect(try f.bucket.get("o/TWO", versionID: o.versionID).bytes == above)
        #expect(f.journal.isEmpty && f.leftoverFiles.isEmpty && f.bucket.multipartUploads().isEmpty)
    }

    @Test func partsAreReadThroughABoundedBufferAndAFewAtATime() throws {
        let f = WireFixture()
        defer { f.cleanUp() }
        f.endpoint.partDelay = 0.02
        let s = f.store()
        let data = content(40_000, seed: 11)
        let o = try f.send(data, to: s)
        #expect(s.stats.largestBuffer <= 256 && s.stats.largestBuffer > 0)
        #expect(s.stats.partsSent == 40)
        #expect(f.endpoint.peakParts <= 3 && f.endpoint.peakParts >= 2)
        #expect(try f.bucket.get("o/AAAAAAAAAAAAAAAAAAAAAAAAAA", versionID: o.versionID).bytes == data)
    }

    @Test func theLibrarysPartSizeByDefault() {
        let s = WireFixture().store(S3Store.Multipart())
        #expect(s.partSize(for: 6 << 30) == 5 << 20)
        #expect(s.partSize(for: 100 << 30) == 11 << 20)  // ceil(100 GiB / 10,000) in whole MiB
        #expect(S3Store.Multipart().threshold == 64 << 20)
    }

    @Test func aFailedPartIsSentAgain() throws {
        let f = WireFixture()
        defer { f.cleanUp() }
        let failed = Flag()
        f.endpoint.hook = { l in l.partNumber == 2 && failed.setOnce() ? .status(500, code: "InternalError") : nil }
        let data = content(5000)
        let o = try f.send(data, to: f.store())
        #expect(f.endpoint.log.filter { $0.partNumber == 2 }.count == 2)
        #expect(try f.bucket.get("o/AAAAAAAAAAAAAAAAAAAAAAAAAA", versionID: o.versionID).bytes == data)
    }

    @Test func aPartThatKeepsFailingAbortsTheUpload() throws {
        let f = WireFixture()
        defer { f.cleanUp() }
        f.endpoint.hook = { l in l.partNumber == 3 ? .dropBefore : nil }
        #expect { try f.send(content(5000), to: f.store()) } throws: { e in
            guard case .failed? = e as? StoreError else { return false }
            return true
        }
        #expect(f.endpoint.log.filter { $0.partNumber == 3 }.count == 3)  // its attempts, then no more
        #expect(f.endpoint.log.contains { $0.method == "DELETE" && $0.query["uploadId"] != nil })
        #expect(f.bucket.multipartUploads().isEmpty && f.bucket.currentKeys.isEmpty)
        #expect(f.journal.isEmpty && f.leftoverFiles.isEmpty)
    }

    @Test func aPartETagTheProviderWontMatchIsRefusedAtCompletion() throws {
        let f = WireFixture()
        defer { f.cleanUp() }
        f.endpoint.hook = { l in l.partNumber == 1 ? .etag("\"0123456789abcdef0123456789abcdef\"") : nil }
        #expect { try f.send(content(5000), to: f.store()) } throws: { e in
            guard case .failed(let why)? = e as? StoreError else { return false }
            return why.contains("InvalidPart")
        }
        #expect(f.bucket.multipartUploads().isEmpty && f.bucket.currentKeys.isEmpty && f.journal.isEmpty)
    }

    @Test func aLostCompletionIsUnknownWhetherItLandedOrNot() throws {
        for fault in [S3Wire.Fault.dropAfter, .dropBefore, .status(503, code: "SlowDown")] {
            let f = WireFixture()
            defer { f.cleanUp() }
            f.endpoint.hook = { l in l.isComplete ? fault : nil }
            #expect { try f.send(content(5000), to: f.store()) } throws: { e in
                guard case .outcomeUnknown? = e as? StoreError else { return false }
                return true
            }
            #expect(f.endpoint.log.filter { $0.isComplete }.count == 1)  // never sent again
            // Aborted: if it had landed, the abort finds no upload and changes nothing.
            #expect(f.bucket.multipartUploads().isEmpty && f.journal.isEmpty)
            if case .dropAfter = fault { #expect(f.bucket.currentKeys == ["o/AAAAAAAAAAAAAAAAAAAAAAAAAA"]) }
            else { #expect(f.bucket.currentKeys.isEmpty) }
        }
    }

    @Test func aKeyRenewedMidUploadKeepsThePartsSent() throws {
        let f = WireFixture(keys: ["AK1", "AK2"])
        defer { f.cleanUp() }
        var m = WireFixture.small
        m.concurrency = 1
        // Part 3 finds the first key expired; the refusal brings the renewed one, as DeviceAccess does.
        f.endpoint.hook = { [endpoint = f.endpoint] l in
            if l.partNumber == 3, l.keyID == "AK1" {
                endpoint.keys = ["AK2"]
                return .status(403, code: "ExpiredToken")
            }
            return nil
        }
        f.credentials.onRefusal = { $0.renew(to: "AK2") }
        let data = content(5000)
        let o = try f.send(data, to: f.store(m))
        #expect(f.credentials.refusalCount == 1)
        let parts = f.endpoint.log.filter { $0.partNumber != nil }
        #expect(parts.filter { $0.partNumber! <= 2 }.map(\.keyID) == ["AK1", "AK1"])  // kept, not sent again
        #expect(parts.filter { $0.partNumber == 3 }.map(\.keyID) == ["AK1", "AK2"])
        #expect(f.endpoint.log.first { $0.isComplete }?.keyID == "AK2")
        #expect(try f.bucket.get("o/AAAAAAAAAAAAAAAAAAAAAAAAAA", versionID: o.versionID).bytes == data)
    }

    @Test func aKeyRefusedMidUploadIsReportedAndTheUploadLeftForCleanup() throws {
        let f = WireFixture()
        defer { f.cleanUp() }
        var m = WireFixture.small
        m.concurrency = 1
        f.endpoint.hook = { [endpoint = f.endpoint] l in
            if l.partNumber == 3 { endpoint.keys = [] }  // revoked, and no other key comes
            return nil
        }
        #expect { try f.send(content(5000), to: f.store(m)) } throws: { e in
            guard case .failed(let why)? = e as? StoreError else { return false }
            return why.contains("403")
        }
        #expect(f.credentials.refusalCount >= 1)
        #expect(f.endpoint.log.filter { $0.partNumber == 3 }.count == 1)  // the refused key isn't sent again
        // The abort was refused too: the upload stays open and recorded, for the next open.
        #expect(f.bucket.multipartUploads().count == 1 && f.journal.count == 1 && f.bucket.currentKeys.isEmpty)
    }

    @Test func overTheLimitsNothingIsSent() throws {
        let f = WireFixture()
        defer { f.cleanUp() }
        #expect(throws: StoreError.self) { try f.store().beginContent("o/X", size: S3Store.maxObject + 1) }
        var m = WireFixture.small
        m.partSize = 1  // 10,001 parts of one byte: more than S3 takes
        #expect(throws: StoreError.self) { try f.send(content(10_001), to: f.store(m)) }
        #expect(f.endpoint.log.isEmpty)
    }
}

@Suite struct MultipartCleanupTests {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let day: TimeInterval = 24 * 3600

    @Test func staleUploadsOfThisInstallationAreAbortedAtOpenAndNothingElse() async throws {
        let f = WireFixture()
        defer { f.cleanUp() }
        let journal = MultipartJournal(directory: f.scratch)
        let old = Int64(now.timeIntervalSince1970 - 2 * day)
        func open(_ key: String, initiated: Int64, recorded started: Double?) throws -> String {
            let id = f.bucket.createMultipartUpload(key, initiated: initiated)
            _ = try f.bucket.uploadPart(key, uploadID: id, partNumber: 1, content(2000))
            if let started { #expect(journal.add(.init(key: key, uploadID: id, started: started))) }
            return id
        }
        let ours = try open("o/OURS", initiated: old, recorded: Double(old))
        let fresh = try open("o/FRESH", initiated: Int64(now.timeIntervalSince1970) - 3600, recorded: now.timeIntervalSince1970 - 3600)
        let foreign = try open("o/FOREIGN", initiated: old, recorded: nil)
        // A record whose upload completed (the record outlived it): the object is never touched.
        let done = try open("o/DONE", initiated: old, recorded: Double(old))
        let etag = try f.bucket.uploadPart("o/DONE", uploadID: done, partNumber: 1, Data("done".utf8))
        let completed = try f.bucket.completeMultipartUpload("o/DONE", uploadID: done, parts: [(1, etag)])

        // A vault opened over the store: the cleanup runs once its state is this process's.
        let fx = Fixture()
        defer { fx.cleanUp() }
        let at = now
        let store = f.store(now: { at })
        let (vault, _) = try await Vault.open(uid: fx.uid, store: store, keys: fx.keys, stateURL: fx.stateURL, nodeID: "mac-a",
                                              createName: "Cleanup")
        _ = vault
        #expect(Set(f.bucket.multipartUploads().map(\.uploadID)) == [fresh, foreign])
        #expect(!f.bucket.multipartUploads().contains { $0.uploadID == ours })
        #expect(f.journal.map(\.uploadID) == [fresh])
        #expect(try f.bucket.get("o/DONE", versionID: completed.versionID).bytes == Data("done".utf8))
        #expect(f.endpoint.log.filter { $0.method == "DELETE" }.map(\.query) == [["uploadId": ours]])
    }

    @Test func anUploadTheProviderStartedRecentlyIsLeftEvenIfTheRecordIsOld() throws {
        // This Mac's clock may be ahead: both times must be old.
        let f = WireFixture()
        defer { f.cleanUp() }
        let id = f.bucket.createMultipartUpload("o/K", initiated: Int64(now.timeIntervalSince1970) - 60)
        #expect(MultipartJournal(directory: f.scratch).add(.init(key: "o/K", uploadID: id, started: now.timeIntervalSince1970 - 3 * day)))
        let at = now
        f.store(now: { at }).cleanUpAbandonedUploads()
        #expect(f.bucket.multipartUploads().map(\.uploadID) == [id] && f.journal.count == 1)
    }

    @Test func aRefusedUploadIsCleanedUpOnceAKeyWorksAgain() throws {
        let f = WireFixture()
        defer { f.cleanUp() }
        var m = WireFixture.small
        m.concurrency = 1
        f.endpoint.hook = { [endpoint = f.endpoint] l in
            if l.partNumber == 3 { endpoint.keys = [] }
            return nil
        }
        _ = try? f.send(content(5000), to: f.store(m))
        #expect(f.bucket.multipartUploads().count == 1 && f.journal.count == 1)
        f.endpoint.hook = nil
        f.endpoint.keys = ["AK1"]
        f.store().cleanUpAbandonedUploads()  // not old enough yet
        #expect(f.bucket.multipartUploads().count == 1)
        let later = Date().addingTimeInterval(2 * day)
        f.store(now: { later }).cleanUpAbandonedUploads()
        #expect(f.bucket.multipartUploads().isEmpty && f.journal.isEmpty)
    }
}

@Suite struct MultipartEngineTests {
    @Test func aLargeFileThroughTheEngineAndALostCompletionSettled() async throws {
        let f = WireFixture()
        defer { f.cleanUp() }
        let fx = Fixture()
        defer { fx.cleanUp() }
        let store = f.store()
        var vault: Vault? = try await Vault.open(uid: fx.uid, store: store, keys: fx.keys, stateURL: fx.stateURL, nodeID: "mac-a",
                                           createName: "Big").vault
        let report = content(20_000, seed: 9)
        let envelope = try fx.envelope()
        let (root, file) = try await vault!.perform { v throws(VaultError) in
            try v.addKey(version: 1, key: fx.key, envelopes: [envelope])
            let root = try v.rootUID()
            return (root, try v.write(report, parent: root, name: "report.bin").entry)
        }
        let entry = try await vault!.perform { v throws(VaultError) in try v.stat(file.uid)! }
        #expect(entry.versionID != nil)
        #expect(f.endpoint.log.contains { $0.isComplete })

        // The completion's answer is lost (it landed): the engine is told the outcome is unknown and records nothing.
        f.endpoint.hook = { l in l.isComplete ? .dropAfter : nil }
        let second = content(9000, seed: 4)
        let lost: VaultError? = await {
            do { _ = try await vault!.perform { v throws(VaultError) in try v.write(second, parent: root, name: "second.bin") } }
            catch { return error as? VaultError }
            return nil
        }()
        #expect(lost?.status == VaultStatus.storeOutcomeUnknown)
        try await vault!.perform { v throws(VaultError) in #expect(try v.list(root).map(\.name) == ["report.bin"]) }
        // Settled as after a lost single PUT reply: written again, as a new object; the lost one names nothing.
        f.endpoint.hook = nil
        let written = try await vault!.perform { v throws(VaultError) in try v.write(second, parent: root, name: "second.bin").entry }
        try await vault!.perform { v throws(VaultError) in
            #expect(Set(try v.list(root).map(\.name)) == ["report.bin", "second.bin"])
            #expect(try v.readData(written.uid) == second)
            #expect(try v.readData(file.uid) == report)
            #expect(try v.publish().published)
        }
        #expect(f.bucket.multipartUploads().isEmpty && f.journal.isEmpty)

        // Re-anchored from the bucket: both read back through the engine.
        vault = nil
        try FileManager.default.removeItem(at: fx.stateURL)
        let reopened = try await Vault.open(uid: fx.uid, store: f.store(), keys: fx.keys, stateURL: fx.stateURL, nodeID: "mac-a").vault
        try await reopened.perform { v throws(VaultError) in
            #expect(try v.readData(file.uid) == report)
            #expect(try v.readData(written.uid) == second)
        }
    }
}

/// True the first time only.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    func setOnce() -> Bool { lock.withLock { defer { set = true }; return !set } }
}

/// Holds every thread GCD will run constrained (non-overcommit) work on, the pool that global queues, concurrent queues
/// and their timers share. It is capped per process (`kern.wq_max_constrained_threads`: five per CPU, so 15 on a
/// 3-core hosted CI Mac and 100 on a 20-core one). The store's callers block in it (the engine's queue, a test's thread): a wait
/// of the store's that needs another thread from that pool to finish can starve once the pool is spent, so none may.
final class ConstrainedPoolHog: @unchecked Sendable {
    private let condition = NSCondition()
    private var count = 0
    private var released = false

    static var limit: Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.wq_max_constrained_threads", &value, &size, nil, 0) == 0 ? Int(value) : 512
    }

    var parked: Int { condition.withLock { count } }

    /// Takes the pool's threads until GCD gives no more (the cap, or what other tests left of it): it has given its
    /// last once a second passes without another. At `userInitiated`, so a busy few-core Mac still admits them
    /// promptly (the cap counts every QoS alike); the first may take a while all the same.
    func park() {
        let limit = Self.limit
        for _ in 0 ..< limit {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                condition.lock()
                defer { condition.unlock() }
                guard !released else { return }
                count += 1
                condition.broadcast()
                while !released { condition.wait() }
            }
        }
        condition.lock()
        defer { condition.unlock() }
        let first = Date().addingTimeInterval(15)
        while count == 0, condition.wait(until: first) {}
        while count > 0, count < limit, condition.wait(until: Date().addingTimeInterval(1)) {}
    }

    func release() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}

@Suite struct MultipartThreadTests {
    /// An upload completes with no thread to spare in GCD's constrained pool: a 3-core CI Mac has 15, and parallel
    /// tests (or the app's engine) can hold them all blocked in the store. Before the store ran its own waits off that
    /// pool, the parts' workers held all 15 waiting for `blocking`'s tasks, which needed a 16th: the suite hung.
    @Test func anUploadNeedsNoThreadFromTheConstrainedPool() throws {
        let f = WireFixture()
        defer { f.cleanUp() }
        f.endpoint.partDelay = 0.005
        let s = f.store()
        let data = content(9000, seed: 21)
        final class Outcome: @unchecked Sendable { var value: Result<StoredObject, any Error>? }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let hog = ConstrainedPoolHog()
        hog.park()
        let parked = hog.parked
        let sender = Thread {
            outcome.value = Result { try f.send(data, to: s) }
            done.signal()
        }
        sender.start()
        let finished = done.wait(timeout: .now() + 20) == .success
        hog.release()
        if !finished { done.wait() }
        #expect(parked > 0)
        #expect(finished, "the upload waited on a thread of the pool it was starved of (\(parked) of \(ConstrainedPoolHog.limit) parked)")
        let o = try #require(outcome.value).get()
        #expect(try f.bucket.get("o/AAAAAAAAAAAAAAAAAAAAAAAAAA", versionID: o.versionID).bytes == data)
    }
}
