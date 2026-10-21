import Testing
import VHOnePassword

@Suite struct BackupStatusTests {
    private static let vault = "vault-uuid-1"

    private static func daemon(
        _ version: Int, check: String? = nil, exported: Int? = nil, rotating: Bool = false, needed: [Int] = []
    ) -> DaemonKeyStatus {
        DaemonKeyStatus(
            vaultUUID: vault, version: version, exportedVersion: exported, keyCheck: check ?? "c\(version)",
            rotationInProgress: rotating, neededVersions: needed
        )
    }

    /// An item holding `versions` (each with key check "c<n>" unless overridden), `current` as its current version.
    private static func item(
        current: Int, versions: [Int], checks: [Int: String] = [:], currentCheck: String? = nil,
        vaultUUID: String = vault, issues: [String] = []
    ) -> BackupItem {
        BackupItem(
            itemID: "item", onePasswordVaultID: "op-vault", nodeID: "node", vaultUUID: vaultUUID,
            currentVersion: current, keyCheck: currentCheck ?? checks[current] ?? "c\(current)",
            versions: versions.sorted(by: >).map {
                StoredKeyVersion(version: $0, keyCheck: checks[$0] ?? "c\($0)", state: $0 == current ? .current : .needed)
            },
            issues: issues
        )
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let daemon: DaemonKeyStatus?
        let item: BackupItem?
        let expected: BackupStatus
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "offline, no item", daemon: nil, item: nil, expected: .unknown),
        Case(name: "offline, with item", daemon: nil, item: item(current: 1, versions: [1]), expected: .unknown),
        Case(name: "never backed up", daemon: daemon(1), item: nil, expected: .needsBackup(.neverBackedUp)),
        Case(name: "never backed up, rotating", daemon: daemon(3, rotating: true, needed: [2]), item: nil,
             expected: .rotating(missingVersions: [3, 2])),
        Case(name: "backed up and confirmed", daemon: daemon(2, exported: 2, needed: [1]),
             item: item(current: 2, versions: [2, 1]), expected: .backedUp(confirmed: true)),
        Case(name: "backed up, never confirmed", daemon: daemon(2, needed: [1]),
             item: item(current: 2, versions: [2, 1]), expected: .backedUp(confirmed: false)),
        Case(name: "backed up, confirmation stale", daemon: daemon(2, exported: 1),
             item: item(current: 2, versions: [2, 1]), expected: .backedUp(confirmed: false)),
        Case(name: "retired versions in the item don't matter", daemon: daemon(3, exported: 3),
             item: item(current: 3, versions: [3, 2, 1]), expected: .backedUp(confirmed: true)),
        Case(name: "needed list repeats the current version", daemon: daemon(2, exported: 2, needed: [2, 1]),
             item: item(current: 2, versions: [2, 1]), expected: .backedUp(confirmed: true)),
        Case(name: "stale after rotation", daemon: daemon(3, needed: [2]),
             item: item(current: 2, versions: [2, 1]), expected: .needsBackup(.newVersion(3))),
        Case(name: "missing a needed older version", daemon: daemon(3, needed: [2, 1]),
             item: item(current: 3, versions: [3, 1]), expected: .needsBackup(.missingVersions([2]))),
        Case(name: "missing several needed versions", daemon: daemon(5, needed: [4, 2, 1]),
             item: item(current: 5, versions: [5, 4]), expected: .needsBackup(.missingVersions([2, 1]))),
        Case(name: "current stored but credential not moved", daemon: daemon(3, needed: [2]),
             item: item(current: 2, versions: [3, 2]), expected: .needsBackup(.currentNotPromoted)),
        Case(name: "key check differs on the current version", daemon: daemon(2, exported: 2),
             item: item(current: 2, versions: [2, 1], checks: [2: "other"]), expected: .mismatch(.keyCheckDiffers(version: 2))),
        Case(name: "key check differs on a stored, not yet current version", daemon: daemon(3),
             item: item(current: 2, versions: [3, 2], checks: [3: "other"]), expected: .mismatch(.keyCheckDiffers(version: 3))),
        Case(name: "item's current check differs although no vN entry", daemon: daemon(2),
             item: item(current: 2, versions: [1], currentCheck: "other"), expected: .mismatch(.keyCheckDiffers(version: 2))),
        Case(name: "item ahead of the daemon", daemon: daemon(3),
             item: item(current: 4, versions: [4, 3]), expected: .mismatch(.itemAheadOfDaemon(itemVersion: 4, daemonVersion: 3))),
        Case(name: "item for another vault", daemon: daemon(1),
             item: item(current: 1, versions: [1], vaultUUID: "other"), expected: .mismatch(.wrongItem)),
        Case(name: "damaged item", daemon: daemon(1),
             item: item(current: 1, versions: [1], issues: ["credential differs from v1"]),
             expected: .mismatch(.damaged(["credential differs from v1"]))),
        Case(name: "rotating, old keys safe", daemon: daemon(3, rotating: true, needed: [2]),
             item: item(current: 3, versions: [3, 2]), expected: .rotating(missingVersions: [])),
        Case(name: "rotating, new key not stored yet", daemon: daemon(4, rotating: true, needed: [3]),
             item: item(current: 3, versions: [3]), expected: .rotating(missingVersions: [4])),
        Case(name: "mismatch wins over rotating", daemon: daemon(3, rotating: true, needed: [2]),
             item: item(current: 3, versions: [3, 2], checks: [3: "other"]), expected: .mismatch(.keyCheckDiffers(version: 3))),
    ]

    @Test(arguments: cases)
    func evaluates(_ c: Case) {
        #expect(BackupStatus.evaluate(daemon: c.daemon, item: c.item) == c.expected)
    }

    @Test func needsAttention() {
        #expect(!BackupStatus.backedUp(confirmed: true).needsAttention)
        #expect(!BackupStatus.backedUp(confirmed: false).needsAttention)
        #expect(!BackupStatus.rotating(missingVersions: []).needsAttention)
        #expect(BackupStatus.rotating(missingVersions: [4]).needsAttention)
        #expect(BackupStatus.needsBackup(.neverBackedUp).needsAttention)
        #expect(BackupStatus.mismatch(.wrongItem).needsAttention)
        #expect(BackupStatus.unknown.needsAttention)
        #expect(BackupStatus.keyUnavailable(.init(reason: "key_missing", detail: nil, versions: [1], backup: .none)).needsAttention)
    }

    @Test func wantsSync() {
        #expect(BackupStatus.needsBackup(.neverBackedUp).wantsSync)
        #expect(BackupStatus.rotating(missingVersions: [4]).wantsSync)
        #expect(!BackupStatus.rotating(missingVersions: []).wantsSync)
        #expect(BackupStatus.backedUp(confirmed: false).wantsSync, "only the confirmation is missing")
        #expect(!BackupStatus.backedUp(confirmed: true).wantsSync)
        #expect(!BackupStatus.mismatch(.wrongItem).wantsSync, "never synced over")
        #expect(!BackupStatus.keyUnavailable(.init(reason: "key_missing", detail: nil, versions: [1], backup: .complete)).wantsSync)
        #expect(!BackupStatus.unknown.wantsSync)
    }

    // MARK: key_available: false

    /// The daemon can't use the vault's key: `key_check` null for an unreadable current key, `missing_versions` for
    /// needed versions it doesn't hold, and the reason code.
    private static func unavailable(
        _ version: Int, reason: String = "key_unsealable", check: String? = nil, missing: [Int] = [], needed: [Int] = [],
        neededChecks: [Int: String] = [:], detail: String? = "The key doesn't unseal on this host."
    ) -> DaemonKeyStatus {
        DaemonKeyStatus(
            vaultUUID: vault, version: version, keyCheck: check, neededVersions: needed, neededKeyChecks: neededChecks,
            keyAvailable: false, unavailableReason: reason, unavailableDetail: detail, missingVersions: missing
        )
    }

    struct UnavailableCase: Sendable, CustomTestStringConvertible {
        let name: String
        let daemon: DaemonKeyStatus
        let item: BackupItem?
        let expected: BackupStatus.KeyUnavailable
        var testDescription: String { name }
    }

    static let unavailableCases: [UnavailableCase] = [
        UnavailableCase(
            name: "unsealable, backed up", daemon: unavailable(2, needed: [1], neededChecks: [1: "c1"]),
            item: item(current: 2, versions: [2, 1]),
            expected: .init(reason: "key_unsealable", detail: "The key doesn't unseal on this host.", versions: [2], backup: .complete)),
        UnavailableCase(
            name: "key missing, never backed up", daemon: unavailable(3, reason: "key_missing", detail: nil), item: nil,
            expected: .init(reason: "key_missing", detail: nil, versions: [3], backup: .none)),
        UnavailableCase(
            name: "a needed old version missing, held", daemon: unavailable(3, reason: "version_missing", check: "c3", missing: [2], needed: [2]),
            item: item(current: 3, versions: [3, 2]),
            expected: .init(reason: "version_missing", detail: "The key doesn't unseal on this host.", versions: [2], backup: .complete)),
        UnavailableCase(
            name: "two versions gone, one held", daemon: unavailable(3, missing: [2], needed: [2]),
            item: item(current: 2, versions: [2, 1]),
            expected: .init(reason: "key_unsealable", detail: "The key doesn't unseal on this host.", versions: [3, 2], backup: .partial(missing: [3]))),
        UnavailableCase(
            name: "held, but another vault's item", daemon: unavailable(1),
            item: item(current: 1, versions: [1], vaultUUID: "other"),
            expected: .init(reason: "key_unsealable", detail: "The key doesn't unseal on this host.", versions: [1], backup: .none)),
        UnavailableCase(
            name: "held, but the helper found the item damaged", daemon: unavailable(1),
            item: item(current: 1, versions: [1], issues: ["v1 doesn't match its key check"]),
            expected: .init(reason: "key_unsealable", detail: "The key doesn't unseal on this host.", versions: [1], backup: .none)),
        UnavailableCase(
            name: "held, but the daemon knows a different check", daemon: unavailable(3, check: "c3", missing: [2], needed: [2], neededChecks: [:]),
            item: item(current: 3, versions: [3, 2], checks: [3: "c3", 2: "c2"]),
            expected: .init(reason: "key_unsealable", detail: "The key doesn't unseal on this host.", versions: [2], backup: .complete)),
        UnavailableCase(
            name: "a version whose check the daemon still knows must agree",
            daemon: unavailable(3, reason: "version_missing", check: "c3", missing: [3], needed: [2], neededChecks: [2: "c2"]),
            item: item(current: 3, versions: [3, 2], checks: [3: "other"]),
            expected: .init(reason: "version_missing", detail: "The key doesn't unseal on this host.", versions: [3], backup: .none)),
        UnavailableCase(
            name: "an unknown reason from a newer daemon", daemon: unavailable(1, reason: "tpm_gone"),
            item: item(current: 1, versions: [1]),
            expected: .init(reason: "tpm_gone", detail: "The key doesn't unseal on this host.", versions: [1], backup: .complete)),
    ]

    @Test(arguments: unavailableCases)
    func unavailableKeys(_ c: UnavailableCase) {
        #expect(BackupStatus.evaluate(daemon: c.daemon, item: c.item) == .keyUnavailable(c.expected))
    }

    @Test func unavailableWinsOverEveryOtherState() {
        // A rotation, a mismatching item, an unconfirmed export: the vault doesn't run, so that is what shows.
        var d = Self.unavailable(3, check: "c3", missing: [2], needed: [2])
        d.rotationInProgress = true
        let status = BackupStatus.evaluate(daemon: d, item: Self.item(current: 3, versions: [3], checks: [3: "other"]))
        guard case .keyUnavailable(let k) = status else { Issue.record("got \(status)"); return }
        #expect(k.versions == [2] && k.backup == .none && !k.canRestore)
        // Offline still means unknown, never "unavailable".
        #expect(BackupStatus.evaluate(daemon: nil, item: Self.item(current: 1, versions: [1])) == .unknown)
    }

    @Test func aDifferingCheckOnANeededVersionIsAMismatch() {
        let d = DaemonKeyStatus(vaultUUID: Self.vault, version: 3, keyCheck: "c3", neededVersions: [2],
                                neededKeyChecks: [2: "c2"])
        #expect(BackupStatus.evaluate(daemon: d, item: Self.item(current: 3, versions: [3, 2], checks: [2: "other"]))
            == .mismatch(.keyCheckDiffers(version: 2)))
        #expect(BackupStatus.evaluate(daemon: d, item: Self.item(current: 3, versions: [3, 2])) == .backedUp(confirmed: false))
    }

    /// Invariants over every combination of a small state space: the daemon's version, the needed versions, rotation,
    /// whether the current check matches, and every item from "none" to each subset of versions with each current.
    @Test func invariantsOverTheStateSpace() {
        var checked = 0
        for version in 1...3 {
            for neededMask in 0..<(1 << (version - 1)) {
                let needed = (1..<version).filter { neededMask & (1 << ($0 - 1)) != 0 }
                for rotating in [false, true] {
                    for exported in [nil, version - 1, version] as [Int?] {
                        let d = Self.daemon(version, exported: exported, rotating: rotating, needed: needed)
                        let required = Set([version] + needed)
                        #expect(BackupStatus.evaluate(daemon: nil, item: nil) == .unknown)

                        var items: [BackupItem?] = [nil]
                        for heldMask in 1..<(1 << 4) {
                            let held = (1...4).filter { heldMask & (1 << ($0 - 1)) != 0 }
                            for current in held {
                                for checkMatches in [true, false] {
                                    items.append(Self.item(
                                        current: current, versions: held,
                                        checks: checkMatches ? [:] : [version: "other"]
                                    ))
                                }
                            }
                        }
                        for item in items {
                            checked += 1
                            let status = BackupStatus.evaluate(daemon: d, item: item)
                            let held = Set(item?.versions.map(\.version) ?? [])
                            let storedCheck = item?.version(version)?.keyCheck
                            switch status {
                            case .backedUp(let confirmed):
                                // Backed up only if everything needed is held, the check matches, nothing rotates.
                                #expect(required.isSubset(of: held))
                                #expect(storedCheck == d.keyCheck && item?.currentVersion == version)
                                #expect(!rotating)
                                #expect(confirmed == (exported == version))
                            case .unknown:
                                Issue.record("unknown with a daemon status")
                            case .rotating(let missing):
                                #expect(rotating)
                                #expect(Set(missing) == required.subtracting(held))
                            case .needsBackup:
                                #expect(!rotating)
                                #expect(!required.isSubset(of: held) || item?.currentVersion != version)
                            case .mismatch:
                                #expect(item != nil)
                            case .keyUnavailable:
                                Issue.record("key unavailable while the daemon reads its keys")
                            }
                            // A differing check on the daemon's version is always a mismatch, rotating or not.
                            if let storedCheck, storedCheck != d.keyCheck {
                                #expect(status == .mismatch(.keyCheckDiffers(version: version)))
                            }
                        }
                    }
                }
            }
        }
        #expect(checked > 1000)
    }
}
