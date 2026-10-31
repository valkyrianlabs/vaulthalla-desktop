public import Foundation
public import VHCore
import Synchronization

extension TransferStats {
    /// The status view's reading of a node's tuning snapshot.
    public init(_ snapshot: TransferTuningSnapshot, at date: Date = .now) {
        self.init(throughputUp: snapshot.uploadBytesPerSecond, throughputDown: snapshot.downloadBytesPerSecond,
                  partBytes: snapshot.partBytes, partsInFlight: snapshot.partsInFlight,
                  tuning: snapshot.tuningEnabled, concurrency: snapshot.concurrency,
                  serverBound: snapshot.serverBound, source: EstimateSource(rawValue: snapshot.source.rawValue),
                  updatedAt: date)
    }
}

extension TransferTuningSnapshot {
    /// Parts in flight, or bytes moved within the rate meters' window (a few seconds).
    public var isActive: Bool { partsInFlight > 0 || uploadBytesPerSecond > 0 || downloadBytesPerSecond > 0 }
}

/// Reports one node's ``TransferMonitor`` to a ``TransferStatsBoard`` for the connection status view: each snapshot
/// while transfers move (``TransferMonitor/updates()``, at most ~4 a second), then nil once they are idle. The monitor
/// publishes only when something happens, so while active the feed also re-reads it every `settle` until the rate
/// meters have drained. Runs until ``stop()`` (or deinit), which clears the node's stats.
public final class TransferStatsFeed: Sendable {
    public let node: NodeID
    private let board: TransferStatsBoard
    private let task: Task<Void, Never>

    public init(monitor: TransferMonitor, node: NodeID, board: TransferStatsBoard, settle: Duration = .seconds(1)) {
        self.node = node
        self.board = board
        let state = Mutex<(active: Bool, reportedIdle: Bool)>((false, false))
        let updates = monitor.updates()
        @Sendable func report(_ snapshot: TransferTuningSnapshot) {
            let active = snapshot.isActive
            let send = state.withLock { state -> Bool in
                state.active = active
                if active {
                    state.reportedIdle = false
                    return true
                }
                defer { state.reportedIdle = true }
                return !state.reportedIdle
            }
            guard send else { return }
            board.report(active ? TransferStats(snapshot) : nil, for: node)
        }
        task = Task {
            await withDiscardingTaskGroup { group in
                group.addTask {
                    for await snapshot in updates { report(snapshot) }
                }
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: settle)
                        if state.withLock({ $0.active }) { report(monitor.snapshot) }
                    }
                }
            }
        }
    }

    deinit {
        task.cancel()
    }

    /// Stops reporting and clears the node's stats.
    public func stop() {
        task.cancel()
        board.report(nil, for: node)
    }
}
