import Foundation

/// Redaction for a report (`vh-redact/1`, docs/mac-experience.md §8). Applied before the report is shown, so what the
/// person reads is exactly what would leave the Mac.
///
/// Two layers:
/// - **Known names** (the nodes, vaults, users, devices, hosts and ids this Mac knows) are replaced by labels that
///   are stable within one report: the same vault is `vault-3` everywhere in it, and means nothing outside it.
/// - **Patterns** catch what nobody listed: addresses, emails, `.local` and URL hosts, ids, paths and anything shaped
///   like a key. A path or key-shaped string is removed, not labelled: it should never have been there.
///
/// File contents, file and folder names, keys, tokens, passwords, pairing codes, certificates and key pins are never
/// collected as evidence in the first place; the pattern layer is the backstop for text that comes from elsewhere (a
/// node's message, log lines).
public struct ReportRedactor: Sendable {
    public static let rules = "vh-redact/1"

    public enum Kind: String, Sendable, CaseIterable {
        case node, vault, user, device, host
        case address, email
        case installID = "install_id"
        /// Removed outright, never labelled.
        case path, secret

        var prefix: String {
            switch self {
            case .node: "node"
            case .vault: "vault"
            case .user: "user"
            case .device: "device"
            case .host: "host"
            case .address: "addr"
            case .email: "email"
            case .installID: "id"
            case .path: "path"
            case .secret: "secret"
            }
        }
    }

    private var labels: [Kind: [String: String]] = [:]
    /// Known values, longest first, so a name that contains another is replaced whole.
    private var known: [(value: String, kind: Kind)] = []
    public private(set) var removed: [String: Int] = [:]

    public init() {}

