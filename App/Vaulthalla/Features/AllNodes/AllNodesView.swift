import SwiftUI
import VHCore
import VHNodes

/// Every node this Mac knows about, live: the fleet's totals, what needs attention across nodes, and one card per
/// node. Each card loads and polls on its own node (`NodePulse`), so a slow or offline node never holds the others
/// back. Every figure is a node's own answer; totals add up only what the nodes reported.
struct AllNodesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.stackSpacing + 8) {
                SectionHeader(eyebrow: "Vaulthalla", title: "All Nodes",
                              subtitle: "Every Vaulthalla server this Mac knows about, live.") {
                    if !model.nodes.isEmpty {
                        Button("Add Node…", systemImage: "plus") { model.presentAddNode() }
                            .controlSize(.small)
                    }
                }

                if model.nodes.isEmpty, model.settingUpLocalNode {
                    Panel {
                        EmptyState(
                            "Connecting to this Mac's server",
                            systemImage: "desktopcomputer",
                            message: "Vaulthalla is installed on this Mac too. Desktop is pairing with it through your macOS account, so there's no code to compare."
                        ) {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else if model.nodes.isEmpty {
                    Panel {
                        EmptyState(
                            "No nodes yet",
                            systemImage: "server.rack",
                            message: "Add a Vaulthalla server from your network or by its address. This Mac pairs with each server once, then manages it from here."
                        ) {
                            Button("Add Node…") { model.presentAddNode() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    let pulses = model.nodes.map { (node: $0, pulse: model.pulse(for: $0)) }
                    let summary = FleetSummary(pulses.map { member($0.node, $0.pulse) })

                    FleetTotals(summary: summary) { keyBackupsTile }

                    if !summary.alerts.isEmpty {
                        FleetAlertsPanel(alerts: summary.alerts)
                    }

                    // Nodes with figures first, in sidebar order; those without (unpaired, revoked, offline before
                    // their first answer) below, so their short cards don't leave gaps between the full ones.
                    let live = pulses.filter { $0.pulse != nil }
                    let idle = pulses.filter { $0.pulse == nil }
                    if !live.isEmpty {
                        cards(live)
                    }
                    if !idle.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            if !live.isEmpty {
                                Text("Not connected")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.fgMuted)
                            }
                            cards(idle)
                        }
                    }
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
    }

    private func cards(_ entries: [(node: Node, pulse: NodePulse?)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)],
                  alignment: .leading, spacing: 16) {
            ForEach(entries, id: \.node.id) { entry in
                NodePulseCard(node: entry.node, pulse: entry.pulse)
            }
        }
    }

    private func member(_ node: Node, _ pulse: NodePulse?) -> FleetSummary.Member {
        FleetSummary.Member(id: node.id, name: node.displayName, reachability: model.status(for: node).reachability,
                            digest: pulse?.digest ?? NodeDigest())
    }

    /// Recovery Keys at a glance; opens the cross-node Recovery Keys page. "not available" until a node answered.
    private var keyBackupsTile: some View {
        let rows = model.recoveryKeys.rows()
        let backedUp = rows.filter { if case .backedUp = $0.status { true } else { false } }.count
        let attention = rows.filter(\.needsAttention).count
        return Button {
            model.showAllRecoveryKeys()
        } label: {
            StatTile(label: "Key backups",
                     value: rows.isEmpty ? nil : attention > 0 ? "\(attention) need attention" : "\(backedUp) of \(rows.count) backed up",
                     systemImage: "key.horizontal", tone: attention > 0 ? .warn : nil)
        }
        .buttonStyle(.plain)
        .help("Recovery Keys across every node")
    }
}

extension NodeConnectionStatus {
    var reachability: FleetSummary.Reachability {
        switch self {
        case .online: .online
        case .connecting: .connecting
        case .offline: .offline
        case .notPaired: .notPaired
        case .revoked: .revoked
        }
    }
}

// MARK: - Totals

/// The fleet at a glance: reachability, health, storage, vaults, spend and activity, added up across nodes.
private struct FleetTotals<Extra: View>: View {
    var summary: FleetSummary
    @ViewBuilder var extra: Extra

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
            StatTile(label: "Nodes", value: "\(summary.onlineCount) of \(summary.nodeCount) online",
                     systemImage: "server.rack", hint: reachabilityHint,
                     tone: summary.unreachableCount > 0 ? .warn : nil)
            StatTile(label: "Health", value: healthValue, systemImage: "waveform.path.ecg", hint: healthHint,
                     tone: healthTone)
            StatTile(label: "Storage used", value: summary.storageReporting > 0 ? Format.bytes(summary.usedBytes) : nil,
                     systemImage: "internaldrive", hint: storageHint)
            StatTile(label: "Vaults", value: summary.storageReporting > 0 ? summary.vaultCount.formatted() : nil,
                     systemImage: "lock.rectangle.stack", hint: conflictsHint,
                     tone: summary.openConflicts > 0 ? .warn : nil)
            StatTile(label: "S3 spend this month", value: money(summary.monthToDate), systemImage: "chart.bar.xaxis",
                     hint: spendHint)
            StatTile(label: "Changes (24 h)", value: activityValue, systemImage: "clock.arrow.circlepath",
                     hint: activityHint)
            extra
        }
    }

    private var reachabilityHint: String {
        var parts: [String] = []
        if summary.unreachableCount > 0 { parts.append("\(summary.unreachableCount) unreachable") }
        if summary.unpairedCount > 0 { parts.append("\(summary.unpairedCount) not paired") }
        return parts.isEmpty ? "Every node connected" : parts.joined(separator: " · ")
    }

    private var healthValue: String? {
        if !summary.nodesWithErrors.isEmpty { return "\(summary.nodesWithErrors.count) with errors" }
        if !summary.nodesWithWarnings.isEmpty { return "\(summary.nodesWithWarnings.count) with warnings" }
        let reported = summary.onlineCount - summary.healthUnknownCount
        return reported > 0 ? "No errors" : nil
    }

    private var healthTone: StatusTone? {
        if !summary.nodesWithErrors.isEmpty { return .danger }
        if !summary.nodesWithWarnings.isEmpty { return .warn }
        return nil
    }

    private var healthHint: String {
        var parts: [String] = []
        if !summary.nodesWithErrors.isEmpty, !summary.nodesWithWarnings.isEmpty {
            parts.append("\(summary.nodesWithWarnings.count) more with warnings")
        }
        if summary.healthUnknownCount > 0 { parts.append("\(summary.healthUnknownCount) not reporting") }
        return parts.isEmpty ? "As each node reports it" : parts.joined(separator: " · ")
    }

    private var storageHint: String {
        if summary.quotaCoverage > 0, summary.quotaCoverage == summary.storageReporting {
            return "of \(Format.bytes(summary.quotaBytes)) in quotas"
        }
        let nodes = summary.storageReporting
        return nodes == 0 ? "No node reports storage yet" : "Across \(nodes) node\(nodes == 1 ? "" : "s")"
    }

    private var conflictsHint: String {
        summary.openConflicts > 0 ? "\(summary.openConflicts) open sync conflicts" : "No open sync conflicts"
    }

    private var spendHint: String {
        guard summary.costReporting > 0 else { return "No node tracks S3 spend" }
        if let projected = money(summary.projectedMonth) { return "Projected \(projected)" }
        return "On \(summary.costReporting) node\(summary.costReporting == 1 ? "" : "s")"
    }

    private var activityValue: String? {
        summary.lastActivity == nil && summary.changes24h == 0 ? nil : summary.changes24h.formatted()
    }

    private var activityHint: String {
        var parts: [String] = []
        if summary.bytesAdded24h > 0 { parts.append("+\(Format.bytes(summary.bytesAdded24h))") }
        if let last = summary.lastActivity { parts.append("last \(Format.relative(last.at))") }
        return parts.isEmpty ? "Across every vault" : parts.joined(separator: " · ")
    }

    /// Amounts per currency, "$12.40 + €3.10"; nil when no node reported one.
    private func money(_ amounts: [String: Decimal]) -> String? {
        guard !amounts.isEmpty else { return nil }
        return amounts.sorted { $0.key < $1.key }
            .compactMap { CostFormat.money("\($0.value)", $0.key) }
            .joined(separator: " + ")
    }
}

