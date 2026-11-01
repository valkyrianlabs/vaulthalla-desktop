import Charts
import SwiftUI
import VHContract
import VHCore
import VHNodes

/// The web console's Health → Activity: the operation queue with recent failures, then trends from the stats
/// snapshots, charted by unit with a value readout under the pointer.
struct ActivityHealthPage: View {
    var queries: NodeQueries
    var overview: WsModel.DashboardOverview?

    @State private var windowHours: Int64 = 168

    var body: some View {
        let operations = queries.query(Ws.Stats.System.Operations.self)
        let trends = queries.query(Ws.Stats.System.Trends.self, .init(windowHours: windowHours))
        VStack(alignment: .leading, spacing: Theme.stackSpacing) {
            HealthDetailSection(anchor: .operationQueue, title: "Operation queue", overview: overview,
                                query: operations, subject: "operations") { response in
                if let stats = response.stats {
                    OperationsBody(stats: stats)
                } else {
                    Text("The daemon has no operation statistics yet.").font(.callout).foregroundStyle(.fgSubtle)
                }
            }
            HealthDetailSection(anchor: .trends, title: "Trends", overview: overview, query: trends,
                                subject: "trends") {
                Picker("Window", selection: $windowHours) {
                    Text("24 h").tag(Int64(24))
                    Text("7 days").tag(Int64(168))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            } content: { response in
                TrendsBody(stats: response.stats)
            }
        }
        .observing(operations, polling: HealthPolling.detail)
        .observing(trends, polling: HealthPolling.trends)
    }
}

// MARK: - Operations

private struct OperationsBody: View {
    var stats: WsModel.OperationStats

    @Environment(AppModel.self) private var model
    @State private var sort: DataSort? = DataSort(column: "when", ascending: false)
    @State private var selection: Int?

