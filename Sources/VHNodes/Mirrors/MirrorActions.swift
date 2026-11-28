public import Foundation
public import VHContract
public import VHTransport

/// The pure side of a mirrored vault's actions, ported from the web console's action dialogs
/// (`web/src/features/mirrors/*Dialog.tsx`, server main): the request each one sends, what the person must have
/// done first (a typed name, a ticked box), and what each answer leaves on screen. The sheets call these; the server
/// checks every action again and refuses with its own sentence.
public enum MirrorActions {
    /// Every read a mirror action can change, as command prefixes: the mirror reads and the vault list (a detach, a
    /// take over or a copy changes vaults).
    public static let invalidating = ["mirror", "storage.vault"]

    /// The refusal that means the old core would keep no role on the vault on its new core: answered by sending the
    /// switch again with `accept_no_access` once the person ticks the box.
    public static let switchNoRole = "mirror_switch_no_role"

    /// The refusal of a vault deletion that needs the mirror choice (`mirror_copy`).
    public static let copyChoiceRequired = "mirror_copy_choice_required"

    // MARK: Requests

    /// Whether `typed` is the vault's name exactly, as the console compares it (no trimming, no case folding).
    public static func nameMatches(_ typed: String, _ row: MirroredVault) -> Bool {
        !row.vaultName.isEmpty && typed == row.vaultName
    }

    /// `mirror.switch`: `accept_no_access` only once the server refused for want of a role and the person ticked
    /// the box.
    public static func switchPayload(_ row: MirroredVault, acceptNoAccess: Bool) -> Ws.Mirror.Switch.Payload {
        .init(vaultID: row.vaultID, acceptNoAccess: acceptNoAccess ? true : nil)
    }

    /// `mirror.takeover {vault_id, confirm}`: nil until the vault's name is typed exactly.
    public static func takeoverPayload(_ row: MirroredVault, typed: String) -> Ws.Mirror.Takeover.Payload? {
        nameMatches(typed, row) ? .init(vaultID: row.vaultID, confirm: typed) : nil
    }

    public static func resyncPayload(_ row: MirroredVault) -> Ws.Mirror.Resync.Payload {
        .init(vaultID: row.vaultID)
    }

    /// `mirror.detach {vault_id, owner, confirm_name}`: nil until the vault's name is typed exactly. A blank owner is
    /// the caller (sent as null, as the console does).
    public static func detachPayload(_ row: MirroredVault, owner: String, typed: String) -> Ws.Mirror.Detach.Payload? {
        guard nameMatches(typed, row) else { return nil }
        return .init(vaultID: row.vaultID, owner: owner.isEmpty ? .null : .value(owner), confirmName: .value(typed))
    }

    /// `mirror.detach.copy {vault_id, name, owner}`: a blank name is the server's "<name> copy", a blank owner the
    /// caller (both sent as null).
    public static func copyPayload(_ row: MirroredVault, name: String, owner: String) -> Ws.Mirror.Detach.Copy.Payload {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(vaultID: row.vaultID, name: trimmed.isEmpty ? .null : .value(trimmed),
                     owner: owner.isEmpty ? .null : .value(owner))
    }

    /// `mirror.cancel {vault_id, remove_copy}` on the core: what the other server does with its copy, as chosen.
    public static func endPayload(_ row: MirroredVault, removeCopy: Bool) -> Ws.Mirror.Cancel.Payload {
        .init(vaultID: row.vaultID, removeCopy: removeCopy)
    }

    /// `mirror.cancel` for an orphaned copy or a start: the vault, or the offer while its vault doesn't exist here.
    public static func cancelPayload(_ row: MirroredVault) -> Ws.Mirror.Cancel.Payload {
        switch MirrorModel.cancelTarget(row) {
        case .vault(let id): .init(vaultID: id)
        case .offer(let id): .init(offer: .integer(id))
        }
    }

    // MARK: Switch

    /// Who the core role moves from and to, as the console names them ("this server" or the other's name).
    public static func switchSides(_ row: MirroredVault) -> (from: String, to: String) {
        let peer = MirrorModel.peerName(row)
        return row.role == .core ? (MirrorCopy.thisServer, peer) : (peer, MirrorCopy.thisServer)
    }

