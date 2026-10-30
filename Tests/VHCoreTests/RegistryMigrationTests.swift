import Foundation
import Testing
import VHCore

/// The registry's move into the App Group container (docs/architecture.md §3, "Signing and the shared container"):
/// copy, verify, then switch; resumable from every crash point; never two migrators; never destructive.
@Suite struct RegistryMigrationTests {
    private let root: URL
    private let environment: RegistryEnvironment
    private let noGroup: RegistryEnvironment

    init() {
        root = FileManager.default.temporaryDirectory
            .appending(path: "RegistryMigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        environment = RegistryEnvironment(
            legacyDirectory: root.appending(path: "Application Support/Vaulthalla", directoryHint: .isDirectory),
            appGroup: "ABCDE12345.sh.vaulthalla.app",
            groupContainer: root.appending(path: "Group Containers/ABCDE12345.sh.vaulthalla.app",
                                           directoryHint: .isDirectory))
        noGroup = RegistryEnvironment(legacyDirectory: environment.legacyDirectory, appGroup: nil, groupContainer: nil)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private var groupURL: URL { environment.groupRegistryURL! }
    private var legacyURL: URL { environment.legacyRegistryURL }

    private func node(_ name: String) -> Node {
        Node(id: NodeID(rawValue: "id-\(name)"), displayName: name, endpoint: NodeEndpoint(host: "\(name).local"))
    }

    /// Writes a registry at `url` as its owner would, and returns its bytes.
    @discardableResult
    private func seed(_ url: URL, _ names: [String]) throws -> Data {
        let lease = CredentialLease(forRegistry: url, holder: "seed")
        try lease.acquire()
        defer { lease.release() }
        let store = NodeStore(fileURL: url, lease: lease)
        for name in names { try store.add(node(name)) }
        return try Data(contentsOf: url)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func open(_ env: RegistryEnvironment? = nil) -> RegistryOwnership {
        RegistryOwnership.open(in: env ?? environment, holder: "app")
    }

    // MARK: - The App Group

    @Test func recognizesTeamPrefixedGroupsOnly() {
        #expect(AppGroup.isVaulthallaGroup("ZG2G6V7GLC.sh.vaulthalla.app"))
        #expect(!AppGroup.isVaulthallaGroup("group.sh.vaulthalla.app"))
        #expect(!AppGroup.isVaulthallaGroup("ZG2G6V7GLC.sh.vaulthalla.app.spike"))
        #expect(!AppGroup.isVaulthallaGroup(".sh.vaulthalla.app"))
        #expect(!AppGroup.isVaulthallaGroup("QG2U5HNCG.sh.vaulthalla.app"))
        #expect(AppGroup.vaulthallaGroup(in: ["X.other", "ZG2G6V7GLC.sh.vaulthalla.app"])
            == "ZG2G6V7GLC.sh.vaulthalla.app")
        // `swift test` is unsigned: no group, so the registry stays in Application Support.
        #expect(AppGroup.entitledIdentifier() == nil)
    }

    // MARK: - Migrating

    @Test func copiesVerifiesThenSwitchesKeepingTheOriginalAsBackup() throws {
        defer { cleanUp() }
        let original = try seed(legacyURL, ["a", "b"])

        let opened = open()
        #expect(opened.migration == .migrated(nodes: 2))
        #expect(opened.location == RegistryLocation(registryURL: groupURL, source: .appGroup))
        #expect(opened.lease.isHeld && opened.lease.covers(registry: groupURL))
        #expect(opened.legacyLease?.isHeld == true, "an older build started alongside stays read-only")

        #expect(try Data(contentsOf: groupURL) == original)
        #expect(try Data(contentsOf: environment.backupURL) == original, "the backup is the original, unchanged")
        #expect(!exists(legacyURL))
        #expect(!exists(environment.groupContainer!.appending(path: RegistryEnvironment.stagingName)))
        let pointer = try #require(environment.pointer())
        #expect(pointer.registryURL.path == groupURL.path)
        #expect(pointer.appGroup == "ABCDE12345.sh.vaulthalla.app")
        #expect(try NodeStore(fileURL: groupURL).load().map(\.displayName) == ["a", "b"])

        // The owner writes the migrated registry under the group's lease.
        let store = NodeStore(fileURL: opened.location.registryURL, lease: opened.lease)
        try store.add(node("c"))
        #expect(try Data(contentsOf: environment.backupURL) == original, "later edits never touch the backup")
    }

    @Test func runningAgainChangesNothing() throws {
        defer { cleanUp() }
        let original = try seed(legacyURL, ["a"])
        _ = open()
        let migrated = try Data(contentsOf: groupURL)
        let pointer = try Data(contentsOf: environment.pointerURL)

        let again = open()
        #expect(again.migration == .alreadyMigrated)
        #expect(again.location.source == .appGroup)
        #expect(try Data(contentsOf: groupURL) == migrated)
        #expect(try Data(contentsOf: environment.pointerURL) == pointer)
        #expect(try Data(contentsOf: environment.backupURL) == original)
    }

    @Test func aFreshInstallStartsInTheGroup() throws {
        defer { cleanUp() }
        let opened = open()
        #expect(opened.migration == .nothingToMigrate)
        #expect(opened.location.registryURL == groupURL)
        #expect(opened.lease.isHeld)
        #expect(!exists(environment.pointerURL) && !exists(environment.legacyDirectory))
    }

    // MARK: - Crash points

    @Test func anInterruptedCopyIsRedone() throws {
        defer { cleanUp() }
        let original = try seed(legacyURL, ["a"])
        // A crash mid-copy leaves a partial staging file and no group registry.
        let staging = environment.groupContainer!.appending(path: RegistryEnvironment.stagingName)
        try FileManager.default.createDirectory(at: environment.groupContainer!, withIntermediateDirectories: true)
        try Data("{\"vers".utf8).write(to: staging)

        #expect(open().migration == .migrated(nodes: 1))
        #expect(try Data(contentsOf: groupURL) == original)
        #expect(!exists(staging))
    }

    @Test func aCopyMovedButNotSwitchedIsFinished() throws {
        defer { cleanUp() }
        let original = try seed(legacyURL, ["a"])
        // A crash after step 2: the group registry is the verified copy, no marker yet, the original in place.
        try FileManager.default.createDirectory(at: environment.groupContainer!, withIntermediateDirectories: true)
        try original.write(to: groupURL)

        #expect(open().migration == .migrated(nodes: 1))
        #expect(environment.pointer() != nil)
        #expect(try Data(contentsOf: environment.backupURL) == original)
        #expect(!exists(legacyURL))
    }

    @Test func aSwitchWithoutTheBackupRenameIsFinished() throws {
        defer { cleanUp() }
        let original = try seed(legacyURL, ["a"])
        _ = open()
        // Undo step 4, as a crash between the marker and the rename would leave it.
        try FileManager.default.moveItem(at: environment.backupURL, to: legacyURL)

        #expect(open().migration == .alreadyMigrated)
        #expect(!exists(legacyURL))
        #expect(try Data(contentsOf: environment.backupURL) == original)
    }

    @Test func aRegistryAnOlderBuildWroteAfterTheMoveIsLeftAlone() throws {
        defer { cleanUp() }
        try seed(legacyURL, ["a"])
        _ = open()
        // A build without the App Group (no marker support) starts an empty registry and adds a node.
        let stray = try seed(legacyURL, ["stray"])

        let again = open()
        #expect(again.migration == .alreadyMigrated)
        #expect(again.location.registryURL == groupURL)
        #expect(try Data(contentsOf: legacyURL) == stray, "not renamed: it isn't what was migrated")
        #expect(try NodeStore(fileURL: groupURL).load().map(\.displayName) == ["a"])
    }

    // MARK: - Refusing

    @Test func twoRegistriesThatDifferAreBothLeftAlone() throws {
        defer { cleanUp() }
        let group = try seed(groupURL, ["group"])
        let legacy = try seed(legacyURL, ["legacy"])

        let opened = open()
        #expect(opened.migration == .conflict)
        #expect(opened.location.registryURL == groupURL)
        #expect(try Data(contentsOf: groupURL) == group)
        #expect(try Data(contentsOf: legacyURL) == legacy)
        #expect(!exists(environment.pointerURL) && !exists(environment.backupURL))
    }

    @Test func anUnreadableRegistryIsNotMigrated() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: environment.legacyDirectory, withIntermediateDirectories: true)
        let garbage = Data("not json".utf8)
        try garbage.write(to: legacyURL)

