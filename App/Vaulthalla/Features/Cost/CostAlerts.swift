import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Cost alerts (`pricing.notifications.list`): raised when a budget window is about to run out or a sync was blocked.
/// Acknowledging one (`pricing.notifications.ack`) takes it off the open count.
struct CostAlertsList: View {
    var node: Node
    var queries: NodeQueries
    var lookup: VaultLookup

    @AppStorage("cost.alerts.showAcknowledged") private var showAcknowledged = false
    @State private var selection: Int64?
    @State private var ack: NodeMutation<Ws.Pricing.Notifications.Ack>

    init(node: Node, queries: NodeQueries, lookup: VaultLookup) {
        self.node = node
        self.queries = queries
        self.lookup = lookup
        _ack = State(initialValue: NodeMutation(Ws.Pricing.Notifications.Ack.self, on: queries,
                                                invalidating: CostQueries.invalidated))
    }

    var body: some View {
        let alerts = queries.query(Ws.Pricing.Notifications.List.self,
                                   CostQueries.alerts(includeAcknowledged: showAcknowledged))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let summary = alerts.value?.summary {
                    OpenAlertsSummary(summary: summary)
                }
                Spacer()
                Toggle("Show acknowledged", isOn: $showAcknowledged)
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, Theme.pagePadding)

            MutationError(error: ack.error)
                .padding(.horizontal, Theme.pagePadding)

            switch alerts.state {
            case .idle, .loading:
                LoadingPanel(subject: "cost alerts")
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .failed(let error):
                ProblemPanel(problem: QueryProblem(error), node: node, subject: "cost alerts") {
                    Task { await alerts.refresh() }
                }
                .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .loaded(let value, _):
                if value.notifications.isEmpty {
                    Panel {
                        EmptyState(showAcknowledged ? "No cost alerts have been raised" : "No open cost alerts",
                                   systemImage: "bell",
                                   message: "Budgets in warn or enforce mode raise an alert when a window is about to run out or a sync was blocked.")
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    Spacer(minLength: 0)
                } else {
                    table(value.notifications)
                }
            }
        }
        .observing(alerts, polling: .seconds(60))
        .serverConfirmation(ack, title: "Acknowledge the alert?", confirmLabel: "Acknowledge")
    }

    private func table(_ alerts: [WsModel.PriceBudgetNotification]) -> some View {
        let rows = alerts.map(AlertRow.init)
        return Table(rows, selection: $selection) {
            TableColumn("Severity") { alert in
                SeverityPill(severity: alert.severity)
            }
            .width(min: 80, ideal: 96, max: 120)

            TableColumn("Alert") { alert in
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title.isEmpty ? Format.words(alert.type) : alert.title)
                        .foregroundStyle(.fg)
                    if !alert.message.isEmpty {
                        Text(alert.message)
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 240, ideal: 420)

            TableColumn("Vault") { alert in
                Text(lookup.name(alert.vaultID) ?? CostFormat.provider(alert.providerKey) ?? "—")
                    .foregroundStyle(alert.vaultID == nil ? Color.fgSubtle : Color.fgMuted)
            }
            .width(min: 90, ideal: 150)

            TableColumn("Raised") { alert in
                Text(CostFormat.relative(alert.createdAt) ?? alert.createdAt)
                    .foregroundStyle(.fgSubtle)
                    .monospacedDigit()
                    .help(CostFormat.moment(alert.createdAt) ?? alert.createdAt)
            }
            .width(min: 80, ideal: 100)

            TableColumn("") { alert in
                if alert.acknowledgedAt != nil {
                    Text("Acknowledged")
                        .font(.caption)
                        .foregroundStyle(.fgFaint)
                        .help(CostFormat.moment(alert.acknowledgedAt) ?? "")
                } else {
                    Button("Acknowledge") { Task { await acknowledge(alert.alert) } }
                        .controlSize(.small)
                        .disabled(ack.isRunning)
                }
            }
            .width(min: 100, ideal: 110, max: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let alert = alerts.first(where: { $0.id == id }), alert.acknowledgedAt == nil {
                Button("Acknowledge") { Task { await acknowledge(alert) } }
            }
        }
    }

    private func acknowledge(_ alert: WsModel.PriceBudgetNotification) async {
        await ack.run(.init(notificationID: alert.id, vaultID: alert.vaultID.map { .value($0) }))
    }
}

/// A table row: the alert, identified by its id.
@dynamicMemberLookup
private struct AlertRow: Identifiable {
    var alert: WsModel.PriceBudgetNotification
    var id: Int64 { alert.id }

    subscript<T>(dynamicMember path: KeyPath<WsModel.PriceBudgetNotification, T>) -> T { alert[keyPath: path] }
}

/// "3 open · worst: Warning", from the daemon's summary of every open alert (not just the page).
private struct OpenAlertsSummary: View {
    var summary: WsModel.PriceBudgetNotificationSummary

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(tone: summary.openCount > 0 ? StatusTone(severity: summary.worstSeverity) : .unknown, size: 7)
            Text(summary.openCount == 0 ? "No open alerts"
                 : "\(summary.openCount) open\(summary.worstSeverity.map { " · worst: \(Format.words($0))" } ?? "")")
                .font(.callout)
                .foregroundStyle(.fgMuted)
        }
    }
}

