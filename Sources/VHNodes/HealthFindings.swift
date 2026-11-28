public import Foundation
public import VHContract
public import VHTransport

/// A node's health findings with what an operator said about each (the server's design/health/findings.md):
/// acknowledged ("I have seen this occurrence"), silenced ("do not tell me about this class"), or still active. The
/// state is the server's, so the console and every paired Mac agree. Severity is never rewritten by a mark: the
/// `errorCount` and `warningCount` stay the truth; the `unattended*` counts leave out what a mark covers.
public struct HealthFindings: Sendable, Hashable {
    public enum State: String, Sendable, Hashable, Comparable {
        case active, acknowledged, silenced

        /// An unknown state from a newer daemon reads as active: it is never hidden.
        public init(_ raw: String?) {
            self = raw.flatMap(State.init(rawValue:)) ?? .active
        }

        private var order: Int {
            switch self {
            case .active: 0
            case .acknowledged: 1
            case .silenced: 2
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
    }

    /// What an operator said about a class: who, when, until when.
    public struct Mark: Sendable, Hashable, Identifiable {
        public var findingClass: String
        public var subject: String
        public var state: State
        /// The highest severity the mark covers.
        public var severity: String
        public var setByName: String
        public var setAt: Date
        /// nil: until the finding clears (acknowledged) or until someone turns it back on (silenced).
        public var expiresAt: Date?
        public var note: String?

        public var id: String { subject.isEmpty ? findingClass : "\(findingClass)|\(subject)" }

        public init(findingClass: String, subject: String = "", state: State, severity: String, setByName: String,
                    setAt: Date, expiresAt: Date? = nil, note: String? = nil) {
            self.findingClass = findingClass
            self.subject = subject
            self.state = state
            self.severity = severity
            self.setByName = setByName
            self.setAt = setAt
            self.expiresAt = expiresAt
            self.note = note
        }

        init(_ mark: WsModel.HealthFindingMark) {
            self.init(findingClass: mark.class, subject: mark.subject, state: State(mark.state), severity: mark.severity,
                      setByName: mark.setByName, setAt: Date(timeIntervalSince1970: TimeInterval(mark.setAt)),
                      expiresAt: mark.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }, note: mark.note)
        }
    }

    /// Something a person can do about a finding. The server only names it; Desktop has no remedy logic of its own.
    public struct Remedy: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            /// A place: the console's route (`/health/storage#retention`, `/cost#budget-alerts`).
            case open(href: String)
            /// An existing ws command with a fixed payload. Not run by this build.
            case command(String, effect: String?)
            case other(String)
        }

        public var id: String
        public var label: String
        public var kind: Kind

        public init(id: String, label: String, kind: Kind) {
            self.id = id
            self.label = label
            self.kind = kind
        }

        init(_ remedy: WsModel.HealthRemedy) {
            id = remedy.id
            label = remedy.label
            switch remedy.kind {
            case WsModel.HealthRemedy.Kind.open where remedy.href != nil:
                kind = .open(href: remedy.href ?? "")
            case WsModel.HealthRemedy.Kind.command where remedy.command != nil:
                kind = .command(remedy.command ?? "", effect: remedy.effect)
            default:
                kind = .other(remedy.kind)
            }
        }

