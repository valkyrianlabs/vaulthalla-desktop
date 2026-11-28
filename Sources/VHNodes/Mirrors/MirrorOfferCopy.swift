import Foundation

/// The console's sentences for offers, mirroring a vault, held changes and the per-link settings (the web console's
/// `web/src/features/mirrors/copy.ts`, server main), word for word. The two sentences for mirroring every vault are
/// this app's own: the console has no switch for `mirror.mirror_all.set`, and they say what the contract says it does.
public enum MirrorOfferCopy {
    // MARK: Offers

    public static let offersTitle = "Offers"
    public static let offersBody =
        "Linked servers offered these vaults to this server. Accepting creates a copy here and sends this server the vault’s keys."
    public static func offerFrom(_ peer: String) -> String { "from \(peer)" }
    public static func offerSize(_ size: String, _ files: String) -> String { "\(size) · \(files) files" }
    public static func offerOwner(_ name: String, _ peer: String) -> String { "Owner on \(peer): \(name)" }
    public static let offerHistory = "Keeps file versions"
    public static func offerGrant(_ role: String) -> String { "Access here: role “\(role)”" }
    public static func offerExpires(_ when: String) -> String { "Expires \(when)" }
    public static let accept = "Accept"
    public static let decline = "Decline"
    public static func acceptTitle(_ name: String) -> String { "Accept “\(name)”?" }
    public static func acceptBody(_ name: String, _ peer: String) -> String {
        "This server creates “\(name)” as a copy of \(peer)’s vault and receives its keys. \(peer) stays the core: the copy follows it."
    }
    public static func accepted(_ name: String) -> String { "Accepted “\(name)”" }
    public static let acceptedHint = "The keys come next, then the first copy."
    public static let acceptFailed = "The offer was not accepted"
    public static func declineTitle(_ name: String) -> String { "Decline “\(name)”?" }
    public static func declineBody(_ peer: String) -> String {
        "\(peer) is told and nothing is copied here. It can offer the vault again later."
    }
    public static func declined(_ name: String) -> String { "Declined “\(name)”" }
    public static let declineFailed = "The offer was not declined"

    /// The outgoing half of the panel (the console lists these in its table, with Cancel the start).
    public static let outgoingTitle = "Offered by this server"
    public static func cancelStartTitle(_ name: String) -> String { "Cancel the start of “\(name)”?" }
    public static func cancelStartBody(_ peer: String) -> String {
        "Nothing more is copied and \(peer) is told. Anything already created for it on this server is removed."
    }
    public static let cancelStartConfirm = "Cancel the start"
    public static let startCancelled = "Start cancelled"
    public static let cancelFailed = "Nothing was changed"
    public static let keepGoing = "Keep it"

    // MARK: Mirror a vault

    public static let addAction = "Mirror a vault"
    public static let addTitle = "Mirror a vault"
    public static let addDescription =
        "Copy one of this server’s vaults to a linked server. This server stays its core; the other keeps a copy and the vault’s keys."
    public static let addVault = "Vault"
    public static let addVaultHint = "Vaults already mirrored aren’t listed."
    public static let addVaultNone = "Every vault here is already mirrored, or none exists yet."
    public static let addServer = "Linked server"
    public static let addServerHint = "The server that keeps the copy."
    public static let addChoose = "Choose…"
    public static let addSteps = [
        "The other server checks the offer. A super admin there accepts it, unless that server accepts every vault from this one.",
        "It then receives the vault’s keys and copies the files. Until the copy finishes, it is read-only there.",
    ]
    public static let addSubmit = "Offer it"
    public static func offered(_ name: String, _ peer: String) -> String { "Offered “\(name)” to \(peer)" }
    public static let offeredHint = "It starts once that server accepts."
    public static let addFailed = "The vault was not offered"

    // MARK: Link settings

    public static let settingsTitle = "Per linked server"
    public static let settingsBody = "How this server answers each linked server’s offers and removals."
    public static let settingsOpen = "Settings"
    public static func settingsDialogTitle(_ peer: String) -> String { "Mirror settings for \(peer)" }
    public static let settingsUnknown = "This server doesn’t report the current setting, so choose one to set it."
    public static func acceptAllHint(_ peer: String) -> String {
        "On: offers from \(peer) are accepted without asking. Off: each one waits here for a super admin."
    }
    public static func keepRemovedHint(_ peer: String) -> String {
        "On: when \(peer) ends a mirror and asks to remove the copy, the copy stays here as an orphaned copy. Off: it is removed."
    }
    public static func mirrorAllLabel(_ peer: String) -> String { "Mirror every vault to \(peer)" }
    public static func mirrorAllHint(_ peer: String) -> String {
        "On: this server offers \(peer) every vault it owns, new ones included. Off: each vault is offered here by hand."
    }
    public static let turnOn = "On"
    public static let turnOff = "Off"
    public static func settingIs(_ on: Bool, _ when: String) -> String { "\(on ? "On" : "Off") · set \(when)" }
    public static let settingFailed = "The setting was not changed"
    /// A setting the mirror rows report (no read exists, so only while a vault is mirrored with that server).
    public static func settingNow(_ on: Bool) -> String { "Now \(on ? "on" : "off")" }
    public static let settingNotReported = "Not reported"
    public static func acceptAllConfirmTitle(_ peer: String) -> String { "Accept every vault \(peer) offers?" }
    public static func acceptAllConfirmBody(_ peer: String) -> String {
        "Every vault \(peer) offers from now on is copied here and its keys are sent to this server, without asking a super admin here first."
    }
    public static func mirrorAllConfirmTitle(_ peer: String) -> String { "Mirror every vault to \(peer)?" }
    public static func mirrorAllConfirmBody(_ peer: String) -> String {
        "Every vault this server owns, and each new one, is offered to \(peer) with its keys. If \(peer) accepts every vault from this server, each one is copied there without anyone being asked."
    }
    public static let turnItOn = "Turn it on"

    // MARK: Held changes

    public static let heldTitle = "Held changes"
    public static let heldBody =
        "Changes made on this server that the core refused. The file went back to the core’s version and the change is kept here with the reason, until you retry or discard it."
    public static let heldEmpty = "No held changes."
    public static let heldShowAll = "Show retried and discarded"
    public static let heldConflict = "Conflict copy"
    public static func heldConflictAs(_ name: String) -> String { "Conflict copy kept as “\(name)”" }
    public static let heldUnknownPath = "(unknown path)"
    public static func heldBy(_ id: Int64) -> String { "by account \(id)" }
    public static let heldReasonHeader = "Why the core refused it"
    public static let heldRetry = "Retry"
    public static let heldRetryHint = "Send it to the core again as the person who made it"
    public static let heldRetryNeedsLive = "Retrying needs the vault to be live here"
    public static let heldDiscard = "Discard"
    public static let heldDownload = "Save their version"
    public static let heldRetried = "Sent to the core again"
    public static let heldRetriedHint = "If the core refuses it again, it is held again."
    public static let heldDiscardTitle = "Discard this held change?"
    public static func heldDiscardBody(_ path: String) -> String {
        "The change to “\(path)” is dropped. Nothing in the vault changes."
    }
    public static let heldDiscardConflictBody = "The record is dismissed. The conflict copy itself stays in the vault."
    public static let heldDiscarded = "Discarded"
    public static let heldFailed = "Nothing was changed"
    /// The console says "in the browser"; here it is this app.
    public static let heldTooLarge = "This version is too large to download here. On the server, run:"
    public static let heldSaveFailed = "Couldn’t save that version"
}
