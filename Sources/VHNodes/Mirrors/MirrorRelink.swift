public import Foundation
public import VHContract

/// Relink: reconnecting a vault two servers once mirrored (ws `mirror.relink.*`, design/peers/mirror.md "As built:
/// relink"), ported from the web console's `web/src/features/mirrors/relink.ts` (server main). Both servers agree, each
/// by a super admin: the asking server's request is accepted on the other before its tree is compared, and the outcome
/// it proposes is approved there before anything changes on either. Every value the server didn't send stays nil, and
/// a word this build doesn't know reads as itself.

/// How an entry drifted between the two copies.
public enum RelinkKind: Hashable, Sendable {
    case onlyThis, onlyTheirs, changedThis, changedTheirs, changedBoth, differs
    case other(String)

    /// The console's DRIFT_KINDS, in its order.
    public static let known: [RelinkKind] = [.onlyThis, .onlyTheirs, .changedThis, .changedTheirs, .changedBoth, .differs]

    public init(_ raw: String) {
        self = Self.known.first { $0.raw == raw } ?? .other(raw)
    }

    public var raw: String {
        switch self {
        case .onlyThis: "only_this"
        case .onlyTheirs: "only_theirs"
        case .changedThis: "changed_this"
        case .changedTheirs: "changed_theirs"
        case .changedBoth: "changed_both"
        case .differs: "differs"
        case .other(let raw): raw
        }
    }
}

/// Which server's version an entry ends with.
public enum RelinkChoice: String, CaseIterable, Hashable, Sendable {
    case this, theirs, both
}

/// The plan's core: which server's tree becomes the vault's truth.
public enum RelinkCore: String, CaseIterable, Hashable, Sendable {
    case this, theirs
}

public enum RelinkSide: Hashable, Sendable {
    case initiator, responder
    case other(String)

    public init(_ raw: String) {
        switch raw {
        case "initiator": self = .initiator
        case "responder": self = .responder
        default: self = .other(raw)
        }
    }
}

public enum RelinkPhase: Hashable, Sendable {
    case requested, accepted, open, proposed, approved, prepared, bring, copying, done, failed, stale, cancelled,
         declined, expired
    case other(String)

    private static let all: [RelinkPhase] = [
        .requested, .accepted, .open, .proposed, .approved, .prepared, .bring, .copying, .done, .failed, .stale,
        .cancelled, .declined, .expired,
    ]

    public init(_ raw: String) {
        self = Self.all.first { $0.raw == raw } ?? .other(raw)
    }

    public var raw: String {
        switch self {
        case .requested: "requested"
        case .accepted: "accepted"
        case .open: "open"
        case .proposed: "proposed"
        case .approved: "approved"
        case .prepared: "prepared"
        case .bring: "bring"
        case .copying: "copying"
        case .done: "done"
        case .failed: "failed"
        case .stale: "stale"
        case .cancelled: "cancelled"
        case .declined: "declined"
        case .expired: "expired"
        case .other(let raw): raw
        }
    }
}

/// What one side takes from the other, keeps of its own as held changes, and gains as conflict copies.
public struct RelinkGains: Hashable, Sendable {
    public var takes: Int64
    public var keepsHeld: Int64
    public var conflictCopies: Int64

    public init(takes: Int64, keepsHeld: Int64, conflictCopies: Int64) {
        self.takes = takes
        self.keepsHeld = keepsHeld
        self.conflictCopies = conflictCopies
    }
}

/// The outcome the asking server proposed, which the other server's admin approves.
public struct RelinkProposal: Hashable, Sendable {
    public var core: RelinkCore?
    /// `override` (one tree wins everywhere) or `plan` (a choice per entry); other words read as themselves.
    public var mode: String
    public var this: RelinkGains
    public var theirs: RelinkGains
    /// The drifted entries the plan covers.
    public var entries: Int64

    public init(core: RelinkCore?, mode: String, this: RelinkGains, theirs: RelinkGains, entries: Int64) {
        self.core = core
        self.mode = mode
        self.this = this
        self.theirs = theirs
        self.entries = entries
    }

