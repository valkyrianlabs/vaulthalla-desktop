public import Foundation

/// A sync anchor (`NSFileProviderSyncAnchor`): which replica store, and how far into its change sequence the system
/// has seen. Until the server has a change journal (vaulthalla/server#259), the replica numbers its own changes: every
/// entry it records as new, changed or gone gets the next revision, so "everything after revision N" is exact.
///
/// Encoded as `vh1:a:<store id>:<revision>`, well under the File Provider's 500-byte limit. An anchor from another
/// store (the database was rebuilt) is refused, which the system answers by enumerating again.
public struct SyncAnchor: Hashable, Sendable, CustomStringConvertible {
    public let storeID: String
    public let revision: Int64

    public init(storeID: String, revision: Int64) {
        self.storeID = storeID
        self.revision = revision
    }

    static let prefix = "vh1:a:"
    public static let maxBytes = 500

    public var data: Data { Data("\(Self.prefix)\(storeID):\(revision)".utf8) }

    public init?(data: Data) {
        guard data.count <= Self.maxBytes, let text = String(data: data, encoding: .utf8), text.hasPrefix(Self.prefix)
        else { return nil }
        let body = text.dropFirst(Self.prefix.count)
        guard let colon = body.lastIndex(of: ":"), let revision = Int64(body[body.index(after: colon)...]),
              revision >= 0
        else { return nil }
        let store = String(body[..<colon])
        guard !store.isEmpty, !store.contains(":") else { return nil }
        self.init(storeID: store, revision: revision)
    }

    public var description: String { "\(storeID):\(revision)" }
}

/// An enumeration page (`NSFileProviderPage`): the offset into a container's children (by name) or the working
/// set's items (by entry id) where the next batch starts. `vh1:p:<offset>`; the system's own initial pages (and
/// anything else) mean the start.
public struct EnumerationPage: Hashable, Sendable {
    public let offset: Int

    public init(offset: Int) {
        self.offset = max(0, offset)
    }

    static let prefix = "vh1:p:"

    public static let first = EnumerationPage(offset: 0)

    public var data: Data { Data("\(Self.prefix)\(offset)".utf8) }

    /// The page `data` names; the first page for the system's initial pages or anything this replica didn't write.
    public init(data: Data) {
        guard data.count <= SyncAnchor.maxBytes, let text = String(data: data, encoding: .utf8),
              text.hasPrefix(Self.prefix), let offset = Int(text.dropFirst(Self.prefix.count)), offset >= 0
        else {
            self = .first
            return
        }
        self.init(offset: offset)
    }

    public var isFirst: Bool { offset == 0 }
}
