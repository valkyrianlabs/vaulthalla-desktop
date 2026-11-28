import Foundation
import Testing
import VHContract
@testable import VHNodes

/// Offers, mirroring a vault, held changes and the per-link settings: the requests the views send and the states they
/// read (the web console's OffersPanel, AddMirrorDialog, HeldChanges and LinkSettingsDialog).
@Suite("Mirror offers, held changes and link settings")
struct MirrorOffersTests {
    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func held(_ edit: (inout MirrorHeldChange) -> Void = { _ in }) -> MirrorHeldChange {
        var h = MirrorHeldChange(id: 7, vaultID: 2, kind: "held", op: "write", path: "/Taxes/2026.pdf", name: "2026.pdf",
                                 personID: 4, reasonCode: "denied", reason: "Permission denied on the core.",
                                 state: .open, createdAt: 1_700_000_000)
        edit(&h)
        return h
    }

    // MARK: Requests

    @Test("accept, decline and cancel name the offer or the vault, and cancel never asks to remove a copy")
    func offerRequests() throws {
        let offer = MirrorOffer(id: 41, peerID: 1, name: "Recipes")
        #expect(try Self.json(MirrorOffers.acceptPayload(offer)) == #"{"offer":41}"#)
        #expect(try Self.json(MirrorOffers.declinePayload(offer)) == #"{"offer":41}"#)

        let start = MirroredVault.Start(id: 42, side: "core", state: "offered", name: "Travel")
        let byVault = MirroredVault(vaultID: 19, vaultName: "Travel", role: .starting, start: start)
        #expect(try Self.json(MirrorOffers.cancelPayload(byVault)) == #"{"vault_id":19}"#)
        let byOffer = MirroredVault(vaultID: 0, vaultName: "", role: .starting, start: start)
        #expect(try Self.json(MirrorOffers.cancelPayload(byOffer)) == #"{"offer":42}"#)
    }

    @Test("an offer is built only once a vault and a linked server are both chosen")
    func addRequest() throws {
        #expect(MirrorOffers.addPayload(vaultID: nil, peerID: 1) == nil)
        #expect(MirrorOffers.addPayload(vaultID: 5, peerID: nil) == nil)
        #expect(MirrorOffers.addPayload(vaultID: 0, peerID: 1) == nil)
        let payload = try #require(MirrorOffers.addPayload(vaultID: 5, peerID: 1))
        #expect(try Self.json(payload) == #"{"peer":"1","vault_id":5}"#)
    }

    @Test("held changes are listed per vault, the retried and discarded ones only when asked")
    func heldRequests() throws {
        #expect(try Self.json(MirrorOffers.heldListPayload(vaultID: 2, all: false)) == #"{"vault_id":2}"#)
        #expect(try Self.json(MirrorOffers.heldListPayload(vaultID: 2, all: true)) == #"{"all":true,"vault_id":2}"#)
        let setting = MirrorOffers.settingPayload(peerID: 3, enabled: true)
        #expect(try Self.json(Ws.Mirror.MirrorAll.Set.Payload(peer: setting.peer, enabled: setting.enabled))
            == #"{"enabled":true,"peer":"3"}"#)
    }

    // MARK: Offers

    @Test("outgoing offers are this server's open starts; incoming ones and finished starts aren't")
    func outgoing() {
        func row(_ side: String, _ state: String, role: MirrorRole = .starting) -> MirroredVault {
            MirroredVault(vaultID: 9, vaultName: "V", role: role,
                          start: .init(id: 1, side: side, state: state, name: "V"))
        }
        let rows = [row("core", "offered"), row("core", "failed"), row("core", "declined"), row("core", "cancelled"),
                    row("mirror", "offered"), row("core", "offered", role: .core)]
        let out = MirrorOffers.outgoing(rows)
        #expect(out.map { $0.start?.state } == ["offered", "failed"])
    }

    @Test("an incoming offer keeps what the server didn't say as unknown")
    func offerFromWire() throws {
        let json = """
            {"offers": [{"id": 41, "offer_uid": "u", "side": "mirror", "peer_id": 1, "vault_uid": "V", "vault_id": null,
             "core_vault_id": 3, "term": 1, "name": "Recipes", "description": "", "quota": 0, "size_bytes": 10,
             "file_count": 2, "history": false, "owner": {"node": "n", "id": 1, "name": ""}, "role": null,
             "state": "offered", "step": "offered", "told": true, "remove_copy": false, "copy": null, "reason": null,
             "detail": null, "attempts": 1, "last_error": null, "created_at": 1, "updated_at": 1, "expires_at": 0,
             "finished_at": null}]}
            """
        let wire = try JSONDecoder().decode(Ws.Mirror.Pending.Response.self, from: Data(json.utf8))
        let offer = MirrorOffer(try #require(wire.offers.first))
        #expect(offer.ownerName == nil && offer.roleName == nil && offer.expiresAt == nil)
        #expect(offer.name == "Recipes" && offer.peerID == 1)
    }

    @Test("only vaults not already mirrored or starting can be offered")
    func offerable() {
        let rows = [
            MirroredVault(vaultID: 1, vaultName: "A", role: .core),
            MirroredVault(vaultID: 2, vaultName: "B", role: .starting),
            MirroredVault(vaultID: 3, vaultName: "C", role: .detached),
        ]
        let ids: [Int64] = [1, 2, 3, 4]
        #expect(MirrorOffers.offerable(ids, id: { $0 }, mirrored: rows) == [3, 4])
    }

    // MARK: Held changes

    @Test("a held change says what was done to which file and why, in the console's words")
    func heldWords() {
        #expect(MirrorOffers.heldWhat(Self.held()) == "Saved a file")
        #expect(MirrorOffers.heldWhat(Self.held { $0.op = "chmod" }) == "chmod")
        #expect(MirrorOffers.heldWhat(Self.held { $0.kind = "conflict"; $0.copyName = "a (conflict).txt" })
            == "Conflict copy kept as “a (conflict).txt”")
        #expect(MirrorOffers.heldWhat(Self.held { $0.kind = "conflict" }) == "Conflict copy")
        #expect(MirrorOffers.heldPath(Self.held { $0.path = nil }) == "2026.pdf")
        #expect(MirrorOffers.heldPath(Self.held { $0.path = ""; $0.name = "" }) == "(unknown path)")
        #expect(MirrorOffers.heldReason(Self.held { $0.reason = "" }) == "denied")
        #expect(MirrorOffers.discardBody(Self.held()) == "The change to “/Taxes/2026.pdf” is dropped. Nothing in the vault changes.")
        #expect(MirrorOffers.discardBody(Self.held { $0.kind = "conflict" }).contains("conflict copy itself stays"))
    }