// MARK: - Alerts

/// What needs attention across every node, most severe first. Each row opens the node's panel it's about.
private struct FleetAlertsPanel: View {
    var alerts: [FleetSummary.FleetAlert]

    @Environment(AppModel.self) private var model
    @State private var showsAll = false

    private static let shown = 6

    var body: some View {
        Panel(title: "Needs attention", subtitle: "Across every node, most severe first.") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(showsAll ? alerts : Array(alerts.prefix(Self.shown))) { entry in
                    Button {
                        model.open(entry.alert, on: entry.node)
                    } label: {
                        NodeAlertRow(alert: entry.alert, node: entry.nodeName)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(entry.alert.title) on \(entry.nodeName)")
                }
            }
        } actions: {
            if alerts.count > Self.shown {
                Button(showsAll ? "Show Fewer" : "Show All \(alerts.count)") { showsAll.toggle() }
                    .controlSize(.small)
            }
        }
    }
}

/// One alert: severity, an optional node name, the card's title and the daemon's message.
struct NodeAlertRow: View {
    var alert: NodeDigest.Alert
    var node: String?

    @State private var hovering = false

    var body: some View {
        let tone = StatusTone(severity: alert.severity)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Severity.symbol(alert.severity))
                .foregroundStyle(tone.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let node {
                        Text(node)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.fgMuted)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(.surface2, in: Capsule())
                    }
                    Text(alert.title)
                        .fontWeight(.medium)
                        .foregroundStyle(.fg)
                        .lineLimit(1)
                    Text(alert.area.title)
                        .font(.caption)
                        .foregroundStyle(.fgFaint)
                }
                Text(alert.message)
                    .foregroundStyle(.fgMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(hovering ? Color.fgMuted : Color.fgFaint)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.surface2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("All nodes") {
    AllNodesView()
        .environment(PreviewSamples.liveModel())
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1280, height: 900)
}

#Preview("All nodes · narrow") {
    AllNodesView()
        .environment(PreviewSamples.liveModel())
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 720, height: 900)
}

#Preview("All nodes · empty") {
    AllNodesView()
        .environment(PreviewSamples.model(nodes: []))
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 900, height: 600)
}
#endif
