import Foundation

/// The pure rules of the Mirrored Vaults pages, ported from the web console's `web/src/features/mirrors/model.ts`
/// (server main): what a vault's role and state read as, the advice for what can be done next, and which actions
/// apply to which role and state. The views and the action pieces call these; nothing here talks to a node, and the
/// server checks every action again.
public enum MirrorModel {
    // MARK: Names

    public static func peerName(_ row: MirroredVault) -> String {
        guard let peer = row.peer else { return MirrorCopy.noServer }
        return peer.name.isEmpty ? MirrorCopy.unnamedServer : peer.name
    }

    public struct Label: Hashable, Sendable {
        public var label: String
        public var tone: MirrorTone
    }

    public static func roleText(_ role: MirrorRole) -> Label {
        switch role {
        case .core: Label(label: "Core", tone: .info)
        case .mirror: Label(label: "Mirror", tone: .info)
        case .orphaned: Label(label: "Orphaned copy", tone: .warn)
        case .starting: Label(label: "Starting", tone: .info)
        case .detached: Label(label: "Detached", tone: .neutral)
        case .none: Label(label: "Not mirrored", tone: .neutral)
        case .other(let raw): Label(label: raw, tone: .unknown)
        }
    }

    /// "This server's role" in one sentence, with the other server's name.
    public static func roleSentence(_ row: MirroredVault) -> String {
        let peer = peerName(row)
        switch row.role {
        case .core: return MirrorCopy.roleCore(peer)
        case .mirror: return MirrorCopy.roleMirror(peer)
        case .orphaned: return MirrorCopy.roleOrphaned(peer)
        case .starting:
            return row.start?.side == "mirror" ? MirrorCopy.roleStartingMirror(peer) : MirrorCopy.roleStartingCore(peer)
        case .detached: return MirrorCopy.roleDetached
        case .none, .other: return MirrorCopy.roleNone
        }
    }

    // MARK: Reasons

    /// The stop and read-only reasons the server records, in words. Anything else falls back to the state's generic
    /// sentence with the code beside it.
    public static let reasonText: [String: String] = [
        "mirror_link_down": "the link to the other server is down",
        "mirror_paused": "the mirror is paused",
        "mirror_core_deleting": "its core is deleting the vault",
        "mirror_switching": "the core role is moving between the two servers",
        "mirror_diverged": "the two copies stopped matching",
        "mirror_core_diverged": "the core found that the two copies stopped matching",
        "mirror_digest_mismatch": "the two copies stopped matching",
        "mirror_scrub_mismatch": "a check found a file that differs from the core’s",
        "mirror_copy_mismatch": "the first copy did not match the core’s files",
        "mirror_revert_mismatch": "a change made here could not be undone cleanly",
        "mirror_settle_moved_digest": "the copies stopped matching while a change was being confirmed",
        "mirror_expired": "the core no longer keeps the changes this copy missed",
        "mirror_log_expired": "the core no longer keeps the changes this copy missed",
        "mirror_log_chain": "the core’s list of changes had a gap",
        "mirror_group_gap": "the core’s list of changes had a gap",
        "mirror_copy_gap": "the first copy had a gap",
        "mirror_term_changed": "the core started a new term",
        "mirror_log_malformed": "the core sent changes this server could not read",
        "mirror_tree_malformed": "the core sent a file list this server could not read",
        "mirror_unknown_op": "the core sent a change this server does not understand",
        "mirror_type_mismatch": "an entry is a file on one server and a folder on the other",
        "mirror_entry_missing": "an entry the core changed is missing here",
        "mirror_entry_unrecorded": "an entry the core changed was never recorded here",
        "mirror_content_unexpected": "the core sent contents this server did not expect",
        "mirror_fetch_failed": "a file’s contents could not be fetched from the core",
        "mirror_fetch_timeout": "fetching a file’s contents from the core timed out",
        "mirror_contents_missing": "some files’ contents never arrived",
        "mirror_hash": "a file’s contents did not match their checksum",
        "mirror_key_missing": "a key this vault needs is missing here",
        "mirror_keys_refused": "the vault’s keys were refused",
        "mirror_keys_unproven": "the vault’s keys could not be proven",
        "mirror_vault_root_missing": "the vault’s folder is missing on this server",
        "mirror_vault_engine_missing": "the vault is not loaded on this server",
        "mirror_resync_failed": "starting the copy over failed",
        "mirror_resync_refused": "the core refused to start the copy over",
        "mirror_core_gone": "the core no longer has the vault",
        "mirror_gone": "the other server no longer has the vault",
        "mirror_core_unreachable": "the core could not be reached",
        "mirror_orphaned": "its core ended the mirror",
        "mirror_first_copy": "the first copy is not finished",
        "mirror_stopped": "the mirror stopped",
        "mirror_rejoining": "the other server took over as the core and this server holds changes it never received",
        "mirror_both_forced": "both servers took over as the core while they were cut off",
        "mirror_copy_writing": "a copy is still being written into it",
    ]

