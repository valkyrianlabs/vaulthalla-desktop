/// A NeedsConfirmation refusal a command declares (contract `confirmations`): the daemon answered ERROR with
/// `data.code` == `code` (`WsError.needsConfirmation(code:message:)`) because a person must accept something first.
/// Ask them (the error's message is the question), then resend with `acceptField` set.
public struct WsConfirmation: Hashable, Sendable {
    /// The refusal's `data.code`.
    public var code: String
    /// The payload member a resend sets to accept it, dotted for nested members (`provision.accept_adoption`). A
    /// boolean flag unless `summary` says otherwise (`recovery.restore` takes the plan's token). nil when no resend
    /// accepts it: `summary` says what to do instead (plan again, ...).
    public var acceptField: String?
    /// What the refusal means and how to accept it.
    public var summary: String

    public init(code: String, acceptField: String?, summary: String) {
        self.code = code
        self.acceptField = acceptField
        self.summary = summary
    }
}
