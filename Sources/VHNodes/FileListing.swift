public import Foundation
public import VHContract

/// One entry of a vault folder as the file browser shows it: the server's `FsEntry` plus what sorting and display
/// need, computed once per listing (a folder can hold tens of thousands of entries).
public struct FileItem: Identifiable, Hashable, Sendable {
    public let entry: WsModel.FsEntry
    public let path: VaultPath
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// The file's length; nil for folders (their size isn't a sum the node keeps).
    public let size: Int64?
    public let modified: Date?
    /// The kind column ("JPEG image", "Folder"), from the type the app derives.
    public let kind: String
    /// Whether `/preview` can render a thumbnail: the node's plan says so (images and PDFs by MIME type when an older
    /// node sends no plan). Never asked for otherwise.
    public let hasThumbnail: Bool

    public var id: String { path.rawValue }
    public var name: String { entry.name }
    public var mimeType: String? { entry.mimeType?.wrapped }
    /// What the node said about how the file can be consumed (nil for folders and older nodes).
    public var plan: WsModel.PreviewPlan? { entry.preview }

    /// `kind`: the display kind for the entry (the app maps the name/MIME type through `UTType`).
    public init(entry: WsModel.FsEntry, in folder: VaultPath, kind: (WsModel.FsEntry, Bool) -> String) {
        self.entry = entry
        let directory = entry.type == WsModel.FsEntry.TypeValue.directory
            || (entry.type != WsModel.FsEntry.TypeValue.file && (entry.fileCount != nil || entry.subdirectoryCount != nil))
        isDirectory = directory
        isSymlink = entry.type == WsModel.FsEntry.TypeValue.symlink
        path = entry.path.isEmpty ? folder.appending(entry.name) : VaultPath(normalizing: entry.path)
        size = directory ? nil : entry.sizeBytes
        modified = FileItem.date(entry.updatedAt) ?? FileItem.date(entry.createdAt)
        self.kind = kind(entry, directory)
        if directory {
            hasThumbnail = false
        } else if let plan = entry.preview {
            hasThumbnail = plan.thumbnail
        } else {
            let mime = entry.mimeType?.wrapped ?? ""
            hasThumbnail = mime.hasPrefix("image/") || mime == "application/pdf"
        }
    }

    private static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        return try? Date(text, strategy: .iso8601)
    }

    /// Identity for caches: the same path with the same content generation (size and modification time).
    public var contentSignature: String {
        "\(path.rawValue)\u{1F}\(entry.updatedAt)\u{1F}\(entry.sizeBytes)"
    }
}

/// How the browser orders a folder: by one column, folders first (as the web console and Finder's "keep folders on
/// top" do), names compared like Finder ("file 2" before "file 10", case-insensitive).
public struct FileSort: Hashable, Sendable, Codable {
    public enum Key: String, Hashable, Sendable, Codable, CaseIterable {
        case name, size, kind, modified
    }

    public var key: Key
    public var ascending: Bool
    public var foldersFirst: Bool

    public init(key: Key = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    public func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted(by: areInIncreasingOrder)
    }

    public func areInIncreasingOrder(_ a: FileItem, _ b: FileItem) -> Bool {
        if foldersFirst, a.isDirectory != b.isDirectory { return a.isDirectory }
        let order: ComparisonResult = switch key {
        case .name: .orderedSame
        case .size: Self.compare(a.size ?? -1, b.size ?? -1)
        case .kind: a.kind.localizedStandardCompare(b.kind)
        case .modified: Self.compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
        }
        if order != .orderedSame { return ascending ? order == .orderedAscending : order == .orderedDescending }
        // Ties (and the name column itself) fall back to the name, in the column's direction only for the name.
        let byName = a.name.localizedStandardCompare(b.name)
        if byName != .orderedSame {
            return key == .name && !ascending ? byName == .orderedDescending : byName == .orderedAscending
        }
        return a.path.rawValue < b.path.rawValue
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}

/// A folder's entries filtered for display.
public enum FileFilter {
    /// Keeps entries matching `query` (case- and diacritic-insensitive substring of the name); hidden and system
    /// entries only when `showHidden`.
    public static func apply(_ items: [FileItem], query: String, showHidden: Bool) -> [FileItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        if needle.isEmpty && showHidden { return items }
        return items.filter { item in
            if !showHidden, item.entry.isHidden || item.entry.isSystem || item.name.hasPrefix(".") { return false }
            return needle.isEmpty || item.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