    private static let divergedItself: Set<String> = ["mirror_diverged", "mirror_core_diverged", "mirror_digest_mismatch"]

    public static func reason(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return reasonText[code]
    }

    // MARK: Status

    public struct Status: Hashable, Sendable {
        public var label: String
        public var tone: MirrorTone
        /// One or two plain sentences: what it means here.
        public var sentence: String
        /// The stop reason's code when the sentence is generic (shown small beside it).
        public var code: String?
    }

    /// What the status rules need beyond the row.
    public struct Facts: Sendable {
        /// Whether the link to the vault's other server is up; nil while unknown.
        public var linkUp: Bool?
        /// The first copy's progress.
        public var firstCopy: MirroredVault.FirstCopy?
        /// Formats a purge date (unix seconds).
        public var date: @Sendable (Int64) -> String

        public init(linkUp: Bool?, firstCopy: MirroredVault.FirstCopy? = nil,
                    date: @escaping @Sendable (Int64) -> String) {
            self.linkUp = linkUp
            self.firstCopy = firstCopy
            self.date = date
        }

        /// The row's own facts: its link and first copy.
        public static func of(_ row: MirroredVault, date: @escaping @Sendable (Int64) -> String) -> Facts {
            Facts(linkUp: row.linkIsUp, firstCopy: row.firstCopy, date: date)
        }
    }

    private static func deletingCopyRemoved(_ d: MirroredVault.Deleting) -> Bool {
        let here = (d.here ?? "").lowercased()
        if here.contains("kept") || here.contains("orphan") || here.contains("leave") { return false }
        if here.contains("remov") { return true }
        return d.copy == "remove"
    }

    private static func startStatus(_ row: MirroredVault, peer: String) -> Status {
        let s = row.start
        // The reason in words, else the server's error text, else the bare code (the console shows the code; its
        // error text says more, and the code still shows beside the sentence).
        let why = reason(s?.reason) ?? s?.lastError.flatMap { $0.isEmpty ? nil : $0 } ?? s?.reason
        let ours = s?.side == "mirror"
        switch s?.state {
        case "offered", "pending":
            return ours
                ? Status(label: MirrorCopy.stWaitingYou, tone: .warn, sentence: MirrorCopy.stWaitingYouBody(peer))
                : Status(label: MirrorCopy.stWaitingThem, tone: .info, sentence: MirrorCopy.stWaitingThemBody(peer))
        case "accepted", "keys_acked":
            return Status(label: MirrorCopy.stKeys, tone: .info, sentence: MirrorCopy.stKeysBody)
        case "installed", "started":
            return Status(label: MirrorCopy.stStarting, tone: .info, sentence: MirrorCopy.stStartingBody)
        case "declined":
            return Status(label: MirrorCopy.stDeclined, tone: .danger,
                          sentence: ours ? MirrorCopy.stDeclinedHere : MirrorCopy.stDeclinedBody(peer))
        case "cancelled":
            return Status(label: MirrorCopy.stCancelled, tone: .neutral, sentence: MirrorCopy.stCancelledBody)
        case "expired":
            return Status(label: MirrorCopy.stOfferExpired, tone: .warn, sentence: MirrorCopy.stOfferExpiredBody(peer))
        case "failed":
            return Status(label: MirrorCopy.stFailed, tone: .danger, sentence: MirrorCopy.stFailedBody(why),
                          code: reason(s?.reason) == nil && why != s?.reason ? s?.reason : nil)
        default:
            return Status(label: MirrorCopy.stStarting, tone: .info, sentence: MirrorCopy.stStartingBody)
        }
    }