    public var isOverride: Bool { mode == "override" }
}

/// Where the two-sided agreement stands: who it waits for, and the server's own sentences for what accepting
/// discloses and what approving does.
public struct RelinkHandshake: Hashable, Sendable {
    public var waitingFor: String?
    public var expiresAt: Int64?
    public var acceptedBy: String?
    public var approvedBy: String?
    public var proposal: RelinkProposal?
    /// What approving changes on this server, in the server's words.
    public var outcome: String?
    /// What accepting lets the other server read, in the server's words.
    public var discloses: String?

    public init(waitingFor: String? = nil, expiresAt: Int64? = nil, acceptedBy: String? = nil, approvedBy: String? = nil,
                proposal: RelinkProposal? = nil, outcome: String? = nil, discloses: String? = nil) {
        self.waitingFor = waitingFor
        self.expiresAt = expiresAt
        self.acceptedBy = acceptedBy
        self.approvedBy = approvedBy
        self.proposal = proposal
        self.outcome = outcome
        self.discloses = discloses
    }
}

/// A vault's relink as `mirror.relink.get` answers it: the open one here, else its last; nil relink: none.
public struct RelinkStatus: Hashable, Sendable {
    public struct Relink: Hashable, Sendable {
        public var uid: String
        public var side: RelinkSide
        public var phase: RelinkPhase
        public var mode: String
        public var core: RelinkCore?
        public var defaultChoice: RelinkChoice?
        /// The server's sentence for a relink that ended or stopped.
        public var error: String?

        public init(uid: String, side: RelinkSide, phase: RelinkPhase, mode: String = "plan", core: RelinkCore? = .this,
                    defaultChoice: RelinkChoice? = nil, error: String? = nil) {
            self.uid = uid
            self.side = side
            self.phase = phase
            self.mode = mode
            self.core = core
            self.defaultChoice = defaultChoice
            self.error = error
        }
    }

    public struct Plan: Hashable, Sendable {
        public var core: RelinkCore?
        /// nil: the core's version.
        public var defaultChoice: RelinkChoice?
        public var this: RelinkGains
        public var theirs: RelinkGains

        public init(core: RelinkCore?, defaultChoice: RelinkChoice?, this: RelinkGains, theirs: RelinkGains) {
            self.core = core
            self.defaultChoice = defaultChoice
            self.this = this
            self.theirs = theirs
        }
    }

    /// Why the relink can't go ahead, in the server's words.
    public struct Blocker: Hashable, Sendable {
        public var code: String
        public var side: String
        public var message: String

        public init(code: String, side: String, message: String) {
            self.code = code
            self.side = side
            self.message = message
        }
    }

    public var vaultID: Int64
    public var relink: Relink?
    /// The drift counts by kind, as sent; empty when the server sent none.
    public var counts: [RelinkKind: Int64]
    /// The drifted entries in all; nil when the server didn't say.
    public var total: Int64?
    public var blockers: [Blocker]
    public var plan: Plan?
    /// Entries brought onto the core so far, and in all, while bringing.
    public var bring: Progress?
    public var handshake: RelinkHandshake?

    public struct Progress: Hashable, Sendable {
        public var done: Int64
        public var total: Int64

        public init(done: Int64, total: Int64) {
            self.done = done
            self.total = total
        }
    }

    public init(vaultID: Int64, relink: Relink? = nil, counts: [RelinkKind: Int64] = [:], total: Int64? = nil,
                blockers: [Blocker] = [], plan: Plan? = nil, bring: Progress? = nil,
                handshake: RelinkHandshake? = nil) {
        self.vaultID = vaultID
        self.relink = relink
        self.counts = counts
        self.total = total
        self.blockers = blockers
        self.plan = plan
        self.bring = bring
        self.handshake = handshake
    }

