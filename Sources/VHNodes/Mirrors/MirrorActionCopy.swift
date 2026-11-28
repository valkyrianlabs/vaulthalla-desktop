import Foundation

/// The action sheets' sentences, ported word for word from the web console's `web/src/features/mirrors/copy.ts`
/// (server main): ending a mirror, cancelling a start, removing an orphaned copy, switching the core, resyncing,
/// detaching, taking over, detaching a copy, the versions kept here, and the mirror choice of a vault's deletion.
/// These actions can lose access to data or leave one copy as the only one: nothing here is softened or shortened.
extension MirrorCopy {
    // MARK: End, cancel a start, remove an orphaned copy

    public static func endTitle(_ name: String) -> String { "End the mirror of “\(name)”?" }
    public static func endBody(_ peer: String) -> String {
        "The mirror ends here at once and \(peer) is told when it is reachable. This vault and its files stay as they are on this server."
    }
    public static func endLegend(_ peer: String) -> String { "What should \(peer) do with its copy?" }
    public static let endLeave = "Keep it there"
    public static func endLeaveHint(_ peer: String) -> String {
        "\(peer) keeps the copy, read-only and no longer following this vault (an orphaned copy)."
    }
    public static let endRemove = "Remove it"
    public static func endRemoveHint(_ peer: String) -> String {
        "\(peer) removes its copy and the vault’s keys, unless that server keeps the vaults this one removes."
    }
    public static let endConfirm = "End the mirror"
    public static func ended(_ name: String) -> String { "Ended the mirror of “\(name)”" }
    public static func endedHint(remove: Bool) -> String {
        remove ? "The other server is asked to remove its copy." : "The other server keeps its copy, orphaned."
    }
    public static func cancelStartTitle(_ name: String) -> String { "Cancel the start of “\(name)”?" }
    public static func cancelStartBody(_ peer: String) -> String {
        "Nothing more is copied and \(peer) is told. Anything already created for it on this server is removed."
    }
    public static let cancelStartConfirm = "Cancel the start"
    public static let startCancelled = "Start cancelled"
    public static func removeOrphanTitle(_ name: String) -> String { "Remove “\(name)” from this server?" }
    public static let removeOrphanBody = "The copy and its keys are removed from this server for good. The other server isn’t affected."
    public static let removeOrphanConfirm = "Remove the copy"
    public static func orphanRemoved(_ name: String) -> String { "Removed “\(name)”" }
    public static let cancelFailed = "Nothing was changed"
    public static let keepGoing = "Keep it"

    // MARK: Switch

    public static func switchTitle(_ name: String) -> String { "Switch the core of “\(name)”?" }
    public static func switchBody(from: String, to: String) -> String {
        "\(to) becomes the vault’s core and \(from) keeps a copy. The vault is read-only on both servers for a moment while the last changes arrive; if anything goes wrong, nothing changes."
    }
    public static let switchNoAccessTitle = "The old core would keep no access"
    public static func switchNoAccess(from: String, to: String) -> String {
        "People on \(from) can open it there again once \(to) gives \(from) a role on it."
    }
    public static let switchNoAccessAccept = "Switch anyway, without access for the old core"
    public static let switchConfirm = "Switch"
    public static let switching = "Switching…"
    public static let switched = "Switched"
    public static func switchedBody(_ to: String) -> String { "\(to) is the vault’s core now." }
    public static func switchKeeps(_ who: String, _ how: String, role: String?) -> String {
        "\(who) keeps \(how) access\(role.map { " through the role “\($0)”" } ?? "")."
    }
    public static func switchKeepsNone(_ who: String) -> String { "\(who) keeps no access until a role is set for it." }
    public static let accessReadOnly = "read-only"
    public static let accessReadWrite = "read and write"
    public static let switchAbandoned = "The switch didn’t happen"
    public static func switchAbandonedBody(_ why: String?) -> String { "Nothing changed\(why.map { ": \($0)" } ?? "")." }
    public static let switchRunning = "Still switching"
    public static let switchRunningBody = "The servers are still finishing it. This page shows the outcome once it is done."
    public static let switchFailed = "The switch didn’t start"
    public static let thisServer = "this server"

    // MARK: Resync

    public static func resyncTitle(_ name: String) -> String { "Resync “\(name)”?" }
    public static func resyncBody(_ peer: String) -> String {
        "The copy starts over from \(peer)’s files. Files already here aren’t fetched again, and anything made here that the core doesn’t have is kept as held changes."
    }
    public static let resyncConfirm = "Resync"
    public static func resynced(_ name: String) -> String { "Resyncing “\(name)”" }
    public static func resyncedHint(held: Int64) -> String {
        held != 0 ? "\(held) changes kept as held changes." : "Nothing made here had to be held."
    }
    public static let resyncFailed = "The resync didn’t start"

