import Foundation
import Testing
import VHContract
@testable import VHNodes

/// Ported from the web console's `web/src/features/mirrors/model.test.ts` (server main), so both say and allow the
/// same things; the console's action-dialog helpers (switch access, limits, held changes, copies) come with the
/// action pieces.
@Suite("Mirrored vaults model")
struct MirrorModelTests {
    static let date: @Sendable (Int64) -> String = { "@\($0)" }

    static func row(_ edit: (inout MirroredVault) -> Void = { _ in }) -> MirroredVault {
        var row = MirroredVault(
            vaultID: 5, vaultName: "Projects", role: .mirror,
            peer: .init(id: 3, nodeID: "node-b", name: "vps", revoked: false),
            term: 2, lastSeq: 40, state: .live, acked: .init(term: 2, seq: 38), createdAt: 1_700_000_000,
            pendingChanges: 0, linkUp: true)
        edit(&row)
        return row
    }

    static func start(side: String = "core", state: String = "offered", id: Int64 = 9, reason: String? = nil,
                      lastError: String? = nil) -> MirroredVault.Start {
        MirroredVault.Start(id: id, side: side, state: state, name: "Projects", reason: reason, lastError: lastError)
    }

    static func status(_ row: MirroredVault, linkUp: Bool? = true, firstCopy: MirroredVault.FirstCopy? = nil)
        -> MirrorModel.Status
    {
        MirrorModel.status(row, .init(linkUp: linkUp, firstCopy: firstCopy, date: date))
    }

    @Test("a live mirror reads live, and read-only once its link is down (never healthy by guess)")
    func live() {
        #expect(Self.status(Self.row()).label == "Live")
        #expect(Self.status(Self.row(), linkUp: nil).tone == .ok)
        let down = Self.status(Self.row(), linkUp: false)
        #expect(down.label == "Read-only: link down")
        #expect(down.sentence.contains("read-only until it reconnects"))
        let core = Self.status(Self.row { $0.role = .core }, linkUp: false)
        #expect(core.sentence.contains("keep working here"))
    }

