#if DEBUG
import Foundation
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: what "Home lab" answers for relinks (`mirror.relink.*`), beside ``MirrorsPreviewData``.
/// `-VHDebugRelink <state>` picks the vault's relink: `requested` (asked, waiting for Offsite's admin to accept),
/// `waiting` (the outcome proposed, awaiting Offsite's approval), `comparison`, `plan` and `confirm` (compared: 63
/// entries differ), `applied` (approved and bringing the chosen versions onto the core), `refused` (the comparison
/// refused for keys that differ, in the server's sentence). `panel`, `approve` and `accept` list two requests
/// Offsite (preview) made of this server's vaults: one asking to compare, one proposing an outcome. Without the flag
/// there is no relink and no request. The server's own sentences (outcome, disclosure) are its words, as built.
nonisolated enum MirrorRelinkPreviewData: PreviewFeature {
    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        switch command {
        case .mirrorRelinkGet, .mirrorRelinkCompare, .mirrorRelinkPlan, .mirrorRelinkApply, .mirrorRelinkEntries,
             .mirrorRelinkPending, .mirrorRelinkAccept, .mirrorRelinkDecline, .mirrorRelinkApprove:
            guard transport.scenario == .full else { throw .denied("only super admins may manage mirrored vaults") }
        default:
            return nil
        }
        let state = UserDefaults.standard.string(forKey: "VHDebugRelink") ?? ""
        switch command {
        case .mirrorRelinkGet:
            let id = (payload as? Ws.Mirror.Relink.Get.Payload)?.vaultID ?? 0
            return try decode(Ws.Mirror.Relink.Get.Response.self, status(id, state))
        case .mirrorRelinkCompare:
            let id = (payload as? Ws.Mirror.Relink.Compare.Payload)?.vaultID ?? 0
            if state == "refused" {
                throw .refused(code: "mirror_relink_keys",
                               message: "The vault's key was rotated on server 'Offsite (preview)' since the mirror ended (version 3 there, 2 here): a relink moves no key, so this needs a new mirror.")
            }
            return try decode(Ws.Mirror.Relink.Compare.Response.self, status(id, state.isEmpty ? "requested" : state))
        case .mirrorRelinkPlan:
            let id = (payload as? Ws.Mirror.Relink.Plan.Payload)?.vaultID ?? 0
            return try decode(Ws.Mirror.Relink.Plan.Response.self, status(id, "comparison"))
        case .mirrorRelinkApply:
            let id = (payload as? Ws.Mirror.Relink.Apply.Payload)?.vaultID ?? 0
            return try decode(Ws.Mirror.Relink.Apply.Response.self, status(id, "waiting"))
        case .mirrorRelinkEntries:
            let p = payload as? Ws.Mirror.Relink.Entries.Payload
            return try decode(Ws.Mirror.Relink.Entries.Response.self,
                              entries(p?.vaultID ?? 0, kind: p?.kind?.rawValue, offset: p?.offset ?? 0))
        case .mirrorRelinkPending:
            let list = ["panel", "approve", "accept"].contains(state) ? requests : []
            return try decode(Ws.Mirror.Relink.Pending.Response.self, #"{"requests": [\#(list.joined(separator: ","))]}"#)
        case .mirrorRelinkAccept:
            return try decode(Ws.Mirror.Relink.Accept.Response.self, request(15, "Old Laptop (preview)", phase: "accepted"))
        case .mirrorRelinkDecline:
            return try decode(Ws.Mirror.Relink.Decline.Response.self, request(15, "Old Laptop (preview)", phase: "declined"))
        case .mirrorRelinkApprove:
            return try decode(Ws.Mirror.Relink.Approve.Response.self, request(20, "Contracts (preview)", phase: "approved"))
        default:
            return nil
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws(WsError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw .contractMismatch("preview \(T.self): \(error)")
        }
    }

    // MARK: The relink

    private static let gains = (this: #"{"takes": 23, "keeps_held": 35, "conflict_copies": 2}"#,
                                theirs: #"{"takes": 35, "keeps_held": 23, "conflict_copies": 0}"#)

    private static func status(_ vaultID: Int64, _ state: String) -> String {
        let now = PreviewData.now
        let phase: String? = switch state {
        case "requested": "requested"
        case "waiting": "proposed"
        case "comparison", "plan", "confirm": "open"
        case "applied": "bring"
        default: nil
        }
        guard let phase else { return #"{"vault_id": \#(vaultID), "relink": null}"# }
        let relink = """
            {"id": 3, "relink_uid": "preview-relink", "side": "initiator", "phase": "\(phase)", "mode": "plan",
             "core": "this", "default_choice": null, "role": null, "term": null, "error": null,
             "by": {"node": "preview-home-lab", "id": 1, "name": "cooper"}, "created_at": \(now - 600),
             "applied_at": null, "finished_at": null}
            """
        let compared = phase == "open" || phase == "proposed" || phase == "bring"
        let counts = compared
            ? #"{"only_this": 12, "only_theirs": 9, "changed_this": 21, "changed_theirs": 14, "changed_both": 4, "differs": 3, "total": 63, "same": 3057}"#
            : "{}"
        let plan = compared
            ? #"{"this": \#(gains.this), "theirs": \#(gains.theirs), "chosen": {"core": 58, "mirror": 3, "both": 2}, "core": "this", "default_choice": null}"#
            : "null"
        let proposal = phase == "proposed"
            ? #"{"plan_hash": "preview", "core": "this", "mode": "plan", "this": \#(gains.this), "theirs": \#(gains.theirs), "chosen": {"core": 58, "mirror": 3, "both": 2}, "entries": 63}"#
            : "null"
        let waiting = phase == "requested" || phase == "proposed" ? #""other_admin""# : "null"
        let progress = phase == "bring"
            ? #"{"bring_total": 3120, "bring_done": 1204, "executed": 1204, "refused": 0, "kept": 35, "row": null}"#
            : "null"
        return """
            {"vault_id": \(vaultID), "relink": \(relink),
             "peer": {"id": 1, "name": "Offsite (preview)", "node": "preview-offsite-node"},
             "counts": \(counts), "blockers": [], \(compared ? #""plan": \#(plan),"# : "")
             \(progress == "null" ? "" : #""progress": \#(progress),"#)
             "handshake": {"waiting_for": \(waiting), "expires_at": \(now + 86_400 - 600), "accepted_at": null,
              "accepted_by": \(phase == "requested" ? "null" : #""admin""#), "approved_at": null,
              "approved_by": \(phase == "bring" ? #""admin""# : "null"), "proposal": \(proposal), "outcome": null,
              "discloses": null}}
            """
    }

    // MARK: Entries

    private static let paths: [(String, String, String?, String?)] = [
        ("changed_this", "/Clients/Acme/2026 retainer.pdf", "file", "file"),
        ("changed_theirs", "/Clients/Acme/Invoices/2026-10.pdf", "file", "file"),
        ("changed_both", "/Templates/NDA (mutual).docx", "file", "file"),
        ("only_this", "/Clients/Northwind/Statement of work.pdf", "file", nil),
        ("only_theirs", "/Clients/Globex", nil, "directory"),
        ("differs", "/Archive/2024/Signed/Lease renewal with the long name that wraps.pdf", "file", "file"),
        ("changed_this", "/Clients/Initech/Change order 3.pdf", "file", "file"),
        ("only_theirs", "/Clients/Globex/Master services agreement.pdf", nil, "file"),
    ]

    private static func entries(_ vaultID: Int64, kind: String?, offset: Int64) -> String {
        let total: Int64 = kind == nil ? 63 : 9
        let count = max(0, min(50, total - offset))
        let rows = (0..<count).map { i -> String in
            let (k, path, this, theirs) = paths[Int((offset + i) % Int64(paths.count))]
            let n = offset + i
            let version = { (kind: String?) in
                kind.map { #"{"kind": "\#($0)", "trashed": false, "path": "\#(path)", "hash": "h\#(n)", "name": "x", "parent": null}"# } ?? "null"
            }
            let choice = n == 2 ? #""both""# : (n == 4 ? #""theirs""# : "null")
            return """
                {"uid": "entry-\(n)", "kind": "\(kind ?? k)", "aspects": \(k.hasPrefix("changed") || k == "differs" ? #"["contents"]"# : "[]"),
                 "path": "\(n < paths.count ? path : path.replacingOccurrences(of: ".pdf", with: " \(n).pdf"))",
                 "this": \(version(this)), "theirs": \(version(theirs)), "choice": \(choice),
                 "resolution": "\(k == "changed_theirs" || k == "only_theirs" ? "mirror" : "core")", "outcome": null, "outcome_note": null}
                """
        }
        return #"{"vault_id": \#(vaultID), "relink_id": 3, "total": \#(total), "offset": \#(offset), "entries": [\#(rows.joined(separator: ","))]}"#
    }

    // MARK: Requests

    private static let discloses =
        "Accepting lets server 'Offsite (preview)' read this vault's file and folder names, their places, sizes and hashes, and what is in its trash (never a file's contents), to compare them with its copy. Nothing changes here until you approve an outcome it proposes."
    private static let outcome =
        "server 'Offsite (preview)' becomes the vault's core and this server its mirror; a plan decides each drifted entry. Here: 35 entries take server 'Offsite (preview)''s version (replaced, added or removed here); 23 of this server's versions leave its tree and are kept as held changes (with their bytes) or in the core's trash; 0 conflict copies are added. Nothing is dropped."

    private static let requests: [String] = [
        request(15, "Old Laptop (preview)", phase: "requested"),
        request(20, "Contracts (preview)", phase: "proposed"),
    ]

    private static func request(_ vaultID: Int64, _ name: String, phase: String) -> String {
        let now = PreviewData.now
        let proposed = phase == "proposed" || phase == "approved"
        let proposal = proposed
            ? #"{"plan_hash": "preview", "core": "theirs", "mode": "plan", "this": \#(gains.theirs), "theirs": \#(gains.this), "chosen": {"core": 58, "mirror": 3, "both": 2}, "entries": 63}"#
            : "null"
        return """
            {"vault_id": \(vaultID), "vault_name": "\(name)", "relink_uid": "preview-request-\(vaultID)", "phase": "\(phase)",
             "peer": {"id": 1, "name": "Offsite (preview)", "node": "preview-offsite-node"}, "asked_by": "maria",
             "status": "\(vaultID == 15 ? "rejoining" : "detached")", "created_at": \(now - 1_800),
             "handshake": {"waiting_for": "this_admin", "expires_at": \(now + 86_400 - 1_800),
              "accepted_at": \(proposed ? String(now - 1_200) : "null"), "accepted_by": \(proposed ? #""cooper""# : "null"),
              "approved_at": null, "approved_by": null, "proposal": \(proposal),
              "outcome": \(proposed ? "\"\(outcome)\"" : "null"), "discloses": "\(discloses)"}}
            """
    }
}
#endif
