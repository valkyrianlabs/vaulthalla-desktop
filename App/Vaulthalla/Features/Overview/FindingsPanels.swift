import SwiftUI
import VHCore
import VHNodes

/// The Overview's findings on a node that reports their state (docs/mac-experience.md §7): what needs attention,
/// each with who acknowledged it and the place that remedies it, then the Silenced list with who and until when.
/// The actions are offered only to an account that may use them (`can_manage`); the severity is the node's, always.
struct FindingsPanels: View {
    var findings: HealthFindings
    var node: NodeID

    var body: some View {
        let alerts = findings.findings.map { NodeDigest.Alert($0, canManage: findings.canManage) }
        let attention = alerts.enumerated()
            .filter { $0.element.state != .silenced }
            .sorted { lhs, rhs in
                if lhs.element.state != rhs.element.state { return lhs.element.state < rhs.element.state }
                let (left, right) = (SeverityRank.of(lhs.element.severity), SeverityRank.of(rhs.element.severity))
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
        let silenced = alerts.filter { $0.state == .silenced }
            + findings.silences.map {
                NodeDigest.Alert(silence: $0, title: findings.classTitles[$0.findingClass], canManage: findings.canManage)
            }
        VStack(alignment: .leading, spacing: Theme.stackSpacing) {
            if !attention.isEmpty {
                Panel(title: "Needs attention", subtitle: findings.canManage
                      ? "Acknowledge what you've seen, or silence what isn't news. Every Mac and the web console see the same."
                      : "Click one to see what's behind it.") {
                    rows(attention)
                }
            }
            if !silenced.isEmpty {
                Panel(title: "Silenced",
                      subtitle: "Not notified or counted on the menu bar until the silence ends. The Health pages still show them.") {
                    rows(silenced)
                }
            }
        }
    }

    private func rows(_ alerts: [NodeDigest.Alert]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                FindingRow(alert: alert, node: node)
                if index < alerts.count - 1 {
                    Rectangle().fill(Color.line).frame(height: 1)
                }
            }
        }
    }
}

/// One finding: severity, title and message (a link to the panel behind it), its state, and the buttons.
private struct FindingRow: View {
    var alert: NodeDigest.Alert
    var node: NodeID

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Severity.symbol(alert.severity))
                .foregroundStyle(StatusTone(severity: alert.severity).color.opacity(alert.isAttended ? 0.55 : 1))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 6) {
                summary
                FindingStateLine(alert: alert, node: node)
                if let note = alert.mark?.note, !note.isEmpty {
                    Text("“\(note)”")
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    /// The title and message; it opens the panel behind the finding when there is one (a silence of a class that
    /// isn't active has none).
    @ViewBuilder private var summary: some View {
        let text = Text("\(Text(alert.title).fontWeight(.medium).foregroundStyle(alert.isAttended ? Color.fgMuted : Color.fg))  \(alert.message)")
            .foregroundStyle(alert.isAttended ? Color.fgSubtle : Color.fgMuted)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        if alert.cardID.isEmpty {
            text
        } else {
            Button {
                model.openHealth(href: alert.href, cardID: alert.cardID, code: alert.code, metricKey: alert.metricKey)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    text
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(hovering ? Color.fgSubtle : Color.fgFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Show what caused this")
        }
    }

    @ViewBuilder private var buttons: some View {
        let remedies = alert.openableRemedies
        let running = model.findingActivity(for: alert, on: node) == .running
        if !remedies.isEmpty || alert.canManage {
            HStack(spacing: 8) {
                ForEach(remedies) { remedy in
                    Button(remedy.label, systemImage: "arrow.forward.circle") { model.open(remedy, of: alert, on: node) }
                        .help("Open it in Vaulthalla")
                }
                if alert.canManage {
                    if alert.state == .active {
                        Button("Acknowledge") { run(.acknowledge) }
                    }
                    if alert.state != .silenced {
                        Menu("Silence") {
                            ForEach(SilenceDuration.allCases) { duration in
                                Button(duration.title) { run(.silence(duration)) }
                            }
                        }
                        .menuStyle(.button)
                        .fixedSize()
                    }
                    if alert.state != .active {
                        Button("Turn Back On") { run(.turnBackOn) }
                    }
                }
                if running {
                    ProgressView().controlSize(.small)
                }
            }
            .controlSize(.small)
            .disabled(running)
        }
    }

    private func run(_ action: HealthFindingAction) {
        Task { await model.act(action, on: alert, node: node) }
    }
}
