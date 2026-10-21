import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Every gateway key the account may manage (`s3.gateway.credentials.list`, revoked ones included).
struct GatewayKeysTab: View {
    var node: Node
    var queries: NodeQueries
    var list: NodeQuery<Ws.S3.Gateway.Credentials.List>
    @Binding var selection: Int64?
    var onCreate: () -> Void

    @State private var sortOrder = [KeyPathComparator(\GatewayKeyRow.sortName)]
    @State private var filter = ""

    var body: some View {
        switch list.state {
        case .idle, .loading:
            LoadingPanel(subject: "gateway keys")
                .padding(.horizontal, Theme.pagePadding)
            Spacer(minLength: 0)
        case .failed(let error):
            ProblemPanel(problem: QueryProblem(error), node: node, subject: "gateway keys") {
                Task { await list.refresh() }
            }
            .padding(.horizontal, Theme.pagePadding)
            Spacer(minLength: 0)
        case .loaded(let value, let at):
            StaleBanner(node: node, updatedAt: at, refreshError: list.refreshError, connected: queries.isConnected)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 8)
            if value.credentials.isEmpty {
                Panel {
                    EmptyState("No gateway keys yet", systemImage: "key",
                               message: "A gateway key lets an S3 client (aws, rclone, mc, backup tools) read and write bound buckets as a Vaulthalla user.") {
                        Button("Create Key…", action: onCreate)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            } else {
                TextField("Filter keys", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 8)
                table(rows(value.credentials))
            }
        }
    }

    private func table(_ rows: [GatewayKeyRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.sortName) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.credential.name)
                        .foregroundStyle(row.credential.enabled ? Color.fg : Color.fgSubtle)
                    Text(row.credential.accessKey)
                        .font(.caption.monospaced())
                        .foregroundStyle(.fgSubtle)
                }
                .lineLimit(1)
                .padding(.vertical, 3)
            }
            .width(min: 180, ideal: 240)

            TableColumn("Acts As", value: \.principal) { row in
                Text(row.principal)
                    .foregroundStyle(.fgMuted)
            }
            .width(min: 70, ideal: 100)

            TableColumn("Access", value: \.scope) { row in
                Text(row.scope)
                    .foregroundStyle(.fgMuted)
            }
            .width(min: 90, ideal: 130)

            TableColumn("Status", value: \.state) { row in
                HStack(spacing: 6) {
                    StatusDot(tone: row.credential.stateTone, size: 7)
                    Text(row.state)
                        .foregroundStyle(.fgMuted)
                }
            }
            .width(min: 70, ideal: 80)

            TableColumn("Last Used", value: \.usedSort) { row in
                Text(row.credential.lastUsedAt.map { Format.relative(epoch: $0) } ?? "Never")
                    .foregroundStyle(.fgSubtle)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Expires", value: \.expiresSort) { row in
                Text(GatewayFormat.epoch(row.credential.expiresAt)?.formatted(date: .abbreviated, time: .omitted) ?? "Never")
                    .foregroundStyle(row.credential.isExpired ? StatusTone.warn.color : .fgSubtle)
            }
            .width(min: 80, ideal: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Copy Access Key ID") { GatewayFormat.copy(row.credential.accessKey) }
            }
        } primaryAction: { ids in
            selection = ids.first
        }
    }

    private func rows(_ credentials: [WsModel.S3GatewayCredential]) -> [GatewayKeyRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return credentials.map(GatewayKeyRow.init)
            .filter { needle.isEmpty || "\($0.credential.name) \($0.credential.accessKey) \($0.principal)".lowercased().contains(needle) }
            .sorted(using: sortOrder)
    }
}

nonisolated struct GatewayKeyRow: Identifiable {
    var credential: WsModel.S3GatewayCredential

    var id: Int64 { credential.id }
    var sortName: String { credential.name.lowercased() }
    var principal: String { credential.principalName }
    var scope: String { GatewayFormat.scopeLabel(credential.scopeMode) }
    var state: String { credential.stateLabel }
    var usedSort: Int64 { credential.lastUsedAt ?? 0 }
    var expiresSort: Int64 { credential.expiresAt ?? .max }
}

// MARK: - Inspector

/// The selected key: what it is, what it reaches, its budget, and what can be done with it.
struct GatewayKeyInspector: View {
    var credential: WsModel.S3GatewayCredential
    var queries: NodeQueries

    private enum Sheet: String, Identifiable {
        case access, budget, expiry
        var id: Self { self }
    }

    @State private var sheet: Sheet?
    @State private var confirmingRevoke = false
    @State private var revoke: NodeMutation<Ws.S3.Gateway.Credentials.Revoke>

    private static let termWidth: CGFloat = 112

    init(credential: WsModel.S3GatewayCredential, queries: NodeQueries) {
        self.credential = credential
        self.queries = queries
        _revoke = State(initialValue: NodeMutation(Ws.S3.Gateway.Credentials.Revoke.self, on: queries,
                                                   invalidating: ["s3.gateway.credentials"]))
    }