    /// Registers a name this Mac knows, and returns its label. Empty and one-character values are ignored: replacing
    /// them would shred ordinary words.
    @discardableResult
    public mutating func know(_ value: String, as kind: Kind) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let made = label(for: trimmed, kind: kind)
        if !known.contains(where: { $0.value.caseInsensitiveCompare(trimmed) == .orderedSame && $0.kind == kind }) {
            known.append((trimmed, kind))
            known.sort { $0.value.count > $1.value.count }
        }
        return made
    }

    /// The label a value has in this report, made on first use.
    public mutating func label(for value: String, kind: Kind) -> String {
        let key = value.lowercased()
        if let existing = labels[kind]?[key] { return existing }
        let made = "\(kind.prefix)-\((labels[kind]?.count ?? 0) + 1)"
        labels[kind, default: [:]][key] = made
        return made
    }

    /// The text with every known name and every pattern match replaced or removed, counting each.
    public mutating func scrub(_ text: String) -> String {
        var out = text
        // Things that must never be present go first, so no later rule can leave half of one behind.
        out = replace(Self.pem, in: out, kind: .secret) { _, _ in "[key removed]" }
        out = replace(Self.url, in: out, kind: .host) { redactor, match in
            // scheme://host[:port]/…: the host becomes a label; the rest of the URL is a path and goes.
            guard let scheme = match.split(separator: ":").first,
                  let host = URLComponents(string: match)?.host, !host.isEmpty else { return "[address removed]" }
            return "\(scheme)://\(redactor.hostLabel(host))"
        }
        for entry in known {
            out = replaceLiteral(entry.value, in: out, kind: entry.kind)
        }
        out = replace(Self.email, in: out, kind: .email) { redactor, match in redactor.label(for: match, kind: .email) }
        out = replace(Self.ipv4, in: out, kind: .address) { redactor, match in redactor.label(for: match, kind: .address) }
        out = replace(Self.ipv6, in: out, kind: .address, when: Self.looksLikeAddress) { redactor, match in
            redactor.label(for: match, kind: .address)
        }
        out = replace(Self.localHost, in: out, kind: .host) { redactor, match in redactor.label(for: match, kind: .host) }
        out = replace(Self.uuid, in: out, kind: .installID) { redactor, match in redactor.label(for: match, kind: .installID) }
        out = replace(Self.path, in: out, kind: .path, when: Self.startsAPath) { _, _ in "[path removed]" }
        out = replace(Self.keyShaped, in: out, kind: .secret) { _, _ in "[removed]" }
        return out
    }

    /// The redaction block of the report: the rule set and the counts.
    public var summary: ReportDocument.Redaction {
        ReportDocument.Redaction(rules: Self.rules, removed: removed)
    }

    // MARK: - Patterns

    private mutating func hostLabel(_ host: String) -> String {
        if host.wholeMatch(of: Self.ipv4) != nil || host.contains(":") { return label(for: host, kind: .address) }
        return label(for: host, kind: .host)
    }

    nonisolated(unsafe) private static let pem =
        /-----BEGIN [A-Z0-9 ]+-----[\s\S]*?(?:-----END [A-Z0-9 ]+-----|$)/
    nonisolated(unsafe) private static let url = /\b[a-zA-Z][a-zA-Z0-9+.\-]*:\/\/[^\s"'<>\]\)]+/
    nonisolated(unsafe) private static let email = /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/
    nonisolated(unsafe) private static let ipv4 =
        /\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?::\d{1,5})?\b/
    /// Any run of hex groups with at least two colons, compressed ("::") or not, with an optional zone. Whether it
    /// is an address and not a clock time is decided in code (`looksLikeAddress`).
    nonisolated(unsafe) private static let ipv6 = /[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:%[A-Za-z0-9]+)?/
    nonisolated(unsafe) private static let localHost = /\b[A-Za-z0-9][A-Za-z0-9\-]*\.(?:local|lan|internal|home\.arpa)\b/
    nonisolated(unsafe) private static let uuid =
        /\b(?:local-)?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b/
    /// An absolute or home-relative path of two or more components.
    nonisolated(unsafe) private static let path = /~?(?:\/[^\s\/"'<>:,;\]\)]+){2,}\/?/
    /// Long runs of base64, base64url or hex: keys, tokens, pins, hashes.
    nonisolated(unsafe) private static let keyShaped = /\b[A-Za-z0-9+\/_\-]{32,}={0,2}/

    /// Swift's regex literals have no lookbehind, so what must not come before or after a match is checked here.
    /// A run of hex groups is an address unless it is glued to a word or is a clock time ("12:30:05").
    private static func looksLikeAddress(_ text: String, _ range: Range<String.Index>) -> Bool {
        if let before = text[..<range.lowerBound].last, before.isLetter || before.isNumber || before == ":" { return false }
        if let after = text[range.upperBound...].first, after.isLetter || after.isNumber || after == ":" { return false }
        let match = text[range]
        if match.contains("::") { return true }
        let groups = match.split(separator: ":")
        let clock = groups.count <= 3 && groups.allSatisfy { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        return !clock
    }

    /// A path starts at a boundary: not in the middle of a word, a URL, a version or a fraction.
    private static func startsAPath(_ text: String, _ range: Range<String.Index>) -> Bool {
        guard let before = text[..<range.lowerBound].last else { return true }
        return !(before.isLetter || before.isNumber || ":/.-".contains(before))
    }

    private mutating func replace(_ regex: some RegexComponent<Substring>, in text: String, kind: Kind,
                                  when accept: (String, Range<String.Index>) -> Bool = { _, _ in true },
                                  with replacement: (inout ReportRedactor, String) -> String) -> String {
        var out = ""
        var index = text.startIndex
        var count = 0
        for match in text.matches(of: regex) {
            guard match.range.lowerBound >= index, accept(text, match.range) else { continue }
            out += text[index..<match.range.lowerBound]
            out += replacement(&self, String(text[match.range]))
            index = match.range.upperBound
            count += 1
        }
        guard count > 0 else { return text }
        out += text[index...]
        removed[kind.rawValue, default: 0] += count
        return out
    }

    private mutating func replaceLiteral(_ value: String, in text: String, kind: Kind) -> String {
        var out = ""
        var index = text.startIndex
        var count = 0
        while let range = text.range(of: value, options: [.caseInsensitive], range: index..<text.endIndex) {
            out += text[index..<range.lowerBound]
            out += label(for: value, kind: kind)
            index = range.upperBound
            count += 1
        }
        guard count > 0 else { return text }
        out += text[index...]
        removed[kind.rawValue, default: 0] += count
        return out
    }
}