    /// A mirrored vault's state with its reason, in words. Read-only is said as such, never guessed healthy: a mirror
    /// whose link is down is read-only, and a state the server didn't send is Unknown.
    public static func status(_ row: MirroredVault, _ facts: Facts) -> Status {
        let peer = peerName(row)
        switch row.role {
        case .starting: return startStatus(row, peer: peer)
        case .detached:
            let theirs = row.detached?.side == "core"
            return Status(label: MirrorCopy.stDetached, tone: .neutral,
                          sentence: theirs ? MirrorCopy.stDetachedThere(peer) : MirrorCopy.stDetachedHere(peer))
        case .none: return Status(label: MirrorCopy.stNone, tone: .neutral, sentence: MirrorCopy.stNoneBody)
        case .other: return Status(label: MirrorCopy.stUnknown, tone: .unknown, sentence: MirrorCopy.stUnknownBody)
        case .core, .mirror, .orphaned: break
        }

        if let deleting = row.deleting, deleting.deleting {
            let when = facts.date(deleting.purgeAfter)
            if row.role == .core {
                return Status(label: MirrorCopy.stDeleting, tone: .warn,
                              sentence: MirrorCopy.stDeletingCore(when, peer, remove: deleting.copy == "remove"))
            }
            return Status(label: MirrorCopy.stCoreDeleting, tone: .warn,
                          sentence: MirrorCopy.stCoreDeletingBody(peer, when, removed: deletingCopyRemoved(deleting)))
        }
        if row.role == .orphaned {
            return Status(label: MirrorCopy.stOrphaned, tone: .warn, sentence: MirrorCopy.stOrphanedBody(peer))
        }

        let core = row.role == .core
        let why = reason(row.stopReason)
        let code = row.stopReason.flatMap { $0.isEmpty || why != nil ? nil : $0 }
        switch row.state {
        case .live:
            if core, row.takeover != nil {
                return Status(label: MirrorCopy.stTookOver, tone: .info, sentence: MirrorCopy.stTookOverBody(peer))
            }
            if !core, let first = facts.firstCopy, !first.finished { return firstCopy(row, facts, peer: peer) }
            if facts.linkUp == false {
                return core
                    ? Status(label: MirrorCopy.stLiveLinkDown, tone: .warn, sentence: MirrorCopy.stLiveLinkDownCore(peer))
                    : Status(label: MirrorCopy.stReadOnlyLink, tone: .warn, sentence: MirrorCopy.stReadOnlyLinkBody(peer))
            }
            return Status(label: MirrorCopy.stLive, tone: .ok,
                          sentence: core ? MirrorCopy.stLiveCore(peer) : MirrorCopy.stLiveMirror(peer))
        case .starting:
            return firstCopy(row, facts, peer: peer)
        case .paused:
            return Status(label: MirrorCopy.stPaused, tone: .warn,
                          sentence: core ? MirrorCopy.stPausedCore(peer, why) : MirrorCopy.stPausedMirror(why), code: code)
        case .diverged:
            // "The copies stopped matching" is what diverged means: only a more specific reason is worth adding.
            let specific = row.stopReason.map { divergedItself.contains($0) } == true ? nil : why
            return Status(label: MirrorCopy.stDiverged, tone: .danger,
                          sentence: core ? MirrorCopy.stDivergedCore(peer) : MirrorCopy.stDivergedMirror(specific),
                          code: code)
        case .expired:
            return Status(label: MirrorCopy.stExpired, tone: .danger,
                          sentence: core ? MirrorCopy.stExpiredCore(peer) : MirrorCopy.stExpiredMirror, code: code)
        case .stopped:
            return Status(label: MirrorCopy.stStopped, tone: .danger,
                          sentence: core ? MirrorCopy.stStoppedCore(peer, why) : MirrorCopy.stStoppedMirror(why),
                          code: code)
        case .switching:
            return Status(label: MirrorCopy.stSwitching, tone: .info, sentence: MirrorCopy.stSwitchingBody)
        case .rejoining:
            return Status(label: MirrorCopy.stRejoining, tone: .danger, sentence: MirrorCopy.stRejoiningBody(peer))
        case .forked:
            return Status(label: MirrorCopy.stForked, tone: .danger, sentence: MirrorCopy.stForkedBody)
        case .other, nil:
            return Status(label: MirrorCopy.stUnknown, tone: .unknown, sentence: MirrorCopy.stUnknownBody)
        }
    }