    var body: some View {
        let focus = model.healthFocus(on: .operationQueue)
        let tone = StatusTone(severity: stats.overallStatus)
        VStack(alignment: .leading, spacing: 20) {
            StatGrid(minimum: 150, uniformHeight: true) {
                StatTile(label: "Queued", value: Format.count(stats.pendingOperations),
                         hint: stats.oldestPendingOperationAgeSeconds.map { "oldest \(Format.duration(seconds: $0))" })
                StatTile(label: "In progress", value: Format.count(stats.inProgressOperations),
                         hint: stats.oldestInProgressOperationAgeSeconds.map { "oldest \(Format.duration(seconds: $0))" })
                StatTile(label: "Stalled", value: Format.count(stats.stalledOperations),
                         hint: "no progress for \(Format.duration(seconds: stats.staleThresholdSeconds))",
                         tone: stats.stalledOperations > 0 && (tone == .warn || tone == .danger) ? tone : nil,
                         highlighted: focus?.metricKey == "stalled" || focus?.code == "system.operations.stalled")
                StatTile(label: "Failed (24 h)", value: Format.count(stats.failedOperations24h),
                         tone: stats.failedOperations24h > 0 && (tone == .warn || tone == .danger) ? tone : nil,
                         highlighted: focus?.code == "system.operations.failed_recent")
                StatTile(label: "Cancelled (24 h)", value: Format.count(stats.cancelledOperations24h))
                StatTile(label: "Share uploads", value: Format.count(stats.activeShareUploads),
                         hint: "\(Format.count(stats.stalledShareUploads)) stalled · "
                            + "\(Format.count(stats.failedShareUploads24h)) failed (24 h)")
            }

            AdaptiveColumns(minColumnWidth: 220, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    SubHeading("By status")
                    BarList(items: Self.bars(stats.operationsByStatus), empty: "No operations recorded.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    SubHeading("By type")
                    BarList(items: Self.bars(stats.operationsByType), empty: "No operations recorded.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    SubHeading("Active share uploads")
                    if stats.uploadBytesExpectedActive > 0 {
                        ProgressView(value: Double(stats.uploadBytesReceivedActive),
                                     total: Double(stats.uploadBytesExpectedActive))
                            .tint(.accentFill)
                        Text("\(Format.bytes(stats.uploadBytesReceivedActive)) of "
                             + "\(Format.bytes(stats.uploadBytesExpectedActive))"
                             + (stats.oldestActiveUploadAgeSeconds.map { " · oldest \(Format.duration(seconds: $0))" } ?? ""))
                            .font(.callout).monospacedDigit().foregroundStyle(.fgMuted)
                    } else {
                        Text(stats.activeShareUploads == 0 ? "No share uploads in flight." : "Upload progress isn't reported.")
                            .font(.callout).foregroundStyle(.fgSubtle)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SubHeading("Recent failures")
                let rows = Array(stats.recentOperationErrors.enumerated()).map { FailureRow(index: $0, error: $1) }
                DataTable(rows: rows, id: \.index, columns: Self.columns, sort: $sort, selection: $selection,
                          tone: { StatusTone(severity: $0.error.status) == .danger ? .danger : nil },
                          help: \.description, copyText: \.description,
                          empty: "No failed or cancelled operations recently.")
            }
        }
    }

    private static func bars(_ counts: [String: Int64]) -> [BarItem] {
        counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { key, value in
            BarItem(id: key, label: Format.words(key), value: Double(value), display: Format.count(value))
        }
    }

    @MainActor private static let columns: [DataColumn<FailureRow>] = [
        DataColumn("when", "When", width: .flexible(min: 90, weight: 0.8),
                   sortKey: { .number($0.error.occurredAt.map(Double.init)) }) { row in
            Text(row.error.occurredAt.map { Format.relative(epoch: $0) } ?? "—")
                .monospacedDigit().foregroundStyle(.fgSubtle)
        },
        DataColumn("op", "Operation", width: .flexible(min: 90, weight: 0.8), sortKey: { .text($0.error.operation) }) { row in
            Text(Format.words(row.error.operation)).foregroundStyle(.fg)
        },
        DataColumn("status", "Status", width: .flexible(min: 90, weight: 0.7), sortKey: { .text($0.error.status) }) { row in
            HStack(spacing: 6) {
                StatusDot(tone: StatusTone(severity: row.error.status), size: 6)
                Text(Format.words(row.error.status)).foregroundStyle(.fgMuted)
            }
        },
        DataColumn("path", "Path", width: .flexible(min: 160, weight: 1.6), hideBelow: 620,
                   sortKey: { .text($0.error.path.isEmpty ? $0.error.target : $0.error.path) }) { row in
            // AnyView: `truncationMode`'s opaque result can't cross into the column's main-actor cell otherwise.
            AnyView(Text(row.error.path.isEmpty ? (row.error.target.isEmpty ? "—" : row.error.target) : row.error.path)
                .fontDesign(.monospaced).font(.caption).truncationMode(.middle).foregroundStyle(.fgMuted))
        },
        DataColumn("error", "Error", width: .flexible(min: 140, weight: 1.6), hideBelow: 480) { row in
            Text(row.error.error ?? "—").foregroundStyle(.fgMuted)
        },
    ]
}

private struct FailureRow {
    var index: Int
    var error: WsModel.OperationStats.RecentOperationError

    var description: String {
        var parts = ["\(Format.words(error.operation)) \(error.status)"]
        if let at = error.occurredAt {
            parts.append(Date(timeIntervalSince1970: TimeInterval(at)).formatted(date: .abbreviated, time: .standard))
        }
        if !error.path.isEmpty { parts.append(error.path) } else if !error.target.isEmpty { parts.append(error.target) }
        if let message = error.error { parts.append(message) }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Trends

/// One trend line, ready to chart.
struct TrendSeries: Identifiable, Hashable {
    struct Point: Hashable {
        var date: Date
        var value: Double
    }

    var key: String
    var label: String
    var unit: String
    var points: [Point]
    var id: String { key }

    init(_ serie: WsModel.StatsTrends.Serie) {
        key = serie.key
        label = serie.label
        unit = serie.unit
        points = serie.points
            .filter(\.value.isFinite)
            .map { Point(date: Date(timeIntervalSince1970: TimeInterval($0.createdAt)), value: $0.value) }
    }

    /// The series named by `keys` that share the first one's unit, in that order.
    static func pick(_ keys: [String], from stats: WsModel.StatsTrends) -> [TrendSeries] {
        let found = keys.compactMap { key in stats.series.first { $0.key == key }.map(TrendSeries.init) }
        guard let unit = found.first?.unit else { return [] }
        return found.filter { $0.unit == unit && !$0.points.isEmpty }
    }

    /// A value in the series' unit: "2.1%", "1.2 MB", "0.4 ms", "18 ops/s".
    static func format(_ value: Double, unit: String) -> String {
        switch unit {
        case "ratio": Format.percent(value)
        case "bytes": Format.bytes(Int64(value.rounded()))
        case "bytes/s", "bytes_per_second": Format.bytes(Int64(value.rounded())) + "/s"
        case "ms": Format.milliseconds(value)
        case "seconds", "s": Format.duration(seconds: Int64(value.rounded()))
        case "count", "": value.formatted(.number.precision(.fractionLength(0...1)))
        default: value.formatted(.number.precision(.fractionLength(0...2))) + " " + unit
        }
    }
}

/// Lines over time with axes and a pointer readout: hover the chart to read every series at that moment.
struct TrendChart: View {
    var series: [TrendSeries]
    var height: CGFloat = 150

    @State private var selected: Date?

    private static let palette: [Color] = [.accentFill, StatusTone.warn.color, StatusTone.ok.color, StatusTone.info.color,
                                           StatusTone.danger.color]

    var body: some View {
        let unit = series.first?.unit ?? ""
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ForEach(Array(series.enumerated()), id: \.element.key) { index, serie in
                    HStack(spacing: 5) {
                        Capsule().fill(color(index)).frame(width: 12, height: 3)
                        Text(serie.label).lineLimit(1)
                        if let value = value(of: serie, at: selected) ?? serie.points.last?.value {
                            Text(TrendSeries.format(value, unit: unit))
                                .monospacedDigit()
                                .foregroundStyle(.fg)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let selected {
                    Text(selected.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.fgSubtle)

            Chart {
                ForEach(Array(series.enumerated()), id: \.element.key) { index, serie in
                    ForEach(serie.points, id: \.date) { point in
                        LineMark(x: .value("Time", point.date), y: .value(serie.label, point.value),
                                 series: .value("Series", serie.key))
                            .foregroundStyle(color(index))
                            .lineStyle(StrokeStyle(lineWidth: 1.6))
                            .interpolationMethod(.monotone)
                    }
                }
                if let selected {
                    RuleMark(x: .value("Selected", selected))
                        .foregroundStyle(Color.lineStrong)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXSelection(value: $selected)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.line)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(TrendSeries.format(number, unit: unit)).foregroundStyle(Color.fgSubtle)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(Color.line.opacity(0.5))
                    AxisValueLabel().foregroundStyle(Color.fgSubtle)
                }
            }
            .frame(height: height)
            .accessibilityLabel(series.map(\.label).joined(separator: ", "))
        }
    }

    private func color(_ index: Int) -> Color {
        Self.palette[index % Self.palette.count]
    }

    /// The series' value nearest to `date`.
    private func value(of serie: TrendSeries, at date: Date?) -> Double? {
        guard let date else { return nil }
        return serie.points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.value
    }
}

/// Curated charts, each grouping series that share a unit (the web console's list); any other series is one pick away.
private struct TrendsBody: View {
    var stats: WsModel.StatsTrends?

    @State private var extra: String?

    private static let charts: [(title: String, keys: [String])] = [
        ("Operation queue", ["operations_pending", "operations_in_progress", "operations_stalled"]),
        ("Failed operations (24 h)", ["operations_failed_24h"]),
        ("Thread pool pressure", ["threadpool_pressure"]),
        ("Thread pool queue depth", ["threadpool_queue_depth"]),
        ("FUSE operations", ["fuse_ops_per_second"]),
        ("FUSE error rate", ["fuse_error_rate", "fuse_expected_error_rate", "fuse_raw_error_rate"]),
        ("FUSE latency", ["fuse_latency_avg_ms"]),
        ("FUSE throughput", ["fuse_read_bytes_per_second", "fuse_write_bytes_per_second"]),
        ("Cache hit rate", ["fs_cache_hit_rate", "db_cache_hit_ratio"]),
        ("Cache usage", ["fs_cache_used_bytes", "http_cache_used_bytes"]),
        ("Database size", ["db_size_bytes"]),
        ("Database connections", ["db_connections_total", "db_connections_active"]),
        ("Sessions", ["connections_active_ws", "connections_human", "connections_unauthenticated"]),
        ("Cleanup backlog", ["retention_trash_overdue_count", "retention_sync_backlog", "retention_audit_backlog"]),
    ]

    var body: some View {
        if let stats, !stats.series.isEmpty {
            let charts = Self.charts.map { ($0.title, TrendSeries.pick($0.keys, from: stats)) }.filter { !$1.isEmpty }
            VStack(alignment: .leading, spacing: 14) {
                FillingGrid(minimum: 380, spacing: 12) {
                    ForEach(charts, id: \.0) { title, series in
                        ChartCard(title: title, series: series)
                    }
                }
                HStack(spacing: 12) {
                    Picker("Any series", selection: $extra) {
                        Text("Choose a series…").tag(String?.none)
                        ForEach(stats.series.sorted { $0.label < $1.label }, id: \.key) { serie in
                            Text(serie.label).tag(Optional(serie.key))
                        }
                    }
                    .frame(maxWidth: 360)
                    Text("\(stats.series.count) series recorded in this window")
                        .font(.caption).monospacedDigit().foregroundStyle(.fgSubtle)
                }
                if let extra, let serie = stats.series.first(where: { $0.key == extra }) {
                    ChartCard(title: serie.label, series: [TrendSeries(serie)])
                }
            }
        } else {
            Text("No snapshots in this window yet. The daemon records one every few minutes while stats snapshots are on.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private struct ChartCard: View {
        var title: String
        var series: [TrendSeries]

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.fg)
                TrendChart(series: series, height: 140)
            }
            .padding(14)
            .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(.line, lineWidth: 1)
            }
        }
    }
}
