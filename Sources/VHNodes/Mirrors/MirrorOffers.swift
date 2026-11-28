public import Foundation
public import VHContract

/// An offer a linked server made this server (`mirror.pending`): the vault it would copy here, who offers it and what
/// accepting grants. Every value the server didn't send stays nil.
public struct MirrorOffer: Identifiable, Hashable, Sendable {
    /// The offer's number on this server (what `mirror.accept` and `mirror.decline` name).
    public var id: Int64
    public var peerID: Int64
    public var name: String
    public var description: String
    public var sizeBytes: Int64
    public var fileCount: Int64
    public var history: Bool
    /// The vault's owner on the core, by name; nil when the server didn't say.
    public var ownerName: String?
    /// The role the core proposes for this server; nil: none.
    public var roleName: String?
    /// When the offer expires unanswered; nil when the server didn't say.
    public var expiresAt: Int64?

    public init(id: Int64, peerID: Int64, name: String, description: String = "", sizeBytes: Int64 = 0,
                fileCount: Int64 = 0, history: Bool = false, ownerName: String? = nil, roleName: String? = nil,
                expiresAt: Int64? = nil) {
        self.id = id
        self.peerID = peerID
        self.name = name
        self.description = description
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.history = history
        self.ownerName = ownerName
        self.roleName = roleName
        self.expiresAt = expiresAt
    }

    public init(_ wire: Ws.Mirror.Pending.Response.Offer) {
        self.init(id: wire.id, peerID: wire.peerID, name: wire.name, description: wire.description,
                  sizeBytes: wire.sizeBytes, fileCount: wire.fileCount, history: wire.history,
                  ownerName: wire.owner.name.isEmpty ? nil : wire.owner.name, roleName: wire.role?.roleName,
                  expiresAt: wire.expiresAt > 0 ? wire.expiresAt : nil)
    }
}

/// A change made on this server that the core refused (`mirror.held.list`): held (the entry went back to the core's
/// version and the change is kept with the reason) or turned into a conflict copy.
public struct MirrorHeldChange: Identifiable, Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case open, retried, discarded
        case other(String)

        public init(_ raw: String) {
            switch raw {
            case "open": self = .open
            case "retried": self = .retried
            case "discarded": self = .discarded
            default: self = .other(raw)
            }
        }
    }

    public var id: Int64
    public var vaultID: Int64
    /// `held` or `conflict` (and newer words).
    public var kind: String
    /// `mkdir`, `move`, `rename`, `remove`, `copy`, `write` (and newer words).
    public var op: String
    public var path: String?
    public var name: String
    public var copyName: String?
    public var personID: Int64
    public var reasonCode: String
    public var reason: String
    public var state: State
    public var createdAt: Int64

    public init(id: Int64, vaultID: Int64, kind: String, op: String, path: String?, name: String,
                copyName: String? = nil, personID: Int64, reasonCode: String, reason: String, state: State,
                createdAt: Int64) {
        self.id = id
        self.vaultID = vaultID
        self.kind = kind
        self.op = op
        self.path = path
        self.name = name
        self.copyName = copyName
        self.personID = personID
        self.reasonCode = reasonCode
        self.reason = reason
        self.state = state
        self.createdAt = createdAt
    }

    public init(_ wire: Ws.Mirror.Held.List.Response.HeldItem) {
        self.init(id: wire.id, vaultID: wire.vaultID, kind: wire.kind, op: wire.op, path: wire.path, name: wire.name,
                  copyName: wire.copyName, personID: wire.person.id, reasonCode: wire.reasonCode, reason: wire.reason,
                  state: State(wire.state), createdAt: wire.createdAt)
    }

    public var isConflict: Bool { kind == "conflict" }
    public var isOpen: Bool { state == .open }
}

/// One of a link's mirror settings, as the console's settings dialog shows it.
public enum MirrorLinkSetting: String, CaseIterable, Hashable, Sendable {
    /// `mirror.accept_all.set`: offers from that server are accepted without asking.
    case acceptAll
    /// `mirror.keep_removed.set`: a copy that server asks to remove stays here, orphaned.
    case keepRemoved
    /// `mirror.mirror_all.set`: this server offers that server every vault it owns, new ones included.
    case mirrorAll