        /// The route of a remedy that opens a place.
        public var href: String? {
            if case .open(let href) = kind { return href }
            return nil
        }
    }

    /// One active finding with its state.
    public struct Finding: Sendable, Hashable, Identifiable {
        /// The class: the code its card raises it under (`system.fuse.error_rate_high`).
        public var findingClass: String
        /// "" for the whole server.
        public var subject: String
        public var cardID: String
        public var severity: String
        /// The card's title.
        public var title: String
        /// What this class of finding means.
        public var classTitle: String
        public var message: String
        public var href: String?
        public var metricKey: String?
        /// Whether the server thinks the class is worth interrupting someone for.
        public var notifies: Bool
        public var state: State
        public var mark: Mark?
        public var remedies: [Remedy]

        public var id: String { subject.isEmpty ? findingClass : "\(findingClass)|\(subject)" }

        init(_ finding: WsModel.HealthFinding) {
            findingClass = finding.class
            subject = finding.subject
            cardID = finding.cardID
            severity = finding.severity
            title = finding.title
            classTitle = finding.classTitle
            message = finding.message
            href = finding.href
            metricKey = finding.metricKey
            notifies = finding.notifies
            state = State(finding.state)
            mark = finding.mark.map(Mark.init)
            remedies = finding.remedies.map(Remedy.init)
        }
    }

    public var overallStatus: String
    public var errorCount: Int64
    public var warningCount: Int64
    /// Errors and warnings no mark covers: what still asks for a person.
    public var unattendedErrorCount: Int64
    public var unattendedWarningCount: Int64
    public var checkedAt: Date
    /// Every active finding, in the server's order (the dashboard's attention list).
    public var findings: [Finding]
    /// Silences set for classes that are not active now.
    public var silences: [Mark]
    /// Whether the paired account may acknowledge and silence (`admin.stats.manage`).
    public var canManage: Bool
    /// What each class means, when the catalog was asked for (`include_catalog`).
    public var classTitles: [String: String]

    public init(_ model: WsModel.HealthFindings) {
        overallStatus = model.overallStatus
        errorCount = model.errorCount
        warningCount = model.warningCount
        unattendedErrorCount = model.unattendedErrorCount
        unattendedWarningCount = model.unattendedWarningCount
        checkedAt = Date(timeIntervalSince1970: TimeInterval(model.checkedAt))
        findings = model.findings.map(Finding.init)
        silences = model.silences.map(Mark.init)
        canManage = model.canManage
        classTitles = Dictionary((model.catalog ?? []).map { ($0.class, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// Findings someone acknowledged or silenced.
    public var attendedCount: Int { findings.filter { $0.state != .active }.count }
}

/// What a person can do to a finding: acknowledge it, silence its class for a while, or turn it back on.
public enum HealthFindingAction: Sendable, Hashable {
    case acknowledge
    case silence(SilenceDuration)
    /// Removes a silence or an acknowledgement.
    case turnBackOn

    public var verb: String {
        switch self {
        case .acknowledge: "acknowledge"
        case .silence: "silence"
        case .turnBackOn: "turn back on"
        }
    }
}

/// How long a silence lasts: the choices Desktop offers.
public enum SilenceDuration: Sendable, Hashable, CaseIterable, Identifiable {
    case hour, day, week, untilTurnedBackOn

    public var id: Self { self }

    public var title: String {
        switch self {
        case .hour: "For 1 Hour"
        case .day: "For 24 Hours"
        case .week: "For 7 Days"
        case .untilTurnedBackOn: "Until I Turn It Back On"
        }
    }

    /// nil: until someone turns it back on.
    public var seconds: Int64? {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .week: 7 * 86_400
        case .untilTurnedBackOn: nil
        }
    }
}

extension NodeQueries {
    /// The node's findings (`health.findings.list`); with `includeCatalog`, what every class means too.
    public func healthFindings(includeCatalog: Bool = false) -> NodeQuery<Ws.Health.Findings.List> {
        query(Ws.Health.Findings.List.self, .init(includeCatalog: includeCatalog ? true : nil))
    }

    /// Whether the node has the findings commands. A node without them keeps the behaviour from before them.
    public var hasHealthFindings: Bool {
        supports(command: .healthFindingsList) == .yes
    }

    /// Runs one action on the class `findingClass` (and `subject`). Only a person's click may call this: nothing
    /// automatic, and never an agent (the server refuses agents and scoped devices too). Answers the node's findings as
    /// they stand afterwards; health queries a view shows are refetched.
    public func perform(_ action: HealthFindingAction, findingClass: String, subject: String = "")
        async -> Result<WsModel.HealthFindings, WsError>
    {
        let subject = subject.isEmpty ? nil : subject
        let invalidating = ["health.", "stats.dashboard."]
        switch action {
        case .acknowledge:
            return Self.settle(await perform(Ws.Health.Finding.Acknowledge.self,
                                             .init(class: findingClass, subject: subject), invalidating: invalidating),
                               \.health)
        case .silence(let duration):
            let payload = Ws.Health.Finding.Silence.Payload(
                class: findingClass, subject: subject, forSeconds: duration.seconds.map { .value($0) })
            return Self.settle(await perform(Ws.Health.Finding.Silence.self, payload, invalidating: invalidating),
                               \.health)
        case .turnBackOn:
            return Self.settle(await perform(Ws.Health.Finding.Unsilence.self,
                                             .init(class: findingClass, subject: subject), invalidating: invalidating),
                               \.health)
        }
    }

    private static func settle<R: WsRequest>(_ result: MutationResult<R>, _ health: KeyPath<R.Response, WsModel.HealthFindings>)
        -> Result<WsModel.HealthFindings, WsError>
    {
        switch result {
        case .success(let response): .success(response[keyPath: health])
        // None of the three asks for a confirmation; one that does is refused here rather than guessed at.
        case .needsConfirmation(let request): .failure(.refused(code: request.code, message: request.message))
        case .failure(let error): .failure(error)
        }
    }
}
