public import Foundation

/// The name a local edit is kept under when the server's file changed since the edit's base
/// (vaulthalla/desktop#4): `"<name> (conflict from <Mac name> <yyyy-MM-dd HHmm>)<.ext>"`, beside the original. The
/// server's version keeps the original name; neither edit is lost.
public enum ConflictName {
    /// The conflict copy's name for `name`, edited on `macName` at `date` (local time in `timeZone`). `attempt` 2, 3, …
    /// adds a counter when that name is taken too: `"report (conflict from Studio 2026-10-24 1530) 2.txt"`. The
    /// extension stays last, and a name with no stem before its dot (".env") has no extension.
    public static func make(for name: String, macName: String, date: Date, timeZone: TimeZone = .current,
                            attempt: Int = 1) -> String {
        let (stem, ext) = split(name)
        let counter = attempt > 1 ? " \(attempt)" : ""
        let suffix = " (conflict from \(clean(macName)) \(stamp(date, timeZone: timeZone)))\(counter)"
        // The server's limit is 255 UTF-8 bytes: shorten the stem, never the marker or the extension.
        let room = 255 - suffix.utf8.count - ext.utf8.count
        return truncated(stem, toUTF8Bytes: max(1, room)) + suffix + ext
    }

    /// `yyyy-MM-dd HHmm`, Gregorian, in `timeZone`.
    public static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Whether `name` looks like a conflict copy this naming made (for tests and diagnostics).
    public static func isConflictCopy(_ name: String) -> Bool {
        name.contains(" (conflict from ")
    }

    /// The Mac's name for the marker, without `/`, `:` or line breaks (the server refuses `/`, Finder shows `:` as `/`).
    static func clean(_ macName: String) -> String {
        let replaced = String(macName.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        let words = replaced.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return words.isEmpty ? "Mac" : words
    }

    static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex
        else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    static func truncated(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= limit else { break }
            result.append(character)
        }
        return result
    }
}
