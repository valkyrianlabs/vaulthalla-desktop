import Foundation
import Testing
import VHCore
@testable import VHOnePassword

/// The Swift client against the Go helper's fake build (see FakeHelper). Nothing here contacts 1Password.
@Suite(.enabled(if: FakeHelper.goAvailable, "needs a Go toolchain to build the helper's fake mode"))
struct OnePasswordHelperTests {
    private static func key(_ byte: UInt8, count: Int = 32) -> [UInt8] { [UInt8](repeating: byte, count: count) }

    /// The Vaulthalla vault the tests back up: its numeric id, which the key check binds.
    private static let vaultNumber = "42"

    /// Version `n` holding `key(byte)`, with its real key check (from the helper itself).
    private static func version(
        _ helper: OnePasswordHelper, _ n: Int, _ byte: UInt8, needed: Bool = true
    ) async throws -> KeyVersion {
        let check = try await helper.testKeyCheck(key(byte), vault: vaultNumber, version: n)
        return KeyVersion(version: n, key: SecretBytes(key(byte)), keyCheck: check, needed: needed)
    }

    private static func check(_ helper: OnePasswordHelper, _ n: Int, _ byte: UInt8) async throws -> String {
        try await helper.testKeyCheck(key(byte), vault: vaultNumber, version: n)
    }

    private static func backup(_ vaultID: String, current: Int, _ versions: KeyVersion...) -> BackupUpsert {
        BackupUpsert(
            onePasswordVaultID: vaultID, nodeID: "node-1", nodeName: "Home Lab", vaultUUID: vaultNumber,
            vaultName: "Photos", currentVersion: current, versions: versions
        )
    }

    private func refusal(_ code: HelperErrorCode, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected \(code), got success")
        } catch let error as OnePasswordHelperError {
            #expect(error.code == code, "got \(error)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    struct Slept: Decodable, Sendable { let slept_ms: Int }
    struct Noisy: Decodable, Sendable { let noisy: Bool }
    struct Empty: Decodable, Sendable {}

    @Test func backupLifecycle() async throws {
        let helper = try FakeHelper.helper()
        defer { Task { await helper.close() } }

        let account = try await helper.checkAccount("Cooper")
        #expect(account.connected && account.account == "Cooper")
        let vault = try await helper.ensureVault()
        #expect(vault.created && vault.title == "Vaulthalla")
        #expect(try await helper.ensureVault().id == vault.id)
        let (c1, c2) = (try await Self.check(helper, 1, 1), try await Self.check(helper, 2, 2))

        let first = try await helper.upsert(Self.backup(vault.id, current: 1, try await Self.version(helper, 1, 1)))
        #expect(first.created && first.written && first.currentVersion == 1 && first.keyCheck == c1)

        let second = try await helper.upsert(Self.backup(
            vault.id, current: 2, try await Self.version(helper, 2, 2), try await Self.version(helper, 1, 1)))
        #expect(!second.created && second.written && second.itemID == first.itemID)
        #expect(second.storedVersions == [
            StoredKeyVersion(version: 2, keyCheck: c2, state: .current),
            StoredKeyVersion(version: 1, keyCheck: c1, state: .needed),
        ])

        let again = try await helper.upsert(Self.backup(
            vault.id, current: 2, try await Self.version(helper, 2, 2), try await Self.version(helper, 1, 1)))
        #expect(!again.written, "an idempotent re-upsert writes nothing")

