import Foundation

/// Every sentence of the Mirrored Vaults pages, ported from the web console's `web/src/features/mirrors/copy.ts`
/// (server main), so Desktop and the console say the same thing. "Core" is the server that owns the vault, "mirror"
/// the one that holds a copy. Where the console points at its own tabs ("the Servers tab"), Desktop names its own
/// place (All Nodes › Linked servers); nothing else is reworded.
public enum MirrorCopy {
    // MARK: The area

    public static let title = "Mirrored Vaults"
    public static let description =
        "A mirrored vault lives on two linked servers. Its core owns it and takes every change; the other server keeps a copy that follows the core and can take over from it."
    public static let denied = "Only super admins can see and manage mirrored vaults."
    public static let emptyTitle = "No mirrored vaults"
    /// The console's empty sentence without its first half ("Choose Mirror a vault…"): Desktop has no Mirror a
    /// vault action yet.
    public static let emptyBody = "Offers other servers make appear here, and so does every vault this server mirrors with a linked server."
    public static let noLinksTitle = "Link a server first"
    public static let noLinksBody = "A vault is mirrored to a linked server. Link one under Linked servers in All Nodes, then come back here."
    public static let loadFailed = "The mirrored vaults didn’t load"
    public static let unnamedServer = "Unnamed server"
    public static let noServer = "no linked server"
    public static let back = "Mirrored Vaults"

    // MARK: Columns

    public static let colVault = "Vault"
    public static let colServer = "Other server"
    public static let colRole = "This server is"
    public static let colState = "State"
    public static let colPending = "Pending"
    public static let colConfirmed = "Last confirmed"
    public static let colLink = "Link"
    public static let pendingNone = "None"

    // MARK: Roles

    public static func roleCore(_ peer: String) -> String { "This server owns the vault; \(peer) keeps a copy." }
    public static func roleMirror(_ peer: String) -> String { "This server keeps a copy of \(peer)’s vault." }
    public static func roleOrphaned(_ peer: String) -> String { "\(peer) ended the mirror and this server kept its copy." }
    public static func roleStartingCore(_ peer: String) -> String { "This server offered the vault to \(peer)." }
    public static func roleStartingMirror(_ peer: String) -> String { "\(peer) offered this server a copy of its vault." }
    public static let roleDetached = "This vault was a mirror and stands on its own now."
    public static let roleNone = "This vault isn’t mirrored."

    // MARK: States

    public static let stLive = "Live"
    public static func stLiveCore(_ peer: String) -> String { "Changes made here reach \(peer) as they happen." }
    public static func stLiveMirror(_ peer: String) -> String {
        "Up to date with \(peer). Changes made here go to \(peer) first and come back once it accepts them."
    }
    public static let stLiveLinkDown = "Live, link down"
    public static func stLiveLinkDownCore(_ peer: String) -> String {
        "The link to \(peer) is down. Changes keep working here and reach \(peer) when it reconnects."
    }
    public static let stReadOnlyLink = "Read-only: link down"
    public static func stReadOnlyLinkBody(_ peer: String) -> String {
        "The link to \(peer) is down, so the copy here is read-only until it reconnects."
    }
    public static let stFirstCopy = "First copy"
    public static func stFirstCopyCore(_ peer: String) -> String { "\(peer) is making its first copy of the vault." }
    public static func stFirstCopyMirror(_ peer: String, _ progress: String?) -> String {
        "\(peer)’s files are being copied here\(progress.map { " (\($0))" } ?? ""). The copy is read-only until it finishes."
    }
    public static func progress(_ done: String, _ total: String) -> String { "\(done) of \(total) entries" }
    public static func progressUnknown(_ done: String) -> String { "\(done) entries so far" }
    public static let stPaused = "Paused"
    public static func stPausedCore(_ peer: String, _ why: String?) -> String {
        "The mirror to \(peer) is paused\(why.map { ": \($0)" } ?? "")."
    }
    public static func stPausedMirror(_ why: String?) -> String {
        "The copy is read-only here\(why.map { " because \($0)" } ?? " while the mirror is paused")."
    }
    public static let stDiverged = "Diverged"
    public static func stDivergedCore(_ peer: String) -> String {
        "\(peer)’s copy stopped matching this one, so the mirror stopped. This vault keeps working here."
    }
    public static func stDivergedMirror(_ why: String?) -> String {
        "The copy here stopped matching the core’s\(why.map { " (\($0))" } ?? ""), so it stopped following it and is read-only."
    }
    public static let stExpired = "Expired"
    public static func stExpiredCore(_ peer: String) -> String {
        "\(peer) fell too far behind: this server no longer keeps the changes it missed."
    }
    public static let stExpiredMirror =
        "The copy fell too far behind: the core no longer keeps the changes it missed. It is read-only here."
    public static let stStopped = "Stopped"
    public static func stStoppedCore(_ peer: String, _ why: String?) -> String {
        "The mirror to \(peer) stopped\(why.map { " because \($0)" } ?? "")."
    }
    public static func stStoppedMirror(_ why: String?) -> String {
        "The copy stopped following the core\(why.map { " because \($0)" } ?? ""). It is read-only here."
    }
    public static let stSwitching = "Switching"
    public static let stSwitchingBody =
        "The core role is moving between the two servers. The vault is read-only on both for a moment."
    public static let stRejoining = "Replaced as the core"
    public static func stRejoiningBody(_ peer: String) -> String {
        "\(peer) took over as the core while this server was cut off, and this server holds changes \(peer) never received. The vault is read-only here; resync it to follow \(peer), or detach it."
    }
    public static let stForked = "Both took over"
    public static let stForkedBody =
        "Both servers took over as the core while they were cut off, so the vault is read-only on both. Pick the server whose files stay, then resync or detach the vault on the other one."
    public static let stTookOver = "Took over"
    public static func stTookOverBody(_ peer: String) -> String {
        "This server took over as the core and takes changes. The old core, \(peer), has not returned yet and may hold changes this server never received."
    }
    public static let stDeleting = "Being deleted"
    public static func stDeletingCore(_ when: String, _ peer: String, remove: Bool) -> String {
        "This vault is deleted and is purged on \(when). Then \(peer)’s copy is \(remove ? "removed (unless that server keeps removed vaults)" : "left there as an orphaned copy")."
    }
    public static let stCoreDeleting = "Core is deleting it"
    public static func stCoreDeletingBody(_ peer: String, _ when: String, removed: Bool) -> String {
        "\(peer) deleted this vault. The copy is read-only here until \(when), then it is \(removed ? "removed" : "kept as an orphaned copy"), unless \(peer) restores it first."
    }
    public static let stOrphaned = "Orphaned copy"
    public static func stOrphanedBody(_ peer: String) -> String {
        "\(peer) ended the mirror and this server kept the copy. It is read-only and follows nothing now."
    }
    public static let stDetached = "Detached"
    public static func stDetachedHere(_ peer: String) -> String {
        "This copy was detached and is a standalone vault on this server. It still shares its keys with the original on \(peer)."
    }
    public static func stDetachedThere(_ peer: String) -> String {
        "\(peer) detached its copy, so the mirror ended. Both servers still hold the vault’s keys."
    }
    public static let stNone = "Not mirrored"
    public static let stNoneBody = "This vault isn’t mirrored."
    public static let stUnknown = "Unknown"
    public static let stUnknownBody = "This server didn’t say how the mirror stands."