    // MARK: Detach

    public static func detachTitle(_ name: String) -> String { "Detach “\(name)”?" }
    public static func detachBody(_ peer: String) -> String {
        "The copy becomes a standalone vault on this server, without asking \(peer), which is told when it is reachable. Nothing is deleted on either server."
    }
    public static let detachLoading = "Checking what detaching would give…"
    public static let detachFork = "Detached at"
    public static func detachPending(_ n: Int64) -> String {
        n == 1 ? "1 change made here and not yet confirmed becomes an ordinary change."
            : "\(n) changes made here and not yet confirmed become ordinary changes."
    }
    public static func detachHeld(_ n: Int64) -> String { n == 1 ? "1 held change stays listed." : "\(n) held changes stay listed." }
    public static func detachUnfinished(_ progress: String) -> String { "The first copy isn’t finished: \(progress) are here." }
    public static func detachMissingTitle(_ n: Int64) -> String {
        n == 1 ? "1 file’s contents aren’t here" : "\(number(n)) files’ contents aren’t here"
    }
    public static let detachMissingBody = "They stay listed, marked missing, and opening one fails. Copy the list to fetch them some other way."
    public static func detachMissingMore(_ n: Int64) -> String { "and \(number(n)) more" }
    public static let detachAllHere = "Every file’s contents are here."
    public static let detachCopyList = "Copy the list of missing files"
    public static let detachOwner = "Owner here"
    public static let detachOwnerHint = "The account that owns the vault on this server once it stands on its own."
    public static func detachOwnerMe(_ name: String) -> String { "You (\(name))" }
    public static let detachRekey = "It keeps the original’s keys until it is re-keyed."
    public static func detachType(_ name: String) -> String { "Type “\(name)” to confirm" }
    public static let detachConfirm = "Detach"
    public static func detached(_ name: String) -> String { "Detached “\(name)”" }
    public static let detachedHint = "It is a standalone vault on this server now. Re-keying it is recommended."
    public static let detachFailed = "The vault was not detached"

    // MARK: Take over

    public static func takeoverTitle(_ name: String) -> String { "Take over as the core of “\(name)”?" }
    public static func takeoverBody(_ peer: String) -> String {
        "This server becomes the vault’s core without asking \(peer), for when \(peer) is gone for good or can’t be reached. Changes made here that were waiting for \(peer) become ordinary changes."
    }
    public static func takeoverWarnTitle(_ peer: String) -> String { "\(peer) may hold changes this server never received" }
    public static func takeoverWarnBody(_ peer: String) -> String {
        "Anything \(peer) took after this copy last caught up isn’t here. If \(peer) comes back, it keeps those changes, read-only, until it is resynced or detached there."
    }
    public static func takeoverSwitchHint(_ peer: String) -> String {
        "If \(peer) still answers, the server refuses: switch the core instead."
    }
    public static func takeoverMissing(_ n: Int64) -> String {
        n == 1 ? "1 file’s contents never arrived here; it stays listed, marked missing."
            : "\(number(n)) files’ contents never arrived here; they stay listed, marked missing."
    }
    public static func takeoverPending(_ n: Int64) -> String {
        n == 1 ? "1 change made here becomes an ordinary change." : "\(number(n)) changes made here become ordinary changes."
    }
    public static func takeoverType(_ name: String) -> String { "Type “\(name)” to confirm" }
    public static let takeoverConfirm = "Take over"
    public static let takingOver = "Taking over…"
    public static let tookOver = "This server is the core now"
    public static func tookOverBody(made: Int64, held: Int64) -> String {
        let changes = made == 1 ? "1 change" : "\(number(made)) changes"
        let heldPart = held != 0 ? "; \(held == 1 ? "1 held change stays" : "\(number(held)) held changes stay") listed" : ""
        return "\(changes) made here became ordinary changes\(heldPart)."
    }
    public static let takeoverFailed = "This server did not take over"

    // MARK: Detach a copy