    public var command: WsCommand {
        switch self {
        case .acceptAll: .mirrorAcceptAllSet
        case .keepRemoved: .mirrorKeepRemovedSet
        case .mirrorAll: .mirrorMirrorAllSet
        }
    }

    /// Turning it on lets vaults or keys move without a further question: it is asked once more, with what it does.
    public var widens: Bool { self != .keepRemoved }

    public func label(_ peer: String) -> String {
        switch self {
        case .acceptAll: MirrorCopy.acceptAllLabel(peer)
        case .keepRemoved: MirrorCopy.keepRemovedLabel(peer)
        case .mirrorAll: MirrorOfferCopy.mirrorAllLabel(peer)
        }
    }

    public func hint(_ peer: String) -> String {
        switch self {
        case .acceptAll: MirrorOfferCopy.acceptAllHint(peer)
        case .keepRemoved: MirrorOfferCopy.keepRemovedHint(peer)
        case .mirrorAll: MirrorOfferCopy.mirrorAllHint(peer)
        }
    }

    /// What turning it on does, said before the person confirms (the widening ones only).
    public func turnOnWarning(_ peer: String) -> String? {
        switch self {
        case .acceptAll: MirrorOfferCopy.acceptAllConfirmBody(peer)
        case .mirrorAll: MirrorOfferCopy.mirrorAllConfirmBody(peer)
        case .keepRemoved: nil
        }
    }

    /// The value a mirror row with that server reports, when one does (`settings` on `mirror.list` rows).
    public func value(in settings: MirroredVault.Settings) -> Bool {
        switch self {
        case .acceptAll: settings.acceptAll
        case .keepRemoved: settings.keepRemoved
        case .mirrorAll: settings.mirrorAll
        }
    }
}

/// The request building and the state rules of offers, held changes and link settings, beside ``MirrorModel``. The
/// server checks every one again and refuses with its own sentence.
public enum MirrorOffers {
    // MARK: Offers

    /// Start states an outgoing offer may still be cancelled in (the console's START_OPEN).
    static let openStartStates: Set<String> = [
        "offered", "pending", "accepted", "keys_acked", "installed", "started", "failed", "expired",
    ]

    /// Offers this server made that haven't finished (`mirror.list` starts whose side is the core): each may be
    /// cancelled.
    public static func outgoing(_ rows: [MirroredVault]) -> [MirroredVault] {
        rows.filter { row in
            guard row.role == .starting, let start = row.start else { return false }
            return start.side == "core" && openStartStates.contains(start.state)
        }
    }

    public static func acceptPayload(_ offer: MirrorOffer) -> Ws.Mirror.Accept.Payload {
        .init(offer: .integer(offer.id))
    }

    public static func declinePayload(_ offer: MirrorOffer) -> Ws.Mirror.Decline.Payload {
        .init(offer: .integer(offer.id))
    }

    /// Cancels an outgoing offer: by the vault, or by the offer while its vault doesn't exist here. Never asks the
    /// other server to remove anything (`remove_copy` is left unsent).
    public static func cancelPayload(_ row: MirroredVault) -> Ws.Mirror.Cancel.Payload {
        switch MirrorModel.cancelTarget(row) {
        case .vault(let id): .init(vaultID: id)
        case .offer(let id): .init(offer: .integer(id))
        }
    }

