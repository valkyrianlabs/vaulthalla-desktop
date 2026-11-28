#if DEBUG
import Foundation
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: "Home lab" mirrors vaults with "Offsite (preview)" (linked, `peer.list` id 1) and once
/// did with "Old NAS (preview)" (unlinked). The rows cover every role and state, a link that is down, pending
/// changes, a first copy in progress, a core deleting its vault, a take over, starts and a detached copy.
/// `-VHDebugMirrorsEmpty YES` answers an empty list. "Studio" isn't a super admin and is refused.
nonisolated enum MirrorsPreviewData: PreviewFeature {
    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        switch command {
        case .mirrorList:
            try superAdmin(transport)
            let rows = UserDefaults.standard.bool(forKey: "VHDebugMirrorsEmpty") ? [] : Self.rows
            return try decode(Ws.Mirror.List.Response.self, #"{"vaults": [\#(rows.joined(separator: ","))]}"#)
        case .mirrorGet:
            try superAdmin(transport)
            let id = (payload as? Ws.Mirror.Get.Payload)?.vaultID ?? 0
            let row = Self.rows.first { $0.hasPrefix(#"{"vault_id": \#(id),"#) }
                ?? Self.row(id, "Vault \(id)", role: "none", state: nil, peer: nil)
            return try decode(Ws.Mirror.Get.Response.self, #"{"vault": \#(row)}"#)
        case .mirrorDetachPreview:
            try superAdmin(transport)
            let id = (payload as? Ws.Mirror.Detach.Preview.Payload)?.vaultID ?? 0
            return try decode(Ws.Mirror.Detach.Preview.Response.self, preview(id))
        default:
            return nil
        }
    }

    private static func superAdmin(_ transport: PreviewTransport) throws(WsError) {
        guard transport.scenario == .full else { throw .denied("only super admins may manage mirrored vaults") }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws(WsError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw .contractMismatch("preview \(T.self): \(error)")
        }
    }

    // MARK: Rows

    private static let offsite = #"{"id": 1, "node_id": "preview-offsite-node", "name": "Offsite (preview)", "revoked": false}"#
    private static let oldNAS = #"{"id": 2, "node_id": "preview-old-nas", "name": "Old NAS (preview)", "revoked": true}"#
    private static let linkSettings = #"{"versions": null, "accept_all": false, "keep_removed": true, "mirror_all": false}"#
    private static let mirrorSettings =
        #"{"versions": {"enabled": true, "keep_last": 10, "max_age_days": 30, "quota_bytes": 0, "set_by": 1, "set_at": \#(PreviewData.now - 86_400)}, "accept_all": true, "keep_removed": false, "mirror_all": false}"#
    private static let grant =
        #"{"role_name": "Mirror readers", "files": 1, "directories": 1, "sync": 0, "roles": 0, "granted_by_node": "preview-offsite-node", "granted_at": \#(PreviewData.now - 86_400 * 12)}"#

    static let rows: [String] = {
        let now = PreviewData.now
        return [
            // Live core, link up, three changes waiting for the mirror.
            row(1, "Family Photos (preview)", role: "core", state: "live", peer: offsite, term: 4, seq: 1_284,
                acked: (4, 1_281), pending: 3, linkUp: true, confirmedAt: now - 40, settings: linkSettings),
            // A mirror whose link is down: read-only, two changes waiting for the core.
            row(2, "Documents (preview)", role: "mirror", state: "live", peer: offsite, term: 2, seq: 611, acked: (2, 609),
                pending: 2, firstCopy: #"{"finished": true, "entries_copied": 3120, "entries_total": null}"#, linkUp: false,
                confirmedAt: now - 3_600 * 5, grant: grant, settings: mirrorSettings),
            // First copy in progress.
            row(3, "Offsite Backup (preview)", role: "mirror", state: "starting", peer: offsite, term: 1, seq: 0,
                firstCopy: #"{"finished": false, "entries_copied": 1840, "entries_total": 4000}"#, linkUp: true,
                grant: grant, settings: mirrorSettings),
            row(4, "Media Archive (preview)", role: "core", state: "paused", peer: offsite, term: 3, seq: 90,
                acked: (3, 90), stopReason: "mirror_paused", linkUp: true, confirmedAt: now - 86_400, settings: linkSettings),
            row(11, "Design Assets (preview)", role: "mirror", state: "diverged", peer: offsite, term: 5, seq: 202,
                acked: (5, 199), stopReason: "mirror_type_mismatch", linkUp: true, confirmedAt: now - 7_200, grant: grant,
                settings: mirrorSettings),
            row(12, "Tax Records (preview)", role: "mirror", state: "expired", peer: offsite, term: 2, seq: 15,
                acked: (2, 15), stopReason: "mirror_log_expired", linkUp: true, confirmedAt: now - 86_400 * 40,
                settings: mirrorSettings),
            // A reason this build has no words for: shown as its code.
            row(13, "Shared Music (preview)", role: "core", state: "stopped", peer: offsite, term: 1, seq: 77, acked: (1, 70),
                stopReason: "mirror_peer_quota", pending: 7, linkUp: true, confirmedAt: now - 86_400 * 2,
                settings: linkSettings),
            row(14, "Camera Roll (preview)", role: "mirror", state: "switching", peer: offsite, term: 6, seq: 3_300,
                acked: (6, 3_300), linkUp: true, confirmedAt: now - 12, settings: mirrorSettings,
                switchJSON: #"{"switch_id": "s-1", "side": "mirror", "phase": "draining", "term": 7, "reason": null, "created_at": \#(now - 20), "ended_at": null}"#),
            row(15, "Old Laptop (preview)", role: "core", state: "rejoining", peer: offsite, term: 3, seq: 58,
                acked: (3, 51), stopReason: "mirror_rejoining", linkUp: true, confirmedAt: now - 86_400 * 3,
                settings: linkSettings),
            row(16, "Lab Notes (preview)", role: "core", state: "forked", peer: offsite, term: 4, seq: 12,
                acked: (3, 9), stopReason: "mirror_both_forced", linkUp: true, confirmedAt: now - 86_400 * 4,
                settings: linkSettings),
            // A core that took over and whose old core hasn't come back.
            row(21, "Client Work (preview)", role: "core", state: "live", peer: offsite, term: 8, seq: 404, acked: nil,
                pending: 404, linkUp: false, settings: linkSettings,
                takeover: #"{"term": 8, "fork": {"term": 7, "seq": 380}, "peer_id": 1, "contents_missing": 0, "created_at": \#(now - 3_600)}"#),
            // Its core deletes the vault: read-only here until the purge.
            row(22, "Home Videos (preview)", role: "mirror", state: "paused", peer: offsite, term: 2, seq: 51,
                acked: (2, 51), stopReason: "mirror_core_deleting", linkUp: true, confirmedAt: now - 600, grant: grant,
                settings: mirrorSettings,
                deleting: #"{"deleting": true, "purge_after": \#(now + 86_400 * 6), "copy": "leave", "here": "kept as an orphaned copy"}"#),
            row(17, "Archive 2019 (preview)", role: "orphaned", state: "stopped", peer: oldNAS, term: 9, seq: 1_002,
                stopReason: "mirror_orphaned", linkUp: false, settings: mirrorSettings),
            // Offers: one waiting for this server (its vault isn't created yet), one that failed.
            row(0, "", role: "starting", state: nil, peer: offsite, linkUp: true,
                start: start(41, side: "mirror", state: "offered", name: "Recipes (preview)", vaultID: nil)),
            row(19, "Travel (preview)", role: "starting", state: nil, peer: offsite, linkUp: true,
                start: start(42, side: "core", state: "failed", name: "Travel (preview)", vaultID: 19,
                             reason: "mirror_no_space", lastError: "not enough space on Offsite for 412 GB")),
            row(20, "Contracts (preview)", role: "detached", state: nil, peer: offsite, linkUp: true,
                detached: #"{"id": 3, "side": "mirror", "vault_id": 20, "peer_id": 1, "fork": {"term": 2, "seq": 88}, "digest_matched": true, "was_state": "live", "missing": 0, "owner_id": 1, "detached_by": 1, "detached_at": \#(now - 86_400 * 9), "rekeyed_at": null, "rekey_recommended": true}"#, rekey: true),
        ]
    }()

    static func row(_ id: Int64, _ name: String, role: String, state: String?, peer: String?, term: Int64? = nil,
                    seq: Int64? = nil, acked: (Int64, Int64)? = nil, stopReason: String? = nil, pending: Int64 = 0,
                    firstCopy: String? = nil, linkUp: Bool = false, confirmedAt: Int64? = nil, grant: String? = nil,
                    settings: String? = nil, start: String? = nil, switchJSON: String? = nil, takeover: String? = nil,
                    deleting: String? = nil, detached: String? = nil, rekey: Bool = false) -> String {
        let q = { (s: String?) in s.map { "\"\($0)\"" } ?? "null" }
        let n = { (v: Int64?) in v.map(String.init) ?? "null" }
        let ackedJSON = acked.map { #"{"term": \#($0.0), "seq": \#($0.1)}"# } ?? "null"
        let created = role == "starting" ? "null" : String(PreviewData.now - 86_400 * 30)
        return """
            {"vault_id": \(id), "vault_name": \(q(name)), "role": \(q(role)), "peer": \(peer ?? "null"),
             "term": \(n(term)), "last_seq": \(n(seq)), "state": \(q(state)), "grant": \(grant ?? "null"),
             "acked": \(ackedJSON), "created_at": \(created), "start": \(start ?? "null"), "switch": \(switchJSON ?? "null"),
             "takeover": \(takeover ?? "null"), "advice": null, "detached": \(detached ?? "null"),
             "rekey_recommended": \(rekey), "deleting": \(deleting ?? "null"), "stop_reason": \(q(stopReason)),
             "pending_changes": \(pending), "first_copy": \(firstCopy ?? (role == "mirror" || role == "core" ? #"{"finished": true, "entries_copied": null, "entries_total": null}"# : "null")),
             "link_up": \(linkUp), "confirmed_at": \(n(confirmedAt)), "settings": \(settings ?? "null")}
            """
    }

    static func start(_ id: Int64, side: String, state: String, name: String, vaultID: Int64?,
                      reason: String? = nil, lastError: String? = nil) -> String {
        let now = PreviewData.now
        let q = { (s: String?) in s.map { "\"\($0)\"" } ?? "null" }
        return """
            {"id": \(id), "offer_uid": "offer-\(id)", "side": "\(side)", "peer_id": 1,
             "vault_uid": "PREVIEWPREVIEWPREVIEWPREVI", "vault_id": \(vaultID.map(String.init) ?? "null"),
             "core_vault_id": \(vaultID ?? 31), "term": 1, "name": "\(name)", "description": "", "quota": 0,
             "size_bytes": 412000000000, "file_count": 18233, "history": false,
             "owner": {"node": "preview-offsite-node", "id": 1, "name": "cooper"}, "role": null, "state": "\(state)",
             "step": "\(state)", "told": true, "remove_copy": false, "copy": null, "reason": \(q(reason)),
             "detail": null, "attempts": 1, "last_error": \(q(lastError)), "created_at": \(now - 7_200),
             "updated_at": \(now - 600), "expires_at": \(now + 86_400 * 6), "finished_at": null}
            """
    }

    // MARK: Detach preview

    private static func preview(_ id: Int64) -> String {
        let (held, missing, digest, pending): (Int64, Int64, String, Int64) = switch id {
        case 2: (1, 0, "true", 2)
        case 3: (0, 2_160, "null", 0)
        case 11: (0, 0, "false", 0)
        case 17: (3, 12, "true", 0)
        default: (0, 0, "true", 0)
        }
        let finished = id != 3
        return """
            {"preview": {"vault_id": \(id), "vault_name": "Vault \(id)", "role": "mirror", "state": "live",
             "stop_reason": null, "peer": \(offsite), "link_up": true,
             "first_copy": {"finished": \(finished), "entries_copied": \(finished ? 3120 : 1840), "entries_total": \(finished ? 3120 : 4000)},
             "applied": {"term": 2, "seq": 609}, "confirmed": {"term": 2, "seq": 609}, "digest_matched": \(digest),
             "pending_changes": \(pending), "held_changes": \(held), "missing_count": \(missing), "missing": [],
             "owner_id": 1}}
            """
    }
}
#endif
