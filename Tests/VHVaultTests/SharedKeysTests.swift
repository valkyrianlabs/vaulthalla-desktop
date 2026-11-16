import Foundation
import Testing
import VHCore
import VHFinder
import VHRecovery
@testable import VHVaultEngine
@testable import VHVaultKeys

/// An item store a test can make fail: a delete that throws (a crash between the move's write and delete), a read
/// back that returns other bytes.
final class FlakyItems: AccountItemStore, @unchecked Sendable {
    let inner = MemoryAccountItemStore()
    var failDeletes = 0
    var corruptReads = false
    func read(_ name: String) throws -> Data? {
        guard var d = try inner.read(name) else { return nil }
        if corruptReads { d[0] ^= 0xFF }
        return d
    }
    func write(_ name: String, _ data: Data) throws { try inner.write(name, data) }
    func delete(_ name: String) throws {
        if failDeletes > 0 { failDeletes -= 1; throw AccountItemError.keychain(-1) }
        try inner.delete(name)
    }
}

@Suite(.serialized) struct SharedKeysTests {
    static let directory = FileManager.default.temporaryDirectory.appending(path: "vh-shared-keys-\(UUID().uuidString)")

    func lease() throws -> CredentialLease {
        let dir = Self.directory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lease = CredentialLease(forRegistry: dir.appending(path: "nodes.json"), holder: "test")
        try lease.acquire()
        return lease
    }

    func bucketKey(_ uid: String, id: String = "key-1", expires: Date = Date() + 3600) -> BucketKey {
        BucketKey(vaultUid: uid, keyID: id, access: "full", bucket: "vhc-\(uid)", bucketID: "b", s3Endpoint: "https://s3.test",
                  region: "r", expiresAt: expires, renewAfter: expires - 60, secret: SecretBytes(Data("secret-\(id)".utf8)))
    }

    // MARK: the stores in the shared group

    @Test func theAppWritesAndTheExtensionOnlyReads() throws {
        let shared = MemoryAccountItemStore()
        let app = VaultItems(shared: LeasedAccountItems(items: shared, lease: try lease()))
        let fileProvider = VaultItems(shared: LeasedAccountItems(items: shared, lease: nil))
        let uid = Uid.random().base32
        try BucketKeyStore(vaultItems: app).save(bucketKey(uid))
        try VaultKeyStore(vaultItems: app).save(uid, version: 1, key: newVaultKey())
        let read = try #require(try BucketKeyStore(vaultItems: fileProvider).load(uid))
        #expect(read.keyID == "key-1" && read.secret.withUnsafeBytes { Data($0) } == Data("secret-key-1".utf8))
        #expect(try VaultKeyStore(vaultItems: fileProvider).versions(uid)?.current == 1)
        #expect(throws: CredentialOwnershipError.self) { try BucketKeyStore(vaultItems: fileProvider).save(bucketKey(uid, id: "key-2")) }
        // Only the vault's items, raw bytes for secrets.
        #expect(Set(shared.names) == ["storage-key.\(uid)", "storage-key.\(uid).key-1", "vault-key.\(uid)", "vault-key.\(uid).1"])
        #expect(try shared.read("vault-key.\(uid).1")?.count == 32)
    }

