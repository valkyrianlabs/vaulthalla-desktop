import SwiftUI
import VHContract
import VHCore
import VHNodes

/// The dashboard figures (`stats.pricing.budget`), each budget window's spend and projection, override requests, and
/// each S3 vault's provider versioning estimate.
struct CostOverview: View {
    var node: Node
    var queries: NodeQueries
    var status: Ws.Pricing.Budget.Status.Response
    var lookup: VaultLookup

    var body: some View {
        let stats = queries.query(Ws.Stats.Pricing.Budget.self, .init())

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.stackSpacing + 8) {
                figures(stats)

                Panel(title: "Budget windows",
                      subtitle: "Spend so far in each budgeted day or month, and where it is heading.") {
                    BudgetWindows(trends: status.trends, lookup: lookup)
                }

                Panel(title: "Override requests",
                      subtitle: "A one-time pass for a sync an enforced budget blocked. Only super admins decide.") {
                    OverrideRequests(queries: queries, overrides: status.overrides, lookup: lookup)
                }

                Panel(title: "Provider versioning",
                      subtitle: "What keeping object versions in each bucket costs or would cost. Each vault has its own estimate, basis and confidence, so they aren't added up.") {
                    ProviderVersioningLinks(queries: queries, lookup: lookup)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, Theme.pagePadding)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .observing(stats, polling: .seconds(60))
    }

    @ViewBuilder
    private func figures(_ stats: NodeQuery<Ws.Stats.Pricing.Budget>) -> some View {
        switch stats.state {
        case .idle, .loading:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .fill(.surface1)
                        .frame(height: 74)
                }
            }
        case .failed(let error):
            InlineProblem(error: error, subject: "the budget figures")
        case .loaded(let response, _):
            let s = response.stats
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                StatTile(label: "Active budgets", value: s.activePolicies.formatted(), hint: "Global, provider, vault")
                StatTile(label: "Blocked syncs (24 h)", value: s.blockedSyncs24h.formatted(), hint: "By enforced budgets",
                         tone: s.blockedSyncs24h > 0 ? .warn : nil)
                StatTile(label: "Open alerts", value: s.unacknowledgedNotifications.formatted(), hint: "Not acknowledged",
                         tone: s.criticalNotifications > 0 ? .danger : s.warningNotifications > 0 ? .warn : nil)
                StatTile(label: "Pending overrides", value: s.pendingOverrides.formatted(), hint: "Awaiting a decision")
                MoneyTile(label: "Spend this month", amount: s.currentMonthlySpend, currency: s.currency,
                          hint: "Within monthly budgets", missingHint: "Needs a monthly budget")
                MoneyTile(label: "Projected month", amount: s.projectedMonthlySpend, currency: s.currency,
                          missingHint: "Not enough data yet")
            }
        }
    }
}

// MARK: - Budget windows

private struct BudgetWindows: View {
    var trends: [WsModel.PriceBudgetTrendStats]
    var lookup: VaultLookup

    var body: some View {
        if trends.isEmpty {
            Text("No budget has a spend limit yet, so there are no budget windows to track.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 0) {
                GridRow {
                    ForEach(["Budget", "Used", "Projected", "Runs out", "Confidence"], id: \.self) { title in
                        Text(title)
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.fgSubtle)
                .padding(.bottom, 8)

                ForEach(Array(trends.enumerated()), id: \.offset) { _, trend in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    row(trend)
                        .padding(.vertical, 9)
                }
            }
        }
    }

    private func row(_ trend: WsModel.PriceBudgetTrendStats) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(target(trend))
                    .foregroundStyle(.fg)
                Text("\(CostFormat.scope(trend.scope)) · \(CostFormat.window(trend.windowType))")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }
            .frame(minWidth: 180, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    MoneyText(amount: trend.totalCost, currency: trend.currency)
                        .foregroundStyle(.fg)
                    Text("of").foregroundStyle(.fgSubtle)
                    MoneyText(amount: trend.limit, currency: trend.currency, unknown: "no limit")
                    Spacer(minLength: 8)
                    if trend.limit != nil {
                        Text(trend.percentUsed.formatted(.percent.precision(.fractionLength(0))))
                            .foregroundStyle(.fgSubtle)
                            .monospacedDigit()
                    }
                }
                .font(.callout)
                if trend.limit != nil {
                    Meter(fraction: trend.percentUsed)
                }
            }
            .frame(minWidth: 220)

            VStack(alignment: .leading, spacing: 2) {
                MoneyText(amount: trend.projectedWindowCost, currency: trend.currency)
                if CostFormat.isPositive(trend.projectedOverage), let over = CostFormat.money(trend.projectedOverage, trend.currency) {
                    Text("over by \(over)")
                        .font(.caption)
                        .foregroundStyle(StatusTone.warn.color)
                }
            }
            .font(.callout)

            Text(CostFormat.relative(trend.predictedExhaustionAt) ?? "—")
                .font(.callout)
                .foregroundStyle(trend.predictedExhaustionAt == nil ? Color.fgFaint : Color.fgMuted)
                .help(CostFormat.moment(trend.predictedExhaustionAt) ?? "Not projected to run out in this window.")

            Group {
                if trend.confidence.isEmpty || trend.confidence == "none" {
                    Text("—")
                        .foregroundStyle(.fgFaint)
                        .help("Not enough recorded spend to project this window yet.")
                } else {
                    Text(Format.words(trend.confidence))
                        .foregroundStyle(.fgMuted)
                }
            }
            .font(.callout)
        }
    }

    private func target(_ trend: WsModel.PriceBudgetTrendStats) -> String {
        switch trend.scope {
        case WsModel.PriceBudgetPolicy.Scope.provider: CostFormat.provider(trend.providerKey) ?? "Provider"
        case WsModel.PriceBudgetPolicy.Scope.vault: lookup.name(trend.vaultID) ?? "Vault"
        case WsModel.PriceBudgetPolicy.Scope.gatewayCredential:
            "Gateway key #\(trend.gatewayCredentialID.map(String.init) ?? "?")"
        case WsModel.PriceBudgetPolicy.Scope.gatewayCredentialVault:
            "Gateway key #\(trend.gatewayCredentialID.map(String.init) ?? "?") on \(lookup.name(trend.vaultID) ?? "a vault")"
        default: "All S3 storage"
        }
    }
}

