public import Foundation

/// Builds a report from facts the app chose to include (docs/mac-experience.md §8). The evidence is made from these
/// typed fields, an allowlist: nothing is collected by dumping what happens to be at hand. Text that came from
/// elsewhere (a node's message, log lines) goes through the redactor's patterns as well.
public enum ReportBuilder {
    /// What a report is about.
    public struct Subject: Sendable {
        public var kind: ReportDocument.Subject.Kind
        public var `class`: String?
        public var severity: String?
        public var card: String?
        public var metric: String?
        /// The card's or error's title, and the node's or app's message: free text.
        public var title: String?
        public var message: String?

        public init(kind: ReportDocument.Subject.Kind, class: String? = nil, severity: String? = nil, card: String? = nil,
                    metric: String? = nil, title: String? = nil, message: String? = nil) {
            self.kind = kind
            self.class = `class`
            self.severity = severity
            self.card = card
            self.metric = metric
            self.title = title
            self.message = message
        }
    }

    /// One finding of a node's health overview, as evidence.
    public struct FindingFact: Sendable {
        public var `class`: String
        public var severity: String
        public var card: String
        public var message: String

        public init(class: String, severity: String, card: String, message: String) {
            self.class = `class`
            self.severity = severity
            self.card = card
            self.message = message
        }
    }

    /// The node the report is about. Its name, addresses and ids are given only so they can be replaced.
    public struct NodeFacts: Sendable {
        public var name: String
        public var hosts: [String]
        public var ids: [String]
        public var version: String?
        public var `protocol`: Int?
        public var protocolRange: ClosedRange<Int>?
        /// "loopback", "lan", "vpn" or "wan": the class of route, never the address.
        public var routeClass: String?
        public var reachability: String
        public var overallStatus: String?
        public var errorCount: Int?
        public var warningCount: Int?
        public var checkedAt: Int64?
        public var findings: [FindingFact]

        public init(name: String, hosts: [String] = [], ids: [String] = [], version: String? = nil, protocol: Int? = nil,
                    protocolRange: ClosedRange<Int>? = nil, routeClass: String? = nil, reachability: String,
                    overallStatus: String? = nil, errorCount: Int? = nil, warningCount: Int? = nil,
                    checkedAt: Int64? = nil, findings: [FindingFact] = []) {
            self.name = name
            self.hosts = hosts
            self.ids = ids
            self.version = version
            self.protocol = `protocol`
            self.protocolRange = protocolRange
            self.routeClass = routeClass
            self.reachability = reachability
            self.overallStatus = overallStatus
            self.errorCount = errorCount
            self.warningCount = warningCount
            self.checkedAt = checkedAt
            self.findings = findings
        }
    }

    /// This Mac and this app.
    public struct DesktopFacts: Sendable {
        public var version: String
        public var build: String
        public var osVersion: String
        public var arch: String
        public var model: String
        public var nodeCount: Int
        public var linkedToCloud: Bool
        /// Switches that explain behaviour ("menu_bar_item": "on"). Keys and values are fixed words, never free text.
        public var settings: [String: String]

        public init(version: String, build: String, osVersion: String, arch: String, model: String, nodeCount: Int,
                    linkedToCloud: Bool, settings: [String: String] = [:]) {
            self.version = version
            self.build = build
            self.osVersion = osVersion
            self.arch = arch
            self.model = model
            self.nodeCount = nodeCount
            self.linkedToCloud = linkedToCloud
            self.settings = settings
        }
    }

    /// Names this Mac knows that must not leave it: every node's, vault's, user's and device's, the hosts and the ids.
    public struct KnownNames: Sendable {
        public var nodes: [String] = []
        public var vaults: [String] = []
        public var users: [String] = []
        public var devices: [String] = []
        public var hosts: [String] = []
        public var ids: [String] = []

        public init(nodes: [String] = [], vaults: [String] = [], users: [String] = [], devices: [String] = [],
                    hosts: [String] = [], ids: [String] = []) {
            self.nodes = nodes
            self.vaults = vaults
            self.users = users
            self.devices = devices
            self.hosts = hosts
            self.ids = ids
        }
    }

