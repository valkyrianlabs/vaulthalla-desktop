import Foundation
import Testing
import VHContract
@testable import VHNodes

/// Relink, ported from the web console's `relink.test.ts` (server main), plus the requests the Reconnect sheet and the
/// requests panel send and the handshake rules they keep.
@Suite("Mirror relink")
struct MirrorRelinkTests {
    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func at(_ phase: String, side: RelinkSide = .initiator, error: String? = nil) -> RelinkStatus {
        RelinkStatus(vaultID: 5, relink: .init(uid: "r1", side: side, phase: RelinkPhase(phase), error: error))
    }

    private static func request(_ phase: RelinkPhase) -> RelinkRequest {
        RelinkRequest(vaultID: 5, vaultName: "Projects", relinkUid: "r1", phase: phase, peerID: 1, peerName: "vps",
                      askedBy: "cooper", handshake: .init(acceptedBy: "admin", approvedBy: nil))
    }

    // MARK: relink.test.ts

    @Test("drift kinds read in words, naming the other server")
    func kindText() {
        #expect(MirrorRelink.kindText(.onlyTheirs, peer: "vps") == "Only on vps")
        #expect(MirrorRelink.kindText(.changedBoth, peer: "vps") == "Changed on both")
        #expect(MirrorRelink.kindText(.differs, peer: "vps") == "Differs")
        #expect(MirrorRelink.kindText(RelinkKind("moved_far"), peer: "vps") == "moved_far", "unknown reads as itself")
    }

    @Test("the counts that are not zero, in order")
    func countLines() {
        let lines = MirrorRelink.countLines([.onlyThis: 2, .changedTheirs: 1, .differs: 0], peer: "vps")
        #expect(lines.map(\.kind) == [.onlyThis, .changedTheirs])
        #expect(lines.map(\.count) == [2, 1])
    }

    @Test("the winner of an entry follows the plan core")
    func winner() {
        #expect(MirrorRelink.winnerOf("core", core: .this) == .this)
        #expect(MirrorRelink.winnerOf("core", core: .theirs) == .theirs)
        #expect(MirrorRelink.winnerOf("mirror", core: .this) == .theirs)
        #expect(MirrorRelink.winnerOf("mirror", core: .theirs) == .this)
        #expect(MirrorRelink.winnerOf("both", core: .this) == .both)
        #expect(MirrorRelink.winnerOf("later", core: .this) == nil, "unknown reads as unknown")
    }

