import Charts
import SwiftUI
import VHContract
import VHCore
import VHNodes

/// The node's health: the summary `stats.dashboard.overview` reports (the web console's Health overview), or one of
/// its drill-down pages. Following a warning scrolls to the panel behind it. Every value and severity is the daemon's;
/// missing values read "not available", unknown is never green.
struct HealthPages: View {
    var node: Node
    var queries: NodeQueries
    var page: HealthPage

    @Environment(AppModel.self) private var model

    var body: some View {
        let overview = queries.query(Ws.Stats.Dashboard.Overview.self, .init())
        ScrollViewReader { proxy in
            Group {
                if let problem = overview.error.map(QueryProblem.init), case .denied = problem {
                    // Every health read needs the same permission: one calm state, not a page of refusals.
                    ProblemPanel(problem: problem, node: node, subject: "health") {}
                } else {
                    switch page {
                    case .summary:
                        QueryContent(query: overview, node: node, subject: "health") { response in
                            HealthDashboard(overview: response.stats, query: overview)
                        }
                    case .runtime: RuntimeHealthPage(queries: queries, overview: overview.value?.stats)
                    case .filesystem: FilesystemHealthPage(queries: queries, overview: overview.value?.stats)
                    case .storage: StorageHealthPage(queries: queries, overview: overview.value?.stats)
                    case .activity: ActivityHealthPage(queries: queries, overview: overview.value?.stats)
                    }
                }
            }
            .task(id: model.healthTarget?.id) {
                guard let focus = model.healthTarget, focus.page == page, let anchor = focus.anchor else { return }
                // Let the page lay out (it may have just switched) before scrolling to the panel.
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
        .observing(overview, polling: HealthPolling.overview)
    }
}

/// The summary: the overall status, what needs attention, then each section's cards. Everything that names a
/// problem leads to the panel behind it.
struct HealthDashboard: View {
    var overview: WsModel.DashboardOverview
    var query: NodeQuery<Ws.Stats.Dashboard.Overview>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.stackSpacing) {
            HealthHero(overview: overview, query: query)
            if !overview.attention.isEmpty {
                AttentionPanel(items: overview.attention)
            }
            // Sections side by side once the window is wide enough for two, each in the column with the most room.
            MasonryColumns(minimum: 620, spacing: Theme.stackSpacing) {
                ForEach(sections, id: \.section.id) { entry in
                    HealthSectionPanel(section: entry.section, cards: entry.cards)
                }
            }
        }
    }

    /// Sections in the daemon's order with their cards, without the hero card and the hidden sections.
    private var sections: [(section: WsModel.DashboardSectionSummary, cards: [WsModel.DashboardCardSummary])] {
        overview.sections
            .filter { !HealthCatalog.hiddenSections.contains($0.id) }
            .map { section in
                (section, overview.cards.filter { $0.sectionID == section.id && $0.id != HealthCatalog.heroCardID })
            }
            .filter { !$0.cards.isEmpty }
    }
}

// MARK: - Hero

private struct HealthHero: View {
    var overview: WsModel.DashboardOverview
    var query: NodeQuery<Ws.Stats.Dashboard.Overview>?

    private var tone: StatusTone { StatusTone(severity: overview.overallStatus) }
    private var hero: WsModel.DashboardCardSummary? {
        overview.cards.first { $0.id == HealthCatalog.heroCardID }
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: Severity.symbol(overview.overallStatus))
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(tone.color)
                        .frame(width: 48, height: 48)
                        .background(tone.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tone.line, lineWidth: 1)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Severity.headline(overview.overallStatus))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.fg)
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.fgMuted)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        if let query {
                            LiveStatus(query: query)
                        }
                        Text("Checked \(Format.relative(epoch: overview.checkedAt))")
                            .font(.caption)
                            .foregroundStyle(.fgFaint)
                    }
                }

                if let hero, !hero.metrics.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(hero.metrics, id: \.key) { metric in
                            MetricChip(metric: metric)
                        }
                    }
                }

                let sections = overview.sections.filter { !HealthCatalog.hiddenSections.contains($0.id) }
                if !sections.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                        ForEach(sections, id: \.id) { section in
                            SectionChip(section: section)
                        }
                    }
                }
            }
        }
    }

    private var detail: String {
        let counts = Severity.issueCount(errors: overview.errorCount, warnings: overview.warningCount)
        if !counts.isEmpty { return counts }
        switch overview.overallStatus {
        case "unknown", "unavailable": return "Some telemetry is not reporting."
        case "healthy", "info": return "No warnings or errors reported."
        default: return "The daemon reports \(Severity.text(overview.overallStatus).lowercased()) without details."
        }
    }
}

private struct MetricChip: View {
    var metric: WsModel.DashboardMetricSummary

    var body: some View {
        HStack(spacing: 6) {
            Text(metric.label)
                .foregroundStyle(.fgSubtle)
            if let value = metric.display {
                Text(value)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(metric.valueTone?.color ?? .fg)
            } else {
                Text("not available")
                    .foregroundStyle(.fgFaint)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.surface1, in: Capsule())
        .overlay { Capsule().strokeBorder(.line, lineWidth: 1) }
    }
}

private struct SectionChip: View {
    var section: WsModel.DashboardSectionSummary

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button {
            model.openHealth(href: section.href, cardID: nil)
        } label: {
            chip
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show \(section.title)")
    }

