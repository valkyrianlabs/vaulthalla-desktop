import SwiftUI
import VHContract
import VHCore
import VHNodes

/// The web console's Health → Filesystem: FUSE operations with their errors split into expected and alertable, the
/// errnos behind them, how the error rates moved, and the filesystem and preview caches.
struct FilesystemHealthPage: View {
    var queries: NodeQueries
    var overview: WsModel.DashboardOverview?

    var body: some View {
        let fuse = queries.query(Ws.Stats.System.Fuse.self)
        let fsCache = queries.query(Ws.Stats.Fs.Cache.self)
        let httpCache = queries.query(Ws.Stats.Http.Cache.self)
        VStack(alignment: .leading, spacing: Theme.stackSpacing) {
            HealthDetailSection(anchor: .fuse, title: "FUSE filesystem", overview: overview, query: fuse,
                                subject: "FUSE statistics") { response in
                FuseBody(stats: response.stats, card: overview?.cards.first { $0.id == HealthAnchor.fuse.cardID },
                         queries: queries)
            }
            AdaptiveColumns(minColumnWidth: 520, spacing: Theme.stackSpacing) {
                HealthDetailSection(anchor: .fsCache, title: "FS cache", overview: overview, query: fsCache,
                                    subject: "cache statistics") { response in
                    CacheBody(stats: response.stats)
                }
                HealthDetailSection(anchor: .httpCache, title: "Preview cache", overview: overview, query: httpCache,
                                    subject: "cache statistics") { response in
                    CacheBody(stats: response.stats)
                }
            }
        }
        .observing(fuse, polling: HealthPolling.detail)
        .observing(fsCache, polling: HealthPolling.detail)
        .observing(httpCache, polling: HealthPolling.detail)
    }
}

// MARK: - FUSE

private struct FuseBody: View {
    var stats: WsModel.FuseStatsSnapshot
    var card: WsModel.DashboardCardSummary?
    var queries: NodeQueries

    @Environment(AppModel.self) private var model
    @State private var sort: DataSort? = DataSort(column: "calls", ascending: false)
    @State private var selection: String?
    @State private var showIdle = false

    /// The card's verdict on alertable errors: rows with alertable errors carry it while it's a warning or an error.
    private var alertTone: StatusTone? {
        switch card?.severity {
        case "warning": .warn
        case "error": .danger
        default: nil
        }
    }