    /// Sentences may start with "this server"; a server's own name keeps its spelling.
    public static func capitalized(_ sentence: String) -> String {
        sentence.hasPrefix(MirrorCopy.thisServer) ? "T" + sentence.dropFirst() : sentence
    }

    /// What the old core keeps after a switch (`peer_access` / `peer_role`), in words.
    public static func accessText(_ response: Ws.Mirror.Switch.Response, oldCore: String) -> String {
        if response.peerAccess == "none" { return MirrorCopy.switchKeepsNone(oldCore) }
        let how = response.peerAccess == "read-write" ? MirrorCopy.accessReadWrite : MirrorCopy.accessReadOnly
        return MirrorCopy.switchKeeps(oldCore, how, role: response.peerRole?.roleName)
    }

    /// The switch sheet's state: the form (with the server's no-role sentence and the person's tick once it refused
    /// for that), then the outcome it waited for.
    public struct SwitchFlow: Hashable, Sendable {
        public enum Outcome: Hashable, Sendable {
            /// The new core's name and what the old core keeps, capitalised.
            case switched(body: String, access: String)
            /// Nothing changed, with the reason in words.
            case abandoned(body: String)
            case running
        }

        /// The server's sentence for `mirror_switch_no_role`; nil until it refused for that.
        public private(set) var noRole: String?
        /// The person's tick under that sentence. Never set for them.
        public var acceptNoAccess = false
        public private(set) var outcome: Outcome?
        /// Any other refusal, shown as the server's sentence.
        public private(set) var failure: WsError?

        public init() {}

        /// The switch may be asked: always at first; after the no-role refusal only once the box is ticked.
        public var canConfirm: Bool { noRole == nil || acceptNoAccess }

        public func payload(_ row: MirroredVault) -> Ws.Mirror.Switch.Payload {
            MirrorActions.switchPayload(row, acceptNoAccess: noRole != nil && acceptNoAccess)
        }

        public mutating func answered(_ response: Ws.Mirror.Switch.Response, row: MirroredVault) {
            failure = nil
            let (from, to) = MirrorActions.switchSides(row)
            switch response.outcome {
            case "switched":
                outcome = .switched(body: MirrorActions.capitalized(MirrorCopy.switchedBody(to)),
                                    access: MirrorActions.capitalized(MirrorActions.accessText(response, oldCore: from)))
            case "abandoned":
                let why = response.reason.map { MirrorModel.reason($0) ?? $0 }
                outcome = .abandoned(body: MirrorCopy.switchAbandonedBody(why))
            default:
                outcome = .running
            }
        }

        public mutating func failed(_ error: WsError) {
            if error.code == MirrorActions.switchNoRole {
                noRole = error.message
                failure = nil
            } else {
                failure = error
            }
        }
    }

    // MARK: Take over

    /// What the take over's answer says, in the console's words.
    public struct TakeoverOutcome: Hashable, Sendable {
        public var body: String
        public var missing: String?
        public var warning: String?

        public init(_ response: Ws.Mirror.Takeover.Response) {
            body = MirrorCopy.tookOverBody(made: response.pendingMadeLocal, held: response.held)
            missing = response.contentsMissing != 0 ? MirrorCopy.takeoverMissing(response.contentsMissing) : nil
            warning = response.warning.isEmpty ? nil : response.warning
        }
    }

    // MARK: Detach

    /// What the detach preview says detaching would give, as the console's list: an unfinished first copy, pending
    /// changes made ordinary, held changes kept, and the keys.
    public static func detachLines(_ preview: Ws.Mirror.Detach.Preview.Response.Preview) -> [String] {
        var lines: [String] = []
        let first = MirroredVault.FirstCopy(finished: preview.firstCopy.finished,
                                            entriesCopied: preview.firstCopy.entriesCopied,
                                            entriesTotal: preview.firstCopy.entriesTotal)
        if let progress = MirrorModel.firstCopyProgress(first) { lines.append(MirrorCopy.detachUnfinished(progress.text)) }
        if preview.pendingChanges != 0 { lines.append(MirrorCopy.detachPending(preview.pendingChanges)) }
        if preview.heldChanges != 0 { lines.append(MirrorCopy.detachHeld(preview.heldChanges)) }
        lines.append(MirrorCopy.detachRekey)
        return lines
    }

