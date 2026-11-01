import SwiftUI
import VHContract
import VHCore
import VHNodes

/// How often a Health page refreshes its panels (the web console's `DETAIL_POLL_MS`).
enum HealthPolling {
    static let detail: Duration = .seconds(15)
    static let overview: Duration = .seconds(15)
    /// Snapshots are written every few minutes; the trend payload is large.
    static let trends: Duration = .seconds(300)
}

/// A daemon severity with its issue counts. A missing severity reads "Unknown", never healthy.
struct HealthBadge: View {
    var severity: String?
    var errors = 0
    var warnings = 0

    var body: some View {
        let severity = severity == "unavailable" ? "unknown" : severity ?? "unknown"
        let counts = Severity.issueCount(errors: Int64(errors), warnings: Int64(warnings))
        StatusBadge(label: counts.isEmpty ? Severity.text(severity) : counts, tone: StatusTone(severity: severity))
    }
}

/// The daemon's warnings and errors, worst first. Each one leads to the panel and metric behind it.
struct IssueList: View {
    var issues: [WsModel.DashboardIssueSummary]
    var cardID: String

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sorted.enumerated()), id: \.offset) { index, issue in
                IssueRow(severity: issue.severity, title: nil, message: issue.message) {
                    model.openHealth(issue, cardID: cardID)
                }
                if index < sorted.count - 1 {
                    Rectangle().fill(Color.line).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 4)
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous).strokeBorder(.line, lineWidth: 1)
        }
    }

    private var sorted: [WsModel.DashboardIssueSummary] {
        issues.sorted { Severity.rank($0.severity) < Severity.rank($1.severity) }
    }
}

/// One warning or error as a row that leads somewhere: icon, an optional title, the daemon's message, a chevron.
struct IssueRow: View {
    var severity: String
    var title: String?
    var message: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: Severity.symbol(severity))
                    .foregroundStyle(StatusTone(severity: severity).color)
                    .frame(width: 16)
                Group {
                    if let title {
                        Text("\(Text(title).fontWeight(.medium).foregroundStyle(Color.fg))  \(message)")
                    } else {
                        Text(message)
                    }
                }
                .foregroundStyle(.fgMuted)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(hovering ? Color.fgSubtle : Color.fgFaint)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(hovering ? Color.surface2 : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show what caused this")
    }
}

/// A panel on a Health page: its anchor (warnings scroll here), the overview card's severity and issues, the live
/// status of its read, and the read's content. A failed read says why inside the panel; its neighbours still show.
struct HealthDetailSection<R: WsRequest, Content: View, Actions: View>: View {
    var anchor: HealthAnchor
    var title: String
    var overview: WsModel.DashboardOverview?
    var query: NodeQuery<R>
    var subject: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: (R.Response) -> Content

    @Environment(AppModel.self) private var model
    @State private var flash = false

    private var card: WsModel.DashboardCardSummary? {
        overview?.cards.first { $0.id == anchor.cardID }
    }

    var body: some View {
        let card = card
        Panel(title: title, subtitle: subtitle(card)) {
            VStack(alignment: .leading, spacing: 16) {
                if let card, !(card.errors + card.warnings).isEmpty {
                    IssueList(issues: card.errors + card.warnings, cardID: card.id)
                }
                switch query.state {
                case .idle, .loading:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading \(subject)…").font(.callout).foregroundStyle(.fgSubtle)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                case .loaded(let value, _):
                    content(value)
                case .failed(let error):
                    HStack(spacing: 12) {
                        InlineProblem(error: error, subject: subject)
                        Spacer(minLength: 0)
                        Button("Try Again") { Task { await query.refresh() } }
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                }
            }
        } actions: {
            HStack(spacing: 10) {
                actions
                if let card {
                    HealthBadge(severity: card.severity, errors: card.errors.count, warnings: card.warnings.count)
                }
                LiveStatus(query: query)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
                .strokeBorder(Color.accentFill, lineWidth: 2)
                .opacity(flash ? 0.9 : 0)
                .allowsHitTesting(false)
        }
        .task(id: model.healthTarget?.id) {
            guard model.healthTarget?.targets(anchor) == true else { return }
            withAnimation(.easeOut(duration: 0.2)) { flash = true }
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeIn(duration: 0.6)) { flash = false }
        }
        .id(anchor)
    }

    private func subtitle(_ card: WsModel.DashboardCardSummary?) -> String? {
        guard let card else { return nil }
        if !card.available { return card.unavailableReason ?? card.description }
        return card.summary.isEmpty ? card.description : card.summary
    }
}

extension HealthDetailSection where Actions == EmptyView {
    init(anchor: HealthAnchor, title: String, overview: WsModel.DashboardOverview?, query: NodeQuery<R>,
         subject: String, @ViewBuilder content: @escaping (R.Response) -> Content) {
        self.init(anchor: anchor, title: title, overview: overview, query: query, subject: subject,
                  actions: { EmptyView() }, content: content)
    }
}

extension Severity {
    /// Worst first: errors, warnings, then the rest.
    static func rank(_ severity: String) -> Int {
        switch severity {
        case "error": 0
        case "warning": 1
        case "unknown", "unavailable": 2
        default: 3
        }
    }
}