    var body: some View {
        let focus = model.healthFocus(on: .fuse)
        let idle = stats.ops.filter { $0.count == 0 }.count
        let rows = showIdle ? stats.ops : stats.ops.filter { $0.count > 0 }
        VStack(alignment: .leading, spacing: 20) {
            StatGrid(minimum: 150, uniformHeight: true) {
                StatTile(label: "Operations", value: Format.count(stats.totalOps),
                         hint: "\(Format.count(stats.totalSuccesses)) succeeded")
                StatTile(label: "Alertable errors", value: Format.percent(stats.alertableErrorRate),
                         hint: "\(Format.count(stats.alertableErrors)) calls", tone: alertTone,
                         highlighted: focus?.metricKey?.hasPrefix("alertable") == true)
                StatTile(label: "Expected errors", value: Format.count(stats.expectedErrors),
                         hint: Format.percent(stats.expectedErrorRate) + " of calls")
                StatTile(label: "All errors", value: Format.percent(stats.errorRate),
                         hint: "\(Format.count(stats.totalErrors)) calls")
                StatTile(label: "Open handles", value: Format.count(stats.openHandlesCurrent),
                         hint: "peak \(Format.count(stats.openHandlesPeak))")
                StatTile(label: "Read", value: Format.bytes(stats.readBytes))
                StatTile(label: "Written", value: Format.bytes(stats.writeBytes))
            }

            if stats.alertableErrors > 0 {
                AlertableBreakdown(stats: stats, tone: alertTone)
            }

            AdaptiveColumns(weights: [2.3, 1], minColumnWidth: 300, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SubHeading("Operations since the daemon started")
                        if idle > 0 {
                            Toggle("Show \(idle) with no calls", isOn: $showIdle)
                                .toggleStyle(.checkbox)
                                .controlSize(.small)
                                .foregroundStyle(.fgSubtle)
                                .fixedSize()
                        }
                    }
                    DataTable(rows: rows, id: \.op, columns: Self.columns(alertTone), sort: $sort,
                              selection: $selection, tone: { op in op.alertableErrors > 0 ? alertTone : nil },
                              help: Self.describe, copyText: Self.describe,
                              empty: "No FUSE operations recorded yet.")
                    if let op = rows.first(where: { $0.op == selection }) {
                        OpDetail(op: op, tone: alertTone)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SubHeading("Errors by errno")
                    BarList(items: stats.topErrors.map(Self.errnoItem), empty: "No errors recorded.",
                            highlighted: focus?.metricKey?.hasPrefix("alertable") == true
                                ? Set(stats.topErrors.filter { $0.alertableCount > 0 }.map(Self.errnoID)) : [])
                    ErrnoLegend()
                }
            }

            FuseTrend(queries: queries)
        }
        .onChange(of: focus?.id, initial: true) { apply(focus) }
    }

    /// Following a warning: sort by what it's about and select the first row behind it.
    private func apply(_ focus: HealthFocus?) {
        guard let focus else { return }
        switch focus.metricKey {
        case "avg_latency": sort = DataSort(column: "avg", ascending: false)
        case "max_latency": sort = DataSort(column: "max", ascending: false)
        case "open_handles": break
        default:
            guard stats.alertableErrors > 0 || focus.metricKey?.hasPrefix("alertable") == true else { return }
            sort = DataSort(column: "alertable", ascending: false)
            selection = stats.ops.filter { $0.alertableErrors > 0 }.max { $0.alertableErrors < $1.alertableErrors }?.op
        }
    }

    private static func columns(_ tone: StatusTone?) -> [DataColumn<WsModel.FuseStatsSnapshot.Op>] {
        [
            DataColumn("op", "Operation", width: .flexible(min: 96, weight: 1.4),
                       sortKey: { .text($0.op) }) { op in
                Text(op.op).fontDesign(.monospaced).foregroundStyle(.fg)
            },
            DataColumn("calls", "Calls", width: .flexible(min: 72), alignment: .trailing,
                       sortKey: { .number(Double($0.count)) }) { op in
                Text(Format.count(op.count)).monospacedDigit().foregroundStyle(.fg)
            },
            DataColumn("errors", "Errors", width: .flexible(min: 64), alignment: .trailing,
                       help: "Every call that returned an error.", sortKey: { .number(Double($0.errors)) }) { op in
                Text(Format.count(op.errors)).monospacedDigit()
                    .foregroundStyle(op.errors == 0 ? Color.fgFaint : Color.fgMuted)
            },
            DataColumn("alertable", "Alertable", width: .flexible(min: 76), alignment: .trailing,
                       help: "Errors that count toward the alertable rate.",
                       sortKey: { .number(Double($0.alertableErrors)) }) { op in
                Text(Format.count(op.alertableErrors)).monospacedDigit().fontWeight(op.alertableErrors > 0 ? .semibold : .regular)
                    .foregroundStyle(op.alertableErrors == 0 ? Color.fgFaint : (tone?.color ?? .fg))
            },
            DataColumn("expected", "Expected", width: .flexible(min: 76), alignment: .trailing, hideBelow: 620,
                       help: "Errors that are the filesystem working as designed: a missing name, a denied caller.",
                       sortKey: { .number(Double($0.expectedErrors)) }) { op in
                Text(Format.count(op.expectedErrors)).monospacedDigit()
                    .foregroundStyle(op.expectedErrors == 0 ? Color.fgFaint : Color.fgMuted)
            },
            DataColumn("rate", "Alertable rate", width: .flexible(min: 96), alignment: .trailing, hideBelow: 760,
                       help: "Alertable errors per call.", sortKey: { .number($0.alertableErrorRate) }) { op in
                Text(op.count == 0 ? "—" : Format.percent(op.alertableErrorRate)).monospacedDigit()
                    .foregroundStyle(.fgMuted)
            },
            DataColumn("avg", "Avg", width: .flexible(min: 64), alignment: .trailing, hideBelow: 540,
                       sortKey: { .number($0.count == 0 ? nil : $0.avgMs) }) { op in
                Text(op.count == 0 ? "—" : Format.milliseconds(op.avgMs)).monospacedDigit().foregroundStyle(.fgMuted)
            },
            DataColumn("max", "Max", width: .flexible(min: 64), alignment: .trailing, hideBelow: 680,
                       sortKey: { .number($0.count == 0 ? nil : $0.maxMs) }) { op in
                Text(op.count == 0 ? "—" : Format.milliseconds(op.maxMs)).monospacedDigit().foregroundStyle(.fgMuted)
            },
            DataColumn("io", "Read / written", width: .flexible(min: 130), alignment: .trailing, hideBelow: 900,
                       sortKey: { .number(Double($0.bytesRead + $0.bytesWritten)) }) { op in
                Text(op.bytesRead + op.bytesWritten == 0 ? "—"
                     : "\(Format.bytes(op.bytesRead)) / \(Format.bytes(op.bytesWritten))")
                    .monospacedDigit().foregroundStyle(.fgMuted)
            },
        ]
    }

    static func describe(_ op: WsModel.FuseStatsSnapshot.Op) -> String {
        var lines = ["\(op.op): \(Format.count(op.count)) calls, \(Format.count(op.successes)) succeeded"]
        if op.errors > 0 {
            lines.append("\(Format.count(op.errors)) errors: \(Format.count(op.alertableErrors)) alertable "
                + "(\(Format.percent(op.alertableErrorRate))), \(Format.count(op.expectedErrors)) expected "
                + "(\(Format.percent(op.expectedErrorRate)))")
        }
        if op.count > 0 {
            lines.append("latency avg \(Format.milliseconds(op.avgMs)), max \(Format.milliseconds(op.maxMs))")
        }
        if op.bytesRead + op.bytesWritten > 0 {
            lines.append("read \(Format.bytes(op.bytesRead)), written \(Format.bytes(op.bytesWritten))")
        }
        return lines.joined(separator: "\n")
    }

    private static func errnoID(_ error: WsModel.FuseStatsSnapshot.TopError) -> String {
        "\(error.errnoValue)"
    }

    private static func errnoItem(_ error: WsModel.FuseStatsSnapshot.TopError) -> BarItem {
        let expected = max(error.count - error.alertableCount, 0)
        return BarItem(
            id: errnoID(error), label: error.name.isEmpty ? "unknown" : error.name, detail: "errno \(error.errnoValue)",
            value: Double(error.count), display: Format.count(error.count),
            emphasis: Double(error.alertableCount), emphasisTone: .warn,
            help: "\(error.name): \(Format.count(error.count)) — \(Format.count(error.alertableCount)) alertable, "
                + "\(Format.count(expected)) expected",
            monospaced: true)
    }
}

