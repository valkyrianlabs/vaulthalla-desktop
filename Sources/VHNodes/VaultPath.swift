import Foundation

/// A vault-relative path ("/docs/a.txt"), normalized the way the web console does (web/src/features/files/paths.ts):
/// always absolute, no empty, `.` or `..` components, no trailing slash. The root is "/".
public struct VaultPath: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public static let root = VaultPath(normalizing: "/")

    /// Normalizes `path`; `.` and `..` components are dropped (the node refuses them, and a listing never has them).
    public init(normalizing path: String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." && $0 != ".." }
        rawValue = parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    public var description: String { rawValue }
    public var isRoot: Bool { rawValue == "/" }

    /// The components, root first excluded: "/a/b" → ["a", "b"].
    public var components: [String] {
        rawValue.split(separator: "/").map(String.init)
    }

    /// The last component; "" for the root.
    public var name: String { components.last ?? "" }

    /// The containing folder; the root's parent is the root.
    public var parent: VaultPath {
        VaultPath(normalizing: components.dropLast().joined(separator: "/"))
    }

    /// `name` (or a relative "a/b") inside this folder.
    public func appending(_ relative: String) -> VaultPath {
        VaultPath(normalizing: rawValue + "/" + relative)
    }

    /// Every folder from the root down to this path, for a path bar: "/a/b" → ["/", "/a", "/a/b"].
    public var ancestry: [VaultPath] {
        var paths = [VaultPath.root]
        var current = VaultPath.root
        for component in components {
            current = current.appending(component)
            paths.append(current)
        }
        return paths
    }

    /// Whether `other` is this path or inside it ("/a" contains "/a/b", not "/ab").
    public func contains(_ other: VaultPath) -> Bool {
        isRoot || other == self || other.rawValue.hasPrefix(rawValue + "/")
    }

    public static func < (lhs: VaultPath, rhs: VaultPath) -> Bool { lhs.rawValue < rhs.rawValue }

    // MARK: Names

    /// Why `name` can't name an entry, or nil when it can: not empty, no "/", not "." or "..", no NUL, at most 255
    /// UTF-8 bytes (the node's filesystem limit).
    public static func problem(withName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "A name can't be empty." }
        if name.contains("/") { return "A name can't contain “/”." }
        if name.contains("\u{0}") { return "A name can't contain a null character." }
        if name == "." || name == ".." { return "“\(name)” is reserved." }
        if name.utf8.count > 255 { return "That name is too long." }
        return nil
    }

    /// `base` if no name in `taken` uses it, else Finder's "base 2", "base 3", … (before the extension for files:
    /// "photo 2.jpg").
    public static func uniqueName(_ base: String, taken: Set<String>, isDirectory: Bool = true) -> String {
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(base.lowercased()) else { return base }
        var stem = base
        var ext = ""
        if !isDirectory, let dot = base.lastIndex(of: "."), dot != base.startIndex {
            stem = String(base[..<dot])
            ext = String(base[dot...])
        }
        var number = 2
        while lowered.contains("\(stem) \(number)\(ext)".lowercased()) { number += 1 }
        return "\(stem) \(number)\(ext)"
    }
}