    @Test func theSharedGroupIsItsOwnAndThisDeviceOnly() {
        let store = KeychainAccountItemStore(service: VaultKeychain.service, keychain: .dataProtection(accessGroup: "T.sh.vaulthalla.app.vault"))
        let q = store.query("vault-key.x.1")
        #expect(q[kSecAttrService as String] as? String == "sh.vaulthalla.app.vault")
        #expect(q[kSecAttrAccessGroup as String] as? String == "T.sh.vaulthalla.app.vault")
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == true)
        let add = store.addAttributes()
        #expect((add[kSecAttrAccessible as String] as! CFString) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        #expect(add[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(VaultKeychain.service != AccountKeychain.service)
    }

    // MARK: the move from the app-only group

    @Test func itemsMoveOnFirstUseWriteVerifyThenDelete() throws {
        let l = try lease()
        let old = MemoryAccountItemStore(), new = MemoryAccountItemStore()
        let uid = Uid.random().base32
        try BucketKeyStore(items: LeasedAccountItems(items: old, lease: l)).save(bucketKey(uid))
        try VaultKeyStore(items: LeasedAccountItems(items: old, lease: l)).save(uid, version: 1, key: newVaultKey())
        let before = old.names
        let items = VaultItems(shared: LeasedAccountItems(items: new, lease: l), legacy: LeasedAccountItems(items: old, lease: l))
        #expect(try BucketKeyStore(vaultItems: items).load(uid)?.keyID == "key-1")
        #expect(try VaultKeyStore(vaultItems: items).versions(uid)?.current == 1)
        #expect(try VaultKeyStore(vaultItems: items).withKey(uid, version: 1) { $0.count } == 32)
        #expect(Set(new.names) == Set(before) && old.names.isEmpty)  // each item moved as it was first read
    }

    @Test func aCrashBetweenTheWriteAndTheDeleteKeepsBothUntilTheNextUse() throws {
        let l = try lease()
        let old = FlakyItems(), new = MemoryAccountItemStore()
        let uid = Uid.random().base32
        try VaultKeyStore(items: LeasedAccountItems(items: old, lease: l)).save(uid, version: 1, key: newVaultKey())
        let bytes = try old.inner.read("vault-key.\(uid).1")
        old.failDeletes = 1  // the first move's delete never happens
        let items = VaultItems(shared: LeasedAccountItems(items: new, lease: l), legacy: LeasedAccountItems(items: old, lease: l))
        #expect(try VaultKeyStore(vaultItems: items).versions(uid)?.current == 1)  // answered from the moved copy
        #expect(try new.read("vault-key.\(uid)") != nil && old.inner.names.contains("vault-key.\(uid)"))  // both
        #expect(try VaultKeyStore(vaultItems: items).versions(uid)?.current == 1)
        #expect(try VaultKeyStore(vaultItems: items).withKey(uid, version: 1) { Data($0) } == bytes)
        #expect(old.inner.names.isEmpty)
    }

    @Test func aFailedReadBackLeavesTheOldItem() throws {
        let l = try lease()
        let old = MemoryAccountItemStore(), new = FlakyItems()
        let uid = Uid.random().base32
        try VaultKeyStore(items: LeasedAccountItems(items: old, lease: l)).save(uid, version: 1, key: newVaultKey())
        let bytes = try old.read("vault-key.\(uid).1")
        new.corruptReads = true
        let items = VaultItems(shared: LeasedAccountItems(items: new, lease: l), legacy: LeasedAccountItems(items: old, lease: l))
        #expect(try VaultKeyStore(vaultItems: items).withKey(uid, version: 1) { Data($0) } == bytes)  // the old item's
        #expect(try old.read("vault-key.\(uid).1") == bytes)  // kept
        #expect(new.inner.names.isEmpty)  // the bad copy removed
    }

    @Test func anOldItemThatDiffersIsNeverDeletedOnAGuess() throws {
        let l = try lease()
        let old = MemoryAccountItemStore(), new = MemoryAccountItemStore()
        try old.write("vault-key.x.1", Data(repeating: 1, count: 32))
        try new.write("vault-key.x.1", Data(repeating: 2, count: 32))
        let items = VaultItems(shared: LeasedAccountItems(items: new, lease: l), legacy: LeasedAccountItems(items: old, lease: l))
        #expect(try items.read("vault-key.x.1") == Data(repeating: 2, count: 32))
        #expect(try old.read("vault-key.x.1") != nil)
    }

    // MARK: the extension: no cloud, the refusal signal, an expired key

    @Test func theExtensionCannotReachTheCloudClient() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Package.swift: what VHVaultEngine depends on, transitively.
        let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        var deps: [String: [String]] = [:]
        let target = try Regex(#"\.target\(\s*name:\s*"(\w+)"(?:,\s*dependencies:\s*\[([^\]]*)\])?"#)
        for m in manifest.matches(of: target) {
            let name = String(m.output[1].substring!)
            let list = m.output[2].substring.map { String($0) } ?? ""
            deps[name] = list.matches(of: try Regex(#""(\w+)""#)).map { String($0.output[1].substring!) }
        }
        var seen: Set<String> = [], queue = ["VHVaultEngine"]
        while let t = queue.popLast() {
            if seen.insert(t).inserted { queue += deps[t] ?? [] }
        }
        #expect(seen.contains("VHVaultKeys") && seen.contains("VHFinder"))
        #expect(!seen.contains("VHCloud") && !seen.contains("VHVault") && !seen.contains("VHKeykit"))
        // The Xcode project: the File Provider extension links VHVaultEngine, never VHVault or VHCloud.
        let project = try String(contentsOf: root.appending(path: "App/Vaulthalla.xcodeproj/project.pbxproj"), encoding: .utf8)
        let block = try #require(project.firstMatch(of: try Regex(#"name = VaulthallaFileProvider;[\s\S]*?packageProductDependencies = \(([\s\S]*?)\);"#)))
        let linked = String(block.output[1].substring!)
        #expect(linked.contains("/* VHVaultEngine */"))
        #expect(!linked.contains("/* VHVault */") && !linked.contains("/* VHCloud */"))
    }

    @Test func aRefusalIsSignalledToTheAppWithoutACloudCall() async throws {
        let container = Self.directory.appending(path: UUID().uuidString)
        let shared = MemoryAccountItemStore()
        let uid = Uid.random().base32
        try BucketKeyStore(items: LeasedAccountItems(items: shared, lease: try lease())).save(bucketKey(uid, id: "key-7"))
        let signal = KeyRefusalSignal(container: container, group: "test.\(UUID().uuidString)")
        let heard = Heard()
        let observer = signal.observe { heard.hit() }
        let credentials = SharedBucketKeyCredentials(store: BucketKeyStore(vaultItems: VaultItems(shared: LeasedAccountItems(items: shared, lease: nil))),
                                                     uid: uid, signal: signal)
        #expect(await credentials.withS3Credentials { $0.accessKeyID } == "key-7")
        await credentials.providerRefused()
        #expect(credentials.state == .refused)
        #expect(await credentials.withS3Credentials { $0.accessKeyID } == nil)  // not used again
        for _ in 0 ..< 50 where !heard.value { try await Task.sleep(for: .milliseconds(20)) }
        #expect(heard.value)
        let taken = signal.take()
        #expect(taken.map(\.vaultUid) == [uid] && taken.map(\.keyID) == ["key-7"] && signal.take().isEmpty)
        _ = observer
        // The app renewed: a new key in the shared group is used at once.
        try BucketKeyStore(items: LeasedAccountItems(items: shared, lease: try lease())).save(bucketKey(uid, id: "key-8"))
        #expect(await credentials.withS3Credentials { $0.accessKeyID } == "key-8")
    }

    @Test func anExpiredKeyWithTheAppNotRunningPausesInWords() async throws {
        let container = Self.directory.appending(path: UUID().uuidString)
        let registry = DesktopVaultRegistry(container: container)
        let f = Fixture()
        let shared = MemoryAccountItemStore()
        let items = VaultItems(shared: LeasedAccountItems(items: shared, lease: try lease()))
        let uid = f.uid.base32
        // The app made the vault and its state; then it quit, and the bucket key expired.
        try VaultKeyStore(vaultItems: items).save(uid, version: 1, key: f.key)
        try BucketKeyStore(vaultItems: items).save(bucketKey(uid, expires: Date() - 60))
        try registry.save(DesktopVaultRecord(uid: uid, name: "Taxes", createdAt: Date(), published: true, adopted: false,
                                             hold: .holding, nodeID: "mac-a"))
        let file: String = try {
            let (v, _) = try Vault.open(uid: f.uid, store: f.bucket, keys: f.keys, stateURL: registry.stateURL(uid), nodeID: "mac-a",
                                        createName: "Taxes")
            try v.addKey(version: 1, key: f.key, envelopes: [try f.envelope()])
            let e = try v.write(Data("return".utf8), parent: try v.rootUID(), name: "a.txt").entry
            _ = try v.publish()
            return e.uid
        }()

        let host = ExtensionEngineHost(uid: uid, container: container, items: VaultItems(shared: LeasedAccountItems(items: shared, lease: nil)))
        let replica = EngineReplica(host: host, numbersURL: registry.directory.appending(path: "desktop-\(uid).ids"))
        // Listing works from the state file with no key at all.
        let listed = try await replica.list(.root, page: .first, pageSize: 10).items
        #expect(listed.map(\.name) == ["a.txt"])
        // Reading needs the bucket: paused, in words, and no request was made (the key isn't used).
        do {
            _ = try await replica.fetch(.entry(listed[0].entryID), into: container)
            Issue.record("a read with an expired key")
        } catch {
            guard case .serverUnreachable(let why) = error else { Issue.record("\(error)"); return }
            #expect(why.contains("expired while Vaulthalla wasn't running") && why.contains("Open Vaulthalla"))
            #expect(why.contains("kept"))
        }
        #expect(await host.unavailableReason() == SharedKeyState.expired(at: Date()).sentence)
        _ = file
        await replica.close()
    }
}

final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var hits = 0
    func hit() { lock.withLock { hits += 1 } }
    var value: Bool { lock.withLock { hits > 0 } }
}
