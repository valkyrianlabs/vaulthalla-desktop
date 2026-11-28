import Foundation
import Testing
import VHContract
import VHTransport
@testable import VHNodes

/// The action sheets' requests and what each answer leaves on screen, matching the web console's dialogs
/// (`web/src/features/mirrors/*Dialog.tsx`, server main).
@Suite("Mirrored vault actions")
struct MirrorActionsTests {
    static func row(_ edit: (inout MirroredVault) -> Void = { _ in }) -> MirroredVault {
        MirrorModelTests.row(edit)
    }

    static func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func switchResponse(outcome: String, reason: String? = nil, access: String = "read-only",
                               role: String? = "Mirror readers") throws -> Ws.Mirror.Switch.Response {
        let q = { (s: String?) in s.map { "\"\($0)\"" } ?? "null" }
        let peerRole = role.map { #"{"role_name": "\#($0)", "files": 1, "directories": 1, "sync": 0, "roles": 0}"# } ?? "null"
        return try decode(Ws.Mirror.Switch.Response.self, """
            {"vault_id": 5, "switch_id": "s-1", "outcome": "\(outcome)", "role": "mirror", "role_term": 3,
             "side": "core", "phase": "\(outcome)", "term": 2, "seq": 40, "digest": null, "entries": 10, "told": true,
             "asked_on": "core", "asked_by": null, "reason": \(q(reason)), "detail": {}, "deadline": 0,
             "created_at": 0, "ended_at": null, "peer_role": \(peerRole), "peer_access": "\(access)"}
            """)
    }

    // MARK: Requests

    @Test("take over and detach send nothing until the vault's name is typed exactly")
    func typedName() throws {
        let row = Self.row()
        #expect(MirrorActions.takeoverPayload(row, typed: "projects") == nil)
        #expect(MirrorActions.takeoverPayload(row, typed: "Projects ") == nil)
        #expect(MirrorActions.takeoverPayload(row, typed: "") == nil)
        let takeover = try #require(MirrorActions.takeoverPayload(row, typed: "Projects"))
        #expect(NSDictionary(dictionary: try Self.json(takeover)) == ["vault_id": 5, "confirm": "Projects"])

        #expect(MirrorActions.detachPayload(row, owner: "", typed: "Project") == nil)
        let detach = try #require(MirrorActions.detachPayload(row, owner: "", typed: "Projects"))
        let sent = try Self.json(detach)
        #expect(sent["vault_id"] as? Int == 5)
        #expect(sent["confirm_name"] as? String == "Projects")
        // A blank owner is the caller, sent as null (the console's `owner || null`).
        #expect(sent["owner"] is NSNull)
        let owned = try Self.json(try #require(MirrorActions.detachPayload(row, owner: "alice", typed: "Projects")))
        #expect(owned["owner"] as? String == "alice")
        // An unnamed vault can never be confirmed by an empty field.
        #expect(MirrorActions.detachPayload(Self.row { $0.vaultName = "" }, owner: "", typed: "") == nil)
    }

    @Test("switch sends accept_no_access only after the refusal and the person's tick")
    func switchRequest() throws {
        let row = Self.row { $0.role = .core }
        var flow = MirrorActions.SwitchFlow()
        #expect(flow.canConfirm)
        #expect(try Self.json(flow.payload(row))["accept_no_access"] == nil)
        // Ticking before any refusal sends nothing extra.
        flow.acceptNoAccess = true
        #expect(try Self.json(flow.payload(row))["accept_no_access"] == nil)
        flow.acceptNoAccess = false

        flow.failed(.refused(code: "mirror_switch_no_role", message: "vps gives this server no role on it."))
        #expect(flow.noRole == "vps gives this server no role on it.")
        #expect(flow.failure == nil)
        #expect(!flow.canConfirm)
        #expect(try Self.json(flow.payload(row))["accept_no_access"] == nil)
        flow.acceptNoAccess = true
        #expect(flow.canConfirm)
        #expect(try Self.json(flow.payload(row))["accept_no_access"] as? Bool == true)

        // Any other refusal is shown as the server's sentence, and keeps the form.
        flow.failed(.refused(code: "peer_link_down", message: "The link to vps is down."))
        #expect(flow.failure?.message == "The link to vps is down.")
        #expect(flow.outcome == nil)
    }

    @Test("the switch's outcome says who is the core now and what the old core keeps")
    func switchOutcome() throws {
        var flow = MirrorActions.SwitchFlow()
        let core = Self.row { $0.role = .core }
        flow.answered(try Self.switchResponse(outcome: "switched"), row: core)
        #expect(flow.outcome == .switched(body: "vps is the vault’s core now.",
                                          access: "This server keeps read-only access through the role “Mirror readers”."))

        var mirror = MirrorActions.SwitchFlow()
        mirror.answered(try Self.switchResponse(outcome: "switched", access: "none", role: nil), row: Self.row())
        #expect(mirror.outcome == .switched(body: "This server is the vault’s core now.",
                                            access: "vps keeps no access until a role is set for it."))

        var rw = MirrorActions.SwitchFlow()
        rw.answered(try Self.switchResponse(outcome: "switched", access: "read-write", role: nil), row: Self.row())
        #expect(rw.outcome == .switched(body: "This server is the vault’s core now.", access: "vps keeps read and write access."))

        var abandoned = MirrorActions.SwitchFlow()
        abandoned.answered(try Self.switchResponse(outcome: "abandoned", reason: "mirror_link_down"), row: core)
        #expect(abandoned.outcome == .abandoned(body: "Nothing changed: the link to the other server is down."))
        var unknownReason = MirrorActions.SwitchFlow()
        unknownReason.answered(try Self.switchResponse(outcome: "abandoned", reason: "mirror_switch_timeout"), row: core)
        #expect(unknownReason.outcome == .abandoned(body: "Nothing changed: mirror_switch_timeout."))

        var running = MirrorActions.SwitchFlow()
        running.answered(try Self.switchResponse(outcome: "running"), row: core)
        #expect(running.outcome == .running)
    }

    @Test("ending, cancelling a start and removing an orphaned copy name the right thing")
    func cancelRequests() throws {
        let end = try Self.json(MirrorActions.endPayload(Self.row { $0.role = .core }, removeCopy: false))
        #expect(NSDictionary(dictionary: end) == ["vault_id": 5, "remove_copy": false])
        #expect(try Self.json(MirrorActions.endPayload(Self.row { $0.role = .core }, removeCopy: true))["remove_copy"] as? Bool == true)

        let orphan = try Self.json(MirrorActions.cancelPayload(Self.row { $0.role = .orphaned }))
        #expect(NSDictionary(dictionary: orphan) == ["vault_id": 5])
        let offer = try Self.json(MirrorActions.cancelPayload(Self.row {
            $0.vaultID = 0
            $0.role = .starting
            $0.start = MirrorModelTests.start(side: "mirror", id: 41)
        }))
        #expect(NSDictionary(dictionary: offer) == ["offer": 41])
    }

    @Test("detach a copy sends a trimmed name and owner, blank ones as null")
    func copyRequest() throws {
        let blank = try Self.json(MirrorActions.copyPayload(Self.row(), name: "  ", owner: ""))
        #expect(blank["vault_id"] as? Int == 5)
        #expect(blank["name"] is NSNull && blank["owner"] is NSNull)
        let named = try Self.json(MirrorActions.copyPayload(Self.row(), name: " Projects 2026 ", owner: "bob"))
        #expect(named["name"] as? String == "Projects 2026")
        #expect(named["owner"] as? String == "bob")
        #expect(NSDictionary(dictionary: try Self.json(MirrorActions.resyncPayload(Self.row()))) == ["vault_id": 5])
    }

    @Test("versions: off sends only enabled; on sends the limits, blank as the defaults; a bad limit sends nothing")
    func versions() throws {
        let off = try Self.json(try #require(MirrorActions.versionsPayload(Self.row(), enabled: false, keepLast: "x",
                                                                           maxAge: "", quota: "")))
        #expect(NSDictionary(dictionary: off) == ["vault_id": 5, "enabled": false])
        let on = try Self.json(try #require(MirrorActions.versionsPayload(Self.row(), enabled: true, keepLast: "5",
                                                                          maxAge: "", quota: " 0 ")))
        #expect(on["keep_last"] as? Int == 5)
        #expect(on["max_age_days"] is NSNull)
        #expect(on["quota_bytes"] as? Int == 0)
        #expect(MirrorActions.versionsPayload(Self.row(), enabled: true, keepLast: "-1", maxAge: "", quota: "") == nil)
        #expect(MirrorActions.versionsPayload(Self.row(), enabled: true, keepLast: "1.5", maxAge: "", quota: "") == nil)
        #expect(MirrorActions.Limit("１２").error == "A whole number, 0 or more.")
        #expect(MirrorActions.Limit("1234567890123456").error != nil)
        #expect(MirrorActions.Limit("") == .value(nil))

        let saved = try Self.decode(Ws.Mirror.Versions.Set.Response.self, #"""
            {"versions": {"enabled": true, "keep_last": 10, "max_age_days": 0, "quota_bytes": null, "set_by": 1, "set_at": 2}}
            """#)
        #expect(MirrorActions.versionsText(saved.versions) { "\($0) B" } == "On: 10 versions per file, no limit, no limit.")
    }

    // MARK: Answers

    @Test("take over: what became of the changes made here, the files missing, the server's warning")
    func takeover() throws {
        let response = try Self.decode(Ws.Mirror.Takeover.Response.self, """
            {"id": 1, "vault_id": 5, "peer_id": 3, "from_term": 2, "term": 3,
             "fork": {"term": 2, "seq": 40, "digest": "d", "entries": 10}, "fork_rows": 10, "pending_made_local": 2,
             "held": 1, "contents_missing": 3, "by": {"id": 1, "name": "cooper"}, "created_at": 0, "settled_at": null,
             "settled_how": null, "detail": {}, "warning": "vps may hold changes.", "fork_base_matches": true}
            """)
        let outcome = MirrorActions.TakeoverOutcome(response)
        #expect(outcome.body == "2 changes made here became ordinary changes; 1 held change stays listed.")
        #expect(outcome.missing == "3 files’ contents never arrived here; they stay listed, marked missing.")
        #expect(outcome.warning == "vps may hold changes.")
        #expect(MirrorCopy.tookOverBody(made: 1, held: 0) == "1 change made here became ordinary changes.")
    }

    @Test("the detach preview reads as the console's list")
    func detachPreview() throws {
        let preview = try Self.decode(Ws.Mirror.Detach.Preview.Response.self, """
            {"preview": {"vault_id": 5, "vault_name": "Projects", "role": "mirror", "state": "live", "stop_reason": null,
             "peer": null, "link_up": true, "first_copy": {"finished": false, "entries_copied": 120, "entries_total": 4000},
             "applied": {"term": 2, "seq": 40}, "confirmed": null, "digest_matched": null, "pending_changes": 1,
             "held_changes": 2, "missing_count": 1200, "missing": [], "owner_id": 1}}
            """).preview
        #expect(MirrorActions.detachLines(preview) == [
            "The first copy isn’t finished: 120 of 4,000 entries are here.",
            "1 change made here and not yet confirmed becomes an ordinary change.",
            "2 held changes stay listed.",
            "It keeps the original’s keys until it is re-keyed.",
        ])
        #expect(MirrorActions.takeoverLines(preview) == [
            "1 change made here becomes an ordinary change.",
            "1,200 files’ contents never arrived here; they stay listed, marked missing.",
        ])
        #expect(MirrorCopy.detachMissingTitle(1_200) == "1,200 files’ contents aren’t here")
    }

    @Test("a copy job: one shape from every answer, its progress, and what the sheet shows")
    func copyJob() throws {
        let get = try Self.decode(Ws.Mirror.Detach.Copy.Get.Response.self, """
            {"copy": {"id": 7, "source_vault_id": 5, "vault_id": 30, "name": "Projects copy", "owner_id": 1,
             "state": "running", "entries_total": 400, "entries_done": 120, "bytes_total": 3000, "bytes_done": 1200,
             "skipped_count": 1, "skipped": [{"path": "/a.jpg", "size_bytes": 5, "reason": "contents_missing"}],
             "error": null, "requested_by": 1, "cancel_requested": false, "attempts": 1, "created_at": 0,
             "updated_at": 10, "finished_at": null}}
            """)
        let job = try #require(get.copy.flatMap(MirrorCopyJob.init))
        #expect(job.isRunning && job.vaultID == 30 && job.skipped.first?.path == "/a.jpg")
        let progress = job.progress { "\($0) B" }
        #expect(progress.ratio == 0.4)
        #expect(progress.text == "120 of 400 entries · 1200 B of 3000 B")
        var noTotals = job
        noTotals.bytesTotal = 0
        noTotals.entriesTotal = 0
        #expect(noTotals.progress { "\($0)" }.ratio == nil)
        #expect(noTotals.progress { "\($0)" }.text == "120 entries so far")
        #expect(MirrorCopyJob.skipText("removed") == "it was removed while the copy ran")
        #expect(MirrorCopyJob.skipText("mirror_new_reason") == "mirror_new_reason")

        // A running job shows whoever started it; an ended one only if this sheet started it.
        var finished = job
        finished.state = .finished
        #expect(MirrorCopyJob.shown(read: job, started: nil, followed: nil).shown == job)
        #expect(MirrorCopyJob.shown(read: finished, started: nil, followed: nil).shown == nil)
        #expect(MirrorCopyJob.shown(read: finished, started: nil, followed: nil).latest == finished)
        #expect(MirrorCopyJob.shown(read: finished, started: nil, followed: 7).shown == finished)
        // Until the read catches up with the copy just started, the start's answer stands in for it.
        var started = job
        started.id = 8
        let stale = MirrorCopyJob.shown(read: finished, started: started, followed: 8)
        #expect(stale.shown == started)
        #expect(MirrorCopyJob.shown(read: nil, started: started, followed: 8).shown == started)
        // An unknown state from a newer daemon never reads as running.
        #expect(!MirrorCopyJob(id: 1, name: "x", state: .other("paused")).isRunning)
    }

    @Test("a vault's deletion asks about the mirror on its core, and refuses a copy held here")
    func deletion() {
        #expect(MirrorActions.deletion(role: .core, choiceRequired: false) == .choose)
        #expect(MirrorActions.deletion(role: nil, choiceRequired: true) == .choose)
        #expect(MirrorActions.deletion(role: .none, choiceRequired: false) == .none)
        #expect(MirrorActions.deletion(role: .mirror, choiceRequired: true) == .heldCopy)
        #expect(MirrorActions.deletion(role: .orphaned, choiceRequired: false) == .orphan)
        #expect(MirrorActions.deletion(role: .detached, choiceRequired: false) == .none)
    }

    @Test("the switch names its sides as the console does")
    func sides() {
        #expect(MirrorActions.switchSides(Self.row { $0.role = .core }) == ("this server", "vps"))
        #expect(MirrorActions.switchSides(Self.row()) == ("vps", "this server"))
        #expect(MirrorActions.capitalized(MirrorCopy.switchBody(from: "vps", to: "this server"))
            .hasPrefix("This server becomes the vault’s core and vps keeps a copy."))
        #expect(MirrorActions.capitalized("vps keeps a copy.") == "vps keeps a copy.")
    }
}
