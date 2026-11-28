import SwiftUI
import VHCore
import VHNodes

/// The menu bar item's image: the mark in the fleet's state. It also keeps SwiftUI's window-opening action for code
/// that isn't a view (`MainWindow`), since it lives as long as the item does.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.fleet.status
        Image(nsImage: MenuBarIcon.image(for: status.level))
            .accessibilityLabel("Vaulthalla: \(status.headline)")
            .task { MainWindow.open = openWindow }
    }
}

/// The panel under the menu bar item (docs/mac-experience.md §2): the fleet in a sentence, the totals that add up,
/// what needs attention, the nodes with favourites first, what waits on the person, and the way into the app.
/// Everything is a figure a node reported or a state the app is in.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    static let width: CGFloat = 340
    private static let shownAlerts = 5
    private static let shownSilenced = 3
    private static let shownNodes = 8

    var body: some View {
        let fleet = model.fleet
        let summary = fleet.summary
        let status = fleet.status
        VStack(alignment: .leading, spacing: 0) {
            header(status, fleet: fleet)
            if !model.nodes.isEmpty {
                divider
                totals(summary)
            }
            if !summary.alerts.isEmpty {
                divider
                attention(summary.alerts)
            }
            if !summary.silenced.isEmpty {
                divider
                silenced(summary.silenced)
            }
            divider
            nodes
            let waiting = waitingItems
            if !waiting.isEmpty {
                divider
                section("Waiting on you") {
                    ForEach(waiting) { item in
                        PanelRow(systemImage: item.systemImage, tone: item.tone, title: item.title, subtitle: item.subtitle) {
                            item.action()
                        }
                    }
                }
            }
            divider
            footer
        }
        .frame(width: Self.width)
        .background(Color.canvasRaised)
        .preferredColorScheme(.dark)
        .tint(.accentFill)
        // Opening the panel asks the nodes now (unless the monitor is already asking).
        .task { await fleet.checkNow(figures: true) }
    }

    private var divider: some View {
        Rectangle().fill(Color.line).frame(height: 1)
    }

    // MARK: Header

    private func header(_ status: FleetStatus, fleet: FleetMonitor) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(for: status.level))
                .font(.title2)
                .foregroundStyle(Self.tone(for: status.level).color)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.headline)
                    .font(.headline)
                    .foregroundStyle(.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = status.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(checkedText(fleet))
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Button {
                Task { await fleet.checkNow(figures: true) }
            } label: {
                if fleet.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.fgSubtle)
            .disabled(fleet.isChecking)
            .help("Check every node now")
            .accessibilityLabel("Check now")
        }
        .padding(14)
        .accessibilityElement(children: .contain)
    }

    private func checkedText(_ fleet: FleetMonitor) -> String {
        guard let checked = fleet.checkedAt else { return "Not checked yet" }
        return "Checked \(checked.formatted(date: .omitted, time: .shortened))"
    }

    static func symbol(for level: FleetStatus.Level) -> String {
        switch level {
        case .notReporting: "circle.dotted"
        case .quiet: "checkmark.circle.fill"
        case .warnings: "exclamationmark.triangle.fill"
        case .attention: "exclamationmark.octagon.fill"
        }
    }

    static func tone(for level: FleetStatus.Level) -> StatusTone {
        switch level {
        case .notReporting: .unknown
        case .quiet: .ok
        case .warnings: .warn
        case .attention: .danger
        }
    }

    // MARK: Totals

    private func totals(_ summary: FleetSummary) -> some View {
        HStack(alignment: .top, spacing: 0) {
            PanelFigure(label: "Online", value: "\(summary.onlineCount) of \(summary.nodeCount)")
            PanelFigure(label: "Stored",
                        value: summary.storageReporting > 0 ? Format.bytes(summary.usedBytes) : nil)
            PanelFigure(label: "Conflicts",
                        value: summary.onlineCount > 0 ? summary.openConflicts.formatted() : nil,
                        tone: summary.openConflicts > 0 ? .warn : nil)
            if summary.costReporting > 0 {
                PanelFigure(label: "This month", value: money(summary.monthToDate))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Amounts per currency, "$12.40 + €3.10"; nil when no node reported one.
    private func money(_ amounts: [String: Decimal]) -> String? {
        guard !amounts.isEmpty else { return nil }
        return amounts.sorted { $0.key < $1.key }
            .compactMap { CostFormat.money("\($0.value)", $0.key) }
            .joined(separator: " + ")
    }

    // MARK: Attention

    private func attention(_ alerts: [FleetSummary.FleetAlert]) -> some View {
        section("Needs attention") {
            ForEach(alerts.prefix(Self.shownAlerts)) { entry in
                PanelFindingRow(entry: entry, subtitle: "\(entry.nodeName) · \(entry.alert.message)") {
                    open { model.open(entry.alert, on: entry.node) }
                } openRemedy: { navigate in
                    open(navigate)
                }
            }
            if alerts.count > Self.shownAlerts {
                PanelRow(systemImage: "ellipsis", tone: nil,
                         title: "and \(alerts.count - Self.shownAlerts) more", subtitle: nil) {
                    open { model.showAllNodes() }
                }
            }
        }
    }

    /// Findings someone silenced: who and until when, and Turn Back On, without raising the item.
    private func silenced(_ entries: [FleetSummary.FleetAlert]) -> some View {
        section("Silenced") {
            ForEach(entries.prefix(Self.shownSilenced)) { entry in
                PanelFindingRow(entry: entry, subtitle: entry.nodeName) {
                    open { model.open(entry.alert, on: entry.node) }
                } openRemedy: { navigate in
                    open(navigate)
                }
            }
            if entries.count > Self.shownSilenced {
                PanelRow(systemImage: "ellipsis", tone: nil,
                         title: "and \(entries.count - Self.shownSilenced) more", subtitle: nil) {
                    open { model.showAllNodes() }
                }
            }
        }
    }

    // MARK: Nodes

    @ViewBuilder
    private var nodes: some View {
        let ordered = model.preferences.favoritesFirst(model.nodes)
        section("Nodes") {
            if ordered.isEmpty {
                PanelRow(systemImage: "plus.circle", tone: .info, title: "Add a Node…",
                         subtitle: "Pair this Mac with a Vaulthalla server.") {
                    open { model.presentAddNode() }
                }
            }
            ForEach(ordered.prefix(Self.shownNodes)) { node in
                PanelNodeRow(node: node) { section in
                    open { model.selectNode(node.id, section: section) }
                }
            }
            if ordered.count > Self.shownNodes {
                PanelRow(systemImage: "ellipsis", tone: nil, title: "Show all \(ordered.count) in Vaulthalla",
                         subtitle: nil) {
                    open { model.showAllNodes() }
                }
            }
        }
    }

    // MARK: Waiting on you

    private struct WaitingItem: Identifiable {
        var id: String
        var systemImage: String
        var tone: StatusTone
        var title: String
        var subtitle: String?
        var action: () -> Void
    }

    private var waitingItems: [WaitingItem] {
        var items: [WaitingItem] = []
        let keys = model.recoveryKeys.attentionCount()
        if keys > 0 {
            items.append(WaitingItem(
                id: "keys", systemImage: NodeSection.recoveryKeys.systemImage, tone: .warn,
                title: keys == 1 ? "1 vault key needs backup" : "\(keys) vault keys need backup",
                subtitle: "Open Recovery Keys") { open { model.showAllRecoveryKeys() } })
        }
        for node in model.nodes where model.needsPairingAgain(node.id) || model.status(for: node) == .revoked {
            items.append(WaitingItem(
                id: "pair-\(node.id.rawValue)", systemImage: "link.badge.plus", tone: .danger,
                title: "\(node.displayName) needs pairing again", subtitle: "Pair this Mac again to use it") {
                    open {
                        model.selectNode(node.id, section: .overview)
                        model.presentPairing(for: node.id)
                    }
                })
        }
        if let update = Updates.shared.pending {
            items.append(WaitingItem(
                id: "update", systemImage: "arrow.down.circle", tone: .info,
                title: "Vaulthalla \(update) is ready", subtitle: "Show the update") {
                    MainWindow.dismissPanel()
                    Updates.shared.showPending()
                })
        }
        return items
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open Vaulthalla") { open {} }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o")
            Spacer(minLength: 0)
            Button {
                open { model.presentAddNode() }
            } label: {
                Image(systemName: "plus")
            }
            .help("Add Node…")
            .accessibilityLabel("Add Node")
            Button {
                MainWindow.dismissPanel()
                NSApp.setActivationPolicy(.regular)
                openSettings()
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings…")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Vaulthalla")
            .accessibilityLabel("Quit Vaulthalla")
            .keyboardShortcut("q")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Pieces

    /// Runs `navigate`, then brings the main window forward; the panel closes as the window takes the keyboard.
    private func open(_ navigate: () -> Void) {
        navigate()
        MainWindow.dismissPanel()
        MainWindow.show()
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(.fgSubtle)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }
}

/// One figure of the panel's totals; a dash while no node reported it.
private struct PanelFigure: View {
    var label: String
    var value: String?
    var tone: StatusTone?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.fgSubtle)
            Text(value ?? "–")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Color.fgFaint : tone?.color ?? Color.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(value ?? "not reported")
    }
}

