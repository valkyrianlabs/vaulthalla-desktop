import Foundation
import Testing
import VHCore
import VHRecovery
@testable import VHVaultEngine

/// A whole Desktop-only vault lifecycle through VHVault against a real S3-compatible endpoint that checks every
/// credential and signature (moto server in a throwaway container: `tools/vaultfmt/live-s3.sh`, which creates a
/// versioned bucket and a key scoped to it, and passes them in the environment). Opt-in: runs only with VH_LIVE_S3.
///
///   VH_LIVE_S3_ENDPOINT, VH_LIVE_S3_BUCKET, VH_LIVE_S3_MULTIPART_BUCKET (a second vault's, the same key),
///   VH_LIVE_S3_REGION, VH_LIVE_S3_ACCESS_KEY, VH_LIVE_S3_SECRET_KEY
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VH_LIVE_S3"] != nil), .serialized)
struct LiveS3Tests {
    let env = ProcessInfo.processInfo.environment

    func credentials(secret: String? = nil, bucket: String? = nil) -> StaticS3Credentials {
        StaticS3Credentials(accessKeyID: env["VH_LIVE_S3_ACCESS_KEY"]!, secret: Data((secret ?? env["VH_LIVE_S3_SECRET_KEY"]!).utf8),
                            bucket: bucket ?? env["VH_LIVE_S3_BUCKET"]!, endpoint: env["VH_LIVE_S3_ENDPOINT"]!,
                            region: env["VH_LIVE_S3_REGION"] ?? "us-east-1")
    }

    let directory = FileManager.default.temporaryDirectory.appending(path: "vhvault-live-\(UUID().uuidString)")

    func store(_ c: StaticS3Credentials) -> S3Store { S3Store(credentials: c, scratch: directory.appending(path: "scratch")) }