    public init(_ wire: Ws.Mirror.Relink.Get.Response) {
        let relink = wire.relink.map {
            Relink(uid: $0.relinkUid, side: RelinkSide($0.side), phase: RelinkPhase($0.phase), mode: $0.mode,
                   core: RelinkCore(rawValue: $0.core), defaultChoice: $0.defaultChoice.flatMap(RelinkChoice.init),
                   error: $0.error)
        }
        var counts: [RelinkKind: Int64] = [:]
        if let c = wire.counts {
            let pairs: [(RelinkKind, Int64?)] = [
                (.onlyThis, c.onlyThis), (.onlyTheirs, c.onlyTheirs), (.changedThis, c.changedThis),
                (.changedTheirs, c.changedTheirs), (.changedBoth, c.changedBoth), (.differs, c.differs),
            ]
            for (kind, n) in pairs { if let n { counts[kind] = n } }
        }
        let plan = wire.plan.map {
            Plan(core: RelinkCore(rawValue: $0.core), defaultChoice: $0.defaultChoice.flatMap(RelinkChoice.init),
                 this: .init(takes: $0.this.takes, keepsHeld: $0.this.keepsHeld, conflictCopies: $0.this.conflictCopies),
                 theirs: .init(takes: $0.theirs.takes, keepsHeld: $0.theirs.keepsHeld,
                               conflictCopies: $0.theirs.conflictCopies))
        }
        let handshake = wire.handshake.map { h in
            RelinkHandshake(
                waitingFor: h.waitingFor, expiresAt: h.expiresAt, acceptedBy: h.acceptedBy, approvedBy: h.approvedBy,
                proposal: h.proposal.map {
                    RelinkProposal(core: RelinkCore(rawValue: $0.core), mode: $0.mode,
                                   this: .init(takes: $0.this.takes, keepsHeld: $0.this.keepsHeld,
                                               conflictCopies: $0.this.conflictCopies),
                                   theirs: .init(takes: $0.theirs.takes, keepsHeld: $0.theirs.keepsHeld,
                                                 conflictCopies: $0.theirs.conflictCopies),
                                   entries: $0.entries)
                },
                outcome: h.outcome, discloses: h.discloses)
        }
        self.init(vaultID: wire.vaultID, relink: relink, counts: counts, total: wire.counts?.total,
                  blockers: (wire.blockers ?? []).map { Blocker(code: $0.code, side: $0.side, message: $0.message) },
                  plan: plan, bring: wire.progress.map { Progress(done: $0.bringDone, total: $0.bringTotal) }, handshake: handshake)
    }
}

/// One drifted entry of the comparison (`mirror.relink.entries`).
public struct RelinkEntry: Identifiable, Hashable, Sendable {
    public var uid: String
    public var kind: RelinkKind
    /// What differs about it (`contents`, `place`, …), as the server words it.
    public var aspects: [String]
    public var path: String
    /// `file`, `directory` or `symlink` on each side; nil where that side doesn't hold it.
    public var thisKind: String?
    public var theirsKind: String?
    /// The person's choice; nil: the plan's default.
    public var choice: RelinkChoice?
    /// What the default gives it: `core`, `mirror` or `both`.
    public var resolution: String

    public var id: String { uid }

    public init(uid: String, kind: RelinkKind, aspects: [String] = [], path: String, thisKind: String? = nil,
                theirsKind: String? = nil, choice: RelinkChoice? = nil, resolution: String = "core") {
        self.uid = uid
        self.kind = kind
        self.aspects = aspects
        self.path = path
        self.thisKind = thisKind
        self.theirsKind = theirsKind
        self.choice = choice
        self.resolution = resolution
    }

    public init(_ wire: Ws.Mirror.Relink.Entries.Response.Entrie) {
        self.init(uid: wire.uid, kind: RelinkKind(wire.kind), aspects: wire.aspects, path: wire.path,
                  thisKind: wire.this?.kind, theirsKind: wire.theirs?.kind,
                  choice: wire.choice.flatMap(RelinkChoice.init), resolution: wire.resolution)
    }
}