        let opened = open()
        guard case .failed = opened.migration else {
            Issue.record("expected a failure, got \(opened.migration)")
            return
        }
        // The app keeps the old location, owned, so it reports the unreadable file and never overwrites it.
        #expect(opened.location == RegistryLocation(registryURL: legacyURL, source: .applicationSupport))
        #expect(opened.lease.isHeld && opened.lease.covers(registry: legacyURL))
        #expect(try Data(contentsOf: legacyURL) == garbage)
        #expect(!exists(groupURL) && !exists(environment.pointerURL))
    }

    @Test func aNewerFormatIsNotMigrated() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: environment.legacyDirectory, withIntermediateDirectories: true)
        let newer = Data(#"{"version": 9, "nodes": []}"#.utf8)
        try newer.write(to: legacyURL)

        let opened = open()
        #expect(!opened.migration.usesAppGroup)
        #expect(try Data(contentsOf: legacyURL) == newer)
        #expect(!exists(groupURL))
    }

    // MARK: - One migrator

    @Test func aRunningOlderBuildDefersTheMigration() throws {
        defer { cleanUp() }
        let original = try seed(legacyURL, ["a"])
        // An older build owns the old location.
        let older = CredentialLease(forRegistry: legacyURL, holder: "older-app")
        try older.acquire()

        let opened = open()
        guard case .deferred(let holder) = opened.migration else {
            Issue.record("expected a deferral, got \(opened.migration)")
            return
        }
        #expect(holder?.name == "older-app")
        // Read-only on the old location until that build exits; the group's lease isn't kept.
        #expect(opened.location.registryURL == legacyURL)
        #expect(!opened.lease.isHeld && opened.lease.covers(registry: legacyURL))
        #expect(!exists(groupURL) && !exists(environment.pointerURL))
        #expect(try Data(contentsOf: legacyURL) == original)
        let groupLease = CredentialLease(forRegistry: groupURL, holder: "probe")
        #expect(throws: Never.self) { try groupLease.acquire() }
        groupLease.release()

        older.release()
        #expect(open().migration == .migrated(nodes: 1), "the next launch migrates")
    }

    @Test func theGroupsOwnerMigratesNobodyElse() throws {
        defer { cleanUp() }
        let original = try seed(legacyURL, ["a"])
        let owner = CredentialLease(forRegistry: groupURL, holder: "agent")
        try owner.acquire()

        let second = open()
        guard case .ownedElsewhere(let holder) = second.migration else {
            Issue.record("expected another owner, got \(second.migration)")
            return
        }
        #expect(holder?.name == "agent")
        #expect(second.location.registryURL == groupURL && !second.lease.isHeld)
        #expect(try Data(contentsOf: legacyURL) == original, "a non-owner never migrates")
        #expect(!exists(groupURL))

        // Without the group's lease the migration refuses outright.
        let unheld = CredentialLease(forRegistry: groupURL, holder: "x")
        let legacy = CredentialLease(forRegistry: legacyURL, holder: "x")
        guard case .failed = RegistryMigration.run(in: environment, groupLease: unheld, legacyLease: legacy) else {
            Issue.record("migrated without the lease")
            return
        }
    }

    @Test func aMarkerForAnotherTeamsContainerIsLeftAlone() throws {
        defer { cleanUp() }
        try seed(legacyURL, ["a"])
        _ = open()
        let otherTeam = RegistryEnvironment(
            legacyDirectory: environment.legacyDirectory, appGroup: "ZZZZZ99999.sh.vaulthalla.app",
            groupContainer: root.appending(path: "Group Containers/ZZZZZ99999.sh.vaulthalla.app"))
        let opened = open(otherTeam)
        #expect(opened.migration == .pointsElsewhere(groupURL.path(percentEncoded: false)))
        #expect(opened.location.registryURL == otherTeam.groupRegistryURL)
        #expect(exists(groupURL) && exists(environment.backupURL))
    }

    // MARK: - Builds without the App Group, and consumers

    @Test func withoutTheGroupTheRegistryStaysInApplicationSupport() throws {
        defer { cleanUp() }
        try seed(legacyURL, ["a"])
        let opened = open(noGroup)
        #expect(opened.migration == .unavailable)
        #expect(opened.location == RegistryLocation(registryURL: legacyURL, source: .applicationSupport))
        #expect(opened.lease.isHeld)
        #expect(!exists(groupURL))
    }

    @Test func withoutTheGroupAMigrationsMarkerIsFollowed() throws {
        defer { cleanUp() }
        try seed(legacyURL, ["a"])
        let migrated = open()
        migrated.lease.release()
        migrated.legacyLease?.release()

        // An unsigned build, or `vaulthalla-mcp` without the group, uses the moved registry and its lease.
        let location = RegistryLocation.resolve(in: noGroup)
        #expect(location == RegistryLocation(registryURL: groupURL, source: .forwarded))
        let opened = open(noGroup)
        #expect(opened.location.registryURL == groupURL && opened.lease.covers(registry: groupURL))
    }

    @Test func consumersReadTheUnmigratedRegistryUntilTheOwnerMovesIt() throws {
        defer { cleanUp() }
        #expect(RegistryLocation.resolve(in: environment).registryURL == groupURL, "fresh: the group")
        #expect(RegistryLocation.resolve(in: noGroup).registryURL == legacyURL)

        try seed(legacyURL, ["a"])
        #expect(RegistryLocation.resolve(in: environment)
            == RegistryLocation(registryURL: legacyURL, source: .applicationSupport))

        _ = open()
        #expect(RegistryLocation.resolve(in: environment)
            == RegistryLocation(registryURL: groupURL, source: .appGroup))
        #expect(RegistryLocation.appGroup(in: environment)?.registryURL == groupURL)
        #expect(RegistryLocation.appGroup(in: noGroup) == nil)
    }
}
