public import Foundation
import Synchronization

/// What a node's transfers are doing now, for the connection status view: throughput both ways, the part size and
/// concurrency in use, and whether adaptive tuning is on. Every member is optional: nil means nothing reported it
/// (the view shows "—"), never zero.
///
/// The resumable-upload and tuning work (VHTransport's lanes and the app's transfer center) reports it through a
/// ``TransferStatsBoard``; nothing here is secret.
public struct TransferStats: Hashable, Sendable {
    /// Where the estimate the tuner works from came from.
    public enum EstimateSource: String, Hashable, Sendable {
        /// Nothing measured yet: the starting part size and concurrency.
        case defaults
        /// The last transfer to the node over this class of route (kept 24 h).
        case cached
        /// A calibration (`/transfer/*`) before a large upload, or Test Connection.
        case calibrated
        /// The parts of this transfer.
        case measured
    }

    /// Bytes per second, recent upload rate.
    public var throughputUp: Double?
    /// Bytes per second, recent download rate.
    public var throughputDown: Double?
    /// The upload part size in use (bytes).
    public var partBytes: Int64?
    /// Parts in flight at once.
    public var partsInFlight: Int?
    /// Whether the part size and concurrency adapt to the measured link.
    public var tuning: Bool?
    /// Parts the tuner allows in flight now.
    public var concurrency: Int?
    /// The server's write path, not the network, bounds uploads (its `Server-Timing`).
    public var serverBound: Bool?
    public var source: EstimateSource?
    public var updatedAt: Date

    public init(throughputUp: Double? = nil, throughputDown: Double? = nil, partBytes: Int64? = nil,
                partsInFlight: Int? = nil, tuning: Bool? = nil, concurrency: Int? = nil, serverBound: Bool? = nil,
                source: EstimateSource? = nil, updatedAt: Date = .now) {
        self.throughputUp = throughputUp
        self.throughputDown = throughputDown
        self.partBytes = partBytes
        self.partsInFlight = partsInFlight
        self.tuning = tuning
        self.concurrency = concurrency
        self.serverBound = serverBound
        self.source = source
        self.updatedAt = updatedAt
    }
}

/// Where transfer code reports ``TransferStats`` per node and the status view reads them: the latest report per node,
/// and a stream of changes. Thread-safe; one per process is enough (``shared``), tests make their own.
public final class TransferStatsBoard: Sendable {
    public static let shared = TransferStatsBoard()

    private struct State {
        var stats: [NodeID: TransferStats] = [:]
        var observers: [UUID: AsyncStream<(NodeID, TransferStats?)>.Continuation] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Records the node's current stats; nil clears them (transfers ended, or the node went away).
    public func report(_ stats: TransferStats?, for node: NodeID) {
        let observers = state.withLock { state in
            state.stats[node] = stats
            return Array(state.observers.values)
        }
        for observer in observers { observer.yield((node, stats)) }
    }

    /// The node's latest stats; nil when nothing reported any.
    public func stats(for node: NodeID) -> TransferStats? {
        state.withLock { $0.stats[node] }
    }

    /// Every later report, as (node, stats). Each call returns an independent stream.
    public func updates() -> AsyncStream<(NodeID, TransferStats?)> {
        let (stream, continuation) = AsyncStream.makeStream(of: (NodeID, TransferStats?).self,
                                                            bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        state.withLock { $0.observers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.observers.removeValue(forKey: id) }
        }
        return stream
    }
}
