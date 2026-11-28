#if DEBUG
import Foundation
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: what "Home lab" answers for offers, mirroring a vault, held changes and the per-link
/// settings, beside ``MirrorsPreviewData``. Two offers from "Offsite (preview)" wait here; "Documents (preview)" holds
/// one change the core refused (two more once retried and discarded ones are shown) and "Archive 2019 (preview)"
/// three, one too large to send inline (id 12); turning on mirror all asks
/// for an approval this Mac can't give, as the server does. Nothing is remembered between answers.
nonisolated enum MirrorOffersPreviewData: PreviewFeature {
    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        switch command {
        case .mirrorPending:
            try superAdmin(transport)
            return try decode(Ws.Mirror.Pending.Response.self, #"{"offers": [\#(offers.joined(separator: ","))]}"#)
        case .mirrorAccept:
            try superAdmin(transport)
            return try decode(Ws.Mirror.Accept.Response.self, #"{"offer": \#(offer(41, "Recipes (preview)", state: "accepted"))}"#)
        case .mirrorDecline:
            try superAdmin(transport)
            return try decode(Ws.Mirror.Decline.Response.self, #"{"offer": \#(offer(41, "Recipes (preview)", state: "declined"))}"#)
        case .mirrorAdd:
            try superAdmin(transport)
            let id = (payload as? Ws.Mirror.Add.Payload)?.vaultID ?? 5
            let name = PreviewData.vaults.first { $0.id == id }?.name ?? "Vault \(id)"
            return try decode(Ws.Mirror.Add.Response.self,
                              #"{"offer": \#(offer(51, name, side: "core", state: "offered", vaultID: id))}"#)
        case .mirrorCancel:
            try superAdmin(transport)
            let id = (payload as? Ws.Mirror.Cancel.Payload)?.vaultID
            return try decode(Ws.Mirror.Cancel.Response.self,
                              #"{"side": "core", "vault_id": \#(id.map(String.init) ?? "null"), "removed": false, "remove_copy": false, "offer": null}"#)
        case .mirrorHeldList:
            try superAdmin(transport)
            let p = payload as? Ws.Mirror.Held.List.Payload
            let rows: [String] = switch p?.vaultID {
            case 2: [documentsHeld[0]] + (p?.all == true ? documentsClosed : [])
            case 17: archiveHeld
            default: []
            }
            return try decode(Ws.Mirror.Held.List.Response.self, #"{"held": [\#(rows.joined(separator: ","))]}"#)
        case .mirrorHeldGet:
            try superAdmin(transport)
            let id = (payload as? Ws.Mirror.Held.Get.Payload)?.id ?? 0
            guard id == 7 else { throw .refused(code: "too_large", message: "That version is larger than 8 MiB.") }
            let bytes = Data("Estimated payments, 2026 (preview)\n".utf8).base64EncodedString()
            return try decode(Ws.Mirror.Held.Get.Response.self,
                              #"{"held": \#(documentsHeld[0]), "name": "2026-estimates.pdf", "size": 35, "content_b64": "\#(bytes)"}"#)
        case .mirrorHeldRetry:
            try superAdmin(transport)
            return try decode(Ws.Mirror.Held.Retry.Response.self, #"{"held": \#(documentsHeld[1])}"#)
        case .mirrorHeldDiscard:
            try superAdmin(transport)
            return try decode(Ws.Mirror.Held.Discard.Response.self, #"{"held": \#(documentsHeld[0])}"#)
        case .mirrorAcceptAllSet:
            try superAdmin(transport)
            let on = (payload as? Ws.Mirror.AcceptAll.Set.Payload)?.enabled ?? false
            return try decode(Ws.Mirror.AcceptAll.Set.Response.self, setting(on))
        case .mirrorKeepRemovedSet:
            try superAdmin(transport)
            let on = (payload as? Ws.Mirror.KeepRemoved.Set.Payload)?.enabled ?? false
            return try decode(Ws.Mirror.KeepRemoved.Set.Response.self, setting(on))
        case .mirrorMirrorAllSet:
            try superAdmin(transport)
            let on = (payload as? Ws.Mirror.MirrorAll.Set.Payload)?.enabled ?? false
            if on {
                throw .stepUpRequired(WsStepUp(family: "keys", target: nil, methods: ["passkey"]),
                                      message: "Mirroring every vault sends every vault’s keys to the other server: approve it with a passkey in the web console.")
            }
            return try decode(Ws.Mirror.MirrorAll.Set.Response.self, setting(false))
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

    // MARK: Offers

    private static let offers: [String] = [
        offer(41, "Recipes (preview)", state: "offered"),
        offer(43, "Photo Library (preview)", state: "offered", description: "Every album since 2009, for the offsite copy.",
              size: 1_840_000_000_000, files: 412_377, owner: "maria",
              role: #"{"role_name": "Family readers", "files": 1, "directories": 1, "sync": 0, "roles": 0}"#),
    ]

    private static func offer(_ id: Int64, _ name: String, side: String = "mirror", state: String, vaultID: Int64? = nil,
                              description: String = "", size: Int64 = 2_400_000_000, files: Int64 = 1_204,
                              owner: String = "cooper", role: String = "null") -> String {
        let now = PreviewData.now
        return """
            {"id": \(id), "offer_uid": "offer-\(id)", "side": "\(side)", "peer_id": 1,
             "vault_uid": "PREVIEWPREVIEWPREVIEWPREVI", "vault_id": \(vaultID.map(String.init) ?? "null"),
             "core_vault_id": \(vaultID ?? 30 + id), "term": 1, "name": "\(name)", "description": "\(description)",
             "quota": 0, "size_bytes": \(size), "file_count": \(files), "history": false,
             "owner": {"node": "preview-offsite-node", "id": 3, "name": "\(owner)"}, "role": \(role),
             "state": "\(state)", "step": "\(state)", "told": true, "remove_copy": false, "copy": null, "reason": null,
             "detail": null, "attempts": 1, "last_error": null, "created_at": \(now - 5_400), "updated_at": \(now - 5_400),
             "expires_at": \(now + 86_400 * 6), "finished_at": null}
            """
    }

    // MARK: Held changes

    private static let documentsHeld: [String] = [
        held(7, op: "write", path: "/Taxes/2026-estimates.pdf", name: "2026-estimates.pdf", code: "denied",
             reason: "This account may not write to /Taxes on the core.", minutesAgo: 42),
        held(8, op: "rename", path: "/Scratch/old-draft.docx", name: "draft-final.docx", code: "conflict",
             reason: "An entry named “draft-final.docx” already exists there on the core.", minutesAgo: 95),
        held(9, kind: "conflict", op: "write", path: "/Budget/2026.xlsx", name: "2026.xlsx",
             copy: "2026 (conflict from Home lab).xlsx", code: "conflict",
             reason: "The core changed this file first; the version made here was kept beside it.", minutesAgo: 180),
    ]

    /// The orphaned copy "Archive 2019 (preview)" (its detach preview says three).
    private static let archiveHeld: [String] = [
        held(12, op: "write", path: "/Scans/1998-2019 family archive.tiff", name: "1998-2019 family archive.tiff",
             code: "denied", reason: "This account may not write to /Scans on the core.", minutesAgo: 60 * 24 * 40,
             vault: 17),
        held(8, op: "rename", path: "/Scratch/old-draft.docx", name: "draft-final.docx", code: "conflict",
             reason: "An entry named “draft-final.docx” already exists there on the core.", minutesAgo: 60 * 24 * 41,
             vault: 17),
        held(9, kind: "conflict", op: "write", path: "/Budget/2019.xlsx", name: "2019.xlsx",
             copy: "2019 (conflict from Home lab).xlsx", code: "conflict",
             reason: "The core changed this file first; the version made here was kept beside it.",
             minutesAgo: 60 * 24 * 42, vault: 17),
    ]

    private static let documentsClosed: [String] = [
        held(5, op: "mkdir", path: "/Receipts/2025", name: "2025", code: "denied",
             reason: "This account may not create folders there on the core.", state: "retried", minutesAgo: 60 * 26),
        held(4, op: "remove", path: "/Old/notes.txt", name: "notes.txt", code: "not_found",
             reason: "The core no longer has that entry.", state: "discarded", minutesAgo: 60 * 50),
    ]

    private static func held(_ id: Int64, kind: String = "held", op: String, path: String, name: String,
                             copy: String? = nil, code: String, reason: String, state: String = "open",
                             minutesAgo: Int64, vault: Int64 = 2) -> String {
        let now = PreviewData.now
        return """
            {"id": \(id), "vault_id": \(vault), "kind": "\(kind)", "op": "\(op)", "entry_uid": "entry-\(id)", "path": "\(path)",
             "name": "\(name)", "copy_name": \(copy.map { "\"\($0)\"" } ?? "null"),
             "person": {"node": "preview-home-lab", "id": 4}, "reason_code": "\(code)", "reason": "\(reason)",
             "state": "\(state)", "created_at": \(now - minutesAgo * 60),
             "resolved_at": \(state == "open" ? "null" : String(now - minutesAgo * 30))}
            """
    }

    // MARK: Settings

    private static func setting(_ on: Bool) -> String {
        #"{"peer": {"id": 1, "node_id": "preview-offsite-node", "name": "Offsite (preview)"}, "enabled": \#(on), "set_by": 1, "set_at": \#(PreviewData.now)}"#
    }
}
#endif