    // Starts
    public static let stWaitingThem = "Waiting for an answer"
    public static func stWaitingThemBody(_ peer: String) -> String { "Offered to \(peer). It starts once \(peer) accepts." }
    public static let stWaitingYou = "Waiting for you"
    public static func stWaitingYouBody(_ peer: String) -> String {
        "\(peer) offered this vault. Accept or decline it under Offers."
    }
    public static let stKeys = "Sending keys"
    public static let stKeysBody = "The offer was accepted and the vault’s keys are being sent and checked."
    public static let stStarting = "Starting"
    public static let stStartingBody = "The vault was created on the mirror and its first copy is starting."
    public static let stDeclined = "Declined"
    public static func stDeclinedBody(_ peer: String) -> String { "\(peer) declined the offer. Nothing was copied." }
    public static let stDeclinedHere = "This server declined the offer. Nothing was copied."
    public static let stCancelled = "Cancelled"
    public static let stCancelledBody = "The start was cancelled. Nothing more happens."
    public static let stOfferExpired = "Offer expired"
    public static func stOfferExpiredBody(_ peer: String) -> String {
        "\(peer) didn’t answer in time. Offer the vault again to try once more."
    }
    public static let stFailed = "Failed"
    public static func stFailedBody(_ why: String?) -> String { "The start failed\(why.map { ": \($0)" } ?? "")." }

    // MARK: Position

    public static let posNone = "No changes yet"
    public static func posAt(_ seq: Int64, _ term: Int64) -> String { "Change \(number(seq)) (term \(term))" }
    public static func posConfirmed(_ seq: Int64, _ term: Int64) -> String {
        "confirmed through \(number(seq)) (term \(term))"
    }
    public static let posNothingConfirmed = "nothing confirmed yet"
    public static func unconfirmed(_ n: Int64) -> String {
        n == 1 ? "1 change not confirmed yet" : "\(number(n)) changes not confirmed yet"
    }

    // MARK: Advice

