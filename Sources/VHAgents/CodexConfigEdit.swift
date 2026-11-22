public import Foundation

/// The one edit Vaulthalla makes to Codex's `config.toml`: `tool_timeout_sec` in its own server's table, which the
/// `codex` CLI can't set. It is deliberately narrow, so that nothing else in the file can change:
///
/// - It acts only on a single standard table header for the server (`[mcp_servers.vaulthalla-desktop]`, the form
///   `codex mcp add` writes, bare or quoted), never inside a multi-line string; any other shape is refused.
/// - It inserts one line right after that header, or rewrites the one existing `tool_timeout_sec` line in that table.
///   Every other byte stays as it was (line endings included).
/// - The new file is written beside the old one (through a symlinked path, beside its target), flushed, given the
///   old file's permissions, and renamed over it; if the file changed meanwhile (Codex wrote it), nothing is replaced.
///   No backup or temporary file is left behind.
public enum CodexConfigEdit {
    public enum Outcome: Equatable, Sendable {
        case changed
        /// Already set to that value.
        case unchanged
        /// Not safe to edit; the reason, for the person.
        case refused(String)
    }

    public static func setToolTimeout(_ seconds: Int, server: String, in url: URL) -> Outcome {
        let target = url.resolvingSymlinksInPath()
        guard let original = try? Data(contentsOf: target) else { return .refused("its config.toml can't be read") }
        guard let text = String(data: original, encoding: .utf8) else { return .refused("its config.toml isn't UTF-8") }
        let edited: String
        switch edit(text, seconds: seconds, server: server) {
        case .success(nil): return .unchanged
        case .success(let changed?): edited = changed
        case .failure(let refusal): return .refused(refusal.reason)
        }
        do {
            try replace(target, expecting: original, with: Data(edited.utf8))
            return .changed
        } catch {
            return .refused(error.reason)
        }
    }

    struct Refusal: Error, Equatable {
        let reason: String
    }

    /// The edited text, nil when the value is already there.
    static func edit(_ text: String, seconds: Int, server: String) -> Result<String?, Refusal> {
        let lines = splitLines(text)
        var headers: [Int] = []
        var tableHeaders: [Int] = []
        var inMultiline: String?
        for (index, line) in lines.enumerated() {
            let body = line.content
            if let delimiter = inMultiline {
                if occurrences(of: delimiter, in: body) % 2 == 1 { inMultiline = nil }
                continue
            }
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                tableHeaders.append(index)
                if isHeader(trimmed, server: server) { headers.append(index) }
                continue
            }
            for delimiter in ["\"\"\"", "'''"] where occurrences(of: delimiter, in: body) % 2 == 1 {
                inMultiline = delimiter
                break
            }
        }
        guard inMultiline == nil else { return .failure(Refusal(reason: "its config.toml has an unclosed string")) }
        guard headers.count == 1, let header = headers.first else {
            return .failure(Refusal(reason: "config.toml has no single [mcp_servers.\(server)] table"))
        }
        let end = tableHeaders.first { $0 > header } ?? lines.count
        let setting = "tool_timeout_sec = \(seconds)"
        var output = lines
        let existing = (header + 1 ..< end).filter { isTimeoutKey(lines[$0].content) }
        switch existing.count {
        case 0:
            let ending = lines[header].ending.isEmpty ? "\n" : lines[header].ending
            if lines[header].ending.isEmpty { output[header].ending = "\n" }
            output.insert(Line(content: setting, ending: ending), at: header + 1)
        case 1:
            let index = existing[0]
            let indentation = String(lines[index].content.prefix { $0 == " " || $0 == "\t" })
            if lines[index].content.trimmingCharacters(in: .whitespaces) == setting { return .success(nil) }
            output[index].content = indentation + setting
        default:
            return .failure(Refusal(reason: "config.toml sets tool_timeout_sec twice for \(server)"))
        }
        return .success(output.map { $0.content + $0.ending }.joined())
    }

    struct Line: Equatable {
        var content: String
        var ending: String
    }

    /// Lines with their endings ("\n" or "\r\n"), split on scalars: Swift's "\r\n" is one Character.
    static func splitLines(_ text: String) -> [Line] {
        var lines: [Line] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard scalar == "\n" else {
                current.append(scalar)
                continue
            }
            var ending = "\n"
            if current.last == "\r" {
                current.removeLast()
                ending = "\r\n"
            }
            lines.append(Line(content: String(current), ending: ending))
            current = String.UnicodeScalarView()
        }
        if !current.isEmpty { lines.append(Line(content: String(current), ending: "")) }
        return lines
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// `[mcp_servers.<server>]`, the server's name bare, "quoted" or 'quoted', with optional spaces and a comment.
    static func isHeader(_ trimmed: String, server: String) -> Bool {
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[[") else { return false }
        var body = trimmed.dropFirst()
        guard let close = body.firstIndex(of: "]") else { return false }
        let after = body[body.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard after.isEmpty || after.hasPrefix("#") else { return false }
        body = body[..<close]
        let parts = body.split(separator: ".", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts[0] == "mcp_servers" else { return false }
        return [server, "\"\(server)\"", "'\(server)'"].contains(parts[1])
    }

    private static func isTimeoutKey(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("tool_timeout_sec") else { return false }
        return trimmed.dropFirst("tool_timeout_sec".count).drop { $0 == " " || $0 == "\t" }.hasPrefix("=")
    }

    /// Writes `data` beside `target` and renames it over `target`, unless `target` no longer holds `expected`.
    static func replace(_ target: URL, expecting expected: Data, with data: Data) throws(Refusal) {
        let path = target.path(percentEncoded: false)
        var info = stat()
        guard stat(path, &info) == 0 else { throw Refusal(reason: "its config.toml can't be read") }
        let directory = target.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(target.lastPathComponent).vaulthalla-\(UUID().uuidString)")
            .path(percentEncoded: false)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Refusal(reason: "a file can't be created beside its config.toml") }
        var written = 0
        let ok = data.withUnsafeBytes { buffer -> Bool in
            while written < buffer.count {
                let count = write(fd, buffer.baseAddress! + written, buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += count
            }
            return fchmod(fd, info.st_mode & 0o7777) == 0 && (fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0)
        }
        close(fd)
        guard ok else {
            unlink(temporary)
            throw Refusal(reason: "the new config.toml couldn't be written")
        }
        guard (try? Data(contentsOf: target)) == expected else {
            unlink(temporary)
            throw Refusal(reason: "Codex changed its config.toml meanwhile")
        }
        guard rename(temporary, path) == 0 else {
            unlink(temporary)
            throw Refusal(reason: "the new config.toml couldn't replace the old one")
        }
    }
}
