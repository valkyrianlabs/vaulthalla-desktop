public import Foundation
public import VHContract

/// A File Provider item identifier (`NSFileProviderItemIdentifier`'s raw value) in a vault's domain: the domain's root,
/// its working set, the trash, or one of the vault's entries by its server id.
///
/// An entry is `e<id>`: the daemon's `FsEntry.id`, which stays the same across rename and move
/// (vaulthalla/server#257), so the system keeps an item's identity (and its local replica) through both. The domain is
/// one vault, so the id alone is unique in it.
public enum FinderItemID: Hashable, Sendable, CustomStringConvertible, Comparable {
    case root
    case workingSet
    case trash
    case entry(Int64)

    /// `NSFileProviderItemIdentifier.rootContainer`, `.workingSet` and `.trashContainer` (pinned by a test that
    /// imports FileProvider).
    public static let rootRawValue = "NSFileProviderRootContainerItemIdentifier"
    public static let workingSetRawValue = "NSFileProviderWorkingSetContainerItemIdentifier"
    public static let trashRawValue = "NSFileProviderTrashContainerItemIdentifier"

    /// nil for an identifier this domain never hands out.
    public init?(rawValue: String) {
        switch rawValue {
        case Self.rootRawValue: self = .root
        case Self.workingSetRawValue: self = .workingSet
        case Self.trashRawValue: self = .trash
        default:
            guard rawValue.hasPrefix("e") else { return nil }
            let digits = rawValue.dropFirst()
            guard let id = Int64(digits), id >= 0, String(id) == digits else { return nil }
            self = .entry(id)
        }
    }

    public var rawValue: String {
        switch self {
        case .root: Self.rootRawValue
        case .workingSet: Self.workingSetRawValue
        case .trash: Self.trashRawValue
        case .entry(let id): "e\(id)"
        }
    }

    public var description: String { rawValue }

    public static func < (lhs: FinderItemID, rhs: FinderItemID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What an entry is, as the daemon types it.
public enum FinderItemKind: Int, Hashable, Sendable, Codable {
    case file = 0
    case directory = 1
    case symlink = 2

    /// From `FsEntry.type`: a type a newer daemon adds counts as a file unless it carries folder counts.
    init(entry: WsModel.FsEntry) {
        switch entry.type {
        case WsModel.FsEntry.TypeValue.directory: self = .directory
        case WsModel.FsEntry.TypeValue.symlink: self = .symlink
        case WsModel.FsEntry.TypeValue.file: self = .file
        default: self = entry.fileCount != nil || entry.subdirectoryCount != nil ? .directory : .file
        }
    }
}

/// An item's version as the File Provider keeps it (`NSFileProviderItemVersion`): opaque bytes the system compares
/// for equality and sends back as the base of the next change.
///
/// - Files: `content` is the daemon's `content_version`, exactly the strong ETag `/download/content` serves (quotes
///   included), so it doubles as `If-Range` and `If-Match`. `metadata` is `metadata_version`.
/// - Folders and symlinks have no content version on the server: both halves are `metadata_version`, so a folder's
///   "content" changes when its metadata does, and never otherwise.
public struct FinderItemVersion: Hashable, Sendable {
    public let content: Data
    public let metadata: Data

    public init(content: Data, metadata: Data) {
        self.content = content
        self.metadata = metadata
    }

    public init(contentVersion: String?, metadataVersion: String) {
        self.init(content: Data((contentVersion ?? metadataVersion).utf8), metadata: Data(metadataVersion.utf8))
    }

    /// The content half as the ETag string it came from; nil unless it is one (a strong, quoted validator).
    public var contentETag: String? {
        guard let text = String(data: content, encoding: .utf8), text.hasPrefix("\""), text.hasSuffix("\""),
              text.count >= 2
        else { return nil }
        return text
    }

    public var metadataString: String { String(decoding: metadata, as: UTF8.self) }
}

/// What the system may do with an item (`NSFileProviderItemCapabilities`, same bits). Conservative and never derived
/// from roles or permissions: Swift has no RBAC (vaulthalla/desktop#1). Everything an entry kind supports is offered,
/// and the server refuses what the account may not do; the refusal is mapped (``FinderError``). Trashing is left out:
/// the domain doesn't sync a Trash (`supportsSyncingTrash = false`), deletes go to the server's trash and recovery.
public struct FinderCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let reading = FinderCapabilities(rawValue: 1 << 0)
    /// Files: writing. Folders: adding sub-items.
    public static let writing = FinderCapabilities(rawValue: 1 << 1)
    public static let reparenting = FinderCapabilities(rawValue: 1 << 2)
    public static let renaming = FinderCapabilities(rawValue: 1 << 3)
    public static let trashing = FinderCapabilities(rawValue: 1 << 4)
    public static let deleting = FinderCapabilities(rawValue: 1 << 5)

    public static func of(_ kind: FinderItemKind, isRoot: Bool = false) -> FinderCapabilities {
        if isRoot { return [.reading, .writing] }
        return switch kind {
        case .file, .directory: [.reading, .writing, .reparenting, .renaming, .deleting]
        // The server's symlinks are listed and can be moved or deleted; their targets aren't written through Finder.
        case .symlink: [.reading, .reparenting, .renaming, .deleting]
        }
    }
}

/// One entry of the vault as the replica keeps it: the fields of `FsEntry` the File Provider shows, plus the path the
/// daemon's commands take. Built from listings and write answers only; nothing here is decided locally.
public struct FinderItem: Hashable, Sendable {
    public var entryID: Int64
    /// The containing folder's entry id; nil for the vault's root.
    public var parentEntryID: Int64?
    public var name: String
    /// Vault-relative path, as the daemon's commands take it.
    public var path: String
    public var kind: FinderItemKind
    public var size: Int64
    /// ISO-8601, as the daemon sends them.
    public var createdAt: String
    public var updatedAt: String
    /// Files: `content_version`. nil for folders and symlinks.
    public var contentVersion: String?
    public var metadataVersion: String
    public var symlinkTarget: String?
    public var isHidden: Bool