    public struct Input: Sendable {
        public var subject: Subject
        public var node: NodeFacts?
        public var desktop: DesktopFacts
        /// This app's own recent log lines.
        public var log: [String]
        public var occurrences: ReportDocument.Occurrences?
        public var note: String?
        public var known: KnownNames

        public init(subject: Subject, node: NodeFacts? = nil, desktop: DesktopFacts, log: [String] = [],
                    occurrences: ReportDocument.Occurrences? = nil, note: String? = nil, known: KnownNames = KnownNames()) {
            self.subject = subject
            self.node = node
            self.desktop = desktop
            self.log = log
            self.occurrences = occurrences
            self.note = note
            self.known = known
        }
    }

    /// The report, redacted. `id` and `now` are the caller's so a rebuilt report (the note changed) keeps its id.
    public static func build(_ input: Input, id: UUID = UUID(), now: Date = .now) -> ReportDocument {
        var redactor = ReportRedactor()
        // The report's own node first, so it is always node-1.
        var nodeLabel: String?
        if let node = input.node {
            nodeLabel = redactor.know(node.name, as: .node) ?? redactor.label(for: node.name, kind: .node)
            for host in node.hosts { redactor.know(host, as: .host) }
            for value in node.ids { redactor.know(value, as: .installID) }
        }
        for name in input.known.nodes { redactor.know(name, as: .node) }
        for name in input.known.vaults { redactor.know(name, as: .vault) }
        for name in input.known.users { redactor.know(name, as: .user) }
        for name in input.known.devices { redactor.know(name, as: .device) }
        for host in input.known.hosts { redactor.know(host, as: .host) }
        for value in input.known.ids { redactor.know(value, as: .installID) }

        var evidence: [ReportDocument.Evidence] = []
        if input.subject.kind != .general {
            var finding: [String: JSONFragment] = ["kind": .string(input.subject.kind.rawValue)]
            finding["class"] = input.subject.class.map(JSONFragment.string)
            finding["severity"] = input.subject.severity.map(JSONFragment.string)
            finding["card"] = input.subject.card.map(JSONFragment.string)
            finding["metric"] = input.subject.metric.map(JSONFragment.string)
            finding["title"] = input.subject.title.map { .string(redactor.scrub($0)) }
            finding["message"] = input.subject.message.map { .string(redactor.scrub($0)) }
            evidence.append(json("finding.json", .object(finding)))
        }
        if let node = input.node, let nodeLabel {
            var facts: [String: JSONFragment] = ["label": .string(nodeLabel), "product": .string("server"),
                                                 "reachability": .string(node.reachability)]
            facts["version"] = node.version.map(JSONFragment.string)
            facts["protocol"] = node.protocol.map(JSONFragment.number)
            if let range = node.protocolRange {
                facts["protocol_range"] = .object(["min": .number(range.lowerBound), "max": .number(range.upperBound)])
            }
            facts["route_class"] = node.routeClass.map(JSONFragment.string)
            if let status = node.overallStatus {
                var health: [String: JSONFragment] = ["overall_status": .string(status)]
                health["error_count"] = node.errorCount.map(JSONFragment.number)
                health["warning_count"] = node.warningCount.map(JSONFragment.number)
                health["checked_at"] = node.checkedAt.map { .number(Int($0)) }
                health["findings"] = .array(node.findings.map {
                    .object(["class": .string($0.class), "severity": .string($0.severity), "card": .string($0.card),
                             "message": .string(redactor.scrub($0.message))])
                })
                facts["health"] = .object(health)
            }
            evidence.append(json("node.json", .object(facts)))
        }
        let desktop = input.desktop
        evidence.append(json("desktop.json", .object([
            "version": .string(desktop.version), "build": .string(desktop.build),
            "os_version": .string(desktop.osVersion), "arch": .string(desktop.arch), "model": .string(desktop.model),
            "node_count": .number(desktop.nodeCount), "linked_to_cloud": .bool(desktop.linkedToCloud),
            "settings": .object(desktop.settings.mapValues(JSONFragment.string)),
        ])))
        if !input.log.isEmpty {
            // Newest lines win when the log is over the limit.
            var lines = input.log.map { redactor.scrub($0) }
            var text = lines.joined(separator: "\n")
            while text.utf8.count > ReportDocument.maxEvidenceBytes, lines.count > 1 {
                lines.removeFirst(max(1, lines.count / 8))
                text = lines.joined(separator: "\n")
            }
            evidence.append(.init(name: "log.txt", mediaType: "text/plain",
                                  text: String(text.utf8.prefix(ReportDocument.maxEvidenceBytes)) ?? ""))
        }

        let note = input.note.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        return ReportDocument(
            id: id.uuidString.lowercased(), createdAt: Int64(now.timeIntervalSince1970), product: "desktop",
            version: desktop.version, build: desktop.build,
            platform: .init(os: "macOS", osVersion: desktop.osVersion, arch: desktop.arch, model: desktop.model),
            subject: .init(kind: input.subject.kind, class: input.subject.class, severity: input.subject.severity,
                           card: input.subject.card, metric: input.subject.metric,
                           node: nodeLabel.map { .init(label: $0, version: input.node?.version, protocol: input.node?.protocol) }),
            occurrences: input.occurrences,
            // The person's own words are theirs to send, but a name they typed is still a name.
            note: note.map { String(redactor.scrub($0).prefix(ReportDocument.maxNoteLength)) },
            redaction: redactor.summary, evidence: evidence)
    }

