import Foundation
import Synchronization
import Testing
import VHCore
@testable import VHTransport

/// ``TransferStatsFeed``: a node's monitor as the connection view's ``TransferStats``, nil once idle.
@Suite struct TransferStatsFeedTests {
    @Test func reportsWhileTransfersMoveAndNilOnceIdle() async throws {
        let now = Mutex<Double>(100)
        let monitor = TransferMonitor(node: "n1", clock: { now.withLock { $0 } })
        let board = TransferStatsBoard()
        let node = NodeID(rawValue: "n1")
        var reports = board.updates().makeAsyncIterator()
        let feed = TransferStatsFeed(monitor: monitor, node: node, board: board, settle: .milliseconds(10))

        // Idle at first: the view shows nothing reported.
        let first = try #require(await reports.next())
        #expect(first.0 == node && first.1 == nil)

        // A part starts: the snapshot as stats, with the tuner's numbers.
        _ = monitor.partStarted(bytes: 1 << 20)
        let started = try #require(await reports.next()?.1)
        #expect(started.partsInFlight == 1 && started.partBytes == 64 << 20 && started.concurrency == 2)
        #expect(started.tuning == true && started.serverBound == false && started.source == .defaults)

        // It ends having moved bytes: still active while the rate meter holds them.
        monitor.uploaded(1 << 20)
        monitor.partEnded(bytes: 1 << 20)
        var last: TransferStats?? = nil
        while let next = await reports.next() {
            last = next.1
            if let stats = next.1, stats.partsInFlight == 0 { break }
        }
        #expect((last ?? nil)?.throughputUp ?? 0 > 0)

        // Nothing moves for longer than the meter's window: the feed's own re-read reports idle (nil).
        now.withLock { $0 += 10 }
        var cleared = false
        while let next = await reports.next() {
            if next.1 == nil { cleared = true; break }
        }
        #expect(cleared)
        #expect(board.stats(for: node) == nil)

        // Stopping clears the node too.
        board.report(TransferStats(throughputUp: 1), for: node)
        feed.stop()
        #expect(board.stats(for: node) == nil)
    }

    @Test func mapsEveryEstimateSource() {
        for source in [TransferTuner.Estimate.Source.defaults, .cached, .calibrated, .measured] {
            var snapshot = TransferTuningSnapshot.idle
            snapshot.source = source
            #expect(TransferStats(snapshot).source?.rawValue == source.rawValue)
        }
    }
}