    var body: some View {
        let ref = Ws.S3.Gateway.Credentials.DefaultRole.Get.Payload(credentialID: credential.id)
        let defaultRole = queries.query(Ws.S3.Gateway.Credentials.DefaultRole.Get.self, ref)
        let budget = queries.query(Ws.S3.Gateway.Budget.Status.self,
                                   .init(gatewayCredentialID: .value(credential.id), limit: 20))
        let vaults = queries.query(Ws.Storage.Vault.List.self)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                GatewayInspectorSection("Details") {
                    DefinitionList(items: details, monospacedValues: ["Access key"], termWidth: Self.termWidth)
                }

                GatewayInspectorSection("Access") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(GatewayFormat.scopeModes.first { $0.value == credential.scopeMode }?.hint
                             ?? GatewayFormat.scopeLabel(credential.scopeMode))
                            .font(.callout)
                            .foregroundStyle(.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        if credential.scopeMode != "user_access" {
                            InlineQuery(query: defaultRole, subject: "this key's default role") { response in
                                DefinitionList(items: [
                                    ("Default role", response.defaultRole.map { $0.role?.name ?? "Role #\($0.vaultRoleID)" } ?? "Not set"),
                                ], termWidth: Self.termWidth)
                            }
                        }
                        Button("Edit Access…") { sheet = .access }
                            .disabled(!credential.enabled)
                    }
                }

                GatewayInspectorSection("Budget") {
                    VStack(alignment: .leading, spacing: 10) {
                        InlineQuery(query: budget, subject: "this key's budget") { response in
                            budgetSummary(response, vaults: vaults.value?.vaults ?? [])
                        }
                        Button("Edit Budget…") { sheet = .budget }
                    }
                }

                if credential.enabled {
                    GatewayInspectorSection("Key") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Button("Change Expiry…") { sheet = .expiry }
                                Button("Revoke…", role: .destructive) { confirmingRevoke = true }
                            }
                            Text("A revoked key can't be turned back on; create a new one instead.")
                                .font(.caption)
                                .foregroundStyle(.fgSubtle)
                            MutationError(error: revoke.error)
                        }
                    }
                }
            }
            .padding(16)
        }
        .observing(defaultRole)
        .observing(budget)
        .observing(vaults)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .access: GatewayAccessSheet(credential: credential, queries: queries)
            case .budget: GatewayBudgetSheet(credential: credential, queries: queries)
            case .expiry: GatewayExpirySheet(credential: credential, queries: queries)
            }
        }
        .confirmationDialog("Revoke “\(credential.name)”?", isPresented: $confirmingRevoke, titleVisibility: .visible) {
            Button("Revoke Key", role: .destructive) {
                Task { await revoke.run(.init(accessKey: credential.accessKey)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clients using this access key are refused from now on. A revoked key can't be turned back on; create a new one instead.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "key")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.accentText)
                    .frame(width: 34, height: 34)
                    .background(.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(credential.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        StatusDot(tone: credential.stateTone, size: 6)
                        Text("\(credential.stateLabel) · acts as \(credential.principalName)")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }
            }
            if let description = credential.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Copy Access Key ID", systemImage: "doc.on.doc") { GatewayFormat.copy(credential.accessKey) }
                .controlSize(.small)
        }
    }

    private var details: [(term: String, value: String)] {
        [
            ("Access key", credential.accessKey),
            ("Acts as", credential.principalName),
            ("Access", GatewayFormat.scopeLabel(credential.scopeMode)),
            ("Created", GatewayFormat.moment(credential.createdAt) ?? "—"),
            ("Last used", credential.lastUsedAt.map { Format.relative(epoch: $0) } ?? "Never"),
            ("Expires", GatewayFormat.moment(credential.expiresAt) ?? "Never"),
            ("Local hits", credential.enforceBudgetForLocalRequests ? "Count against the budget" : "Free"),
        ]
    }

    @ViewBuilder
    private func budgetSummary(_ response: Ws.S3.Gateway.Budget.Status.Response, vaults: [WsModel.Vault]) -> some View {
        let policies = response.policies.filter { $0.isActive && $0.gatewayCredentialID == credential.id }
        if policies.isEmpty {
            Text("No budget. Requests through this key aren't capped.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(policies, id: \.id) { policy in
                    let trend = response.trends.first {
                        $0.policyID == policy.id && $0.windowType == "monthly"
                    }
                    GatewayBudgetMeter(policy: policy, trend: trend,
                                       title: policy.vaultID.map { id in vaults.first { $0.id == id }?.name ?? "Vault #\(id)" } ?? "Whole key")
                }
            }
        }
    }
}

/// A titled group in a gateway inspector.
struct GatewayInspectorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.fgSubtle)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One budget's monthly spend against its cap.
struct GatewayBudgetMeter: View {
    var policy: WsModel.PriceBudgetPolicy
    var trend: WsModel.PriceBudgetTrendStats?
    var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundStyle(.fg)
                Text(Format.words(policy.mode))
                    .font(.caption)
                    .foregroundStyle(policy.mode == "enforce" ? Color.accentText : .fgSubtle)
                Spacer()
                Text(limits)
                    .foregroundStyle(.fgMuted)
                    .monospacedDigit()
            }
            .font(.callout)
            if let trend {
                let fraction = min(max(trend.percentUsed / 100, 0), 1)
                Capsule()
                    .fill(.surface3)
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(fraction >= 0.9 ? StatusTone.warn.color : Color.accentFill)
                                .frame(width: proxy.size.width * fraction)
                        }
                    }
                Text("\(GatewayFormat.money(trend.totalCost, currency: trend.currency) ?? trend.totalCost) spent this month\(trend.limit.map { " of \(GatewayFormat.money($0, currency: trend.currency) ?? $0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            } else {
                Text("No spend recorded this month.")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }
        }
    }

    private var limits: String {
        let parts = [
            GatewayFormat.money(policy.maxMonthlyCost, currency: policy.currency).map { "\($0) / month" },
            GatewayFormat.money(policy.maxDailyCost, currency: policy.currency).map { "\($0) / day" },
            GatewayFormat.money(policy.maxRunCost, currency: policy.currency).map { "\($0) / run" },
        ].compactMap(\.self)
        return parts.isEmpty ? "No limits (records only)" : parts.joined(separator: " · ")
    }
}