    @Test("the first copy shows its progress")
    func firstCopy() {
        let s = Self.status(Self.row(), firstCopy: .init(finished: false, entriesCopied: 120, entriesTotal: 4000))
        #expect(s.label == "First copy")
        #expect(s.sentence.contains("120 of 4,000 entries"))
        #expect(MirrorModel.firstCopyProgress(.init(finished: false, entriesCopied: 1, entriesTotal: 4))?.ratio == 0.25)
        #expect(MirrorModel.firstCopyProgress(.init(finished: false, entriesCopied: 3, entriesTotal: 0))?.ratio == nil)
        #expect(MirrorModel.firstCopyProgress(.init(finished: false, entriesCopied: 3, entriesTotal: 0))?.text
            == "3 entries so far")
        #expect(MirrorModel.firstCopyProgress(.init(finished: true, entriesCopied: 4, entriesTotal: 4)) == nil)
        // The core counts nothing: no progress to show, never a made-up one.
        #expect(MirrorModel.firstCopyProgress(.init(finished: false, entriesCopied: nil, entriesTotal: 4)) == nil)
    }

    @Test("stopped states give their reason in words, or the code when it has none")
    func stopped() {
        let d = Self.status(Self.row { $0.state = .diverged; $0.stopReason = "mirror_digest_mismatch" })
        #expect(d.label == "Diverged")
        #expect(d.sentence.contains("stopped matching the core’s, so"))
        #expect(d.code == nil)
        #expect(Self.status(Self.row { $0.state = .diverged; $0.stopReason = "mirror_type_mismatch" }).sentence
            .contains("a file on one server"))
        let odd = Self.status(Self.row { $0.state = .stopped; $0.stopReason = "mirror_something_new" })
        #expect(odd.code == "mirror_something_new")
        #expect(Self.status(Self.row { $0.state = .expired }).tone == .danger)
        #expect(Self.status(Self.row { $0.state = .switching }).label == "Switching")
        #expect(Self.status(Self.row { $0.state = nil }).tone == .unknown)
        #expect(Self.status(Self.row { $0.state = .other("resting") }).label == "Unknown")
        #expect(Self.status(Self.row { $0.role = .other("witness") }).tone == .unknown)
    }

    @Test("the core deleting a vault names the date and what happens to the copy")
    func deleting() {
        let mirror = Self.status(Self.row {
            $0.state = .paused
            $0.stopReason = "mirror_core_deleting"
            $0.deleting = .init(deleting: true, purgeAfter: 99, copy: "leave")
        })
        #expect(mirror.label == "Core is deleting it")
        #expect(mirror.sentence.contains("until @99, then it is kept as an orphaned copy"))
        let core = Self.status(Self.row { $0.role = .core; $0.deleting = .init(deleting: true, purgeAfter: 99, copy: "remove") })
        #expect(core.sentence.contains("purged on @99"))
        #expect(core.sentence.contains("removed"))
    }

    @Test("starts read from the side that asks")
    func starts() {
        #expect(Self.status(Self.row { $0.role = .starting; $0.start = Self.start() }).label == "Waiting for an answer")
        #expect(Self.status(Self.row { $0.role = .starting; $0.start = Self.start(side: "mirror") }).label == "Waiting for you")
        let failed = Self.status(Self.row {
            $0.role = .starting
            $0.start = Self.start(state: "failed", reason: "mirror_no_space", lastError: "no space")
        })
        #expect(failed.tone == .danger)
        // A code without words reads as the server's error text, with the code beside it once.
        #expect(failed.sentence == "The start failed: no space.")
        #expect(failed.code == "mirror_no_space")
        let worded = Self.status(Self.row {
            $0.role = .starting
            $0.start = Self.start(state: "failed", reason: "mirror_key_missing", lastError: "x")
        })
        #expect(worded.sentence == "The start failed: a key this vault needs is missing here.")
        #expect(worded.code == nil)
    }

    @Test("actions follow the role and state")
    func actions() {
        let a = { (row: MirroredVault) in MirrorModel.actions(row, firstCopyFinished: nil) }
        #expect(a(Self.row { $0.role = .core }) == [.switch, .cancel])
        #expect(a(Self.row { $0.role = .core; $0.state = .diverged }) == [.cancel])
        #expect(a(Self.row()) == [.switch, .detach, .copy, .versions, .held])
        #expect(a(Self.row { $0.state = .diverged }) == [.resync, .detach, .copy, .versions, .held])
        #expect(!a(Self.row()).contains(.cancel), "a completed mirror leaves by detaching")
        #expect(a(Self.row { $0.role = .orphaned }) == [.detach, .copy, .cancel, .held])
        #expect(a(Self.row { $0.role = .starting; $0.start = Self.start() }) == [.cancel])
        #expect(a(Self.row { $0.role = .starting; $0.start = Self.start(state: "declined") }) == [])
        #expect(a(Self.row { $0.role = .core; $0.deleting = .init(deleting: true, purgeAfter: 1, copy: "leave") }) == [.cancel])
        #expect(MirrorModel.cancelKind(Self.row { $0.role = .core }) == .end)
        #expect(MirrorModel.cancelKind(Self.row { $0.role = .orphaned }) == .removeOrphan)
        #expect(MirrorModel.cancelTarget(Self.row { $0.vaultID = 0; $0.start = Self.start(id: 12) }) == .offer(12))
        #expect(MirrorModel.cancelTarget(Self.row()) == .vault(5))
        // The row's own first copy decides take over when nothing else is known.
        #expect(MirrorModel.actions(Self.row { $0.firstCopy = .init(finished: true) }).contains(.takeover))
        #expect(!MirrorModel.actions(Self.row { $0.firstCopy = nil }).contains(.takeover))
    }

    @Test("advice says what to do next, and nothing on a healthy vault")
    func advice() {
        #expect(MirrorModel.advice(Self.row(), linkUp: true, held: 0) == nil)
        #expect(MirrorModel.advice(Self.row(), linkUp: true, held: 2)?.contains("2 changes made here were refused") == true)
        #expect(MirrorModel.advice(Self.row { $0.state = .diverged }, linkUp: true, held: 0)?.contains("Resync") == true)
        #expect(MirrorModel.advice(Self.row { $0.state = .diverged }, linkUp: false, held: 0)?.contains("needs the link") == true)
        #expect(MirrorModel.advice(Self.row { $0.role = .orphaned }, linkUp: true, held: 0)?.contains("Detach") == true)
        #expect(MirrorModel.advice(Self.row { $0.role = .starting; $0.start = Self.start() }, linkUp: true, held: 0)?
            .contains("A super admin on vps") == true)
    }

    @Test("positions and unconfirmed changes")
    func positions() {
        #expect(MirrorModel.positionText(Self.row()) == "Change 40 (term 2) · confirmed through 38 (term 2)")
        #expect(MirrorModel.positionText(Self.row { $0.lastSeq = nil }) == "No changes yet")
        #expect(MirrorModel.unconfirmed(Self.row { $0.role = .core }) == 2)
        #expect(MirrorModel.unconfirmed(Self.row { $0.role = .core; $0.acked = .init(term: 1, seq: 3) }) == nil)
        #expect(MirrorModel.unconfirmed(Self.row()) == nil)
    }

    @Test("take over: a mirror whose first copy finished and that still matches, never an orphan")
    func takeover() {
        #expect(MirrorModel.actions(Self.row(), firstCopyFinished: true) == [.switch, .takeover, .detach, .copy, .versions, .held])
        #expect(MirrorModel.actions(Self.row { $0.state = .stopped }, firstCopyFinished: true).contains(.takeover))
        #expect(MirrorModel.actions(Self.row { $0.state = .switching }, firstCopyFinished: true).contains(.takeover),
                "the way out of a switch whose core never came back")
        #expect(!MirrorModel.canTakeOver(Self.row(), firstCopyFinished: false))
        #expect(!MirrorModel.canTakeOver(Self.row(), firstCopyFinished: nil), "unknown hides it")
        #expect(!MirrorModel.canTakeOver(Self.row { $0.state = .diverged }, firstCopyFinished: true))
        #expect(!MirrorModel.canTakeOver(Self.row { $0.role = .orphaned }, firstCopyFinished: true))
        #expect(!MirrorModel.canTakeOver(Self.row { $0.role = .core }, firstCopyFinished: true))
    }

    @Test("a replaced core (rejoining), both taking over (forked) and an open take over read in words")
    func replacedCore() {
        let rejoining = Self.status(Self.row { $0.role = .core; $0.state = .rejoining; $0.stopReason = "mirror_rejoining" })
        #expect(rejoining.label == "Replaced as the core")
        #expect(rejoining.sentence.contains("vps took over as the core"))
        #expect(rejoining.sentence.contains("read-only here; resync it"))
        #expect(rejoining.code == nil)
        let forked = Self.status(Self.row { $0.role = .core; $0.state = .forked; $0.stopReason = "mirror_both_forced" })
        #expect(forked.sentence.contains("Both servers took over"))
        #expect(forked.sentence.contains("Pick the server whose files stay"))
        let took = Self.row {
            $0.role = .core
            $0.takeover = .init(term: 3, fork: .init(term: 2, seq: 40), peerID: 3, contentsMissing: 0, createdAt: 1)
        }
        #expect(Self.status(took, linkUp: false).sentence.contains("has not returned yet"))
        #expect(MirrorModel.advice(took, linkUp: false, held: 0)?.contains("The old core has not returned yet") == true)
        #expect(MirrorModel.actions(Self.row { $0.role = .core; $0.state = .rejoining }, firstCopyFinished: nil) == [.resync, .detach, .held])
        #expect(MirrorModel.actions(Self.row { $0.role = .core; $0.state = .forked }, firstCopyFinished: nil) == [.resync, .detach, .held])
        #expect(MirrorModel.actions(took, firstCopyFinished: nil) == [.switch, .detach, .cancel])
        #expect(MirrorModel.advice(Self.row { $0.role = .core; $0.state = .rejoining }, linkUp: true, held: 0)?
            .contains("Resync it to follow vps again") == true)
    }

    @Test("the server’s advice line replaces the console’s own")
    func serverAdvice() {
        let advised = Self.row { $0.state = .diverged; $0.advice = "Linked server 3 took over in term 4." }
        #expect(MirrorModel.advice(advised, linkUp: true, held: 0) == "Linked server 3 took over in term 4.")
        #expect(MirrorModel.advice(advised, linkUp: true, held: 1)?
            .hasPrefix("Linked server 3 took over in term 4. One change made here was refused") == true)
    }

    // MARK: Desktop's own

    @Test("the link is unknown without a server, down once unlinked, else as reported")
    func link() {
        #expect(Self.row().link == .up)
        #expect(Self.row { $0.linkUp = false }.link == .down)
        #expect(Self.row { $0.peer = nil }.link == .unknown)
        #expect(Self.row { $0.peer = nil }.linkIsUp == nil)
        #expect(Self.row { $0.peer?.revoked = true }.link == .unlinked)
        #expect(Self.row { $0.peer?.revoked = true }.linkIsUp == false)
        #expect(MirrorModel.peerName(Self.row { $0.peer?.name = "" }) == "Unnamed server")
        #expect(MirrorModel.peerName(Self.row { $0.peer = nil }) == "no linked server")
    }

    @Test("the list orders live ones first, then starts, orphans and ended ones, by name")
    func order() {
        let rows = [
            Self.row { $0.vaultName = "b"; $0.role = .detached },
            Self.row { $0.vaultName = "z"; $0.role = .core },
            Self.row { $0.vaultName = "a"; $0.role = .orphaned },
            Self.row { $0.vaultName = "c"; $0.role = .starting },
            Self.row { $0.vaultName = "y" },
        ]
        #expect(MirrorModel.sorted(rows).map(\.vaultName) == ["y", "z", "c", "a", "b"])
        #expect(MirrorModel.mirror(of: 5, in: [Self.row { $0.role = .detached }]) == nil)
        #expect(MirrorModel.mirror(of: 5, in: rows)?.vaultName == "z")
    }

    @Test("versions read as the console says them; blank or 0 is no limit")
    func versions() {
        let on = MirroredVault.Settings.Versions(enabled: true, keepLast: 10, maxAgeDays: nil, quotaBytes: 0)
        #expect(MirrorModel.versionsText(on) { "\($0)B" } == "On: 10 versions per file, no limit, no limit.")
        #expect(MirrorModel.versionsText(.init(enabled: false)) { "\($0)B" } == "Off.")
    }

    @Test("a mirror.list row reads like the mirror.get row, every member carried")
    func decodesList() throws {
        let json = """
            {"vaults": [{"vault_id": 7, "vault_name": "Photos", "role": "mirror",
              "peer": {"id": 1, "node_id": "n", "name": "Offsite", "revoked": false}, "term": 3, "last_seq": 12,
              "state": "live", "grant": {"role_name": "Viewer", "files": 1, "directories": 1, "sync": 0, "roles": 0,
                "granted_by_node": "n", "granted_at": 100}, "acked": {"term": 3, "seq": 11}, "created_at": 50,
              "start": null, "switch": null, "takeover": null, "advice": null, "detached": null,
              "rekey_recommended": false, "deleting": null, "stop_reason": null, "pending_changes": 1,
              "first_copy": {"finished": false, "entries_copied": 4, "entries_total": 8}, "link_up": false,
              "confirmed_at": 90, "settings": {"versions": {"enabled": true, "keep_last": 5, "max_age_days": null,
                "quota_bytes": null, "set_by": null, "set_at": null}, "accept_all": true, "keep_removed": false,
                "mirror_all": false}}]}
            """
        let list = try JSONDecoder().decode(Ws.Mirror.List.Response.self, from: Data(json.utf8))
        let row = try #require(list.vaults.first.map(MirroredVault.init))
        #expect(row.role == .mirror)
        #expect(row.state == .live)
        #expect(row.link == .down)
        #expect(row.pendingChanges == 1)
        #expect(row.confirmedAt == 90)
        #expect(row.grant?.roleName == "Viewer")
        #expect(row.firstCopy == .init(finished: false, entriesCopied: 4, entriesTotal: 8))
        #expect(row.settings?.acceptAll == true)
        #expect(row.settings?.versions?.keepLast == 5)
        // An unfinished first copy wins over the link, as on the console.
        #expect(MirrorModel.status(row, .of(row, date: Self.date)).label == "First copy")
    }
}
