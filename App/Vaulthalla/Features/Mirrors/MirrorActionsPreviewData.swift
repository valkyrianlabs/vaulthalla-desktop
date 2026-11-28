#if DEBUG
import Foundation
import Synchronization
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: the mirror actions' answers, beside the read answers in `MirrorsPreviewData` (which
/// asks these for every command it doesn't answer itself). Nothing here reaches a node.
///
/// - Switch: "Family Photos" (1) is refused for want of a role until the box is ticked, then switches with no access
///   for the old core; "Documents" (2) is refused because its link is down; the others switch.
/// - Take over: "Documents" (2) takes over; "Home Videos" (22) is refused (its core still answers); "Tax Records" (12)
///   needs a step-up this Mac can't give.
/// - Resync, detach, versions and ending answer as the server would; ending "Shared Music" (13) needs a step-up.
/// - Detach a copy: "Archive 2019" (17) has a copy running since launch; "Design Assets" (11) finished one two days
///   ago; a copy started here runs about 25 seconds, and cancelling one ends it cancelled.
extension MirrorsPreviewData {
    static func actionAnswer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        switch command {
        case .mirrorSwitch, .mirrorTakeover, .mirrorResync, .mirrorDetach, .mirrorDetachCopy, .mirrorDetachCopyGet,
             .mirrorDetachCopyCancel, .mirrorVersionsSet, .mirrorCancel:
            guard transport.scenario == .full else { throw .denied("only super admins may manage mirrored vaults") }
        default:
            return nil
        }
        let now = PreviewData.now
        switch command {
        case .mirrorSwitch:
            guard let p = payload as? Ws.Mirror.Switch.Payload else { throw .invalid("Bad payload.") }
            switch p.vaultID {
            case 1 where p.acceptNoAccess != true:
                throw .refused(code: "mirror_switch_no_role",
                               message: "Offsite (preview) gives this server no role on “Family Photos (preview)”: after the switch, nobody here could open it.")
            case 2:
                throw .refused(code: "peer_link_down", message: "The link to Offsite (preview) is down, so the switch can't start.")
            default:
                let none = p.acceptNoAccess == true
                return try actionDecode(Ws.Mirror.Switch.Response.self, """
                    {"vault_id": \(p.vaultID), "switch_id": "preview-switch", "outcome": "switched", "role": "mirror",
                     "role_term": 5, "side": "core", "phase": "switched", "term": 4, "seq": 1284, "digest": null,
                     "entries": 3120, "told": true, "asked_on": "core", "asked_by": null, "reason": null, "detail": {},
                     "deadline": \(now + 60), "created_at": \(now - 4), "ended_at": \(now),
                     "peer_role": \(none ? "null" : #"{"role_name": "Mirror readers", "files": 1, "directories": 1, "sync": 0, "roles": 0}"#),
                     "peer_access": "\(none ? "none" : "read-only")"}
                    """)
            }

        case .mirrorTakeover:
            guard let p = payload as? Ws.Mirror.Takeover.Payload else { throw .invalid("Bad payload.") }
            switch p.vaultID {
            case 22:
                throw .refused(code: "mirror_core_reachable",
                               message: "Offsite (preview) still answers, so this server can't take over. Switch the core instead.")
            case 12:
                throw .stepUpRequired(.init(family: "data.destroy", target: "vault:12", methods: ["console_approval"]),
                                      message: "Taking over as a vault’s core needs a fresh approval of data.destroy.")
            default:
                return try actionDecode(Ws.Mirror.Takeover.Response.self, """
                    {"id": 4, "vault_id": \(p.vaultID), "peer_id": 1, "from_term": 2, "term": 3,
                     "fork": {"term": 2, "seq": 609, "digest": "preview", "entries": 3120}, "fork_rows": 3120,
                     "pending_made_local": 2, "held": 1, "contents_missing": 0, "by": {"id": 1, "name": "cooper"},
                     "created_at": \(now), "settled_at": null, "settled_how": null, "detail": {},
                     "warning": "Offsite (preview) may hold changes this server never received.", "fork_base_matches": true}
                    """)
            }

        case .mirrorResync:
            guard let p = payload as? Ws.Mirror.Resync.Payload else { throw .invalid("Bad payload.") }
            let held: Int64 = switch p.vaultID {
            case 12: 3
            case 15, 16: 4
            default: 0
            }
            return Ws.Mirror.Resync.Response(vaultID: p.vaultID, state: "starting", copyFinished: false, term: 6,
                                             held: held, entries: 3120)

        case .mirrorDetach:
            guard let p = payload as? Ws.Mirror.Detach.Payload else { throw .invalid("Bad payload.") }
            guard case .value(let typed)? = p.confirmName, Self.rows.contains(where: { $0.contains(#""vault_name": "\#(typed)""#) })
            else { throw .refused(code: "mirror_name_mismatch", message: "That is not the vault's name.") }
            return try actionDecode(Ws.Mirror.Detach.Response.self, detached(p.vaultID))

        case .mirrorDetachCopy:
            guard let p = payload as? Ws.Mirror.Detach.Copy.Payload else { throw .invalid("Bad payload.") }
            let name: String = if case .value(let n)? = p.name { n } else { "\(Self.vaultName(p.vaultID)) copy" }
            let job = PreviewCopyJob(id: Int64.random(in: 100...999), name: name, startedAt: Date.now)
            previewCopies.withLock { $0[p.vaultID] = job }
            return try actionDecode(Ws.Mirror.Detach.Copy.Response.self, #"{"copy": \#(job.json(p.vaultID))}"#)

        case .mirrorDetachCopyGet:
            guard let p = payload as? Ws.Mirror.Detach.Copy.Get.Payload else { throw .invalid("Bad payload.") }
            let job = previewCopies.withLock { $0[p.vaultID] }
            return try actionDecode(Ws.Mirror.Detach.Copy.Get.Response.self,
                                    #"{"copy": \#(job.map { $0.json(p.vaultID) } ?? "null")}"#)

        case .mirrorDetachCopyCancel:
            guard let p = payload as? Ws.Mirror.Detach.Copy.Cancel.Payload else { throw .invalid("Bad payload.") }
            let job = previewCopies.withLock { copies -> PreviewCopyJob? in
                guard var job = copies[p.vaultID], job.state == "running" else { return nil }
                job.cancelledAt = .now
                copies[p.vaultID] = job
                return job
            }
            guard let job else { throw .refused(code: "mirror_copy_not_running", message: "No copy of this vault is running.") }
            return try actionDecode(Ws.Mirror.Detach.Copy.Cancel.Response.self, #"{"copy": \#(job.json(p.vaultID))}"#)

        case .mirrorVersionsSet:
            guard let p = payload as? Ws.Mirror.Versions.Set.Payload else { throw .invalid("Bad payload.") }
            let limit = { (v: Nullable<Int64>?, fallback: Int64?) -> Int64? in
                if case .value(let n)? = v { return n }
                return fallback
            }
            return Ws.Mirror.Versions.Set.Response(versions: .init(
                enabled: p.enabled, keepLast: p.enabled ? limit(p.keepLast, 10) : nil,
                maxAgeDays: p.enabled ? limit(p.maxAgeDays, 30) : nil, quotaBytes: p.enabled ? limit(p.quotaBytes, nil) : nil,
                setBy: 1, setAt: now))

        case .mirrorCancel:
            guard let p = payload as? Ws.Mirror.Cancel.Payload else { throw .invalid("Bad payload.") }
            if p.vaultID == 13 {
                throw .stepUpRequired(.init(family: "data.destroy", target: "vault:13", methods: ["console_approval"]),
                                      message: "Ending a mirror needs a fresh approval of data.destroy.")
            }
            let side = p.vaultID == 17 ? "mirror" : "core"
            return try actionDecode(Ws.Mirror.Cancel.Response.self, """
                {"side": "\(side)", "vault_id": \(p.vaultID.map(String.init) ?? "null"), "removed": \(p.vaultID == 17),
                 "remove_copy": \(p.removeCopy == true), "offer": null}
                """)

        default:
            return nil
        }
    }

    private static func actionDecode<T: Decodable>(_ type: T.Type, _ json: String) throws(WsError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw .contractMismatch("preview \(T.self): \(error)")
        }
    }

    private static func vaultName(_ id: Int64) -> String {
        let row = rows.first { $0.hasPrefix(#"{"vault_id": \#(id),"#) } ?? ""
        guard let range = row.range(of: #""vault_name": ""#) else { return "Vault \(id)" }
        return String(row[range.upperBound...].prefix { $0 != "\"" })
    }

    private static func detached(_ id: Int64) -> String {
        let now = PreviewData.now
        let missing: Int64 = id == 17 ? 12 : id == 3 ? 2_160 : 0
        return """
            {"detached": {"vault_id": \(id), "owner_id": 1, "missing": \(missing), "pending_kept": 2, "pending_held": 0,
             "core_told": "told",
             "record": {"id": 9, "side": "mirror", "vault_id": \(id), "peer_id": 1, "fork": {"term": 2, "seq": 609},
              "digest_matched": true, "was_state": "live", "missing": \(missing), "owner_id": 1, "detached_by": 1,
              "detached_at": \(now), "rekeyed_at": null, "rekey_recommended": true},
             "before": {"vault_id": \(id), "vault_name": "\(vaultName(id))", "role": "mirror", "state": "live",
              "stop_reason": null, "peer": null, "link_up": true,
              "first_copy": {"finished": true, "entries_copied": 3120, "entries_total": 3120},
              "applied": {"term": 2, "seq": 609}, "confirmed": {"term": 2, "seq": 609}, "digest_matched": true,
              "pending_changes": 2, "held_changes": 0, "missing_count": \(missing), "missing": [], "owner_id": 1}}}
            """
    }

    /// The copies "written" here, by held vault.
    nonisolated static let previewCopies = Mutex<[Int64: PreviewCopyJob]>([
        17: PreviewCopyJob(id: 51, name: "Archive 2019 (preview) copy", startedAt: Date.now.addingTimeInterval(-9),
                           duration: 120),
        11: PreviewCopyJob(id: 33, name: "Design Assets (preview) copy",
                           startedAt: Date.now.addingTimeInterval(-86_400 * 2), duration: 600),
    ])
}

/// A pretend copy job: it runs for `duration`, then finishes with the files whose contents never arrived left out.
nonisolated struct PreviewCopyJob: Sendable {
    var id: Int64
    var name: String
    var startedAt: Date
    var duration: TimeInterval = 25
    var cancelledAt: Date?

    static let entries: Int64 = 3_120
    static let bytes: Int64 = 8_400_000_000

    private var fraction: Double {
        min(1, max(0, (cancelledAt ?? .now).timeIntervalSince(startedAt) / duration))
    }

    var state: String {
        if cancelledAt.map({ Date.now.timeIntervalSince($0) > 1.5 }) == true { return "cancelled" }
        return fraction >= 1 ? "finished" : "running"
    }

    func json(_ vaultID: Int64) -> String {
        let f = fraction
        let state = state
        let started = Int64(startedAt.timeIntervalSince1970)
        let ended = state == "running" ? "null" : String(started + Int64(duration))
        let skippedPaths = ["Scans/1998/roll-04.tiff", "Scans/1998/roll-05.tiff", "Mail/archive-2019.mbox"]
        let skipped = state == "finished" && vaultID == 17 || vaultID == 11
            ? skippedPaths.map { #"{"path": "\#($0)", "size_bytes": 48211000, "reason": "contents_missing"}"# }
            : []
        return """
            {"id": \(id), "source_vault_id": \(vaultID), "vault_id": \(state == "cancelled" ? "null" : "4\(vaultID)"),
             "name": "\(name)", "owner_id": 1, "state": "\(state)", "entries_total": \(Self.entries),
             "entries_done": \(Int64(Double(Self.entries) * f)), "bytes_total": \(Self.bytes),
             "bytes_done": \(Int64(Double(Self.bytes) * f)), "skipped_count": \(skipped.isEmpty ? 0 : 12),
             "skipped": [\(skipped.joined(separator: ","))], "error": null, "requested_by": 1,
             "cancel_requested": \(cancelledAt != nil), "attempts": 1, "created_at": \(started),
             "updated_at": \(Int64(Date.now.timeIntervalSince1970)), "finished_at": \(ended)}
            """
    }
}
#endif
