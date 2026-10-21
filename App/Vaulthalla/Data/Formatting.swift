import Foundation
import VHContract

/// Display helpers shared by the screens. They format what the daemon sent; none of them invents a value.
nonisolated enum Format {
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    /// Epoch seconds as "3 min ago".
    static func relative(epoch seconds: Int64, now: Date = .now) -> String {
        relative(Date(timeIntervalSince1970: TimeInterval(seconds)), now: now)
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        if abs(date.timeIntervalSince(now)) < 10 { return "just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// The daemon's ISO-8601 timestamps ("2026-10-20T12:00:00Z"); nil when unreadable.
    static func date(iso text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return try? Date(text, strategy: .iso8601)
    }

    static func day(iso text: String?) -> String? {
        date(iso: text)?.formatted(date: .abbreviated, time: .omitted)
    }

    static func moment(iso text: String?) -> String? {
        date(iso: text)?.formatted(date: .abbreviated, time: .shortened)
    }

    /// `snake_case` status words as a label ("provider_versioning" → "Provider versioning").
    static func words(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

/// The daemon's severity words, as the web console says them (features/health/model.ts).
enum Severity {
    static func text(_ severity: String) -> String {
        switch severity {
        case "healthy": "Healthy"
        case "info": "Info"
        case "warning": "Warning"
        case "error": "Error"
        case "unavailable": "Not available"
        default: "Unknown"
        }
    }

    /// The overall status in words. `info` means nothing is wrong but some cards carry notes.
    static func headline(_ status: String) -> String {
        switch status {
        case "info": "No issues"
        case "healthy": "Healthy"
        case "unavailable": "Not reporting"
        default: text(status)
        }
    }

    static func symbol(_ severity: String) -> String {
        switch severity {
        case "healthy": "checkmark.circle"
        case "info": "info.circle"
        case "warning": "exclamationmark.triangle"
        case "error": "xmark.octagon"
        default: "questionmark.circle"
        }
    }

    static func issueCount(errors: Int64, warnings: Int64) -> String {
        var parts: [String] = []
        if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
        if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

extension WsModel.DashboardMetricSummary {
    private static let unknownWords: Set<String> = ["", "unknown", "n/a", "not available", "unavailable"]

    /// The value to show, or nil for "not available". Money is formatted from its number and ISO currency; a money
    /// metric without a number keeps the daemon's words ("not estimated"), never $0.00.
    var display: String? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if Self.unknownWords.contains(text.lowercased()) { return nil }
        if let unit, unit.count == 3, unit.allSatisfy(\.isUppercase), let numericValue {
            return numericValue.formatted(.currency(code: unit))
        }
        return text
    }

    /// Only warnings and errors color a value; a value the daemon couldn't measure never gets a tone.
    var valueTone: StatusTone? {
        guard display != nil else { return nil }
        switch tone {
        case "warning": return .warn
        case "error": return .danger
        default: return nil
        }
    }
}