    /// The summary a person reads first, and what "Copy Summary" copies.
    public static func summary(of report: ReportDocument, reference: String? = nil) -> String {
        var lines: [String] = []
        lines.append("Vaulthalla \(report.product.capitalized) \(report.version) (\(report.build)) on "
                     + "\(report.platform.os) \(report.platform.osVersion), \(report.platform.model) \(report.platform.arch)")
        switch report.subject.kind {
        case .finding:
            lines.append("About: \(report.subject.severity ?? "finding") \(report.subject.class ?? "")"
                         + (report.subject.node.map { " on \($0.label)\($0.version.map { " (Vaulthalla \($0))" } ?? "")" } ?? ""))
        case .error:
            lines.append("About: error \(report.subject.class ?? "")")
        case .general:
            lines.append("About: a problem, described below")
        }
        if let occurrences = report.occurrences {
            lines.append("Seen \(occurrences.count) time\(occurrences.count == 1 ? "" : "s")")
        }
        if let note = report.note { lines.append("Note: \(note)") }
        let removed = report.redaction.removed.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
        lines.append(removed.isEmpty ? "Nothing needed replacing."
                     : "Replaced or removed before you saw this: \(removed.joined(separator: ", ")).")
        lines.append("Report \(report.id)" + (reference.map { ", reference \($0)" } ?? ""))
        return lines.joined(separator: "\n")
    }

    /// Writes the report as a folder a person can open: `report.json` (the document), `summary.txt`, and each piece
    /// of evidence as its own file.
    public static func write(_ report: ReportDocument, to directory: URL, reference: String? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try report.encoded(pretty: true).write(to: directory.appending(path: "report.json"), options: .atomic)
        try Data(summary(of: report, reference: reference).utf8)
            .write(to: directory.appending(path: "summary.txt"), options: .atomic)
        for part in report.evidence {
            // Names come from the fixed list above; anything else would be a path, and is not written.
            guard part.name.wholeMatch(of: /[a-z][a-z0-9_\-]*\.(?:json|txt)/) != nil else { continue }
            try Data(part.text.utf8).write(to: directory.appending(path: part.name), options: .atomic)
        }
    }

    // MARK: - JSON with a fixed shape

    /// Just enough JSON to write evidence with sorted keys and no optional noise.
    enum JSONFragment: Encodable {
        case string(String), number(Int), bool(Bool), object([String: JSONFragment]), array([JSONFragment])

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            }
        }
    }

    private static func json(_ name: String, _ value: JSONFragment) -> ReportDocument.Evidence {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return .init(name: name, mediaType: "application/json", text: text)
    }
}