    /// What the take over sheet lists from the same preview: the pending changes and missing files.
    public static func takeoverLines(_ preview: Ws.Mirror.Detach.Preview.Response.Preview) -> [String] {
        var lines: [String] = []
        if preview.pendingChanges != 0 { lines.append(MirrorCopy.takeoverPending(preview.pendingChanges)) }
        if preview.missingCount != 0 { lines.append(MirrorCopy.takeoverMissing(preview.missingCount)) }
        return lines
    }

    // MARK: Versions

    /// A limit field: blank is the server's default (nil), else a whole number, 0 or more (0 is no limit).
    public enum Limit: Hashable, Sendable {
        case value(Int64?)
        case invalid(String)

        public init(_ text: String) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { self = .value(nil); return }
            guard t.count <= 15, t.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int64(t) else {
                self = .invalid(MirrorCopy.limitInvalid)
                return
            }
            self = .value(n)
        }

        public var error: String? {
            if case .invalid(let error) = self { return error }
            return nil
        }
    }

    /// `mirror.versions.set`: off sends only `enabled`; on sends the three limits (blank as null: the defaults). nil
    /// while a limit is not a whole number.
    public static func versionsPayload(_ row: MirroredVault, enabled: Bool, keepLast: String, maxAge: String,
                                       quota: String) -> Ws.Mirror.Versions.Set.Payload? {
        guard enabled else { return .init(vaultID: row.vaultID, enabled: false) }
        let limits = [Limit(keepLast), Limit(maxAge), Limit(quota)]
        var values: [Nullable<Int64>] = []
        for limit in limits {
            guard case .value(let v) = limit else { return nil }
            values.append(v.map { .value($0) } ?? .null)
        }
        return .init(vaultID: row.vaultID, enabled: true, keepLast: values[0], maxAgeDays: values[1],
                     quotaBytes: values[2])
    }

    public static func versionsText(_ versions: Ws.Mirror.Versions.Set.Response.Versions,
                                    bytes: (Int64) -> String) -> String {
        MirrorModel.versionsText(.init(enabled: versions.enabled, keepLast: versions.keepLast,
                                       maxAgeDays: versions.maxAgeDays, quotaBytes: versions.quotaBytes),
                                 bytes: bytes)
    }

    // MARK: A vault's deletion

    /// What a vault's deletion must say about its mirror (`mirror.get` role, or the refusal that names the choice).
    public enum Deletion: Hashable, Sendable {
        /// Not mirrored, or not known to be.
        case none
        /// The core: what happens to the other server's copy must be chosen (nothing is chosen for the person).
        case choose
        /// A copy held here: it can't be deleted; detach it or end the mirror on its core.
        case heldCopy
        /// An orphaned copy: removed from the mirror page.
        case orphan
    }

    public static func deletion(role: MirrorRole?, choiceRequired: Bool) -> Deletion {
        switch role {
        case .mirror?: .heldCopy
        case .orphaned?: .orphan
        case .core?: .choose
        default: choiceRequired ? .choose : .none
        }
    }
}