    @Test("only files keep both versions")
    func keepBoth() {
        #expect(MirrorRelink.canKeepBoth(RelinkEntry(uid: "u", kind: .onlyThis, path: "/a", thisKind: "file")))
        #expect(!MirrorRelink.canKeepBoth(RelinkEntry(uid: "u", kind: .differs, path: "/a", thisKind: "directory",
                                                      theirsKind: "directory")))
    }

    @Test("a choice and a bulk choice as the plan takes them; empty is the default")
    func planPayloads() throws {
        #expect(try Self.json(MirrorRelink.planPayload(vaultID: 5, .entry(uid: "u1", choice: .both)))
            == #"{"set":[{"choice":"both","uid":"u1"}],"vault_id":5}"#)
        #expect(try Self.json(MirrorRelink.planPayload(vaultID: 5, .entry(uid: "u1", choice: nil)))
            == #"{"set":[{"choice":null,"uid":"u1"}],"vault_id":5}"#)
        #expect(try Self.json(MirrorRelink.planPayload(vaultID: 5, .shown(kind: .changedTheirs, choice: .theirs)))
            == #"{"by_kind":[{"choice":"theirs","kind":"changed_theirs"}],"vault_id":5}"#)
        #expect(try Self.json(MirrorRelink.planPayload(vaultID: 5, .shown(kind: nil, choice: nil)))
            == #"{"by_kind":[{"choice":null,"kind":""}],"vault_id":5}"#)
        #expect(try Self.json(MirrorRelink.planPayload(vaultID: 5, .defaultChoice(nil))) == #"{"default":"","vault_id":5}"#)
        #expect(try Self.json(MirrorRelink.planPayload(vaultID: 5, .core(.theirs))) == #"{"core":"theirs","vault_id":5}"#)
        #expect(try Self.json(MirrorRelink.planPayload(vaultID: 5, .discard)) == #"{"discard":true,"vault_id":5}"#)
    }

    @Test("what each side gains and loses, in words")
    func gains() {
        #expect(MirrorRelink.gainsText(.init(takes: 1, keepsHeld: 1, conflictCopies: 0))
            == "takes 1 from the other, keeps 1 of its own as held change")
        #expect(MirrorRelink.gainsText(.init(takes: 0, keepsHeld: 2, conflictCopies: 2)).contains("2 conflict copies"))
        #expect(MirrorRelink.gainsText(nil) == "")
    }

    @Test("the phase in words: running while bringing or copying, the server sentence when stale")
    func phase() {
        #expect(!MirrorRelink.phaseText(nil).running)
        #expect(MirrorRelink.phaseText(Self.at("bring")).running)
        #expect(MirrorRelink.phaseText(Self.at("copying")).running)
        #expect(MirrorRelink.phaseText(Self.at("done")).tone == .ok)
        #expect(MirrorRelink.phaseText(Self.at("stale", error: "the vault changed on this server")).text
            == "the vault changed on this server")
        #expect(MirrorRelink.phaseText(Self.at("rewinding")).tone == .unknown, "a phase this build doesn't know")
        #expect(MirrorRelink.phaseText(Self.at("rewinding")).text.contains("rewinding"))
    }

    @Test("the handshake in words: the asking side waits (and polls) for the other admin, the asked side is told where to answer")
    func handshake() {
        #expect(MirrorRelink.phaseText(Self.at("requested"), peer: "vps").text.contains("Waiting for vps’s admin to accept"))
        #expect(MirrorRelink.phaseText(Self.at("requested"), peer: "vps").running)
        #expect(MirrorRelink.phaseText(Self.at("proposed"), peer: "vps").text.contains("Awaiting vps’s approval"))
        #expect(MirrorRelink.phaseText(Self.at("approved"), peer: "vps").running)
        #expect(MirrorRelink.phaseText(Self.at("declined"), peer: "vps").tone == .warn)
        #expect(MirrorRelink.phaseText(Self.at("requested", side: .responder), peer: "vps").text.contains("Relink requests"))
        #expect(!MirrorRelink.phaseText(Self.at("requested", side: .responder), peer: "vps").running)
    }

    @Test("a request asks the person here in words")
    func requestAsk() {
        #expect(MirrorRelink.requestAsk(Self.request(.requested)) == "vps (cooper) asks to compare its copy with this vault.")
        #expect(MirrorRelink.requestAsk(Self.request(.accepted)).hasPrefix("Accepted by admin"))
    }

    // MARK: Desktop's rules

    @Test("the sheet asks once on opening and compares once accepted; never while waiting, running or on the asked side")
    func compareOnItsOwn() {
        #expect(MirrorRelink.shouldCompare(RelinkStatus(vaultID: 5), comparedOnce: false))
        #expect(!MirrorRelink.shouldCompare(RelinkStatus(vaultID: 5), comparedOnce: true))
        #expect(MirrorRelink.shouldCompare(Self.at("declined"), comparedOnce: false))
        #expect(MirrorRelink.shouldCompare(Self.at("accepted"), comparedOnce: true))
        for phase in ["requested", "open", "proposed", "approved", "bring", "copying"] {
            #expect(!MirrorRelink.shouldCompare(Self.at(phase), comparedOnce: false), "\(phase)")
        }
        #expect(!MirrorRelink.shouldCompare(Self.at("accepted", side: .responder), comparedOnce: false))
        #expect(MirrorRelink.isWaiting(Self.at("proposed")) && !MirrorRelink.isWaiting(Self.at("proposed", side: .responder)))
        #expect(MirrorRelink.isOpen(Self.at("open")) && !MirrorRelink.isOpen(Self.at("open", side: .responder)))
        #expect(MirrorRelink.compareAgainLabel(Self.at("declined")) == "Ask again")
        #expect(MirrorRelink.compareAgainLabel(Self.at("stale")) == "Compare again")
    }

    @Test("apply and approve need the vault's name typed exactly; keep names the winning server")
    func confirmations() throws {
        let row = MirrorModelTests.row { $0.role = .detached }
        #expect(MirrorRelink.applyPayload(row, typed: "projects", keep: .this, peerID: 3) == nil)
        #expect(MirrorRelink.applyPayload(row, typed: "", keep: nil, peerID: 3) == nil)
        let keep = try #require(MirrorRelink.applyPayload(row, typed: "Projects", keep: .theirs, peerID: 3))
        #expect(try Self.json(keep) == #"{"confirm":"Projects","keep":"theirs","peer":"3","vault_id":5}"#)
        let plan = try #require(MirrorRelink.applyPayload(row, typed: "Projects", keep: nil, peerID: 3))
        #expect(try Self.json(plan) == #"{"confirm":"Projects","vault_id":5}"#)

        let q = Self.request(.proposed)
        #expect(MirrorRelink.approvePayload(q, typed: "Project") == nil)
        #expect(try Self.json(try #require(MirrorRelink.approvePayload(q, typed: "Projects")))
            == #"{"confirm":"Projects","vault_id":5}"#)
        #expect(try Self.json(MirrorRelink.acceptPayload(q)) == #"{"vault_id":5}"#)
    }

    @Test("the linked server: its own while the link stands, else the same node's, else the person chooses")
    func ownPeer() {
        let linked: [(id: Int64, nodeID: String)] = [(7, "node-b")]
        #expect(MirrorRelink.ownPeer(MirrorModelTests.row(), linked: linked) == 3)
        let revoked = MirrorModelTests.row { $0.peer?.revoked = true }
        #expect(MirrorRelink.ownPeer(revoked, linked: linked) == 7)
        #expect(MirrorRelink.ownPeer(revoked, linked: []) == nil)
        #expect(MirrorRelink.comparePayload(revoked, peerID: nil) == nil)
    }

    @Test("counts, pages and the read status from the wire; what wasn't sent stays unknown")
    func wire() throws {
        #expect(MirrorRelink.totalText(nil) { "\($0)" } == nil)
        #expect(MirrorRelink.totalText(0) { "\($0)" } == "Both trees are the same.")
        #expect(MirrorRelink.totalText(1) { "\($0)" } == "1 entry differs")
        #expect(MirrorRelink.pageText(offset: 50, total: 63) { "\($0)" } == "51–63 of 63")
        #expect(MirrorRelink.pageText(offset: 0, total: 50) { "\($0)" } == nil)

        let get = try JSONDecoder().decode(Ws.Mirror.Relink.Get.Response.self, from: Data(#"""
            {"vault_id": 5, "relink": {"id": 1, "relink_uid": "r1", "side": "initiator", "phase": "open", "mode": "plan",
              "core": "theirs", "default_choice": null, "role": null, "term": null, "error": null,
              "by": {"node": "n", "id": 1, "name": "cooper"}, "created_at": 1, "applied_at": null, "finished_at": null},
             "counts": {"only_this": 2, "total": 2}, "blockers": [{"code": "mirror_relink_keys", "side": "both", "message": "Keys differ."}]}
            """#.utf8))
        let s = RelinkStatus(get)
        #expect(s.relink?.core == .theirs && s.relink?.phase == .open && s.relink?.side == .initiator)
        #expect(s.counts == [.onlyThis: 2] && s.total == 2)
        #expect(s.blockers.map(\.message) == ["Keys differ."])
        #expect(s.plan == nil && s.handshake == nil && s.bring == nil)
    }
}
