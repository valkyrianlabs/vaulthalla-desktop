import SwiftUI
import VHContract
import VHCore
import VHNodes

/// What a budget applies to: everything, one provider, or one S3 vault.
struct BudgetTarget: Identifiable, Hashable {
    var scope: Ws.Pricing.Budget.Policy.Upsert.Payload.Scope
    var title: String
    var detail: String
    var providerKey: String?
    var vaultID: Int64?

    var id: String { "\(scope.rawValue):\(providerKey ?? ""):\(vaultID.map(String.init) ?? "")" }

    /// The active policy for this target, else the latest disabled one.
    func policy(in policies: [WsModel.PriceBudgetPolicy]) -> WsModel.PriceBudgetPolicy? {
        let matches = policies.filter {
            $0.scope == scope.rawValue && $0.providerKey == providerKey && $0.vaultID == vaultID
                && $0.gatewayCredentialID == nil
        }
        return matches.first(where: \.isActive) ?? matches.first
    }
}

/// The price budget policies (`pricing.budget.status` → policies): one row per system scope and per S3 vault, each
/// edited in a sheet (`pricing.budget.policy.upsert` / `.disable`).
struct BudgetPoliciesView: View {
    var queries: NodeQueries
    var policies: [WsModel.PriceBudgetPolicy]
    var lookup: VaultLookup
    var vaultsLoading: Bool

    @State private var selection: String?
    @State private var editing: BudgetTarget?

    private struct Row: Identifiable {
        var target: BudgetTarget
        var policy: WsModel.PriceBudgetPolicy?
        var id: String { target.id }
    }

    var body: some View {
        let system = systemTargets.map { Row(target: $0, policy: $0.policy(in: policies)) }
        let vaults = vaultTargets.map { Row(target: $0, policy: $0.policy(in: policies)) }
        let all = system + vaults

        VStack(alignment: .leading, spacing: 10) {
            Text(inheritedNote(system))
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.pagePadding)

            Table(all, selection: $selection) {
                TableColumn("Applies to") { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.target.title).foregroundStyle(.fg)
                        Text(row.target.detail)
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                    .padding(.vertical, 3)
                }
                .width(min: 180, ideal: 260)

                TableColumn("Mode") { row in
                    ModeBadge(policy: row.policy)
                }
                .width(min: 80, ideal: 100, max: 120)

                TableColumn("Limits") { row in
                    Text(CostFormat.limits(row.policy))
                        .foregroundStyle(row.policy?.isActive == true ? Color.fgMuted : Color.fgFaint)
                        .monospacedDigit()
                }
                .width(min: 160, ideal: 300)

                TableColumn("Price catalog") { row in
                    Text(catalogText(row.policy))
                        .foregroundStyle(.fgSubtle)
                }
                .width(min: 120, ideal: 180)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let row = all.first(where: { $0.id == id }) {
                    Button("Edit Budget…") { editing = row.target }
                }
            } primaryAction: { ids in
                if let id = ids.first, let row = all.first(where: { $0.id == id }) { editing = row.target }
            }

            if vaults.isEmpty {
                Text(vaultsLoading ? "Loading vaults…" : "No S3 vaults. Vault budgets apply to vaults stored on S3-compatible providers.")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 12)
            }
        }
        .sheet(item: $editing) { target in
            BudgetPolicySheet(target: target, policy: target.policy(in: policies), queries: queries)
        }
        #if DEBUG
        .task { debugOpenBudget(all.map(\.target)) }
        #endif
    }

    private var systemTargets: [BudgetTarget] {
        [BudgetTarget(scope: .global, title: "All S3 storage", detail: "Combined spend across every provider and vault")]
            + CostFormat.providers.map {
                BudgetTarget(scope: .provider, title: $0.label, detail: "Every vault on this provider", providerKey: $0.key)
            }
    }

    private var vaultTargets: [BudgetTarget] {
        lookup.s3.map { BudgetTarget(scope: .vault, title: $0.name, detail: "Vault #\($0.id)", vaultID: $0.id) }
    }

    private func inheritedNote(_ system: [Row]) -> String {
        let inherited = system.compactMap { row -> String? in
            guard let policy = row.policy, policy.isActive, policy.mode != WsModel.PriceBudgetPolicy.Mode.off else { return nil }
            if let monthly = CostFormat.money(policy.maxMonthlyCost, policy.currency) {
                return "\(row.target.title) (\(monthly)/month)"
            }
            return "\(row.target.title) (\(CostFormat.mode(policy.mode).lowercased()))"
        }
        if inherited.isEmpty {
            return "Every sync is checked against all budgets that match it. No system budget is active, so only a vault's own budget applies."
        }
        return "Every sync is checked against all budgets that match it. Each vault is also clamped by \(inherited.joined(separator: ", "))."
    }

    private func catalogText(_ policy: WsModel.PriceBudgetPolicy?) -> String {
        guard let policy, policy.isActive else { return "—" }
        var parts = [policy.requireVerifiedCatalog ? "Verified only" : "Any catalog"]
        if policy.allowStaleCatalog { parts.append("stale allowed") }
        return parts.joined(separator: ", ")
    }

    #if DEBUG
    /// `-VHDebugBudget <scope:provider:vault>` (a row id, e.g. `global::`) opens its sheet (DebugSnapshot).
    private func debugOpenBudget(_ targets: [BudgetTarget]) {
        guard editing == nil, let id = UserDefaults.standard.string(forKey: "VHDebugBudget") else { return }
        editing = targets.first { $0.id == id }
    }
    #endif
}