    public static let adviceLabel = "What to do"
    public static func advWaitingThem(_ peer: String) -> String {
        "A super admin on \(peer) accepts it under Linked servers › Mirrored vaults, unless \(peer) accepts every vault from this server."
    }
    public static let advWaitingYou = "Accept or decline the offer above."
    public static let advStartFailed = "Cancel it, then offer the vault again."
    public static let advRekey = "Re-keying this vault is recommended, so the original’s keys no longer open it."
    public static let advOrphaned = "Keep it as this server’s own vault with Detach, or remove it with its keys."
    public static let advDeletingCore =
        "To keep the vault and its mirror, restore it from Vaults › Deleted vaults before the purge."
    public static let advDeletingMirror =
        "To keep these files on this server whatever the core does, detach the copy before then."
    public static let advLinkDownCore = "Check the link under Linked servers in All Nodes."
    public static let advLinkDownMirror =
        "Check the link under Linked servers in All Nodes; the copy takes changes again once it reconnects. To use it on its own now, detach it."
    public static func advStoppedCore(_ peer: String) -> String { "Resync it on \(peer), or end the mirror." }
    public static let advStoppedMirror =
        "Resync it to start over from the core’s files, or detach it to keep it as this server’s own vault."
    public static let advStoppedMirrorLinkDown =
        "Resyncing needs the link. Once it reconnects, resync it; or detach it to keep it as this server’s own vault."
    public static let advSwitching = "Wait a moment; it finishes or changes nothing."
    public static func advRejoining(_ peer: String) -> String {
        "Resync it to follow \(peer) again (the changes only this server has are kept as held changes), or detach it to keep it as this server’s own vault."
    }
    public static let advForked =
        "On the server whose files should not stay, resync the vault (what only it has is kept as held changes) or detach it."
    public static func advTookOver(_ peer: String) -> String {
        "The old core has not returned yet. When \(peer) comes back, it stops taking changes and follows this server."
    }
    public static func advHeld(_ n: Int64) -> String {
        n == 1 ? "One change made here was refused by the core: review it under Held changes."
            : "\(n) changes made here were refused by the core: review them under Held changes."
    }

    // MARK: Detail

    public static let detailServer = "Other server"
    public static let detailLink = "Link"
    public static let linkUp = "Connected"
    public static let linkDown = "Not connected"
    public static let linkUnknown = "Unknown"
    public static let linkGone = "Unlinked"
    public static let detailPosition = "Position"
    public static let detailConfirmed = "Last confirmed"
    public static let confirmedNever = "Nothing confirmed yet"
    public static let detailDigest = "Copies compared"
    public static let digestMatched = "Matched"
    public static let digestDiffered = "Differed"
    public static let digestNotYet = "Not compared yet"
    public static let detailPending = "Changes waiting for the core"
    public static let detailHeld = "Held changes"
    public static let detailMissing = "Files whose contents aren’t here"
    public static let detailGrant = "Access the core gives here"
    public static let grantNone = "Nothing yet: nobody here can open it."
    public static func grantBy(_ role: String) -> String { "Role “\(role)”" }
    public static let detailSince = "Mirrored since"
    public static let detailFirstCopy = "First copy"
    public static let detailFacts = "Details"
    public static let detailActions = "Actions"
    public static let noActions = "Nothing can be done with this vault from here right now."
    public static let notMirroredTitle = "This vault isn’t mirrored"
    public static let notMirroredBody = "It has no mirror on this server. Mirrored vaults are listed on the Mirrored Vaults page."
    public static let unknownValue = "Unknown"

    // MARK: Settings (read-only here)

    public static let settingsTitle = "Settings"
    public static let settingsBody = "How this server answers the linked server’s offers and removals, and what it keeps of this vault."
    public static func acceptAllLabel(_ peer: String) -> String { "Accept every vault \(peer) offers" }
    public static func keepRemovedLabel(_ peer: String) -> String { "Keep the vaults \(peer) removes" }
    public static let versionsTitle = "Versions kept here"
    public static func versionsNow(on: Bool, keep: String, days: String, quota: String) -> String {
        on ? "On: \(keep) per file, \(days), \(quota)." : "Off."
    }
    public static let noLimit = "no limit"
    public static let settingOn = "On"
    public static let settingOff = "Off"

    // MARK: Actions (labels and hints of the console's detail page)

    public static let switchAction = "Switch the core…"
    public static func switchHint(core: Bool, peer: String) -> String {
        core ? "Make \(peer) the core; this server keeps a copy." : "Make this server the core; \(peer) keeps a copy."
    }
    public static let takeoverAction = "Take over as core…"
    public static func takeoverHint(_ peer: String) -> String { "Only if \(peer) is gone for good or can’t be reached." }
    public static let copyAction = "Detach a copy…"
    public static let copyHint = "Write a new, separate vault from this copy; the copy stays as it is."
    public static let resyncAction = "Resync…"
    public static let resyncHint = "Start the copy over from the core’s files."
    public static let resyncNeedsLink = "Resyncing needs the link to the core."
    public static let detachAction = "Detach…"
    public static let detachHint = "Keep this copy as a standalone vault on this server."
    public static let manageVersions = "Versions…"
    public static let versionsHint = "Keep previous versions of what the core replaces or deletes."
    public static let endAction = "End the mirror…"
    public static func endHint(_ peer: String) -> String { "Stop mirroring to \(peer)." }
    public static let removeOrphanAction = "Remove the copy…"
    public static let removeOrphanHint = "Remove this copy and its keys from this server."
    public static let cancelStartAction = "Cancel the start…"
    public static let cancelStartHint = "Stop before anything more is copied."
    public static let heldAction = "Held changes"
    public static let heldHint = "Changes made here that the core refused."

    // MARK: Vaults page

    public static func mirroredWith(_ peer: String) -> String { "Mirrored with \(peer)" }

    static func number(_ value: Int64) -> String {
        value.formatted(.number.locale(.init(identifier: "en_US")))
    }
}