    private static func firstCopy(_ row: MirroredVault, _ facts: Facts, peer: String) -> Status {
        if row.role == .core {
            return Status(label: MirrorCopy.stFirstCopy, tone: .info, sentence: MirrorCopy.stFirstCopyCore(peer))
        }
        let progress = firstCopyProgress(facts.firstCopy)
        return Status(label: MirrorCopy.stFirstCopy, tone: .info,
                      sentence: MirrorCopy.stFirstCopyMirror(peer, progress?.text))
    }

    public struct Progress: Hashable, Sendable {
        /// 0…1 for a meter; nil while the total is unknown.
        public var ratio: Double?
        /// "120 of 4,000 entries".
        public var text: String
    }

    /// The first copy's progress on the mirror side; nil once finished or when nothing was counted.
    public static func firstCopyProgress(_ first: MirroredVault.FirstCopy?) -> Progress? {
        guard let first, !first.finished, let copied = first.entriesCopied else { return nil }
        if let total = first.entriesTotal, total > 0 {
            return Progress(ratio: min(1, Double(copied) / Double(total)),
                            text: MirrorCopy.progress(MirrorCopy.number(copied), MirrorCopy.number(total)))
        }
        return Progress(ratio: nil, text: MirrorCopy.progressUnknown(MirrorCopy.number(copied)))
    }

    // MARK: Position

    /// Where the two copies stand: the last change numbered here, and the last one the other side confirmed.
    public static func positionText(_ row: MirroredVault) -> String {
        guard let seq = row.lastSeq, let term = row.term else { return MirrorCopy.posNone }
        let confirmed = row.acked.map { MirrorCopy.posConfirmed($0.seq, $0.term) } ?? MirrorCopy.posNothingConfirmed
        return "\(MirrorCopy.posAt(seq, term)) · \(confirmed)"
    }

    /// Changes the core has numbered that the mirror hasn't confirmed yet (same term only; nil when it can't be told).
    public static func unconfirmed(_ row: MirroredVault) -> Int64? {
        guard row.role == .core, let seq = row.lastSeq, let term = row.term else { return nil }
        guard let acked = row.acked else { return seq }
        guard acked.term == term else { return nil }
        return max(0, seq - acked.seq)
    }

    // MARK: Actions

    private static let startOpen: Set<String> = [
        "offered", "pending", "accepted", "keys_acked", "installed", "started", "failed", "expired",
    ]

    /// Whether this server's copy may take over as the core: a mirror (not orphaned) whose first copy finished and
    /// that still matches its core. Unknown (nil) hides it. The server also refuses while the core answers.
    public static func canTakeOver(_ row: MirroredVault, firstCopyFinished: Bool?) -> Bool {
        row.role == .mirror && firstCopyFinished == true && row.state != .diverged && row.state != .starting
    }

    /// A core that was replaced (rejoining) or took over at the same time as the other server (forked).
    private static func coreReplaced(_ row: MirroredVault) -> Bool {
        row.role == .core && (row.state == .rejoining || row.state == .forked)
    }

    /// Which actions a vault offers, by this server's role and the vault's state (the server checks again and refuses
    /// with its sentence). A completed mirror on the mirror side ends by detaching, never by cancel.
    /// `firstCopyFinished` decides take over; unknown hides it.
    public static func actions(_ row: MirroredVault, firstCopyFinished: Bool?) -> [MirrorAction] {
        var out: [MirrorAction] = []
        let deleting = row.deleting?.deleting == true
        switch row.role {
        case .core:
            if coreReplaced(row) {
                out += [.resync, .detach, .held]
                break
            }
            if row.state == .live, !deleting { out.append(.switch) }
            if row.takeover != nil { out.append(.detach) }
            out.append(.cancel)
        case .mirror:
            if row.state == .live, !deleting { out.append(.switch) }
            if canTakeOver(row, firstCopyFinished: firstCopyFinished) { out.append(.takeover) }
            if row.state == .diverged || row.state == .expired || row.state == .stopped { out.append(.resync) }
            out += [.detach, .copy, .versions, .held]
        case .orphaned:
            out += [.detach, .copy, .cancel, .held]
        case .starting:
            if let start = row.start, startOpen.contains(start.state) { out.append(.cancel) }
        case .detached:
            out.append(.held)
        case .none, .other:
            break
        }
        return out
    }