/// Which operations and errnos the alertable errors come from: the answer to "why is FUSE warning?".
private struct AlertableBreakdown: View {
    var stats: WsModel.FuseStatsSnapshot
    var tone: StatusTone?

    var body: some View {
        let ops = stats.ops.filter { $0.alertableErrors > 0 }.sorted { $0.alertableErrors > $1.alertableErrors }
        let errnos = stats.topErrors.filter { $0.alertableCount > 0 }.sorted { $0.alertableCount > $1.alertableCount }
        let shown = tone ?? .info
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("\(Format.count(stats.alertableErrors)) alertable errors in \(Format.count(stats.totalOps)) calls "
                     + "(\(Format.percent(stats.alertableErrorRate))). They come from:")
                    .foregroundStyle(.fg)
            } icon: {
                Image(systemName: tone == nil ? "info.circle" : "exclamationmark.triangle")
                    .foregroundStyle(shown.color)
            }
            .font(.callout.weight(.medium))
            AdaptiveColumns(minColumnWidth: 260, spacing: 24) {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    Text("Operations").font(.caption).foregroundStyle(.fgSubtle).frame(height: 24)
                    ForEach(ops, id: \.op) { op in
                        Chip(text: op.op, value: Format.count(op.alertableErrors),
                             share: Double(op.alertableErrors) / Double(max(stats.alertableErrors, 1)), tone: shown)
                            .help(FuseBody.describe(op))
                    }
                }
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    Text("Errnos").font(.caption).foregroundStyle(.fgSubtle).frame(height: 24)
                    ForEach(errnos, id: \.errnoValue) { error in
                        Chip(text: error.name, value: Format.count(error.alertableCount),
                             share: Double(error.alertableCount) / Double(max(stats.alertableErrors, 1)), tone: shown)
                            .help("errno \(error.errnoValue): \(Format.count(error.alertableCount)) alertable of "
                                  + "\(Format.count(error.count))")
                    }
                    if stats.alertableErrnoTypes > Int64(errnos.count) {
                        Text("and \(stats.alertableErrnoTypes - Int64(errnos.count)) more errnos")
                            .font(.caption).foregroundStyle(.fgSubtle)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shown.soft, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(shown.line, lineWidth: 1)
        }
    }

    private struct Chip: View {
        var text: String
        var value: String
        var share: Double
        var tone: StatusTone

        var body: some View {
            HStack(spacing: 6) {
                Text(text).fontDesign(.monospaced).foregroundStyle(.fg)
                Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(tone.color)
                Text(Format.percent(share, digits: 0)).monospacedDigit().foregroundStyle(.fgSubtle)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(.surface2, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.line, lineWidth: 1) }
        }
    }
}

