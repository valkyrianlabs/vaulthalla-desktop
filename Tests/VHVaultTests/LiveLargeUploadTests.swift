import Foundation
import Testing
import VHCore
import VHRecovery
@testable import VHVaultEngine

/// One large file through the engine and the store's multipart path against a real provider, with the app's own
/// settings (the 64 MiB threshold, the library's part size, four parts in flight). Opt-in, never in CI, and only on
/// the maintainer's explicit go for that run: it uploads VH_LIVE_S3_LARGE_GIB gibibytes.
///
///   VH_LIVE_S3_LARGE_GIB (a whole number), VH_LIVE_S3_ENDPOINT, VH_LIVE_S3_BUCKET (empty, versioned, removed by the
///   caller afterwards), VH_LIVE_S3_REGION, VH_LIVE_S3_ACCESS_KEY, VH_LIVE_S3_SECRET_KEY
///
/// It reports what a model can't: how long the provider takes to complete the upload (past the store's 60 s
/// no-progress bound that is an unknown outcome and the file is sent again), its multipart ETag, and whether the
/// completion's answer names the version. It reads back only the file's ends and a piece of its middle.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VH_LIVE_S3_LARGE_GIB"] != nil), .serialized)
struct LiveLargeUploadTests {
    let env = ProcessInfo.processInfo.environment
    let directory = FileManager.default.temporaryDirectory.appending(path: "vhvault-large-\(UUID().uuidString)")

    @Test func aLargeFileGoesUpInPartsAndReadsBack() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let gib = try #require(UInt64(env["VH_LIVE_S3_LARGE_GIB"] ?? ""))
        let size = gib << 30
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Random bytes, written 8 MiB at a time; the pieces compared later are read back from this file.
        let source = directory.appending(path: "large.bin")
        #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
        let out = try FileHandle(forWritingTo: source)
        var block = Data(count: 8 << 20)
        var written: UInt64 = 0
        while written < size {
            block.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            try out.write(contentsOf: block)
            written += UInt64(block.count)
        }
        try out.close()

        let credentials = StaticS3Credentials(accessKeyID: env["VH_LIVE_S3_ACCESS_KEY"]!, secret: Data(env["VH_LIVE_S3_SECRET_KEY"]!.utf8),
                                              bucket: env["VH_LIVE_S3_BUCKET"]!, endpoint: env["VH_LIVE_S3_ENDPOINT"]!,
                                              region: env["VH_LIVE_S3_REGION"] ?? "us-east-1")
        let bucket = S3Store(credentials: credentials, scratch: directory.appending(path: "scratch"))
        let uid = Uid.random()
        let key = newVaultKey()
        let keys = MemoryVaultKeys([1: key], current: 1)
        let envelope = try KEV1.wrap(vaultKey: key, suite: .x25519, keyVersion: 1, vaultUid: uid,
                                     recipientPublicKey: RecoverySeed.generate().x25519PublicKey())
        let state = directory.appending(path: "state")
        var vault: Vault? = try await Vault.open(uid: uid, store: bucket, keys: keys, stateURL: state, nodeID: "live-mac-large",
                                                 createName: "Live large").vault
        let began = Date()
        let entry = try await vault!.perform { v throws(VaultError) in
            try v.addKey(version: 1, key: key, envelopes: [envelope])
            let entry = try v.write(contentsOf: source, parent: try v.rootUID(), name: "large.bin").entry
            #expect(try v.publish().published)
            return entry
        }
        let took = Date().timeIntervalSince(began)

        let part = bucket.partSize(for: size)
        let timing = try #require(bucket.stats.lastUpload)
        let head = try bucket.head("o/" + entry.uid)
        print("LARGE: \(gib) GiB plaintext, part size \(part >> 20) MiB, \(bucket.stats.partsSent) parts sent")
        print("LARGE: write and publish \(Int(took)) s; parts \(Int(timing.parts)) s (\(String(format: "%.1f", Double(size) / 1_048_576 / max(timing.parts, 1))) MiB/s)")
        print("LARGE: completion answered after \(String(format: "%.2f", timing.completion)) s; check \(String(format: "%.2f", timing.check)) s")
        print("LARGE: completion named the version: \(timing.completionNamedVersion); ETag \(head.etag ?? "none")")
        #expect(timing.completion < 60)
        #expect(head.versionID == entry.versionID)
        #expect(head.etag?.contains("-") == true)
        #expect(try bucket.listUploads(prefix: "o/").isEmpty)

        // The ends and a piece of the middle, through the engine, from the version the manifest names; then again from
        // a fresh state (a reader with only the bucket and the vault's keys).
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        func piece(_ offset: UInt64, _ length: Int) throws -> Data {
            try reader.seek(toOffset: offset)
            return try #require(try reader.read(upToCount: length))
        }
        let pieces: [(UInt64, Int)] = [(0, 2 << 20), (size / 2 - 12345, 1 << 20), (size - (2 << 20), 2 << 20)]
        for (offset, length) in pieces {
            let want = try piece(offset, length)
            let got = try await vault!.perform { v throws(VaultError) in
                try v.readData(entry.uid, offset: offset, length: UInt64(length))
            }
            #expect(got == want)
        }
        vault = nil
        try FileManager.default.removeItem(at: state)
        let reanchored = try await Vault.open(uid: uid, store: bucket, keys: keys, stateURL: state, nodeID: "live-mac-large").vault
        let (offset, length) = pieces[2]
        let want = try piece(offset, length)
        let got = try await reanchored.perform { v throws(VaultError) in
            try v.readData(entry.uid, offset: offset, length: UInt64(length))
        }
        #expect(got == want)
        print("LARGE: read back the start, the middle and the end; a fresh reader read the end")
    }
}