    @Test("open held writes can be saved, retried and discarded; conflicts only discarded; closed ones nothing")
    func heldStates() {
        let open = Self.held()
        #expect(MirrorOffers.canSave(open) && MirrorOffers.canRetry(open) && MirrorOffers.canDiscard(open))
        let rename = Self.held { $0.op = "rename" }
        #expect(!MirrorOffers.canSave(rename) && MirrorOffers.canRetry(rename))
        let conflict = Self.held { $0.kind = "conflict" }
        #expect(!MirrorOffers.canSave(conflict) && !MirrorOffers.canRetry(conflict) && MirrorOffers.canDiscard(conflict))
        for state in [MirrorHeldChange.State.retried, .discarded, .other("archived")] {
            let closed = Self.held { $0.state = state }
            #expect(!MirrorOffers.canSave(closed) && !MirrorOffers.canRetry(closed) && !MirrorOffers.canDiscard(closed))
        }
        #expect(MirrorOffers.heldStateText(.other("archived")) == "archived")
        #expect(MirrorOffers.heldStateTone(.other("archived")) == .unknown)
        #expect(MirrorOffers.heldStateTone(.open) == .warn)
        #expect(MirrorOffers.saveCommand(open) == "vh mirror save 7 ./2026.pdf")
        let sorted = MirrorOffers.sortedHeld([Self.held { $0.id = 1; $0.createdAt = 5 }, Self.held { $0.id = 2; $0.createdAt = 9 }])
        #expect(sorted.map(\.id) == [2, 1])
    }

    @Test("retrying needs the vault live here with its link not known to be down")
    func retryLive() {
        let live = MirroredVault(vaultID: 2, vaultName: "D", role: .mirror,
                                 peer: .init(id: 1, nodeID: "n", name: "vps", revoked: false), state: .live, linkUp: true)
        #expect(MirrorOffers.retryIsLive(live))
        var down = live
        down.linkUp = false
        #expect(!MirrorOffers.retryIsLive(down))
        var paused = live
        paused.state = .paused
        #expect(!MirrorOffers.retryIsLive(paused))
    }

    // MARK: Link settings

    @Test("a link's setting is what a row with that server reports, else unknown (never guessed off)")
    func settings() {
        let peer = MirroredVault.Peer(id: 1, nodeID: "n", name: "vps", revoked: false)
        let settings = MirroredVault.Settings(acceptAll: true, keepRemoved: false, mirrorAll: false)
        let rows = [MirroredVault(vaultID: 1, vaultName: "A", role: .core, peer: peer, settings: settings)]
        #expect(MirrorOffers.current(.acceptAll, peerID: 1, rows: rows) == true)
        #expect(MirrorOffers.current(.keepRemoved, peerID: 1, rows: rows) == false)
        #expect(MirrorOffers.current(.acceptAll, peerID: 2, rows: rows) == nil)
        #expect(MirrorOffers.current(.acceptAll, peerID: 1, rows: []) == nil)
    }

    @Test("accept all and mirror all widen what moves without asking: they say so before they are turned on")
    func widening() {
        #expect(MirrorLinkSetting.acceptAll.widens && MirrorLinkSetting.mirrorAll.widens)
        #expect(!MirrorLinkSetting.keepRemoved.widens)
        #expect(MirrorLinkSetting.acceptAll.turnOnWarning("vps")?.contains("without asking") == true)
        #expect(MirrorLinkSetting.mirrorAll.turnOnWarning("vps")?.contains("with its keys") == true)
        #expect(MirrorLinkSetting.keepRemoved.turnOnWarning("vps") == nil)
        #expect(MirrorLinkSetting.allCases.map(\.command) == [.mirrorAcceptAllSet, .mirrorKeepRemovedSet, .mirrorMirrorAllSet])
        #expect(MirrorLinkSetting.acceptAll.label("vps") == "Accept every vault vps offers")
        #expect(MirrorLinkSetting.keepRemoved.hint("vps").hasPrefix("On: when vps ends a mirror"))
    }
}