    private var chip: some View {
        let tone = StatusTone(severity: section.severity)
        let counts = Severity.issueCount(errors: section.errorCount, warnings: section.warningCount)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                StatusDot(tone: tone, size: 6)
                Text(section.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.fg)
            }
            Text(counts.isEmpty ? Severity.text(section.severity) : counts)
                .font(.caption2)
                .foregroundStyle(counts.isEmpty ? Color.fgSubtle : tone.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.surface2 : Color.surface1,
                    in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous).strokeBorder(.line, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Attention

private struct AttentionPanel: View {
    var items: [WsModel.DashboardOverview.AttentionItem]

    @Environment(AppModel.self) private var model

    var body: some View {
        Panel(title: "Needs attention", subtitle: "Click one to see what's behind it.") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(AttentionOrder.sorted(items).enumerated()), id: \.offset) { index, item in
                    IssueRow(severity: item.severity, title: item.title, message: item.message) {
                        model.openHealth(item)
                    }
                    if index < items.count - 1 {
                        Rectangle().fill(Color.line).frame(height: 1)
                    }
                }
            }
        }
    }
}

// MARK: - Sections and cards

private struct HealthSectionPanel: View {
    var section: WsModel.DashboardSectionSummary
    var cards: [WsModel.DashboardCardSummary]

    @Environment(AppModel.self) private var model

    var body: some View {
        let tone = StatusTone(severity: section.severity)
        let counts = Severity.issueCount(errors: section.errorCount, warnings: section.warningCount)
        Panel(title: section.title, subtitle: section.description) {
            FillingGrid(minimum: 260, spacing: 10) {
                ForEach(cards, id: \.id) { card in
                    Button {
                        let issue = (card.errors + card.warnings).first
                        model.openHealth(href: card.href, cardID: card.id, code: issue?.code, metricKey: issue?.metricKey)
                    } label: {
                        HealthCardTile(card: card)
                    }
                    .buttonStyle(CardButtonStyle())
                    .help("Show \(card.title)")
                }
            }
        } actions: {
            HStack(spacing: 10) {
                StatusBadge(label: counts.isEmpty ? Severity.text(section.severity) : counts, tone: tone)
                Button("Details") { model.openHealth(href: section.href, cardID: nil) }
                    .controlSize(.small)
            }
        }
    }
}

/// A card that is also a link: lifts its surface under the pointer, dims while pressed.
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration)
    }

    private struct CardButtonBody: View {
        var configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .strokeBorder(hovering ? Color.lineStrong : .clear, lineWidth: 1)
                }
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

/// One overview card: its severity, up to four metrics as the daemon reports them, a trend when it sent one, and
/// its warnings and errors.
struct HealthCardTile: View {
    var card: WsModel.DashboardCardSummary

    var body: some View {
        let tone = StatusTone(severity: card.severity)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                StatusDot(tone: tone)
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.fg)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Severity.text(card.severity))
                    .font(.caption)
                    .foregroundStyle(tone == .ok ? Color.fgSubtle : tone.color)
            }

            if !card.available {
                Text(card.unavailableReason ?? "Not reporting.")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    let metrics = HealthCatalog.metrics(of: card)
                    ForEach(Array(stride(from: 0, to: metrics.count, by: 2)), id: \.self) { start in
                        GridRow {
                            MetricCell(metric: metrics[start])
                            if start + 1 < metrics.count {
                                MetricCell(metric: metrics[start + 1])
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }

                if let series = card.series.first(where: { $0.points.count > 1 }) {
                    Sparkline(series: series)
                }
            }

            let issues = card.errors + card.warnings
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue.message, systemImage: Severity.symbol(issue.severity))
                            .font(.caption)
                            .foregroundStyle(StatusTone(severity: issue.severity).color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(.line, lineWidth: 1)
        }
        .help(card.description)
    }
}

private struct MetricCell: View {
    var metric: WsModel.DashboardMetricSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.label.uppercased())
                .font(.caption2.weight(.medium))
                .tracking(0.5)
                .foregroundStyle(.fgSubtle)
                .lineLimit(1)
            if let value = metric.display {
                Text(value)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(metric.valueTone?.color ?? .fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text("not available")
                    .font(.callout)
                    .foregroundStyle(.fgFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card's first trend series: shape only, no axes.
private struct Sparkline: View {
    var series: WsModel.DashboardCardSummary.Serie

    var body: some View {
        Chart(Array(series.points.enumerated()), id: \.offset) { _, point in
            AreaMark(x: .value("Time", Date(timeIntervalSince1970: TimeInterval(point.createdAt))),
                     y: .value(series.label, point.value))
                .foregroundStyle(LinearGradient(colors: [Color.accentFill.opacity(0.22), .clear],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", Date(timeIntervalSince1970: TimeInterval(point.createdAt))),
                     y: .value(series.label, point.value))
                .foregroundStyle(Color.accentFill)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 30)
        .accessibilityLabel("\(series.label) trend")
    }
}