// MARK: - Toolbar bell

/// The toolbar bell for the selected node's open cost alerts. Shown only where the daemon grants the system-wide cost
/// view (super admins: `pricing.budget.status` without a vault); the badge count and tone are the daemon's summary of
/// every open alert (`open_count`, `worst_severity`), never derived from the page shown.
struct CostAlertsBell: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.showsAllNodes, let node = model.selectedNode, let queries = model.liveQueries(for: node) {
            CostAlertsGate(queries: queries)
                .id(node.id)
        }
    }
}

private struct CostAlertsGate: View {
    var queries: NodeQueries

    var body: some View {
        let gate = queries.query(Ws.Pricing.Budget.Status.self, CostQueries.status)
        Group {
            if gate.value != nil {
                CostAlertsBellButton(queries: queries)
            }
        }
        .observing(gate)
    }
}

private struct CostAlertsBellButton: View {
    var queries: NodeQueries

    static let shown: Int64 = 8

    @Environment(AppModel.self) private var model
    @AppStorage(CostTab.storageKey) private var tab = CostTab.overview
    @State private var isOpen = false

    var body: some View {
        let alerts = queries.query(Ws.Pricing.Notifications.List.self,
                                   .init(limit: Self.shown, includeAcknowledged: false))
        let summary = alerts.value?.summary
        let count = summary?.openCount ?? 0
        let tone = StatusTone(severity: summary?.worstSeverity)

        Button {
            isOpen.toggle()
        } label: {
            if count > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bell.badge")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(tone.color, Color.primary)
                    Text(count > 99 ? "99+" : count.formatted())
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tone.color)
                }
            } else {
                Image(systemName: "bell")
            }
        }
        .help(label(alerts))
        .accessibilityLabel(label(alerts))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            CostAlertsPopover(queries: queries, alerts: alerts) {
                isOpen = false
                tab = .alerts
                model.select(.cost)
            }
        }
        .observing(alerts, polling: .seconds(60))
    }

    private func label(_ alerts: NodeQuery<Ws.Pricing.Notifications.List>) -> String {
        if alerts.error != nil, alerts.value == nil { return "Cost alerts unavailable" }
        guard let count = alerts.value?.summary.openCount, count > 0 else { return "Cost alerts" }
        return "\(count) open cost alert\(count == 1 ? "" : "s")"
    }
}

private struct CostAlertsPopover: View {
    var queries: NodeQueries
    var alerts: NodeQuery<Ws.Pricing.Notifications.List>
    var openAll: () -> Void

    @State private var ack: NodeMutation<Ws.Pricing.Notifications.Ack>

    init(queries: NodeQueries, alerts: NodeQuery<Ws.Pricing.Notifications.List>, openAll: @escaping () -> Void) {
        self.queries = queries
        self.alerts = alerts
        self.openAll = openAll
        _ack = State(initialValue: NodeMutation(Ws.Pricing.Notifications.Ack.self, on: queries,
                                                invalidating: CostQueries.invalidated))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Cost alerts")
                    .font(.headline)
                    .foregroundStyle(.fg)
                Spacer()
                Button("Open Cost Alerts", action: openAll)
                    .buttonStyle(.link)
                    .font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            Group {
                switch alerts.state {
                case .idle, .loading:
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 80)
                case .failed(let error):
                    InlineProblem(error: error, subject: "cost alerts")
                        .padding(14)
                case .loaded(let value, _):
                    if value.notifications.isEmpty {
                        Text("No open alerts.")
                            .font(.callout)
                            .foregroundStyle(.fgSubtle)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(value.notifications, id: \.id) { alert in
                                    row(alert)
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 360)
                        let hidden = value.summary.openCount - Int64(value.notifications.count)
                        if hidden > 0 {
                            Divider()
                            Button("View all \(value.summary.openCount) alerts", action: openAll)
                                .buttonStyle(.link)
                                .font(.callout)
                                .frame(maxWidth: .infinity)
                                .padding(10)
                        }
                    }
                }
            }

            if ack.error != nil {
                MutationError(error: ack.error)
                    .padding(10)
            }
        }
        .frame(width: 380)
    }

    private func row(_ alert: WsModel.PriceBudgetNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(tone: StatusTone(severity: alert.severity), size: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(alert.title.isEmpty ? "Budget alert" : alert.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.fg)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(CostFormat.relative(alert.createdAt) ?? "")
                        .font(.caption)
                        .foregroundStyle(.fgFaint)
                        .monospacedDigit()
                }
                if !alert.message.isEmpty {
                    Text(alert.message)
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                        .lineLimit(2)
                }
            }
            Button("Acknowledge", systemImage: "checkmark") {
                Task { await ack.run(.init(notificationID: alert.id, vaultID: alert.vaultID.map { .value($0) })) }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Acknowledge")
            .disabled(ack.isRunning)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}