    /// The actions with the row's own first-copy fact.
    public static func actions(_ row: MirroredVault) -> [MirrorAction] {
        actions(row, firstCopyFinished: row.firstCopy?.finished)
    }

    /// What cancel means for this row: end a mirror (core), remove an orphaned copy with its keys, or cancel a start.
    public enum CancelKind: Hashable, Sendable { case end, removeOrphan, start }

    public static func cancelKind(_ row: MirroredVault) -> CancelKind {
        switch row.role {
        case .core: .end
        case .orphaned: .removeOrphan
        default: .start
        }
    }

    /// What names a row for `mirror.cancel`: the vault, or the offer while its vault doesn't exist here yet.
    public enum CancelTarget: Hashable, Sendable {
        case vault(Int64)
        case offer(Int64)
    }

    public static func cancelTarget(_ row: MirroredVault) -> CancelTarget {
        row.vaultID > 0 ? .vault(row.vaultID) : .offer(row.start?.id ?? 0)
    }

    public struct ActionText: Hashable, Sendable {
        public var label: String
        public var hint: String
        /// Drawn as a destructive button.
        public var danger: Bool
        /// A system symbol for the button.
        public var systemImage: String
    }

    /// An action's button label and hint, as the console's detail page says them.
    public static func actionText(_ action: MirrorAction, _ row: MirroredVault) -> ActionText {
        let peer = peerName(row)
        switch action {
        case .switch:
            return ActionText(label: MirrorCopy.switchAction, hint: MirrorCopy.switchHint(core: row.role == .core, peer: peer),
                              danger: false, systemImage: "arrow.left.arrow.right")
        case .takeover:
            return ActionText(label: MirrorCopy.takeoverAction, hint: MirrorCopy.takeoverHint(peer), danger: true,
                              systemImage: "shield.lefthalf.filled")
        case .copy:
            return ActionText(label: MirrorCopy.copyAction, hint: MirrorCopy.copyHint, danger: false,
                              systemImage: "doc.on.doc")
        case .resync:
            return ActionText(label: MirrorCopy.resyncAction,
                              hint: row.linkIsUp == false ? MirrorCopy.resyncNeedsLink : MirrorCopy.resyncHint,
                              danger: false, systemImage: "arrow.triangle.2.circlepath")
        case .detach:
            return ActionText(label: MirrorCopy.detachAction, hint: MirrorCopy.detachHint, danger: false,
                              systemImage: "folder")
        case .versions:
            return ActionText(label: MirrorCopy.manageVersions, hint: MirrorCopy.versionsHint, danger: false,
                              systemImage: "clock.arrow.circlepath")
        case .cancel:
            switch cancelKind(row) {
            case .end:
                return ActionText(label: MirrorCopy.endAction, hint: MirrorCopy.endHint(peer), danger: true,
                                  systemImage: "nosign")
            case .removeOrphan:
                return ActionText(label: MirrorCopy.removeOrphanAction, hint: MirrorCopy.removeOrphanHint, danger: true,
                                  systemImage: "trash")
            case .start:
                return ActionText(label: MirrorCopy.cancelStartAction, hint: MirrorCopy.cancelStartHint, danger: true,
                                  systemImage: "nosign")
            }
        case .held:
            return ActionText(label: MirrorCopy.heldAction, hint: MirrorCopy.heldHint, danger: false,
                              systemImage: "info.circle")
        }
    }

    /// Whether the server would refuse the action outright right now (the console disables it): a resync needs the
    /// link.
    public static func needsLink(_ action: MirrorAction, _ row: MirroredVault) -> Bool {
        action == .resync && row.linkIsUp == false
    }