/// A policy's mode as configuration, not health: accent for the modes that act.
struct ModeBadge: View {
    var policy: WsModel.PriceBudgetPolicy?

    var body: some View {
        if let policy, policy.isActive {
            let acts = policy.mode == WsModel.PriceBudgetPolicy.Mode.warn || policy.mode == WsModel.PriceBudgetPolicy.Mode.enforce
            Text(CostFormat.mode(policy.mode))
                .font(.caption.weight(.medium))
                .foregroundStyle(acts ? Color.accentText : Color.fgMuted)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(acts ? Color.accentSoft : Color.surface2, in: Capsule())
                .overlay { Capsule().strokeBorder(acts ? Color.accentLine : Color.line, lineWidth: 1) }
        } else {
            Text("Not set")
                .font(.caption)
                .foregroundStyle(.fgFaint)
        }
    }
}

// MARK: - Editing

/// Creates or replaces the budget of one target (`pricing.budget.policy.upsert`), or disables it.
struct BudgetPolicySheet: View {
    var target: BudgetTarget
    var policy: WsModel.PriceBudgetPolicy?

    private typealias Mode = Ws.Pricing.Budget.Policy.Upsert.Payload.Mode

    @State private var mode: Mode
    @State private var currency: String
    @State private var run: String
    @State private var daily: String
    @State private var monthly: String
    @State private var requireVerified: Bool
    @State private var allowStale: Bool
    @State private var maxAgeHours: String
    @State private var confirmDisable = false
    @State private var upsert: NodeMutation<Ws.Pricing.Budget.Policy.Upsert>
    @State private var disable: NodeMutation<Ws.Pricing.Budget.Policy.Disable>
    @Environment(\.dismiss) private var dismiss

    init(target: BudgetTarget, policy: WsModel.PriceBudgetPolicy?, queries: NodeQueries) {
        self.target = target
        self.policy = policy
        let active = policy?.isActive == true
        _mode = State(initialValue: active ? (policy.flatMap { Mode(rawValue: $0.mode) } ?? .off) : .off)
        _currency = State(initialValue: policy?.currency ?? "USD")
        _run = State(initialValue: Self.plain(policy?.maxRunCost))
        _daily = State(initialValue: Self.plain(policy?.maxDailyCost))
        _monthly = State(initialValue: Self.plain(policy?.maxMonthlyCost))
        _requireVerified = State(initialValue: policy?.requireVerifiedCatalog ?? true)
        _allowStale = State(initialValue: policy?.allowStaleCatalog ?? false)
        let seconds = policy.map { $0.maxCatalogAgeSeconds } ?? 43_200
        _maxAgeHours = State(initialValue: seconds.map { ($0 % 3600 == 0 ? String($0 / 3600) : String(format: "%.2f", Double($0) / 3600)) } ?? "")
        _upsert = State(initialValue: NodeMutation(Ws.Pricing.Budget.Policy.Upsert.self, on: queries,
                                                   invalidating: CostQueries.invalidated))
        _disable = State(initialValue: NodeMutation(Ws.Pricing.Budget.Policy.Disable.self, on: queries,
                                                    invalidating: CostQueries.invalidated))
    }

    /// "25.00000000" → "25", "12.50000000" → "12.5": the daemon pads to 8 digits.
    private static func plain(_ amount: String?) -> String {
        guard let amount, let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else { return "" }
        return NSDecimalNumber(decimal: value).stringValue
    }