    public init(entryID: Int64, parentEntryID: Int64?, name: String, path: String, kind: FinderItemKind, size: Int64,
                createdAt: String, updatedAt: String, contentVersion: String?, metadataVersion: String,
                symlinkTarget: String? = nil, isHidden: Bool = false) {
        self.entryID = entryID
        self.parentEntryID = parentEntryID
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
        self.symlinkTarget = symlinkTarget
        self.isHidden = isHidden
    }

    /// A listed entry. `parent` is the listed folder's id, used when the entry doesn't name its parent.
    public init(entry: WsModel.FsEntry, parent: Int64?) {
        let kind = FinderItemKind(entry: entry)
        self.init(entryID: entry.id, parentEntryID: entry.parentID ?? parent, name: entry.name,
                  path: Self.normalize(entry.path), kind: kind,
                  size: kind == .file ? entry.sizeBytes : 0, createdAt: entry.createdAt, updatedAt: entry.updatedAt,
                  contentVersion: kind == .file ? entry.contentVersion : nil, metadataVersion: entry.metadataVersion,
                  symlinkTarget: kind == .symlink ? entry.target : nil, isHidden: entry.isHidden)
    }

    /// An entry from `fs.metadata`, a listing's own folder or a write's answer: the base members only, so the kind
    /// comes from the caller (`known`), else from whether the entry has a content version (only files do).
    public init(base: WsModel.FsEntryBase, known: FinderItemKind? = nil) {
        let kind = known ?? (base.contentVersion != nil ? .file : .directory)
        self.init(entryID: base.id, parentEntryID: base.parentID, name: base.name,
                  path: Self.normalize(base.path), kind: kind,
                  size: kind == .file ? base.sizeBytes : 0, createdAt: base.createdAt, updatedAt: base.updatedAt,
                  contentVersion: kind == .file ? base.contentVersion : nil, metadataVersion: base.metadataVersion,
                  isHidden: base.isHidden)
    }

    public var isRoot: Bool { parentEntryID == nil }

    public var version: FinderItemVersion {
        FinderItemVersion(contentVersion: contentVersion, metadataVersion: metadataVersion)
    }

    /// The item's identifier in a domain whose root entry is `rootEntryID`.
    public func identifier(root rootEntryID: Int64?) -> FinderItemID {
        entryID == rootEntryID || isRoot ? .root : .entry(entryID)
    }

    /// The parent's identifier: the root's parent is the root, as the File Provider wants it.
    public func parentIdentifier(root rootEntryID: Int64?) -> FinderItemID {
        guard let parentEntryID, entryID != rootEntryID else { return .root }
        return parentEntryID == rootEntryID ? .root : .entry(parentEntryID)
    }

    public var capabilities: FinderCapabilities { FinderCapabilities.of(kind, isRoot: isRoot) }

    public var created: Date? { Self.date(createdAt) }
    public var modified: Date? { Self.date(updatedAt) ?? created }

    static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Paths as the daemon spells them: absolute, no empty or dot components, no trailing slash.
    public static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." && $0 != ".." }
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    /// `name` inside the folder at `folder`.
    public static func join(_ folder: String, _ name: String) -> String {
        folder == "/" || folder.isEmpty ? "/" + name : folder + "/" + name
    }
}