/// A clickable row of the panel: a symbol, a title and an optional second line.
private struct PanelRow: View {
    var systemImage: String
    var tone: StatusTone?
    var title: String
    var subtitle: String?
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: systemImage)
                    .foregroundStyle(tone?.color ?? Color.fgSubtle)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(.fg)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.fgMuted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Color.surface2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A finding in the panel: its severity, title and a line, its state (who acknowledged or silenced it, until when),
/// and its menu (the remedies, and for an account that may, Acknowledge, Silence and Turn Back On).
private struct PanelFindingRow: View {
    var entry: FleetSummary.FleetAlert
    var subtitle: String
    var action: () -> Void
    /// Opens the main window after the navigation it is given (the panel closes as the window comes forward).
    var openRemedy: (() -> Void) -> Void

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let alert = entry.alert
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Button(action: action) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: alert.state == .silenced ? "bell.slash" : Severity.symbol(alert.severity))
                        .foregroundStyle(alert.isAttended ? Color.fgSubtle : StatusTone(severity: alert.severity).color)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(alert.title)
                            .foregroundStyle(alert.isAttended ? Color.fgMuted : Color.fg)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.fgMuted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        FindingStateLine(alert: alert, node: entry.node)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            FindingActionsMenu(alert: alert, node: entry.node, opening: openRemedy)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Color.surface2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
        .onHover { hovering = $0 }
    }
}