/// The selected operation in full, under the table.
private struct OpDetail: View {
    var op: WsModel.FuseStatsSnapshot.Op
    var tone: StatusTone?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(op.op).fontDesign(.monospaced).fontWeight(.semibold).foregroundStyle(.fg)
            fact("calls", Format.count(op.count))
            fact("succeeded", Format.count(op.successes))
            fact("alertable", "\(Format.count(op.alertableErrors)) · \(Format.percent(op.alertableErrorRate))",
                 tone: op.alertableErrors > 0 ? tone : nil)
            fact("expected", "\(Format.count(op.expectedErrors)) · \(Format.percent(op.expectedErrorRate))")
            if op.count > 0 {
                fact("avg", Format.milliseconds(op.avgMs))
                fact("max", Format.milliseconds(op.maxMs))
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
        .textSelection(.enabled)
    }

    private func fact(_ label: String, _ value: String, tone: StatusTone? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.fgSubtle)
            Text(value).monospacedDigit().foregroundStyle(tone?.color ?? .fg)
        }
        .fixedSize()
    }
}

private struct ErrnoLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                swatch(StatusTone.warn.color, "alertable")
                swatch(Color.accentFill.opacity(0.4), "expected")
            }
            Text("Expected errors don't count toward the alertable rate: a lookup of a name that doesn't exist, or a "
                 + "caller the permission model refused (a uid with no Vaulthalla user, or a role that doesn't allow it).")
                .foregroundStyle(.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(.top, 4)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 6)
            Text(label).foregroundStyle(.fgMuted)
        }
    }
}

/// FUSE error rates over the last day, from the stats snapshots: whether what the counters show is still happening.
private struct FuseTrend: View {
    var queries: NodeQueries

    var body: some View {
        let trends = queries.query(Ws.Stats.System.Trends.self, .init(windowHours: 24))
        VStack(alignment: .leading, spacing: 8) {
            SubHeading("Error rates, last 24 hours")
            if let stats = trends.value?.stats {
                let series = TrendSeries.pick(["fuse_error_rate", "fuse_expected_error_rate"], from: stats)
                if series.isEmpty {
                    Text("No snapshots in this window yet.").font(.callout).foregroundStyle(.fgSubtle)
                } else {
                    TrendChart(series: series, height: 140)
                }
            } else if let error = trends.error {
                InlineProblem(error: error, subject: "trends")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .observing(trends, polling: HealthPolling.trends)
    }
}

// MARK: - Caches

/// A cache's hit rate, usage and churn. A cache without a byte cap (the FS metadata cache) reads "no size cap", never
/// 0 % of 0 B.
struct CacheBody: View {
    var stats: WsModel.CacheStatsSnapshot

    var body: some View {
        let requests = stats.hits + stats.misses
        AdaptiveColumns(weights: [1, 1.8], minColumnWidth: 230, spacing: 20) {
            DonutChart(
                parts: [
                    .init(label: "Hits", value: Double(stats.hits), color: .accentFill),
                    .init(label: "Misses", value: Double(stats.misses), color: StatusTone.unknown.color.opacity(0.6)),
                ],
                center: requests > 0 ? Format.percent(Double(stats.hits) / Double(requests), digits: 1) : "—",
                caption: requests > 0 ? "hit rate" : "no requests yet",
                label: "Cache hits and misses")
            StatGrid(minimum: 130, uniformHeight: true) {
                StatTile(label: "Used", value: Format.bytes(stats.usedBytes),
                         hint: stats.capacityBytes.map { $0 > 0 ? "of \(Format.bytes($0))" : "no size cap" } ?? "no size cap")
                StatTile(label: "Inserts", value: Format.count(stats.inserts))
                StatTile(label: "Evictions", value: Format.count(stats.evictions))
                StatTile(label: "Invalidations", value: Format.count(stats.invalidations))
                StatTile(label: "Read / written",
                         value: "\(Format.bytes(stats.bytesRead)) / \(Format.bytes(stats.bytesWritten))")
                StatTile(label: "Work ops", value: Format.count(stats.op.count),
                         hint: stats.op.count > 0
                            ? "avg \(Format.milliseconds(stats.op.avgMs)) · max \(Format.milliseconds(stats.op.maxMs))" : nil)
            }
        }
    }
}