/// How much of a budget window is used. Accent until the daemon's own warning thresholds are crossed.
private struct Meter: View {
    var fraction: Double

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        Capsule()
            .fill(.surface3)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(fraction >= 0.9 ? StatusTone.warn.color : Color.accentFill)
                        .frame(width: proxy.size.width * clamped)
                }
            }
            .accessibilityLabel("Budget used")
            .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}

// MARK: - Overrides

private struct OverrideRequests: View {
    var queries: NodeQueries
    var overrides: [WsModel.PriceBudgetOverride]
    var lookup: VaultLookup

    @State private var approve: NodeMutation<Ws.Pricing.Budget.Override.Approve>
    @State private var deny: NodeMutation<Ws.Pricing.Budget.Override.Deny>
    @State private var deciding: (override: WsModel.PriceBudgetOverride, approve: Bool)?

    init(queries: NodeQueries, overrides: [WsModel.PriceBudgetOverride], lookup: VaultLookup) {
        self.queries = queries
        self.overrides = overrides
        self.lookup = lookup
        _approve = State(initialValue: NodeMutation(Ws.Pricing.Budget.Override.Approve.self, on: queries,
                                                    invalidating: CostQueries.invalidated))
        _deny = State(initialValue: NodeMutation(Ws.Pricing.Budget.Override.Deny.self, on: queries,
                                                 invalidating: CostQueries.invalidated))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if overrides.isEmpty {
                Text("No override requests.")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(overrides.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        row(item)
                            .padding(.vertical, 9)
                    }
                }
            }
            MutationError(error: approve.error ?? deny.error)
        }
        .confirmationDialog(dialogTitle, isPresented: decidingBinding, titleVisibility: .visible,
                            presenting: deciding) { choice in
            Button(choice.approve ? "Approve" : "Deny", role: choice.approve ? nil : .destructive) {
                Task { await decide(choice.override, approve: choice.approve) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            let vault = lookup.name(choice.override.vaultID) ?? "this vault"
            if choice.approve {
                let estimate = CostFormat.money(choice.override.estimatedCost, choice.override.currency)
                Text("The next sync of \(vault) may exceed its enforced budget once\(estimate.map { " (estimated \($0))" } ?? "").")
            } else {
                Text("The blocked sync of \(vault) stays blocked until spend fits the budget or a new override is approved.")
            }
        }
        .serverConfirmation(approve, title: "Approve the override?", confirmLabel: "Approve")
        .serverConfirmation(deny, title: "Deny the override?", confirmLabel: "Deny")
    }

    private func row(_ item: WsModel.PriceBudgetOverride) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(item.id)").foregroundStyle(.fgSubtle).monospacedDigit()
                    Text(lookup.name(item.vaultID) ?? "—").foregroundStyle(.fg)
                }
                if let reason = item.reason, !reason.isEmpty {
                    Text("“\(reason)”")
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusBadge(label: Format.words(item.status),
                        tone: item.status == WsModel.PriceBudgetOverride.Status.requested ? .info : .unknown)
            MoneyText(amount: item.estimatedCost, currency: item.currency)
                .font(.callout)
                .frame(width: 100, alignment: .trailing)
            Text(CostFormat.relative(item.createdAt) ?? "—")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .frame(width: 90, alignment: .trailing)
                .help(CostFormat.moment(item.createdAt) ?? item.createdAt)
            if item.status == WsModel.PriceBudgetOverride.Status.requested {
                HStack(spacing: 6) {
                    Button("Approve…") { deciding = (item, true) }
                    Button("Deny…") { deciding = (item, false) }
                }
                .controlSize(.small)
                .disabled(approve.isRunning || deny.isRunning)
            }
        }
    }

    private var dialogTitle: String {
        guard let deciding else { return "" }
        return deciding.approve ? "Approve override #\(deciding.override.id)?" : "Deny override #\(deciding.override.id)?"
    }

    private var decidingBinding: Binding<Bool> {
        Binding(get: { deciding != nil }, set: { if !$0 { deciding = nil } })
    }

    private func decide(_ item: WsModel.PriceBudgetOverride, approve shouldApprove: Bool) async {
        if shouldApprove {
            deny.reset()
            await approve.run(.init(overrideID: item.id))
        } else {
            approve.reset()
            await deny.run(.init(overrideID: item.id))
        }
    }
}