        let items = try await helper.listItems(onePasswordVaultID: vault.id)
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.itemID == first.itemID && item.nodeID == "node-1" && item.vaultUUID == Self.vaultNumber)
        #expect(item.title == "Vaulthalla · Photos · Home Lab" && item.currentVersion == 2 && item.issues.isEmpty)
        #expect(item.backedUpAt != nil && item.updatedAt != nil)

        let daemon = DaemonKeyStatus(vaultUUID: Self.vaultNumber, version: 2, exportedVersion: 1, keyCheck: c2, neededVersions: [1])
        #expect(BackupStatus.evaluate(daemon: daemon, item: item) == .backedUp(confirmed: false))

        let revealed = try await helper.reveal(onePasswordVaultID: vault.id, itemID: first.itemID)
        #expect(revealed.nodeID == "node-1" && revealed.vaultUUID == Self.vaultNumber && revealed.currentVersion == 2)
        #expect(revealed.versions.map(\.version) == [2, 1])
        #expect(revealed.versions[0].key.withUnsafeBytes { Array($0) } == Self.key(2))
        #expect(revealed.versions[1].key.withUnsafeBytes { Array($0) } == Self.key(1))
        let allNeeded = revealed.versions.allSatisfy { $0.needed }
        #expect(allNeeded)

        let one = try await helper.reveal(onePasswordVaultID: vault.id, itemID: first.itemID, versions: [1])
        #expect(one.versions.count == 1 && one.versions[0].keyCheck == c1)
        await refusal(.notFound) { _ = try await helper.reveal(onePasswordVaultID: vault.id, itemID: first.itemID, versions: [9]) }

        // Diagnostics name ops, never keys.
        let diagnostics = await helper.diagnostics.joined(separator: "\n")
        #expect(diagnostics.contains("op=item.upsert ok"))
        for byte: UInt8 in [1, 2] {
            #expect(!diagnostics.contains(Data(Self.key(byte)).base64EncodedString()))
        }
    }

    @Test func storedVersionsAreNeverOverwritten() async throws {
        let helper = try FakeHelper.helper()
        defer { Task { await helper.close() } }
        try await helper.checkAccount("Cooper")
        let vault = try await helper.ensureVault()
        _ = try await helper.upsert(Self.backup(vault.id, current: 1, try await Self.version(helper, 1, 1)))
        do {
            _ = try await helper.upsert(Self.backup(
                vault.id, current: 2, try await Self.version(helper, 2, 2), try await Self.version(helper, 1, 9)))
            Issue.record("conflicting version accepted")
        } catch let OnePasswordHelperError.refused(code, _, hint, _) {
            #expect(code == .versionConflict)
            #expect(hint != nil)
        }
        let revealed = try await helper.reveal(onePasswordVaultID: vault.id, itemID: try #require(try await helper.listItems(onePasswordVaultID: vault.id).first).itemID)
        #expect(revealed.versions.map(\.version) == [1])
        #expect(revealed.versions[0].key.withUnsafeBytes { Array($0) } == Self.key(1))
    }

    @Test func aKeyThatDoesNotMatchItsCheckIsRefused() async throws {
        let helper = try FakeHelper.helper()
        defer { Task { await helper.close() } }
        try await helper.checkAccount("Cooper")
        let vault = try await helper.ensureVault()
        // key(2) under version 1's check: the helper recomputes the check and refuses before writing anything.
        let wrong = KeyVersion(version: 1, key: SecretBytes(Self.key(2)), keyCheck: try await Self.check(helper, 1, 1), needed: true)
        await refusal(.keyCheckMismatch) { _ = try await helper.upsert(Self.backup(vault.id, current: 1, wrong)) }
        #expect(try await helper.listItems(onePasswordVaultID: vault.id).isEmpty)
    }

    @Test(arguments: [
        HelperErrorCode.integrationDisabled, .appNotRunning, .appNotInstalled, .locked, .denied, .libraryBlocked,
    ])
    func accountFailuresMapToStableCodes(_ code: HelperErrorCode) async throws {
        let helper = try FakeHelper.helper()
        defer { Task { await helper.close() } }
        do {
            try await helper.checkAccount("fake:\(code.rawValue)")
            Issue.record("expected \(code)")
        } catch let OnePasswordHelperError.refused(got, message, hint, _) {
            #expect(got == code)
            #expect(!message.isEmpty)
            #expect(hint?.isEmpty == false)
            if code == .integrationDisabled {
                #expect(hint?.contains("Settings → Developer") == true && hint?.contains("Integrate with other apps") == true)
            }
        }
    }

    @Test func operationsNeedAnAccountCheck() async throws {
        let helper = try FakeHelper.helper()
        defer { Task { await helper.close() } }
        await refusal(.noSession) { _ = try await helper.ensureVault() }
    }

    @Test func malformedAndUnknownRequestsAreRefused() async throws {
        let helper = try FakeHelper.helper()
        defer { Task { await helper.close() } }
        try await helper.checkAccount("Cooper")
        await refusal(.unknownOp) { _ = try await helper.send(op: "no.such.op", as: Empty.self) }
        await refusal(.badRequest) { _ = try await helper.send(op: "item.upsert", as: Empty.self) { w in w.field("bogus", 1) } }
        await refusal(.badRequest) {
            _ = try await helper.send(op: "vault.ensure", as: Empty.self) { w in w.field("title", 5) }
        }
        // A line the helper can't parse is answered with "id": null; it still reaches the request in flight.
        await refusal(.badRequest) {
            _ = try await helper.send(op: "vault.ensure", as: Empty.self) { w in w.key("title") } // {"title":}
        }
        #expect(try await helper.ensureVault().title == "Vaulthalla", "the stream recovers")
    }

    @Test func restartsAfterACrashAndReauthorizes() async throws {
        let helper = try FakeHelper.helper()
        defer { Task { await helper.close() } }
        try await helper.checkAccount("Cooper")
        _ = try await helper.ensureVault()
        let firstPID = try #require(await helper.processIdentifier)

        do {
            _ = try await helper.send(op: "fake.crash", as: Empty.self) { w in w.field("code", 70) }
            Issue.record("crash not reported")
        } catch let error as OnePasswordHelperError {
            guard case .exited = error else { Issue.record("got \(error)"); return }
        }
        #expect(await eventually { !processExists(firstPID) })

        // No explicit account.check: the client re-runs it for the new process.
        let vault = try await helper.ensureVault()
        #expect(vault.created, "a new process (the fake's state is in memory)")
        let secondPID = try #require(await helper.processIdentifier)
        #expect(secondPID != firstPID)
    }

    @Test func stopsRestartingInACrashLoop() async throws {
        let helper = try FakeHelper.helper(maxConsecutiveCrashes: 2)
        defer { Task { await helper.close() } }
        for _ in 0..<2 {
            await #expect(throws: OnePasswordHelperError.self) { _ = try await helper.send(op: "fake.crash", as: Empty.self) }
        }
        await #expect(throws: OnePasswordHelperError.crashLoop) { try await helper.checkAccount("Cooper") }
        await helper.resetFailures()
        try await helper.checkAccount("Cooper")
    }

    @Test func timesOutAndStartsAFreshHelper() async throws {
        // Only the request meant to hang gets a short timeout: the fresh helper's first request includes launching a
        // process, which on a busy machine can take longer than 400 ms by itself.
        let helper = try FakeHelper.helper()
        defer { Task { await helper.close() } }
        try await helper.checkAccount("Cooper")
        let pid = try #require(await helper.processIdentifier)
        await #expect(throws: OnePasswordHelperError.timeout(op: "fake.sleep")) {
            _ = try await helper.send(op: "fake.sleep", as: Slept.self, timeout: .milliseconds(400)) { w in
                w.field("ms", 10_000)
            }
        }
        #expect(await eventually { !processExists(pid) }, "the stuck helper is terminated")
        let slept = try await helper.send(op: "fake.sleep", as: Slept.self) { w in w.field("ms", 10) }
        #expect(slept.slept_ms == 10)
        #expect(try #require(await helper.processIdentifier) != pid)
    }

    @Test func concurrentRequestsAreSerialized() async throws {
        let helper = try FakeHelper.helper()
        defer { Task { await helper.close() } }
        try await helper.checkAccount("Cooper")
        let vault = try await helper.ensureVault()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    if i.isMultiple(of: 2) {
                        _ = try await helper.send(op: "fake.sleep", as: Slept.self) { w in w.field("ms", 20) }
                    } else {
                        _ = try await helper.listItems(onePasswordVaultID: vault.id)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func linesItCannotRouteAreIgnored() async throws {
        let helper = try FakeHelper.helper()
        defer { Task { await helper.close() } }
        let noisy = try await helper.send(op: "fake.noise", as: Noisy.self)
        #expect(noisy.noisy)
    }

    @Test func accountSwitchRestartsTheHelper() async throws {
        let helper = try FakeHelper.helper()
        defer { Task { await helper.close() } }
        try await helper.checkAccount("Personal")
        let pid = try #require(await helper.processIdentifier)
        try await helper.checkAccount("Work")
        #expect(try #require(await helper.processIdentifier) != pid)
    }

    @Test func closeStopsTheHelper() async throws {
        let helper = try FakeHelper.helper()
        try await helper.checkAccount("Cooper")
        let pid = try #require(await helper.processIdentifier)
        await helper.close()
        #expect(await eventually { !processExists(pid) })
        await #expect(throws: OnePasswordHelperError.closed) { try await helper.checkAccount("Cooper") }
    }

    @Test func releasingTheClientTerminatesTheHelper() async throws {
        var helper: OnePasswordHelper? = try FakeHelper.helper()
        try await helper?.checkAccount("Cooper")
        let pid = try #require(await helper?.processIdentifier)
        helper = nil
        #expect(await eventually { !processExists(pid) })
    }

    @Test func missingExecutableFailsToLaunch() async {
        let helper = OnePasswordHelper(configuration: .init(executableURL: URL(filePath: "/nonexistent/vaulthalla-1password")))
        await #expect {
            try await helper.checkAccount("Cooper")
        } throws: { error in
            if case OnePasswordHelperError.launchFailed = error { return true }
            return false
        }
    }
}
