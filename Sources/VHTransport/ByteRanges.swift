import Foundation
import VHContract

/// Sorted, coalesced, half-open byte ranges: what a resumable upload's server holds durably for one file
/// (`ranges` in the session status and in each part's answer).
public struct ByteRanges: Hashable, Sendable, Codable {
    public private(set) var ranges: [Range<Int64>] = []

    public init() {}

    public init(_ ranges: some Sequence<Range<Int64>>) {
        for range in ranges { insert(range) }
    }

    /// From the wire's `[[start, end), …]`; malformed pairs are skipped.
    public init(wire: [[Int64]]?) {
        for pair in wire ?? [] where pair.count == 2 && pair[0] < pair[1] && pair[0] >= 0 {
            insert(pair[0]..<pair[1])
        }
    }

    /// Bytes covered.
    public var byteCount: Int64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    public var isEmpty: Bool { ranges.isEmpty }

    public mutating func insert(_ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var merged = range
        var kept: [Range<Int64>] = []
        kept.reserveCapacity(ranges.count + 1)
        for existing in ranges {
            if existing.upperBound < merged.lowerBound || existing.lowerBound > merged.upperBound {
                kept.append(existing)
            } else {
                merged = min(existing.lowerBound, merged.lowerBound)..<max(existing.upperBound, merged.upperBound)
            }
        }
        kept.append(merged)
        ranges = kept.sorted { $0.lowerBound < $1.lowerBound }
    }

    public mutating func formUnion(_ other: ByteRanges) {
        for range in other.ranges { insert(range) }
    }

    /// Whether every byte of `range` is covered.
    public func contains(_ range: Range<Int64>) -> Bool {
        range.isEmpty || ranges.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }

    /// Whether any byte of `range` is covered.
    public func overlaps(_ range: Range<Int64>) -> Bool {
        ranges.contains { $0.overlaps(range) }
    }

    /// The uncovered ranges of `0..<size`.
    public func gaps(upTo size: Int64) -> [Range<Int64>] {
        var gaps: [Range<Int64>] = []
        var cursor: Int64 = 0
        for range in ranges where range.lowerBound < size {
            if range.lowerBound > cursor { gaps.append(cursor..<range.lowerBound) }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < size { gaps.append(cursor..<size) }
        return gaps
    }

    /// `[[start, end), …]` for the wire and for persisted state.
    public var wire: [[Int64]] { ranges.map { [$0.lowerBound, $0.upperBound] } }

    public init(from decoder: any Decoder) throws {
        self.init(wire: try decoder.singleValueContainer().decode([[Int64]].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wire)
    }
}

/// The resumable routes' JSON (the server's docs/reference/transfer-protocol.md §3). Lenient: a member that is
/// missing or of another shape reads as nil, and callers decide what that means.
enum WireUpload {
    struct Parts: Decodable, Sendable, Hashable {
        var default_bytes: Int64?
        var min_bytes: Int64?
        var max_bytes: Int64?
        var max_in_flight: Int?
    }

    struct FileError: Decodable, Sendable, Hashable {
        var code: String?
        var message: String?
        var etag: String?
    }

    struct File: Decodable, Sendable {
        var file_id: String
        var path: String?
        var size: Int64?
        var state: String?
        var received_bytes: Int64?
        var ranges: [[Int64]]?
        var error: FileError?
        var entry: Entry?
    }

    /// A committed file's entry, as `PUT /upload/content` answers it (the bare entry, or `{entry: …}`).
    struct Entry: Decodable, Sendable {
        var value: WsModel.FsEntryBase?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            struct Wrapped: Decodable { var entry: WsModel.FsEntryBase? }
            value = (try? container.decode(WsModel.FsEntryBase.self)) ?? (try? container.decode(Wrapped.self))?.entry
        }
    }

    struct Session: Decodable, Sendable {
        var upload_id: String?
        var state: String?
        var expires_at: Int64?
        var part: Parts?
        var files: [File]?
    }

    struct Ack: Decodable, Sendable {
        var file_id: String?
        var offset: Int64?
        var length: Int64?
        var sha256: String?
        var received_bytes: Int64?
        var ranges: [[Int64]]?
        var state: String?
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