    // MARK: Advice

    /// The next step in plain words, from the role and state. The server's own advice line replaces the console's
    /// wording when it is present; the count of held changes is added either way. nil when there is nothing to do.
    public static func advice(_ row: MirroredVault, linkUp: Bool?, held: Int64) -> String? {
        let peer = peerName(row)
        let heldLine = row.role != .core && held > 0 ? MirrorCopy.advHeld(held) : nil
        if let advice = row.advice, !advice.isEmpty {
            return heldLine.map { "\(advice) \($0)" } ?? advice
        }
        switch row.role {
        case .starting:
            guard let s = row.start else { return nil }
            let waiting = s.state == "offered" || s.state == "pending"
            if s.side == "core", waiting { return MirrorCopy.advWaitingThem(peer) }
            if s.side == "mirror", waiting { return MirrorCopy.advWaitingYou }
            if s.state == "failed" || s.state == "expired" { return MirrorCopy.advStartFailed }
            return nil
        case .detached:
            return row.rekeyRecommended || row.detached?.rekeyRecommended == true ? MirrorCopy.advRekey : nil
        case .orphaned:
            return MirrorCopy.advOrphaned
        case .none, .other:
            return nil
        case .core, .mirror:
            break
        }
        if row.deleting?.deleting == true {
            return row.role == .core ? MirrorCopy.advDeletingCore : MirrorCopy.advDeletingMirror
        }
        let core = row.role == .core
        var parts: [String] = []
        switch row.state {
        case .live, .paused:
            if linkUp == false { parts.append(core ? MirrorCopy.advLinkDownCore : MirrorCopy.advLinkDownMirror) }
        case .diverged, .expired, .stopped:
            parts.append(core ? MirrorCopy.advStoppedCore(peer)
                : linkUp == false ? MirrorCopy.advStoppedMirrorLinkDown : MirrorCopy.advStoppedMirror)
        case .switching:
            parts.append(MirrorCopy.advSwitching)
        case .rejoining:
            parts.append(MirrorCopy.advRejoining(peer))
        case .forked:
            parts.append(MirrorCopy.advForked)
        case .starting, .other, nil:
            break
        }
        if core, row.takeover != nil, row.state == .live { parts.append(MirrorCopy.advTookOver(peer)) }
        if let heldLine { parts.append(heldLine) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Lists

    /// Live and running ones first, then the ones that need someone (orphaned), then ended ones; by name within.
    public static func listOrder(_ row: MirroredVault) -> Int {
        switch row.role {
        case .core, .mirror: 0
        case .starting: 1
        case .orphaned: 2
        case .detached: 3
        case .none: 4
        case .other: 5
        }
    }

    public static func sorted(_ rows: [MirroredVault]) -> [MirroredVault] {
        rows.sorted {
            let (a, b) = (listOrder($0), listOrder($1))
            if a != b { return a < b }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// The row for a vault of this server, when it is (or is becoming) mirrored: detached and not-mirrored rows
    /// don't count.
    public static func mirror(of vaultID: Int64, in rows: [MirroredVault]) -> MirroredVault? {
        rows.first { $0.vaultID == vaultID && $0.role != .detached && $0.role != .none }
    }

    // MARK: Settings

    /// A versions limit: nil or 0 is no limit.
    public static func limitText(_ value: Int64?, _ unit: (Int64) -> String) -> String {
        guard let value, value != 0 else { return MirrorCopy.noLimit }
        return unit(value)
    }

    public static func versionsText(_ versions: MirroredVault.Settings.Versions, bytes: (Int64) -> String) -> String {
        MirrorCopy.versionsNow(
            on: versions.enabled,
            keep: limitText(versions.keepLast) { "\($0) versions" },
            days: limitText(versions.maxAgeDays) { "\($0) days" },
            quota: limitText(versions.quotaBytes, bytes))
    }
}

/// An action on a mirrored vault. The detail's actions bar lists the ones ``MirrorModel/actions(_:)`` gives; `held`
/// is the held-changes list rather than a button.
public enum MirrorAction: String, CaseIterable, Hashable, Sendable {
    case cancel, `switch`, takeover, resync, detach, copy, versions, held
}
