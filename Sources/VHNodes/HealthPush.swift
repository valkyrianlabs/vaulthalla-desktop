import VHContract
public import VHTransport

/// One `health.changed` event (the server's design/health/findings.md §6): the findings or their state changed on a
/// node this session follows by `health.subscribe`. It carries no findings, only the headline numbers; the client asks
/// `health.findings.list`. The last event of a subscription whose account lost `admin.stats.view` says
/// `"subscribed": false` and carries the revision only.
public struct HealthChange: Sendable, Hashable {
    /// The unsolicited frame's command.
    public static let command = "health.changed"

    /// Higher on every event of a connection.
    public var revision: Int64
    /// false: the subscription ended (permission lost); go back to polling.
    public var subscribed: Bool
    public var overallStatus: String?
    public var errorCount: Int64?
    public var warningCount: Int64?
    public var unattendedErrorCount: Int64?
    public var unattendedWarningCount: Int64?

    public init(revision: Int64, subscribed: Bool = true, overallStatus: String? = nil, errorCount: Int64? = nil,
                warningCount: Int64? = nil, unattendedErrorCount: Int64? = nil, unattendedWarningCount: Int64? = nil) {
        self.revision = revision
        self.subscribed = subscribed
        self.overallStatus = overallStatus
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.unattendedErrorCount = unattendedErrorCount
        self.unattendedWarningCount = unattendedWarningCount
    }

    /// The event in an unsolicited frame; nil for any other frame, or one without a revision.
    public init?(_ message: UnsolicitedMessage) {
        guard message.command == Self.command, message.requestId == nil, let data = message.data,
              let revision = data["revision"]?.integerValue else { return nil }
        self.init(revision: revision, subscribed: data["subscribed"]?.boolValue ?? true,
                  overallStatus: data["overall_status"]?.stringValue, errorCount: data["error_count"]?.integerValue,
                  warningCount: data["warning_count"]?.integerValue,
                  unattendedErrorCount: data["unattended_error_count"]?.integerValue,
                  unattendedWarningCount: data["unattended_warning_count"]?.integerValue)
    }
}