    /// The name a linked server goes by (the console's peerLabel).
    public static func peerLabel(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return MirrorCopy.unnamedServer }
        return name
    }

    // MARK: Mirror a vault

    /// Vaults that can be offered: not already mirrored or starting here (detached ones and unmirrored ones can).
    public static func offerable<V>(_ vaults: [V], id: (V) -> Int64, mirrored: [MirroredVault]) -> [V] {
        let busy = Set(mirrored.filter { $0.role != .detached && $0.role != .none }.map(\.vaultID))
        return vaults.filter { !busy.contains(id($0)) }
    }

    /// The offer to send, once both a vault and a linked server are chosen; nil until then (nothing is preselected).
    public static func addPayload(vaultID: Int64?, peerID: Int64?) -> Ws.Mirror.Add.Payload? {
        guard let vaultID, vaultID > 0, let peerID else { return nil }
        return .init(vaultID: vaultID, peer: String(peerID))
    }

    // MARK: Held changes

    static let opText: [String: String] = [
        "mkdir": "Created a folder", "move": "Moved", "rename": "Renamed", "remove": "Removed", "copy": "Copied",
        "write": "Saved a file",
    ]

    /// What was done, in words (an op this build doesn't know reads as itself).
    public static func heldWhat(_ held: MirrorHeldChange) -> String {
        if held.isConflict {
            return held.copyName.map(MirrorOfferCopy.heldConflictAs) ?? MirrorOfferCopy.heldConflict
        }
        return opText[held.op] ?? held.op
    }

    public static func heldPath(_ held: MirrorHeldChange) -> String {
        if let path = held.path, !path.isEmpty { return path }
        if !held.name.isEmpty { return held.name }
        return MirrorOfferCopy.heldUnknownPath
    }

    /// The core's refusal, in its words (its code when it gave none).
    public static func heldReason(_ held: MirrorHeldChange) -> String {
        held.reason.isEmpty ? held.reasonCode : held.reason
    }

    public static func heldStateText(_ state: MirrorHeldChange.State) -> String {
        switch state {
        case .open: "Open"
        case .retried: "Retried"
        case .discarded: "Discarded"
        case .other(let raw): raw
        }
    }

    public static func heldStateTone(_ state: MirrorHeldChange.State) -> MirrorTone {
        switch state {
        case .open: .warn
        case .retried: .info
        case .discarded: .neutral
        case .other: .unknown
        }
    }

    /// Only a held write's bytes can be saved (`mirror.held.get` answers no other).
    public static func canSave(_ held: MirrorHeldChange) -> Bool {
        held.isOpen && held.op == "write" && held.kind == "held"
    }

    /// Only an open held change (not a conflict copy) can be retried, and only while the vault is live here.
    public static func canRetry(_ held: MirrorHeldChange) -> Bool {
        held.isOpen && held.kind == "held"
    }

    public static func canDiscard(_ held: MirrorHeldChange) -> Bool { held.isOpen }

    /// Whether retrying can work: the vault live here and its link not known to be down (the console's `live`).
    public static func retryIsLive(_ row: MirroredVault) -> Bool {
        row.state == .live && row.linkIsUp != false
    }

    /// The discard question's body: a conflict copy's record is dismissed, a held change dropped.
    public static func discardBody(_ held: MirrorHeldChange) -> String {
        held.isConflict ? MirrorOfferCopy.heldDiscardConflictBody : MirrorOfferCopy.heldDiscardBody(heldPath(held))
    }

    /// Newest first, as the console's table starts.
    public static func sortedHeld(_ held: [MirrorHeldChange]) -> [MirrorHeldChange] {
        held.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id > $1.id }
    }

    /// The command that saves a version too large to send inline.
    public static func saveCommand(_ held: MirrorHeldChange) -> String {
        "vh mirror save \(held.id) ./\(held.name.isEmpty ? "held-version" : held.name)"
    }

    public static func heldListPayload(vaultID: Int64, all: Bool) -> Ws.Mirror.Held.List.Payload {
        .init(vaultID: vaultID, all: all ? true : nil)
    }

    // MARK: Link settings

    /// What a linked server's setting is, from the mirror rows with it: nil while no row reports it (unknown, never
    /// guessed off).
    public static func current(_ setting: MirrorLinkSetting, peerID: Int64, rows: [MirroredVault]) -> Bool? {
        rows.first { $0.peer?.id == peerID && !($0.peer?.revoked ?? true) && $0.settings != nil }
            .flatMap(\.settings).map(setting.value(in:))
    }

    public static func settingPayload(peerID: Int64, enabled: Bool) -> (peer: String, enabled: Bool) {
        (String(peerID), enabled)
    }
}