// MARK: - Provider versioning

/// One button per S3 vault; each opens that vault's provider versioning estimate (`recovery.costs`), the panel the
/// web console links to from here.
private struct ProviderVersioningLinks: View {
    var queries: NodeQueries
    var lookup: VaultLookup

    @State private var shown: Int64?

    var body: some View {
        if !lookup.isKnown {
            ProgressView().controlSize(.small)
        } else if lookup.s3.isEmpty {
            Text("No S3 vaults. Provider versioning applies to vaults backed by a bucket.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
        } else {
            FlowLayout(spacing: 8) {
                ForEach(lookup.s3, id: \.id) { vault in
                    Button {
                        shown = vault.id
                    } label: {
                        Label(vault.name, systemImage: "cloud")
                    }
                    .popover(isPresented: Binding(get: { shown == vault.id }, set: { if !$0 { shown = nil } }),
                             arrowEdge: .bottom) {
                        RecoveryCostSummary(vault: vault, queries: queries)
                    }
                }
            }
        }
    }
}

/// A vault's provider versioning cost, in brief: the daemon's estimates with their basis, or why there are none.
private struct RecoveryCostSummary: View {
    var vault: WsModel.Vault
    var queries: NodeQueries

    var body: some View {
        let costs = queries.query(Ws.Recovery.Costs.self, .init(vaultID: vault.id))
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vault.name)
                    .font(.headline)
                    .foregroundStyle(.fg)
                Text("Provider versioning cost · estimates, not provider invoices")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }
            InlineQuery(query: costs, subject: "this vault's cost estimates") { response in
                report(response.costs)
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .observing(costs)
    }

    @ViewBuilder
    private func report(_ report: WsModel.RecoveryCostReport) -> some View {
        let active = report.phase == "active"
        VStack(alignment: .leading, spacing: 10) {
            if !report.priced {
                Callout(tone: .info, systemImage: "info.circle") {
                    Text(report.unpricedReason ?? "This vault's versioning can't be priced.")
                }
            }
            DefinitionList(items: [
                ("Phase", active ? "Versioning on" : "Before versioning"),
                (active ? "This month so far" : "Would cost monthly",
                 figure(active ? report.currentMonthToDate : report.preActivationMonthly)),
                ("Projected monthly", figure(active ? report.currentMonthProjected : report.projectedMonthly)),
                ("Noncurrent versions", report.history.knownNoncurrentVersions.formatted()
                    + " · " + Format.bytes(report.history.knownNoncurrentBytes)),
                ("Confidence", Format.words(report.confidence)),
                ("Price catalog", catalog(report.catalog)),
            ], termWidth: 140)
            if report.alert.exceeded, let threshold = CostFormat.money(report.alert.threshold) {
                Label("Above this vault's monthly alert of \(threshold).", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(StatusTone.warn.color)
            }
            if let computed = CostFormat.relative(report.computedAt) {
                Text("Computed \(computed)")
                    .font(.caption)
                    .foregroundStyle(.fgFaint)
            }
        }
    }

    /// The expected amount and its range, or "not estimated" with the daemon's reason.
    private func figure(_ figure: WsModel.RecoveryCostFigure) -> String {
        guard let expected = CostFormat.money(figure.expected) else {
            return figure.reason.map { "\(CostFormat.notEstimated) (\($0))" } ?? CostFormat.notEstimated
        }
        if let low = CostFormat.money(figure.low), let high = CostFormat.money(figure.high), low != high {
            return "\(expected) (\(low)–\(high), \(figure.basis))"
        }
        return "\(expected) (\(figure.basis))"
    }

    private func catalog(_ catalog: WsModel.RecoveryCostCatalog) -> String {
        var words = [catalog.verified ? "Verified" : "Unverified"]
        if catalog.stale { words.append("stale") }
        if let version = catalog.version { words.append(version) }
        return words.joined(separator: " · ")
    }
}
