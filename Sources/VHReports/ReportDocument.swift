public import Foundation

/// A problem report in the `vh-report/1` form (docs/mac-experience.md §8; the contract is
/// `docs/design/report-intake.md` in valkyrianlabs/vaulthalla-cloud). One JSON document: what the report is about,
/// the evidence as text, and what redaction removed. What the person reads before sending is this document; what is
/// sent is this document.
public struct ReportDocument: Codable, Hashable, Sendable {
    public static let format = "vh-report/1"
    /// The service's limits: the whole document, each evidence part, and how many parts.
    public static let maxDocumentBytes = 1 << 20
    public static let maxEvidenceBytes = 256 << 10
    public static let maxEvidenceParts = 16
    public static let maxNoteLength = 2000

    public var format: String
    /// Made by the sender. Sending the same id again returns the first answer.
    public var id: String
    public var createdAt: Int64
    public var product: String
    public var version: String
    public var build: String
    public var platform: Platform
    public var subject: Subject
    public var occurrences: Occurrences?
    /// The person's own words.
    public var note: String?
    public var redaction: Redaction
    public var evidence: [Evidence]

    public struct Platform: Codable, Hashable, Sendable {
        public var os: String
        public var osVersion: String
        public var arch: String
        public var model: String

        public init(os: String, osVersion: String, arch: String, model: String) {
            self.os = os
            self.osVersion = osVersion
            self.arch = arch
            self.model = model
        }

        enum CodingKeys: String, CodingKey {
            case os, arch, model
            case osVersion = "os_version"
        }
    }

    public struct Subject: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// A health finding a node reported.
            case finding
            /// An error the app showed.
            case error
            /// Help ▸ Report a Problem: nothing in particular.
            case general
        }

        public var kind: Kind
        /// The finding's class, or the error's stable code.
        public var `class`: String?
        public var severity: String?
        public var card: String?
        public var metric: String?
        public var node: NodeRef?

        public init(kind: Kind, class: String? = nil, severity: String? = nil, card: String? = nil,
                    metric: String? = nil, node: NodeRef? = nil) {
            self.kind = kind
            self.class = `class`
            self.severity = severity
            self.card = card
            self.metric = metric
            self.node = node
        }
    }

    /// The server a report is about: a label, never its name or address.
    public struct NodeRef: Codable, Hashable, Sendable {
        public var label: String
        public var product: String
        public var version: String?
        public var `protocol`: Int?

        public init(label: String, product: String = "server", version: String? = nil, protocol: Int? = nil) {
            self.label = label
            self.product = product
            self.version = version
            self.protocol = `protocol`
        }
    }

    public struct Occurrences: Codable, Hashable, Sendable {
        public var count: Int
        public var firstSeen: Int64
        public var lastSeen: Int64

        public init(count: Int, firstSeen: Int64, lastSeen: Int64) {
            self.count = count
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
        }

        enum CodingKeys: String, CodingKey {
            case count
            case firstSeen = "first_seen"
            case lastSeen = "last_seen"
        }
    }

    public struct Redaction: Codable, Hashable, Sendable {
        public var rules: String
        /// How many of each kind of thing were replaced or removed.
        public var removed: [String: Int]

        public init(rules: String, removed: [String: Int]) {
            self.rules = rules
            self.removed = removed
        }
    }

    public struct Evidence: Codable, Hashable, Sendable {
        public var name: String
        public var mediaType: String
        public var text: String

        public init(name: String, mediaType: String, text: String) {
            self.name = name
            self.mediaType = mediaType
            self.text = text
        }

        enum CodingKeys: String, CodingKey {
            case name, text
            case mediaType = "media_type"
        }
    }

    public init(id: String, createdAt: Int64, product: String, version: String, build: String, platform: Platform,
                subject: Subject, occurrences: Occurrences? = nil, note: String? = nil, redaction: Redaction,
                evidence: [Evidence]) {
        format = Self.format
        self.id = id
        self.createdAt = createdAt
        self.product = product
        self.version = version
        self.build = build
        self.platform = platform
        self.subject = subject
        self.occurrences = occurrences
        self.note = note
        self.redaction = redaction
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey {
        case format, id, product, version, build, platform, subject, occurrences, note, redaction, evidence
        case createdAt = "created_at"
    }

    /// The document as it is sent and saved: sorted keys, so the same report is the same bytes.
    public func encoded(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// What the service answers for a stored report.
public struct ReportReceipt: Codable, Hashable, Sendable {
    public var id: String
    /// The short form people quote ("VHR-7K2M9Q").
    public var reference: String
    public var receivedAt: Int64

    public init(id: String, reference: String, receivedAt: Int64) {
        self.id = id
        self.reference = reference
        self.receivedAt = receivedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, reference
        case receivedAt = "received_at"
    }
}
