public import Foundation
import Synchronization

/// The node registry on disk: `nodes.json` in Application Support, a versioned envelope `{"version": 1, "nodes": []}`.
///
/// Calls are synchronous and serialized by a mutex rather than an actor: the file is a few kilobytes, and the shell
/// needs the result of an edit (say, the node it just added) in the same turn it selects it. Every mutation writes the
/// whole file atomically, so a crash leaves either the old or the new list, never a torn one. An unreadable file is
/// reported and never overwritten: mutations throw until it is fixed or removed.
public final class NodeStore: Sendable {
    public static let currentVersion = 1

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The file exists but isn't a node list this version understands (corrupt, or written by something else).
        case unreadable(String)
        /// Written by a newer Desktop. Left untouched so a downgrade can't destroy it.
        case unsupportedVersion(Int)
        case notFound(NodeID)
        case duplicate(NodeID)

        public var description: String {
            switch self {
            case .unreadable(let reason): "The saved node list can't be read: \(reason)"
            case .unsupportedVersion(let version): "The saved node list is format \(version), newer than this app supports."
            case .notFound(let id): "No node \(id)."
            case .duplicate(let id): "Node \(id) already exists."
            }
        }
    }

    public let fileURL: URL
    private let cache = Mutex<[Node]?>(nil)

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Vaulthalla/nodes.json`.
    public static func defaultFileURL() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Vaulthalla", directoryHint: .isDirectory)
            .appending(path: "nodes.json", directoryHint: .notDirectory)
    }

    /// The saved nodes in the operator's order. A missing file is an empty registry.
    public func load() throws -> [Node] {
        try cache.withLock { cached in
            if let cached { return cached }
            let nodes = try readFile()
            cached = nodes
            return nodes
        }
    }

    /// Re-reads the file, dropping what was cached.
    @discardableResult
    public func reload() throws -> [Node] {
        cache.withLock { $0 = nil }
        return try load()
    }

    @discardableResult
    public func add(_ node: Node) throws -> [Node] {
        try mutate { nodes in
            guard !nodes.contains(where: { $0.id == node.id }) else { throw Failure.duplicate(node.id) }
            nodes.append(node)
        }
    }

    /// Replaces the node with the same id, keeping its position.
    @discardableResult
    public func update(_ node: Node) throws -> [Node] {
        try mutate { nodes in
            guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { throw Failure.notFound(node.id) }
            nodes[index] = node
        }
    }

    @discardableResult
    public func remove(_ id: NodeID) throws -> [Node] {
        try mutate { nodes in
            guard let index = nodes.firstIndex(where: { $0.id == id }) else { throw Failure.notFound(id) }
            nodes.remove(at: index)
        }
    }

    /// Puts the nodes in the order of `ids`. Ids that aren't saved are ignored; saved nodes missing from `ids` keep
    /// their relative order after the listed ones, so a stale ordering never drops a node.
    @discardableResult
    public func reorder(_ ids: [NodeID]) throws -> [Node] {
        try mutate { nodes in
            var remaining = nodes
            var ordered: [Node] = []
            ordered.reserveCapacity(nodes.count)
            for id in ids {
                if let index = remaining.firstIndex(where: { $0.id == id }) {
                    ordered.append(remaining.remove(at: index))
                }
            }
            nodes = ordered + remaining
        }
    }

    /// Moves one node to `index` in the final list (clamped to the valid range).
    @discardableResult
    public func move(_ id: NodeID, to index: Int) throws -> [Node] {
        try mutate { nodes in
            guard let from = nodes.firstIndex(where: { $0.id == id }) else { throw Failure.notFound(id) }
            let node = nodes.remove(at: from)
            nodes.insert(node, at: min(max(index, 0), nodes.count))
        }
    }

    // MARK: - File

    private struct Envelope: Codable {
        var version: Int
        var nodes: [Node]
    }

    /// Only the version, so a newer file is recognized even when its nodes don't decode.
    private struct VersionProbe: Decodable {
        var version: Int
    }

    private func mutate(_ change: (inout [Node]) throws -> Void) throws -> [Node] {
        try cache.withLock { cached in
            var nodes = try cached ?? readFile()
            try change(&nodes)
            try writeFile(nodes)
            cached = nodes
            return nodes
        }
    }

    private func readFile() throws -> [Node] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).version
        } catch {
            throw Failure.unreadable("not a versioned node list")
        }
        guard version == Self.currentVersion else { throw Failure.unsupportedVersion(version) }
        do {
            return try decoder.decode(Envelope.self, from: data).nodes
        } catch {
            throw Failure.unreadable(String(describing: error))
        }
    }

    private func writeFile(_ nodes: [Node]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Envelope(version: Self.currentVersion, nodes: nodes))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