/// A relink a linked server asks of one of this server's vaults (`mirror.relink.pending`).
public struct RelinkRequest: Identifiable, Hashable, Sendable {
    public var vaultID: Int64
    public var vaultName: String
    public var relinkUid: String
    public var phase: RelinkPhase
    public var peerID: Int64
    public var peerName: String
    /// Who asked on the other server; nil when it didn't say.
    public var askedBy: String?
    /// The vault's mirror status on this server (`detached`, `orphaned`, …).
    public var status: String?
    public var createdAt: Int64
    public var handshake: RelinkHandshake?

    public var id: String { relinkUid }

    public init(vaultID: Int64, vaultName: String, relinkUid: String, phase: RelinkPhase, peerID: Int64,
                peerName: String, askedBy: String? = nil, status: String? = nil, createdAt: Int64 = 0,
                handshake: RelinkHandshake? = nil) {
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.relinkUid = relinkUid
        self.phase = phase
        self.peerID = peerID
        self.peerName = peerName
        self.askedBy = askedBy
        self.status = status
        self.createdAt = createdAt
        self.handshake = handshake
    }

    public init(_ wire: Ws.Mirror.Relink.Pending.Response.Request) {
        let handshake = wire.handshake.map { h in
            RelinkHandshake(
                waitingFor: h.waitingFor, expiresAt: h.expiresAt, acceptedBy: h.acceptedBy, approvedBy: h.approvedBy,
                proposal: h.proposal.map {
                    RelinkProposal(core: RelinkCore(rawValue: $0.core), mode: $0.mode,
                                   this: .init(takes: $0.this.takes, keepsHeld: $0.this.keepsHeld,
                                               conflictCopies: $0.this.conflictCopies),
                                   theirs: .init(takes: $0.theirs.takes, keepsHeld: $0.theirs.keepsHeld,
                                                 conflictCopies: $0.theirs.conflictCopies),
                                   entries: $0.entries)
                },
                outcome: h.outcome, discloses: h.discloses)
        }
        self.init(vaultID: wire.vaultID, vaultName: wire.vaultName, relinkUid: wire.relinkUid,
                  phase: RelinkPhase(wire.phase), peerID: wire.peer.id, peerName: MirrorOffers.peerLabel(wire.peer.name),
                  askedBy: wire.askedBy.isEmpty ? nil : wire.askedBy, status: wire.status.isEmpty ? nil : wire.status,
                  createdAt: wire.createdAt, handshake: handshake)
    }
}

/// The pure parts of the Reconnect sheet and the requests panel: what a drift kind and an entry's resolution read
/// as, the counts in words, the phase in words, and the payload each choice makes. The server checks every one again
/// and refuses with its own sentence.
public enum MirrorRelink {
    /// The console's page of entries.
    public static let page: Int64 = 50

    public static func kindText(_ kind: RelinkKind, peer: String) -> String {
        switch kind {
        case .onlyThis: "Only on this server"
        case .onlyTheirs: "Only on \(peer)"
        case .changedThis: "Changed here"
        case .changedTheirs: "Changed on \(peer)"
        case .changedBoth: "Changed on both"
        case .differs: "Differs"
        case .other(let raw): raw
        }
    }

    public static func choiceText(_ choice: RelinkChoice, peer: String) -> String {
        switch choice {
        case .this: "Keep this server’s"
        case .theirs: "Keep \(peer)’s"
        case .both: "Keep both"
        }
    }

    /// The plan's core, in words.
    public static func coreName(_ core: RelinkCore, peer: String) -> String {
        core == .this ? MirrorCopy.thisServer : peer
    }

    /// Which side's version an entry ends with, from its resolution and the plan's core; nil for a resolution this
    /// build doesn't know.
    public static func winnerOf(_ resolution: String, core: RelinkCore) -> RelinkChoice? {
        switch resolution {
        case "both": .both
        case "core": core == .this ? .this : .theirs
        case "mirror": core == .this ? .theirs : .this
        default: nil
        }
    }

