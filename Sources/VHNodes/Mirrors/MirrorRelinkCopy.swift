/// The web console's words for reconnecting a once-mirrored pair (`RelinkDialog.tsx`, `RelinkRequestsPanel.tsx`,
/// `copy.ts`, server main), kept here so the Reconnect sheet, the requests panel and their tests say the same thing.
public enum MirrorRelinkCopy {
    // MARK: The action

    public static let reconnectAction = "Reconnect…"
    public static func reconnectHint(_ peer: String) -> String {
        "Mirror it with \(peer) again and resolve how the two copies drifted."
    }

    // MARK: The Reconnect sheet

    public static func title(_ vault: String) -> String { "Reconnect “\(vault)”" }
    public static func description(_ peer: String) -> String {
        "Mirror it again with \(peer) and resolve how the two copies drifted. Nothing is dropped: the losing versions are kept as held changes or conflict copies."
    }
    public static let linkedServer = "Linked server"
    public static let choose = "Choose…"
    public static let comparing = "Comparing"
    public static let compareAgain = "Compare again"
    public static let askAgain = "Ask again"
    public static let cancelRequest = "Cancel the request"
    public static let same = "Both trees are the same."
    public static let keepThis = "Keep this server’s"
    public static func keepTheirs(_ peer: String) -> String { "Keep \(peer)’s" }
    public static let review = "Review each change…"
    public static let coreLabel = "The core (its tree is the truth)"
    public static let thisServerOption = "This server"
    public static let leftUnset = "Entries left unset"
    public static let coresVersion = "The core’s version"
    public static let show = "Show"
    public static let everyKind = "Every kind"
    public static let setAllShown = "Set all shown…"
    public static let theDefault = "The default"
    public static func bothFiles(_ text: String) -> String { "\(text) (files)" }
    public static func defaultChoice(_ winner: String?) -> String { winner.map { "Default (\($0))" } ?? "Default" }
    public static let previous = "Previous"
    public static let next = "Next"
    public static let back = "Back"
    public static let close = "Close"
    public static let applyPlan = "Apply this plan…"
    public static let planFailed = "The plan was not changed"
    public static let compareFailed = "The two servers could not be compared"
    public static let applyFailed = "The vault was not relinked"
    public static func serverSays(_ side: String, _ gains: String) -> String { "\(side) \(gains)." }
    public static func proposedCore(_ core: String, override: Bool) -> String {
        "Proposed: \(core) becomes the core (\(override ? "its tree wins everywhere" : "the plan decides each entry"))."
    }
    public static func brought(_ done: String, _ total: String) -> String { "\(done) of \(total) brought onto the core" }

    // The confirm step.
    public static func winsTitle(_ winner: String) -> String { "\(winner)’s data wins everywhere" }
    public static func planTitle(_ core: String) -> String { "\(core) becomes the core; the plan decides each entry" }
    public static func confirmBody(_ core: String, peer: String) -> String {
        "\(core) becomes the vault’s core and the other server its mirror. What the other server held that differs is kept there as held changes, with its bytes. \(peer)’s admin approves this outcome before anything changes on either server."
    }
    public static func typeToConfirm(_ name: String) -> String { "Type “\(name)” to confirm" }
    public static func keepTree(_ who: String) -> String { "Keep \(who)’s tree" }
    public static let applyThePlan = "Apply the plan"

    // After apply (the console's toasts).
    public static func waitingTitle(_ peer: String) -> String { "Waiting for \(peer)’s admin" }
    public static func waitingBody(_ peer: String) -> String {
        "Nothing changes on either server until \(peer)’s admin approves; this server carries it out then."
    }
    public static func relinkingTitle(_ vault: String, _ peer: String) -> String { "Relinking “\(vault)” with \(peer)" }
    public static let relinkingBody = "The vault is read-only here until the copy completes."

    // MARK: The requests panel

    public static let requestsTitle = "Relink requests"
    public static let requestsBody =
        "Linked servers that hold a vault of this server since a mirror between them ended ask to mirror it again. A super admin here accepts the comparison, then approves the outcome."
    public static let decline = "Decline"
    public static let accept = "Accept…"
    public static let acceptConfirm = "Accept"
    public static let reviewApprove = "Review and approve…"
    public static func thisServerStatus(_ status: String) -> String { "this server: \(status)" }
    public static func expires(_ when: String) -> String { "expires \(when)" }

    public static func acceptTitle(_ peer: String, _ vault: String) -> String { "Let \(peer) compare “\(vault)”?" }
    public static func declineTitle(_ peer: String, _ vault: String) -> String { "Decline \(peer)’s relink of “\(vault)”?" }
    public static let declineBody = "The relink ends on both servers. Neither copy changes."
    public static func accepted(_ peer: String, _ vault: String) -> String { "Accepted \(peer)’s request for “\(vault)”" }
    public static let acceptedHint = "It compares its copy next; the outcome waits for approval here."
    public static func declined(_ peer: String, _ vault: String) -> String { "Declined \(peer)’s relink of “\(vault)”" }
    public static let declinedHint = "Neither copy changed."
    public static let acceptFailed = "The request was not accepted"
    public static let declineFailed = "The relink was not declined"

    // The approve sheet.
    public static func approveTitle(_ peer: String, _ vault: String) -> String { "Approve \(peer)’s relink of “\(vault)”?" }
    public static let approveBody =
        "Nothing changes on either server before you approve. A changed plan or a change to this vault since voids the approval."
    public static let approve = "Approve"
    public static let cancel = "Cancel"
    public static let approveFailed = "The outcome was not approved"
    public static let overrideLine = "The hard override: one tree wins everywhere."
    public static func planLine(_ entries: Int64) -> String {
        "A plan of \(entries) drifted entr\(entries == 1 ? "y" : "ies")."
    }
    public static func approved(_ peer: String, _ vault: String) -> String { "Approved \(peer)’s relink of “\(vault)”" }
    public static func approvedHint(_ peer: String) -> String { "\(peer) carries it out now." }
}