/// A copy job (`mirror.detach.copy`, `.get` and `.cancel` answer the same row as three generated types), in one
/// shape. Every value is as sent.
public struct MirrorCopyJob: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case running, finished, failed, cancelled
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "running": self = .running
            case "finished": self = .finished
            case "failed": self = .failed
            case "cancelled": self = .cancelled
            default: self = .other(raw)
            }
        }
    }

    public struct Skipped: Hashable, Sendable, Decodable {
        public var path: String
        public var sizeBytes: Int64
        public var reason: String

        enum CodingKeys: String, CodingKey {
            case path
            case sizeBytes = "size_bytes"
            case reason
        }
    }

    public var id: Int64
    public var vaultID: Int64?
    public var name: String
    public var state: State
    public var entriesTotal: Int64
    public var entriesDone: Int64
    public var bytesTotal: Int64
    public var bytesDone: Int64
    public var skippedCount: Int64
    public var skipped: [Skipped]
    public var error: String?
    public var cancelRequested: Bool
    public var updatedAt: Int64
    public var finishedAt: Int64?

    public init(id: Int64, vaultID: Int64? = nil, name: String, state: State, entriesTotal: Int64 = 0,
                entriesDone: Int64 = 0, bytesTotal: Int64 = 0, bytesDone: Int64 = 0, skippedCount: Int64 = 0,
                skipped: [Skipped] = [], error: String? = nil, cancelRequested: Bool = false, updatedAt: Int64 = 0,
                finishedAt: Int64? = nil) {
        self.id = id
        self.vaultID = vaultID
        self.name = name
        self.state = state
        self.entriesTotal = entriesTotal
        self.entriesDone = entriesDone
        self.bytesTotal = bytesTotal
        self.bytesDone = bytesDone
        self.skippedCount = skippedCount
        self.skipped = skipped
        self.error = error
        self.cancelRequested = cancelRequested
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
    }

    private struct Wire: Decodable {
        var id: Int64
        var vault_id: Int64?
        var name: String
        var state: String
        var entries_total: Int64
        var entries_done: Int64
        var bytes_total: Int64
        var bytes_done: Int64
        var skipped_count: Int64
        var skipped: [Skipped]
        var error: String?
        var cancel_requested: Bool
        var updated_at: Int64
        var finished_at: Int64?
    }

    /// From any of the three generated rows (they have the same members); nil should they ever differ.
    init?(wire: some Encodable) {
        guard let w = try? JSONDecoder().decode(Wire.self, from: JSONEncoder().encode(wire)) else { return nil }
        self.init(id: w.id, vaultID: w.vault_id, name: w.name, state: State(w.state), entriesTotal: w.entries_total,
                  entriesDone: w.entries_done, bytesTotal: w.bytes_total, bytesDone: w.bytes_done,
                  skippedCount: w.skipped_count, skipped: w.skipped, error: w.error,
                  cancelRequested: w.cancel_requested, updatedAt: w.updated_at, finishedAt: w.finished_at)
    }

    public init?(_ copy: Ws.Mirror.Detach.Copy.Response.Copy) { self.init(wire: copy) }
    public init?(_ copy: Ws.Mirror.Detach.Copy.Get.Response.Copy) { self.init(wire: copy) }
    public init?(_ copy: Ws.Mirror.Detach.Copy.Cancel.Response.Copy) { self.init(wire: copy) }

    public var isRunning: Bool { state == .running }

    /// The progress (entries, and bytes once the total is known): a ratio for the meter, nil while the totals are
    /// unknown, and "120 of 400 entries · 1.2 GB of 3 GB".
    public func progress(bytes: (Int64) -> String) -> MirrorModel.Progress {
        let ratio: Double? = bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal))
            : entriesTotal > 0 ? min(1, Double(entriesDone) / Double(entriesTotal)) : nil
        let entries = entriesTotal > 0
            ? MirrorCopy.progress(MirrorCopy.number(entriesDone), MirrorCopy.number(entriesTotal))
            : MirrorCopy.progressUnknown(MirrorCopy.number(entriesDone))
        let size = bytesTotal > 0 ? MirrorCopy.copyBytes(bytes(bytesDone), bytes(bytesTotal)) : nil
        return MirrorModel.Progress(ratio: ratio, text: size.map { "\(entries) · \($0)" } ?? entries)
    }

    /// Why a file was left out, in words; the code itself when this build has none.
    public static func skipText(_ reason: String) -> String {
        switch reason {
        case "contents_missing": "its contents never arrived here"
        case "removed": "it was removed while the copy ran"
        case "unreadable": "it could not be read"
        default: reason
        }
    }

    /// What the copy sheet shows (the console's rule): the newest job, standing in the start's answer for it until
    /// the read catches up with the copy just started; it is `shown` (progress or outcome) while it runs or when it
    /// is the one this sheet started, otherwise the form shows with a line about it.
    public static func shown(read: MirrorCopyJob?, started: MirrorCopyJob?, followed: Int64?)
        -> (latest: MirrorCopyJob?, shown: MirrorCopyJob?)
    {
        var latest = read
        if let followed, let started, read.map({ $0.id < followed }) ?? true { latest = started }
        guard let job = latest, job.isRunning || job.id == followed else { return (latest, nil) }
        return (latest, job)
    }
}
