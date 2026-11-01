import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// The node's warnings and errors where they're always in sight: a count on the sidebar's Overview row and a pill in
/// every node page's header. The pill opens the list; each item leads to the panel and row behind it. Nothing shows
/// while the node reports no issues, or when this account can't read stats.
extension View {
    func healthBadge(section: NodeSection, node: Node) -> some View {
        modifier(HealthSidebarBadge(isOverview: section == .overview, node: node))
    }
}

/// The severity read both share (`stats.dashboard.severity`, the console's health dot): small, polled once a minute.
@MainActor
private enum HealthSeverity {
    static let polling: Duration = .seconds(60)

    static func query(_ model: AppModel, _ node: Node) -> NodeQuery<Ws.Stats.Dashboard.Severity>? {
        guard let queries = model.liveQueries(for: node), queries.supports(command: .statsDashboardSeverity) != .no else {
            return nil
        }
        return queries.query(Ws.Stats.Dashboard.Severity.self)
    }

    /// A refusal (or a daemon without the command) won't change by polling; ask again only on a new view.
    static func polls(_ query: NodeQuery<Ws.Stats.Dashboard.Severity>) -> Duration? {
        switch query.error {
        case .denied, .unauthorized, .contractMismatch, .unknownCommand, .protocolUnsupported: nil
        default: polling
        }
    }

    static func issues(_ query: NodeQuery<Ws.Stats.Dashboard.Severity>) -> (count: Int64, tone: StatusTone)? {
        guard query.error == nil, let stats = query.value?.stats else { return nil }
        let count = stats.errorCount + stats.warningCount
        guard count > 0 else { return nil }
        return (count, stats.errorCount > 0 ? .danger : .warn)
    }
}

private struct HealthSidebarBadge: ViewModifier {
    var isOverview: Bool
    var node: Node

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if isOverview, let query = HealthSeverity.query(model, node) {
            let issues = HealthSeverity.issues(query)
            content
                .badge(issues.map { Text("\(min($0.count, 999))").foregroundStyle($0.tone.color) })
                .task(id: Key(query: ObjectIdentifier(query), polls: HealthSeverity.polls(query) != nil)) {
                    await query.observe(polling: HealthSeverity.polls(query))
                }
        } else {
            content
        }
    }

    private struct Key: Hashable {
        var query: ObjectIdentifier
        var polls: Bool
    }
}

/// "2 warnings" in a node page's header. Click it for what they are; click one to go there.
struct NodeHealthPill: View {
    var node: Node

    @Environment(AppModel.self) private var model
    @State private var showing = false

    var body: some View {
        if let query = HealthSeverity.query(model, node) {
            Group {
                if let stats = query.value?.stats, let issues = HealthSeverity.issues(query) {
                    Button {
                        showing.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: Severity.symbol(stats.errorCount > 0 ? "error" : "warning"))
                            Text(Severity.issueCount(errors: stats.errorCount, warnings: stats.warningCount))
                            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(issues.tone.color)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(issues.tone.soft, in: Capsule())
                        .overlay { Capsule().strokeBorder(issues.tone.line, lineWidth: 1) }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("What needs attention on \(node.displayName)")
                    .popover(isPresented: $showing, arrowEdge: .bottom) {
                        AttentionPopover(node: node) { showing = false }
                    }
                }
            }
            .task(id: ObjectIdentifier(query)) {
                await query.observe(polling: HealthSeverity.polls(query))
            }
        }
    }
}

/// The overview's attention items, worst first, each leading to its panel.
private struct AttentionPopover: View {
    var node: Node
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Needs attention").font(.headline).foregroundStyle(.fg)
            if let queries = model.liveQueries(for: node) {
                let overview = queries.query(Ws.Stats.Dashboard.Overview.self, .init())
                Group {
                    if let stats = overview.value?.stats {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(AttentionOrder.sorted(stats.attention).enumerated()), id: \.offset) { _, item in
                                IssueRow(severity: item.severity, title: item.title, message: item.message) {
                                    model.openHealth(item)
                                    dismiss()
                                }
                            }
                        }
                    } else if let error = overview.error {
                        InlineProblem(error: error, subject: "health")
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 50)
                    }
                }
                .observing(overview)
            }
            Divider()
            Button("Show Overview") {
                model.openHealth(.summary)
                dismiss()
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 420)
    }
}

/// Attention items worst first, the daemon's order within a severity.
enum AttentionOrder {
    static func sorted(_ items: [WsModel.DashboardOverview.AttentionItem]) -> [WsModel.DashboardOverview.AttentionItem] {
        items.enumerated().sorted { lhs, rhs in
            let (l, r) = (Severity.rank(lhs.element.severity), Severity.rank(rhs.element.severity))
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }
}