    public struct CountLine: Hashable, Sendable {
        public var kind: RelinkKind
        public var label: String
        public var count: Int64
    }

    /// The drift counts that are not zero, in a fixed order.
    public static func countLines(_ counts: [RelinkKind: Int64], peer: String) -> [CountLine] {
        RelinkKind.known.compactMap { kind in
            let n = counts[kind] ?? 0
            return n > 0 ? CountLine(kind: kind, label: kindText(kind, peer: peer), count: n) : nil
        }
    }

    /// Only files may keep both versions (a folder's place is one or the other).
    public static func canKeepBoth(_ entry: RelinkEntry) -> Bool {
        entry.thisKind == "file" || entry.theirsKind == "file"
    }

    /// "takes 3 from the other, keeps 2 of its own as held changes, gains 1 conflict copy"; empty when unknown.
    public static func gainsText(_ g: RelinkGains?) -> String {
        guard let g else { return "" }
        var parts = ["takes \(g.takes) from the other"]
        parts.append("keeps \(g.keepsHeld) of its own as held change\(g.keepsHeld == 1 ? "" : "s")")
        if g.conflictCopies != 0 {
            parts.append("gains \(g.conflictCopies) conflict cop\(g.conflictCopies == 1 ? "y" : "ies")")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: The handshake

    /// The phases that wait on the other server's admin.
    public static let awaitingOther: Set<RelinkPhase> = [.requested, .proposed]
    /// Asked and answered, nothing applied yet.
    public static let handshake: Set<RelinkPhase> = [.requested, .accepted, .open, .proposed, .approved]
    /// A relink that ended: the sheet asks again on opening.
    public static let ended: Set<RelinkPhase> = [.done, .failed, .stale, .cancelled, .declined, .expired]

    public struct PhaseText: Hashable, Sendable {
        public var text: String
        /// Still moving: the sheet polls while it is.
        public var running: Bool
        public var tone: MirrorTone
    }

    /// The relink running: a sentence and whether it is still moving.
    public static func phaseText(_ status: RelinkStatus?, peer: String = "the other server") -> PhaseText {
        guard let r = status?.relink else { return .init(text: "Not compared yet.", running: false, tone: .info) }
        if r.side == .responder, handshake.contains(r.phase) {
            let text = switch r.phase {
            case .requested: "\(peer) asks to compare its copy with this vault: answer it under Relink requests."
            case .proposed: "\(peer) proposes an outcome: approve or decline it under Relink requests."
            case .approved: "Approved here: \(peer) carries it out."
            default: "Accepted here: \(peer) compares and proposes an outcome."
            }
            return .init(text: text, running: false, tone: r.phase == .requested || r.phase == .proposed ? .warn : .info)
        }
        switch r.phase {
        case .requested:
            return .init(text: "Waiting for \(peer)’s admin to accept the request. Nothing of its copy is compared before they do.",
                         running: true, tone: .info)
        case .accepted:
            return .init(text: "\(peer)’s admin accepted: comparing…", running: true, tone: .info)
        case .proposed:
            return .init(text: "Awaiting \(peer)’s approval of the outcome. Nothing changes on either server before they approve.",
                         running: true, tone: .info)
        case .approved:
            return .init(text: "\(peer)’s admin approved: carrying it out…", running: true, tone: .info)
        case .declined:
            return .init(text: r.error ?? "\(peer)’s admin declined. Neither copy changed.", running: false, tone: .warn)
        case .expired:
            return .init(text: r.error ?? "The request expired. Neither copy changed: ask again.", running: false, tone: .warn)
        case .open:
            return .init(text: "Compared. Choose how to resolve the drift.", running: false, tone: .info)
        case .prepared, .bring:
            return .init(text: "Bringing the chosen versions onto the core…", running: true, tone: .info)
        case .copying:
            return .init(text: "The mirror is copying the core’s tree…", running: true, tone: .info)
        case .done:
            return .init(text: "Relinked: both servers hold the same tree.", running: false, tone: .ok)
        case .stale:
            return .init(text: r.error ?? "The vault changed since it was compared: compare again.", running: false, tone: .warn)
        case .failed:
            return .init(text: r.error ?? "The relink failed.", running: false, tone: .danger)
        case .cancelled:
            return .init(text: r.error.flatMap { $0 != "discarded" ? $0 : nil } ?? "The relink was discarded.",
                         running: false, tone: .info)
        case .other(let raw):
            return .init(text: r.error ?? "The relink is \(raw).", running: false, tone: .unknown)
        }
    }

    /// A request a linked server made of this server, in words: what it asks the person here to decide.
    public static func requestAsk(_ q: RelinkRequest) -> String {
        let who = q.askedBy.map { "\(q.peerName) (\($0))" } ?? q.peerName
        switch q.phase {
        case .requested:
            return "\(who) asks to compare its copy with this vault."
        case .proposed:
            return "\(who) proposes how to reconnect this vault."
        case .accepted:
            return "Accepted\(q.handshake?.acceptedBy.map { " by \($0)" } ?? ""): \(q.peerName) compares and proposes an outcome, approved here."
        case .approved:
            return "Approved\(q.handshake?.approvedBy.map { " by \($0)" } ?? ""): \(q.peerName) carries it out."
        default:
            return "\(q.peerName)’s relink is \(q.phase.raw)."
        }
    }

    /// The sheet's relink as a key: asked again (or compared) at most once per relink and phase.
    public static func compareKey(_ status: RelinkStatus) -> String {
        status.relink.map { "\($0.uid):\($0.phase.raw)" } ?? "none"
    }

    /// Whether the sheet compares on its own, as the console's dialog does: once on opening when there is no relink
    /// to show (opening is the request: it asks the other server), and once the other server's admin accepted (this
    /// server then reads the two trees). Never for a relink waiting or running, never on the asked side.
    public static func shouldCompare(_ status: RelinkStatus, comparedOnce: Bool) -> Bool {
        let phase = status.relink?.phase
        let fresh = (phase == nil || ended.contains(phase!)) && !comparedOnce
        let accepted = phase == .accepted && status.relink?.side == .initiator
        return fresh || accepted
    }

    /// The asking side waits for the other server's admin (it may cancel the request).
    public static func isWaiting(_ status: RelinkStatus?) -> Bool {
        guard let r = status?.relink, r.side == .initiator else { return false }
        return awaitingOther.contains(r.phase)
    }

    /// Compared and open for choosing (the asking side only).
    public static func isOpen(_ status: RelinkStatus?) -> Bool {
        status?.relink?.phase == .open && status?.relink?.side == .initiator
    }

    /// "Ask again" after a relink that ended without a comparison standing, else "Compare again".
    public static func compareAgainLabel(_ status: RelinkStatus?) -> String {
        guard let phase = status?.relink?.phase, ended.contains(phase), phase != .done, phase != .stale else {
            return MirrorRelinkCopy.compareAgain
        }
        return MirrorRelinkCopy.askAgain
    }

    /// The linked server this vault relinks with: its own peer while that link stands, else the linked server with
    /// the same node; nil: the person chooses (nothing is preselected).
    public static func ownPeer(_ row: MirroredVault, linked: [(id: Int64, nodeID: String)]) -> Int64? {
        if let peer = row.peer, !peer.revoked { return peer.id }
        guard let node = row.peer?.nodeID else { return nil }
        return linked.first { $0.nodeID == node }?.id
    }

    // MARK: Requests

    /// `mirror.relink.compare {vault_id, peer}`: nil until a linked server is known.
    public static func comparePayload(_ row: MirroredVault, peerID: Int64?) -> Ws.Mirror.Relink.Compare.Payload? {
        guard let peerID else { return nil }
        return .init(vaultID: row.vaultID, peer: String(peerID))
    }

    public enum PlanEdit: Hashable, Sendable {
        case core(RelinkCore)
        /// nil: the core's version.
        case defaultChoice(RelinkChoice?)
        /// One entry's choice; nil: the plan's default.
        case entry(uid: String, choice: RelinkChoice?)
        /// Every shown entry (one kind, or nil: every kind); nil choice: the default.
        case shown(kind: RelinkKind?, choice: RelinkChoice?)
        /// Cancels the request (or discards the plan).
        case discard
    }

    /// `mirror.relink.plan`, as the console's controls send it.
    public static func planPayload(vaultID: Int64, _ edit: PlanEdit) -> Ws.Mirror.Relink.Plan.Payload {
        typealias P = Ws.Mirror.Relink.Plan.Payload
        switch edit {
        case .core(let core):
            return P(vaultID: vaultID, core: core == .this ? .this : .theirs)
        case .defaultChoice(let choice):
            return P(vaultID: vaultID, default: choice.flatMap { P.Default(rawValue: $0.rawValue) } ?? .empty)
        case .entry(let uid, let choice):
            return P(vaultID: vaultID,
                     set: [.init(uid: uid, choice: choice.flatMap { P.SetItem.Choice(rawValue: $0.rawValue) })])
        case .shown(let kind, let choice):
            return P(vaultID: vaultID, byKind: [.init(kind: kind?.raw ?? "",
                                                      choice: choice.flatMap { P.ByKindItem.Choice(rawValue: $0.rawValue) })])
        case .discard:
            return P(vaultID: vaultID, discard: true)
        }
    }

    /// `mirror.relink.apply {vault_id, confirm[, keep, peer]}`: nil until the vault's name is typed exactly. `keep`
    /// is the hard override (one server's tree wins everywhere); without it the plan applies.
    public static func applyPayload(_ row: MirroredVault, typed: String, keep: RelinkCore?, peerID: Int64?)
        -> Ws.Mirror.Relink.Apply.Payload?
    {
        guard MirrorActions.nameMatches(typed, row) else { return nil }
        guard let keep else { return .init(vaultID: row.vaultID, confirm: typed) }
        return .init(vaultID: row.vaultID, confirm: typed, keep: keep == .this ? .this : .theirs,
                     peer: peerID.map(String.init) ?? "")
    }

    public static func entriesPayload(vaultID: Int64, kind: RelinkKind?, offset: Int64) -> Ws.Mirror.Relink.Entries.Payload {
        .init(vaultID: vaultID, kind: kind.flatMap { Ws.Mirror.Relink.Entries.Payload.Kind(rawValue: $0.raw) },
              offset: offset, limit: page)
    }

    public static func acceptPayload(_ q: RelinkRequest) -> Ws.Mirror.Relink.Accept.Payload { .init(vaultID: q.vaultID) }
    public static func declinePayload(_ q: RelinkRequest) -> Ws.Mirror.Relink.Decline.Payload { .init(vaultID: q.vaultID) }

    /// `mirror.relink.approve {vault_id, confirm}`: nil until the vault's name is typed exactly.
    public static func approvePayload(_ q: RelinkRequest, typed: String) -> Ws.Mirror.Relink.Approve.Payload? {
        guard !q.vaultName.isEmpty, typed == q.vaultName else { return nil }
        return .init(vaultID: q.vaultID, confirm: typed)
    }

    /// "1–50 of 63", once there is more than a page.
    public static func pageText(offset: Int64, total: Int64, count: (Int64) -> String) -> String? {
        guard total > page else { return nil }
        return "\(offset + 1)–\(min(offset + page, total)) of \(count(total))"
    }

    /// "63 entries differ" / "1 entry differs" / "Both trees are the same."; nil while the total is unknown.
    public static func totalText(_ total: Int64?, count: (Int64) -> String) -> String? {
        guard let total else { return nil }
        if total == 0 { return MirrorRelinkCopy.same }
        return "\(count(total)) entr\(total == 1 ? "y differs" : "ies differ")"
    }
}