    @Test func aWrongSecretIsRefusedAndReported() throws {
        let bad = credentials(secret: "not-the-secret-0000000000000000000000000")
        let s = store(bad)
        #expect { try s.head(".vaulthalla/root") } throws: { e in
            guard case .failed(let why)? = e as? StoreError else { return false }
            return why.contains("403")
        }
        #expect(bad.refusalCount == 1)
    }

    @Test func aWholeVaultLifecycle() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let c = credentials()
        let bucket = store(c)
        let uid = Uid.random()
        let key = newVaultKey()
        let keys = MemoryVaultKeys([1: key], current: 1)
        let envelope = try KEV1.wrap(vaultKey: key, suite: .x25519, keyVersion: 1, vaultUid: uid,
                                     recipientPublicKey: RecoverySeed.generate().x25519PublicKey())
        let stateA = directory.appending(path: "a/state")

        // Create, add the key (its envelope PUT first), a folder and two files (one streamed in several pieces).
        var vault: Vault?
        var info: OpenInfo
        do {  // scoped, so nothing else keeps the handle (and its state lock) once `vault` lets go
            let first = try await Vault.open(uid: uid, store: bucket, keys: keys, stateURL: stateA, nodeID: "live-mac-a",
                                             createName: "Live")
            (vault, info) = (first.vault, first.info)
        }
        #expect(info.anchor == .created)
        let report = content(300_000, seed: 7)
        let small = Data("hello from the live test\n".utf8)
        let (root, docs, file, note) = try await vault!.perform { v throws(VaultError) in
            try v.addKey(version: 1, key: key, envelopes: [envelope])
            let root = try v.rootUID()
            let docs = try v.mkdir(parent: root, name: "Docs")
            let file = try v.write(report, parent: docs.uid, name: "report.bin").entry
            let note = try v.write(small, parent: root, name: "note.txt").entry
            return (root, docs.uid, file, note)
        }
        #expect(file.versionID != nil)

        // List, read back whole and by range, rename, trash, publish.
        try await vault!.perform { v throws(VaultError) in
            #expect(Set(try v.list(root).map(\.name)) == ["Docs", "note.txt"])
            #expect(try v.list(docs).map(\.name) == ["report.bin"])
            #expect(try v.readData(file.uid) == report)
            #expect(try v.readData(file.uid, offset: 65_530, length: 100) == report[65_530 ..< 65_630])
            try v.rename(file.uid, to: "final.bin")
            try v.trashEntry(note.uid)
            let p = try v.publish()
            #expect(p.published && p.epoch == 1)
            #expect(!(try v.refresh().moved))
        }

        // A second version of the file: the provider's versions are listed, the old one readable by its id.
        let rewritten = Data("version two".utf8)
        let (old, entry) = try await vault!.perform { v throws(VaultError) in
            let before = try v.stat(file.uid)!
            let after = try v.write(rewritten, uid: file.uid, expectedGeneration: before.generation).entry
            #expect(try v.publish().epoch == 2)
            return (before.versionID!, after)
        }
        #expect(entry.versions.count == 2 && entry.versions.contains { $0.versionID == old })
        #expect(try await vault!.perform { v throws(VaultError) in try v.readData(file.uid, versionID: old) } == report)

        // Reopen from the state file: no re-anchor.
        vault = nil
        do {
            let reopened = try await Vault.open(uid: uid, store: bucket, keys: keys, stateURL: stateA, nodeID: "live-mac-a")
            (vault, info) = (reopened.vault, reopened.info)
        }
        #expect(info.anchor == .state && info.epoch == 2)
        #expect(try await vault!.perform { v throws(VaultError) in try v.readData(file.uid) } == rewritten)

        // Reopen with the state file deleted: re-anchored from the bucket, everything published is there.
        vault = nil
        try FileManager.default.removeItem(at: stateA)
        do {
            let reanchored = try await Vault.open(uid: uid, store: bucket, keys: keys, stateURL: stateA, nodeID: "live-mac-a")
            (vault, info) = (reanchored.vault, reanchored.info)
        }
        #expect(info.anchor == .reanchored && !info.freshnessVerified && info.epoch == 2)
        try await vault!.perform { v throws(VaultError) in
            #expect(try v.list(docs).map(\.name) == ["final.bin"])
            #expect(try v.readData(file.uid) == rewritten)
            #expect(try v.trash().map(\.uid) == [note.uid])
        }

        // A second VHVault instance (its own state, another installation) reads what the first wrote.
        let (other, otherInfo) = try await Vault.open(uid: uid, store: store(credentials()), keys: keys,
                                                      stateURL: directory.appending(path: "b/state"), nodeID: "live-mac-b")
        #expect(otherInfo.anchor == .reanchored && otherInfo.epoch == 2)
        try await other.perform { v throws(VaultError) in
            #expect(try v.readData(file.uid) == rewritten)
            #expect(try v.readData(file.uid, versionID: old) == report)
        }

        // Purge the trashed note: its objects are deleted by version id once a root without it settled.
        try await vault!.perform { v throws(VaultError) in
            try v.purge(note.uid)
            #expect(try v.publish().purged == 1)
        }
        let left = try bucket.versions("o/", stopAt: nil, underPrefix: true).filter { $0.key.hasSuffix(note.uid) }
        #expect(left.isEmpty)
    }

    /// One multipart upload against moto, which enforces S3's 5 MiB minimum part: the threshold lowered to 8 MiB, the
    /// library's part size (5 MiB), a file of 26 MiB in six parts, read back through the engine from the version the
    /// completion named and again after a re-anchor, and no upload left open.
    @Test func aMultipartUploadThroughTheEngine() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var multipart = S3Store.Multipart()
        multipart.threshold = 8 << 20
        let bucket = S3Store(credentials: credentials(bucket: env["VH_LIVE_S3_MULTIPART_BUCKET"]!),
                             scratch: directory.appending(path: "scratch-mp"), multipart: multipart)
        let uid = Uid.random()
        let key = newVaultKey()
        let keys = MemoryVaultKeys([1: key], current: 1)
        let envelope = try KEV1.wrap(vaultKey: key, suite: .x25519, keyVersion: 1, vaultUid: uid,
                                     recipientPublicKey: RecoverySeed.generate().x25519PublicKey())
        let state = directory.appending(path: "mp/state")
        let big = content(26 << 20, seed: 29)
        var vault: Vault? = try await Vault.open(uid: uid, store: bucket, keys: keys, stateURL: state, nodeID: "live-mac-mp",
                                                 createName: "Live multipart").vault
        let entry = try await vault!.perform { v throws(VaultError) in
            try v.addKey(version: 1, key: key, envelopes: [envelope])
            let entry = try v.write(big, parent: try v.rootUID(), name: "big.bin").entry
            #expect(try v.publish().published)
            return entry
        }
        let objectKey = "o/" + entry.uid
        let head = try bucket.head(objectKey)
        #expect(head.versionID == entry.versionID)
        #expect(head.etag?.hasSuffix("-6\"") == true)  // S3's multipart ETag: six parts
        #expect(try await vault!.perform { v throws(VaultError) in try v.readData(entry.uid) } == big)
        #expect(try bucket.listUploads(prefix: "o/").isEmpty)

        vault = nil
        try FileManager.default.removeItem(at: state)
        let reanchored = try await Vault.open(uid: uid, store: bucket, keys: keys, stateURL: state, nodeID: "live-mac-mp").vault
        try await reanchored.perform { v throws(VaultError) in
            #expect(try v.readData(entry.uid) == big)
            #expect(try v.readData(entry.uid, offset: 10 << 20, length: 1000) == big[(10 << 20) ..< (10 << 20) + 1000])
        }
    }
}