    private var currencyValid: Bool { currency.wholeMatch(of: /[A-Za-z0-9]{3,8}/) != nil }
    private func limitValid(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespaces).isEmpty || CostFormat.isDecimal(text) }
    private var maxAgeSeconds: Int64? {
        let text = maxAgeHours.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let hours = Double(text), hours > 0 else { return nil }
        return Int64((hours * 3600).rounded())
    }
    private var maxAgeValid: Bool { maxAgeHours.trimmingCharacters(in: .whitespaces).isEmpty || maxAgeSeconds != nil }
    private var valid: Bool { currencyValid && limitValid(run) && limitValid(daily) && limitValid(monthly) && maxAgeValid }
    private var busy: Bool { upsert.isRunning || disable.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text(CostFormat.mode($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Budget · \(target.title)")
                            .font(.headline)
                        Text(policy?.isActive == true ? "Active budget." : "No active budget. Saving one starts applying it.")
                            .foregroundStyle(.fgSubtle)
                    }
                } footer: {
                    Text(CostFormat.modeHint(mode.rawValue))
                        .foregroundStyle(.fgSubtle)
                }

                Section {
                    TextField("Currency", text: $currency)
                        .onChange(of: currency) { _, value in
                            if value != value.uppercased() { currency = value.uppercased() }
                        }
                    limitField("Per sync run", text: $run)
                    limitField("Per day", text: $daily)
                    limitField("Per month", text: $monthly)
                } header: {
                    Text("Limits")
                } footer: {
                    if !currencyValid {
                        Text("Use a 3–8 letter currency code.").foregroundStyle(StatusTone.danger.color)
                    } else if !(limitValid(run) && limitValid(daily) && limitValid(monthly)) {
                        Text("Use a plain amount, such as 25 or 12.50.").foregroundStyle(StatusTone.danger.color)
                    } else if mode != .off, [run, daily, monthly].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        Text("With no limits set, this budget only records spend.").foregroundStyle(.fgSubtle)
                    } else {
                        Text("Empty means no limit for that window.").foregroundStyle(.fgSubtle)
                    }
                }

                Section {
                    Toggle("Require a verified catalog", isOn: $requireVerified)
                    Toggle("Allow a stale catalog", isOn: $allowStale)
                    TextField("Maximum catalog age (hours)", text: $maxAgeHours, prompt: Text("12"))
                } header: {
                    Text("Price catalog")
                } footer: {
                    Text(maxAgeValid
                         ? "Estimates from an unverified or too-old catalog count as unknown cost, unless allowed here."
                         : "The maximum age must be more than zero hours.")
                        .foregroundStyle(maxAgeValid ? Color.fgSubtle : StatusTone.danger.color)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            MutationError(error: upsert.error ?? disable.error)
                .padding(.horizontal, 20)

            HStack {
                if policy?.isActive == true {
                    Button("Disable…", role: .destructive) { confirmDisable = true }
                        .disabled(busy)
                }
                if busy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Budget") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid || busy)
            }
            .padding(20)
        }
        .frame(width: 520)
        .confirmationDialog("Disable the \(target.title) budget?", isPresented: $confirmDisable, titleVisibility: .visible) {
            Button("Disable Budget", role: .destructive) { Task { await turnOff() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its limits stop applying immediately. Spend already recorded stays in the ledger.")
        }
        .serverConfirmation(upsert, title: "Save the budget?", confirmLabel: "Save")
        .serverConfirmation(disable, title: "Disable the budget?", confirmLabel: "Disable", role: .destructive)
        .interactiveDismissDisabled(busy)
    }

    private func limitField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text, prompt: Text("No limit"))
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
    }

    private func amount(_ text: String) -> Nullable<String> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? .null : .value(trimmed)
    }

    private func save() async {
        let payload = Ws.Pricing.Budget.Policy.Upsert.Payload(
            scope: target.scope, providerKey: target.providerKey.map { .value($0) },
            vaultID: target.vaultID.map { .value($0) }, mode: .value(mode), currency: .value(currency.uppercased()),
            maxRunCost: amount(run), maxDailyCost: amount(daily), maxMonthlyCost: amount(monthly),
            requireVerifiedCatalog: requireVerified, allowStaleCatalog: allowStale,
            maxCatalogAgeSeconds: maxAgeSeconds.map { .value($0) } ?? .null)
        disable.reset()
        if await upsert.run(payload) != nil { dismiss() }
    }

    private func turnOff() async {
        guard let scope = Ws.Pricing.Budget.Policy.Disable.Payload.Scope(rawValue: target.scope.rawValue) else { return }
        upsert.reset()
        let payload = Ws.Pricing.Budget.Policy.Disable.Payload(
            scope: scope, providerKey: target.providerKey.map { .value($0) }, vaultID: target.vaultID.map { .value($0) })
        if await disable.run(payload) != nil { dismiss() }
    }
}
