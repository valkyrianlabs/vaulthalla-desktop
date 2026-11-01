public import Foundation

/// The items a domain keeps downloaded, "Keep Downloaded" in Finder (valkyrianlabs/vaulthalla-desktop#35): their entry
/// ids, in `<domain>.pins.json` beside the replica database but apart from it, so a rebuilt cache keeps them. A pinned
/// item reports `downloadEagerlyAndKeepDownloaded`, and what is below a pinned folder inherits it. The app deletes the
/// file with the domain.
public struct PinStore: Sendable {
    /// nil: in memory only.
    public let url: URL?
    public private(set) var entries: Set<Int64>

    public init(url: URL?) {
        self.url = url
        entries = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([Int64].self, from: $0) }
            .map(Set.init) ?? []
    }

    /// The pins file of the replica database at `storeURL`.
    public static func url(forStore storeURL: URL) -> URL {
        storeURL.deletingPathExtension().appendingPathExtension("pins.json")
    }

    public static func deleteFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Pins or unpins `ids` and saves. Returns the ids whose state changed.
    @discardableResult
    public mutating func set(_ ids: some Sequence<Int64>, pinned: Bool) throws -> [Int64] {
        var changed: [Int64] = []
        for id in ids where entries.contains(id) != pinned {
            if pinned { entries.insert(id) } else { entries.remove(id) }
            changed.append(id)
        }
        guard !changed.isEmpty, let url else { return changed }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries.sorted()).write(to: url, options: .atomic)
        return changed
    }
}
