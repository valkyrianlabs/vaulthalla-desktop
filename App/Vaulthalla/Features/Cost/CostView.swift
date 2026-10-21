import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Cost control: S3 price budgets (global, per provider, per vault), what they recorded, the spend windows and their
/// projections, cost alerts and override requests. The system-wide view is the daemon's to grant (super admins);
/// anyone else gets its refusal as a calm "no access" state.
struct CostView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        if let queries = model.liveQueries(for: node) {
            CostScreen(node: node, queries: queries)
                .environment(queries)
        } else {
            PlaceholderSection(node: node, section: .cost)
        }
    }
}

/// The page's tabs. Kept in the app's defaults so the alerts bell can open the Alerts tab.
enum CostTab: String, CaseIterable, Identifiable {
    case overview, alerts, budgets, ledger

    static let storageKey = "cost.tab"

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .alerts: "Alerts"
        case .budgets: "Budgets"
        case .ledger: "Ledger"
        }
    }
}

/// The queries the Cost screens share (one key each, so the bell and the page share one fetch).
enum CostQueries {
    /// `pricing.budget.status` system-wide: super admins only, so it also tells whether the account may see cost
    /// control at all.
    static let status = Ws.Pricing.Budget.Status.Payload(limit: 20, includeInactive: true)
    static func alerts(includeAcknowledged: Bool) -> Ws.Pricing.Notifications.List.Payload {
        .init(limit: 100, includeAcknowledged: includeAcknowledged)
    }
    /// What a cost alert acknowledgement or a budget change makes stale.
    static let invalidated = ["pricing", "stats.pricing"]
}

private struct CostScreen: View {
    var node: Node
    var queries: NodeQueries

    @Environment(AppModel.self) private var model
    @AppStorage(CostTab.storageKey) private var tab = CostTab.overview

    var body: some View {
        let status = queries.query(Ws.Pricing.Budget.Status.self, CostQueries.status)
        let vaults = queries.query(Ws.Storage.Vault.List.self)
        let lookup = VaultLookup(vaults.value?.vaults)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(eyebrow: node.displayName, title: "Cost",
                          subtitle: "Budgets for S3 provider spend: what syncs may cost, what they did cost, and what happens when a budget runs out.") {
                let connection = model.status(for: node)
                StatusBadge(label: connection.label, tone: connection.tone, pulse: connection.isTransitional)
            }
            .padding([.horizontal, .top], Theme.pagePadding)
            .padding(.bottom, 14)

            switch status.state {
            case .idle, .loading:
                LoadingPanel(subject: "cost control")
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .failed(let error):
                ProblemPanel(problem: QueryProblem(error), node: node, subject: "cost control") {
                    Task { await status.refresh() }
                }
                .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .loaded(let value, let at):
                Picker("Section", selection: $tab) {
                    ForEach(CostTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 12)

                StaleBanner(node: node, updatedAt: at, refreshError: status.refreshError, connected: queries.isConnected)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 8)

                switch tab {
                case .overview:
                    CostOverview(node: node, queries: queries, status: value, lookup: lookup)
                case .alerts:
                    CostAlertsList(node: node, queries: queries, lookup: lookup)
                case .budgets:
                    BudgetPoliciesView(queries: queries, policies: value.policies, lookup: lookup,
                                       vaultsLoading: vaults.value == nil && vaults.error == nil)
                case .ledger:
                    CostLedgerView(queries: queries, lookup: lookup)
                }
            }
        }
        .observing(status, polling: .seconds(60))
        .observing(vaults)
        #if DEBUG
        .task { debugSelectTab() }
        #endif
    }

    #if DEBUG
    /// `-VHDebugCostTab <tab>` opens a tab (DebugSnapshot).
    private func debugSelectTab() {
        if let raw = UserDefaults.standard.string(forKey: "VHDebugCostTab"), let chosen = CostTab(rawValue: raw) {
            tab = chosen
        }
    }
    #endif
}

/// Vault names for ids, and the S3 vaults budgets apply to. A vault the account can't list reads "Vault #id".
struct VaultLookup {
    var vaults: [WsModel.Vault]
    var isKnown: Bool

    init(_ vaults: [WsModel.Vault]?) {
        self.vaults = vaults ?? []
        isKnown = vaults != nil
    }

    var s3: [WsModel.Vault] {
        vaults.filter { $0.type == WsModel.Vault.TypeValue.s3 }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func name(_ id: Int64?) -> String? {
        guard let id else { return nil }
        return vaults.first { $0.id == id }?.name ?? "Vault #\(id)"
    }
}

/// A money figure that may be unknown: "not estimated" in faint text, never $0.00.
struct MoneyText: View {
    var amount: String?
    var currency: String?
    var unknown = CostFormat.notEstimated

    var body: some View {
        if let text = CostFormat.money(amount, currency) {
            Text(text).monospacedDigit()
        } else {
            Text(unknown).foregroundStyle(.fgFaint)
        }
    }
}

/// A stat tile for money: the amount, or "not estimated" with why.
struct MoneyTile: View {
    var label: String
    var amount: String?
    var currency: String?
    var hint: String?
    var missingHint: String?

    var body: some View {
        let text = CostFormat.money(amount, currency)
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.weight(.medium))
                .tracking(0.6)
                .foregroundStyle(.fgSubtle)
                .lineLimit(1)
            if let text {
                Text(text)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.fg)
                    .lineLimit(1)
            } else {
                Text(CostFormat.notEstimated)
                    .font(.body)
                    .foregroundStyle(.fgFaint)
                    .frame(minHeight: 24, alignment: .leading)
            }
            if let line = text == nil ? missingHint : hint {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(.line, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A severity word as a small tinted pill (the backend's severity; unknown words stay neutral).
struct SeverityPill: View {
    var severity: String?

    var body: some View {
        StatusBadge(label: severity.map(Format.words) ?? "Unknown", tone: StatusTone(severity: severity))
    }
}

#if DEBUG
#Preview("Cost (preview data)") {
    let model = PreviewSamples.liveModel()
    CostView(node: PreviewSamples.nodes[1])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1100, height: 760)
}

#Preview("No access (preview data)") {
    let model = PreviewSamples.liveModel()
    CostView(node: PreviewSamples.nodes[3])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 900, height: 520)
}
#endif