/// One node in the panel: its status, its name, a line in the node's own words, a star, and a menu into its areas.
private struct PanelNodeRow: View {
    var node: Node
    /// Opens the node at a section.
    var open: (NodeSection) -> Void

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private static let quick: [NodeSection] = [.overview, .files, .syncConflicts, .cost, .devices]

    var body: some View {
        let status = model.status(for: node)
        let preferences = model.preferences
        HStack(spacing: 9) {
            Button {
                open(.overview)
            } label: {
                HStack(spacing: 9) {
                    StatusDot(tone: tone(status), pulse: status.isTransitional)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(node.displayName)
                                .foregroundStyle(.fg)
                                .lineLimit(1)
                            if preferences.isFavorite(node.id) {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.accentText)
                                    .accessibilityLabel("Favorite")
                            }
                            if preferences.isMuted(node.id) {
                                Image(systemName: "bell.slash.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.fgFaint)
                                    .accessibilityLabel("Notifications muted")
                            }
                        }
                        Text(line(status))
                            .font(.caption)
                            .foregroundStyle(.fgMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(Self.quick) { section in
                    Button(section.title, systemImage: section.systemImage) { open(section) }
                }
                Divider()
                Button(preferences.isFavorite(node.id) ? "Remove from Favorites" : "Add to Favorites",
                       systemImage: preferences.isFavorite(node.id) ? "star.slash" : "star") {
                    preferences.toggleFavorite(node.id)
                }
                Button(preferences.isMuted(node.id) ? "Turn Notifications On" : "Mute Notifications",
                       systemImage: preferences.isMuted(node.id) ? "bell" : "bell.slash") {
                    preferences.setMuted(!preferences.isMuted(node.id), for: node.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(hovering ? Color.fgMuted : Color.fgFaint)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Go to an area of \(node.displayName)")
            .accessibilityLabel("More for \(node.displayName)")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Color.surface2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
        .onHover { hovering = $0 }
    }

    /// The dot: the node's health while it is online and reports it, else its connection.
    private func tone(_ status: NodeConnectionStatus) -> StatusTone {
        guard status == .online, let health = model.pulse(for: node)?.digest.health.value else { return status.tone }
        if health.hasErrors { return .danger }
        if health.hasWarnings { return .warn }
        return .ok
    }

    /// One line: what the node says about itself, or why it isn't connected.
    private func line(_ status: NodeConnectionStatus) -> String {
        if let mismatch = model.incompatibility(for: node) {
            return mismatch.side == .desktopTooOld ? "Needs a newer Vaulthalla Desktop" : "Needs a newer Vaulthalla on the node"
        }
        switch status {
        case .online:
            guard let digest = model.pulse(for: node)?.digest else { return "Online" }
            var parts: [String] = []
            switch digest.health {
            case .value(let health):
                parts.append(health.hasErrors || health.hasWarnings
                             ? Severity.issueCount(errors: health.errorCount, warnings: health.warningCount)
                             : "Healthy")
            case .loading: parts.append("Checking health…")
            case .denied, .unsupported, .failed: parts.append("Online")
            }
            if let storage = digest.storage.value { parts.append(Format.bytes(storage.usedBytes)) }
            if let open = digest.conflicts.value, open > 0 {
                parts.append(open == 1 ? "1 conflict" : "\(open) conflicts")
            }
            return parts.joined(separator: " · ")
        case .offline:
            return model.offlineReason(for: node.id) ?? "Offline"
        case .connecting, .notPaired, .revoked:
            return status.label
        }
    }
}

#if DEBUG
#Preview("Menu bar panel") {
    MenuBarPanel()
        .environment(PreviewSamples.liveModel())
}

#Preview("Menu bar panel · empty") {
    MenuBarPanel()
        .environment(PreviewSamples.model(nodes: []))
}
#endif