    public static func copyTitle(_ name: String) -> String { "Detach a copy of “\(name)”?" }
    public static func copyBody(_ peer: String, follows: Bool) -> String {
        "The copy held here stays exactly as it is\(follows ? " and keeps following \(peer)" : ""). A new, separate vault is written from it on this server, with its own key."
    }
    public static let copyWhat = "Every folder, file and link comes along with its name, place and modification time; the trash, versions, shares and access rules don’t."
    public static let copyName = "Name of the new vault"
    public static func copyNameHint(_ name: String) -> String { "Blank: “\(name) copy”." }
    public static let copyOwner = "Owner of the new vault"
    public static let copyOwnerHint = "The account that owns the new vault, with an owner’s usual access."
    public static let copyStart = "Write the copy"
    public static func copyStarted(_ name: String) -> String { "Writing “\(name)”" }
    public static let copyLoading = "Checking for a copy already running…"
    public static let copyRunning = "Writing the copy"
    public static func copyRunningBody(_ name: String) -> String {
        "“\(name)” is read-only until it is finished. It runs on the server: you can close this and come back."
    }
    public static func copyBytes(_ done: String, _ total: String) -> String { "\(done) of \(total)" }
    public static let copyCancel = "Cancel the copy"
    public static let copyCancelling = "Cancelling…"
    public static func copyCancelTitle(_ name: String) -> String { "Cancel writing “\(name)”?" }
    public static let copyCancelBody = "The partial vault is removed. The copy held here isn’t affected."
    public static let copyFinished = "Finished"
    public static func copyFinishedBody(_ name: String) -> String { "“\(name)” is a vault of this server now." }
    public static let copyOpen = "Open the new vault"
    public static func copySkippedTitle(_ n: Int64) -> String {
        n == 1 ? "1 file was left out" : "\(number(n)) files were left out"
    }
    public static func copySkippedMore(_ n: Int64) -> String { "and \(number(n)) more" }
    public static let copySkippedList = "Copy the list of files left out"
    public static let copyNoneSkipped = "Nothing was left out."
    public static let copyFailedState = "Failed"
    public static func copyFailedBody(_ why: String?) -> String {
        "The copy failed\(why.map { ": \($0)" } ?? ""). Its partial vault was removed."
    }
    public static let copyCancelledState = "Cancelled"
    public static let copyCancelledBody = "The copy was cancelled and its partial vault removed."
    public static let copyAgain = "Write another copy"
    public static func copyLast(_ name: String, _ when: String) -> String { "The last copy, “\(name)”, ended \(when)." }
    public static let copyFailed = "The copy didn’t start"
    public static let copyCancelFailed = "The copy wasn’t cancelled"
    public static let done = "Done"

    // MARK: Versions

    public static let versionsBody =
        "Before the core replaces or deletes a file, this server can keep its previous version. They are this server’s own: the core never sees them. Find them in a file’s Recovery history."
    public static let versionsUnknown = "This server doesn’t report the current setting; saving sets it."
    public static let versionsKeep = "Keep versions of what the core replaces or deletes"
    public static let versionsKeepLast = "Versions per file"
    public static let versionsMaxAge = "Days kept"
    public static let versionsQuota = "Space they may take (bytes)"
    public static let versionsLimitHint = "Blank: the default (10 versions, 30 days). 0: no limit of this kind."
    public static let versionsSave = "Save"
    public static func versionsSaved(_ on: Bool) -> String {
        on ? "Versions are kept here now" : "Versions are no longer kept here"
    }
    public static let versionsFailed = "The setting was not changed"
    public static let limitInvalid = "A whole number, 0 or more."
    public static let close = "Close"

    // MARK: A vault's deletion

    public static func deleteMirrorLegend(_ peer: String) -> String {
        "This vault is mirrored to \(peer): what happens to its copy there?"
    }
    public static let deleteMirrorLegendUnknown = "This vault is mirrored: what happens to the copy on the other server?"
    public static let deleteMirrorLeave = "Leave it there"
    public static let deleteMirrorLeaveHint = "Once this vault is purged, the copy stays on the other server as an orphaned copy."
    public static let deleteMirrorRemove = "Remove it too"
    public static let deleteMirrorRemoveHint = "Once this vault is purged, the other server removes its copy too (unless it keeps removed vaults)."
    public static let deleteMirrorReadOnly = "Until the purge, the copy is read-only there. Restoring this vault keeps the mirror."
    public static func deleteHeldCopy(_ peer: String) -> String {
        "This vault is a copy of \(peer)’s vault, so it can’t be deleted here. Detach it first to make it this server’s own, or end the mirror on \(peer)."
    }
    public static let deleteOrphan = "This vault is an orphaned copy. Remove it from the mirror page instead."
    public static let deleteOpenMirror = "Open its mirror"
}
