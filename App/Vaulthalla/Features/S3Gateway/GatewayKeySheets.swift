import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Runs one gateway change and remembers its failure for the sheet that made it.
@MainActor
@Observable
final class GatewayChange {
    private(set) var busy = false
    private(set) var failure: WsError?

    @ObservationIgnored private let queries: NodeQueries
    @ObservationIgnored private let invalidating: [String]

    init(queries: NodeQueries, invalidating: [String]) {
        self.queries = queries
        self.invalidating = invalidating
    }

    @discardableResult
    func run<R: WsRequest>(_ request: R.Type, _ payload: R.Payload) async -> Bool where R.Payload: Decodable {
        busy = true
        failure = nil
        defer { busy = false }
        switch await queries.perform(R.self, payload, invalidating: invalidating) {
        case .success: return true
        case .failure(let error): failure = error
        case .needsConfirmation(let request): failure = .error(request.message)
        }
        return false
    }
}

// MARK: - Access

/// What a key reaches: its scope mode, default vault role, selected vaults, per-vault exceptions and path overrides
/// (the web console's AccessEditor). Each change is its own command; the scope itself is saved with Save Access.
struct GatewayAccessSheet: View {
    var credential: WsModel.S3GatewayCredential
    var queries: NodeQueries

    @State private var scope: String
    @State private var summary: String
    @State private var localBudget: Bool
    @State private var roleID: Int64?
    @State private var addVault: Int64?
    @State private var assignVault: Int64?
    @State private var assignRole: Int64?
    @State private var overrideVault: Int64?
    @State private var change: GatewayChange
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    init(credential: WsModel.S3GatewayCredential, queries: NodeQueries) {
        self.credential = credential
        self.queries = queries
        _scope = State(initialValue: credential.scopeMode)
        _summary = State(initialValue: credential.description ?? "")
        _localBudget = State(initialValue: credential.enforceBudgetForLocalRequests)
        _change = State(initialValue: GatewayChange(queries: queries, invalidating: ["s3.gateway.credentials"]))
    }

    private var id: Int64 { credential.id }
    private var policyScope: Bool { credential.scopeMode != "user_access" }

    var body: some View {
        let defaultRole = queries.query(Ws.S3.Gateway.Credentials.DefaultRole.Get.self, .init(credentialID: id))
        let selected = queries.query(Ws.S3.Gateway.Credentials.SelectedVaults.List.self, .init(credentialID: id))
        let defaultOverrides = queries.query(Ws.S3.Gateway.Credentials.DefaultRole.Overrides.List.self, .init(credentialID: id))
        let assignments = queries.query(Ws.S3.Gateway.Credentials.Roles.List.self, .init(credentialID: id))
        let roles = queries.query(Ws.Roles.Vault.List.self)
        let vaults = queries.query(Ws.Storage.Vault.List.self)
        let permissions = queries.query(Ws.Permissions.List.self)

        let vaultList = vaults.value?.vaults ?? []
        let selectedIDs = Set((selected.value?.selectedVaults ?? []).filter(\.enabled).map(\.vaultID))
        let exceptionVaults = credential.scopeMode == "global" ? vaultList : vaultList.filter { selectedIDs.contains($0.id) }
        let fsPermissions = (permissions.value?.permissions ?? []).map(\.qualified).filter { $0.hasPrefix("vault.fs.") }.sorted()
        let roleList = roles.value?.roles ?? []
        let overrideVaultID = overrideVault ?? exceptionVaults.first?.id

        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Access", selection: $scope) {
                        ForEach(GatewayFormat.scopeModes, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    TextField("Description", text: $summary)
                    Toggle("Count cache and local hits against this key's budget", isOn: $localBudget)
                    HStack {
                        if saved { Label("Saved", systemImage: "checkmark").foregroundStyle(StatusTone.ok.color) }
                        Spacer()
                        Button("Save Access") { Task { await save(selected: selectedIDs, roleID: roleID ?? defaultRole.value?.defaultRole?.vaultRoleID) } }
                            .disabled(change.busy)
                    }
                } header: {
                    Text("Access of “\(credential.name)”")
                } footer: {
                    Text(GatewayFormat.scopeModes.first { $0.value == scope }?.hint ?? "")
                        .foregroundStyle(.fgSubtle)
                }

                if scope != credential.scopeMode {
                    Section {
                        Label("Save Access to switch to \(GatewayFormat.scopeLabel(scope).lowercased()) before editing its policy.",
                              systemImage: "info.circle")
                            .foregroundStyle(.fgMuted)
                    }
                } else if !policyScope {
                    Section {
                        Text("This key uses \(credential.principalName)'s own vault roles and overrides. There is no extra gateway policy to configure.")
                            .foregroundStyle(.fgMuted)
                    }
                } else {
                    Section {
                        Picker("Role", selection: Binding(get: { roleID ?? defaultRole.value?.defaultRole?.vaultRoleID },
                                                          set: { roleID = $0 })) {
                            Text("Choose a role…").tag(Int64?.none)
                            ForEach(roleList, id: \.id) { Text($0.name).tag(Int64?.some($0.id)) }
                        }
                        HStack {
                            Spacer()
                            Button("Clear") {
                                Task {
                                    if await change.run(Ws.S3.Gateway.Credentials.DefaultRole.Clear.self, .init(credentialID: id)) {
                                        roleID = nil
                                    }
                                }
                            }
                            .disabled(defaultRole.value?.defaultRole == nil || change.busy)
                            Button("Set Role") {
                                guard let role = roleID ?? defaultRole.value?.defaultRole?.vaultRoleID else { return }
                                Task { await change.run(Ws.S3.Gateway.Credentials.DefaultRole.Set.self,
                                                        .init(credentialID: id, vaultRoleID: role, enabled: true)) }
                            }
                            .disabled((roleID ?? defaultRole.value?.defaultRole?.vaultRoleID) == nil || change.busy)
                        }
                    } header: {
                        Text("Default vault role")
                    } footer: {
                        Text(credential.scopeMode == "global"
                             ? "Applies to every bound bucket unless a per-vault exception overrides it."
                             : "Applies to every selected vault unless a per-vault exception overrides it.")
                            .foregroundStyle(.fgSubtle)
                    }

                    if credential.scopeMode == "vault_allowlist" {
                        Section("Selected vaults") {
                            let rows = selected.value?.selectedVaults ?? []
                            if rows.isEmpty {
                                Text(selected.error.map { _ in "Couldn't load the selected vaults." } ?? "No vaults selected yet.")
                                    .foregroundStyle(.fgSubtle)
                            }
                            ForEach(rows, id: \.vaultID) { row in
                                HStack {
                                    Text(row.vault?.name ?? vaultName(row.vaultID, in: vaultList))
                                    if !row.enabled { DeviceTag(text: "Off", tone: .unknown) }
                                    Spacer()
                                    Button("Remove") {
                                        Task { await change.run(Ws.S3.Gateway.Credentials.SelectedVaults.Remove.self,
                                                                .init(credentialID: id, vaultID: row.vaultID)) }
                                    }
                                    .disabled(change.busy)
                                }
                            }
                            HStack {
                                Picker("Add vault", selection: $addVault) {
                                    Text("Choose a vault…").tag(Int64?.none)
                                    ForEach(vaultList.filter { !selectedIDs.contains($0.id) }, id: \.id) {
                                        Text($0.name).tag(Int64?.some($0.id))
                                    }
                                }
                                Button("Add") {
                                    guard let vault = addVault else { return }
                                    Task {
                                        if await change.run(Ws.S3.Gateway.Credentials.SelectedVaults.Add.self,
                                                            .init(credentialID: id, vaultID: vault, enabled: true)) {
                                            addVault = nil
                                        }
                                    }
                                }
                                .disabled(addVault == nil || change.busy)
                            }
                        }
                    }

                    Section {
                        OverrideRows(rows: (defaultOverrides.value?.overrides ?? []).map(OverrideRow.init),
                                     empty: "No default overrides.", busy: change.busy) { row in
                            Task { await change.run(Ws.S3.Gateway.Credentials.DefaultRole.Overrides.Remove.self,
                                                    .init(credentialID: id, overrideID: row.id)) }
                        }
                        OverrideForm(permissions: fsPermissions, disabled: defaultRole.value?.defaultRole == nil || change.busy) { spec in
                            await change.run(Ws.S3.Gateway.Credentials.DefaultRole.Overrides.Add.self,
                                             .init(credentialID: id, permissionQualified: spec.permission,
                                                   effect: spec.effect, globPath: spec.glob, enabled: spec.enabled))
                        }
                    } header: {
                        Text("Default path overrides")
                    } footer: {
                        Text("Allow or deny one permission under a path pattern, in every vault the key reaches.")
                            .foregroundStyle(.fgSubtle)
                    }

                    Section {
                        let rows = assignments.value?.roles ?? []
                        if rows.isEmpty {
                            Text("No per-vault exceptions.")
                                .foregroundStyle(.fgSubtle)
                        }
                        ForEach(rows, id: \.vaultID) { row in
                            HStack {
                                Text(row.vault?.name ?? vaultName(row.vaultID, in: vaultList))
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.fgFaint)
                                Text(row.role?.name ?? "Role #\(row.vaultRoleID)")
                                    .foregroundStyle(.fgMuted)
                                Spacer()
                                Button("Revoke") {
                                    Task { await change.run(Ws.S3.Gateway.Credentials.Roles.Revoke.self,
                                                            .init(credentialID: id, vaultID: row.vaultID)) }
                                }
                                .disabled(change.busy)
                            }
                        }
                        let assigned = Set(rows.map(\.vaultID))
                        HStack {
                            Picker("Vault", selection: $assignVault) {
                                Text("Choose a vault…").tag(Int64?.none)
                                ForEach(exceptionVaults.filter { !assigned.contains($0.id) }, id: \.id) {
                                    Text($0.name).tag(Int64?.some($0.id))
                                }
                            }
                            Picker("Role", selection: Binding(get: { assignRole ?? roleList.first?.id }, set: { assignRole = $0 })) {
                                ForEach(roleList, id: \.id) { Text($0.name).tag(Int64?.some($0.id)) }
                            }
                            Button("Assign") {
                                guard let vault = assignVault, let role = assignRole ?? roleList.first?.id else { return }
                                Task {
                                    if await change.run(Ws.S3.Gateway.Credentials.Roles.Assign.self,
                                                        .init(credentialID: id, vaultID: vault, vaultRoleID: role, enabled: true)) {
                                        assignVault = nil
                                    }
                                }
                            }
                            .disabled(assignVault == nil || roleList.isEmpty || change.busy)
                        }
                    } header: {
                        Text("Per-vault exceptions")
                    } footer: {
                        Text("A different vault role for one vault.")
                            .foregroundStyle(.fgSubtle)
                    }

                    Section("Per-vault path overrides") {
                        Picker("Vault", selection: Binding(get: { overrideVaultID }, set: { overrideVault = $0 })) {
                            if exceptionVaults.isEmpty { Text("No vaults").tag(Int64?.none) }
                            ForEach(exceptionVaults, id: \.id) { Text($0.name).tag(Int64?.some($0.id)) }
                        }
                        if let vaultID = overrideVaultID {
                            VaultOverrides(credentialID: id, vaultID: vaultID, queries: queries,
                                           permissions: fsPermissions, change: change)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            MutationError(error: change.failure)
                .padding(.horizontal, 20)

            HStack {
                if change.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 640, height: 700)
        .observing(defaultRole)
        .observing(selected)
        .observing(defaultOverrides)
        .observing(assignments)
        .observing(roles)
        .observing(vaults)
        .observing(permissions)
    }

    private func vaultName(_ id: Int64, in vaults: [WsModel.Vault]) -> String {
        vaults.first { $0.id == id }?.name ?? "Vault #\(id)"
    }

    private func save(selected: Set<Int64>, roleID: Int64?) async {
        saved = false
        let description = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let policy = scope != "user_access"
        let payload = Ws.S3.Gateway.Credentials.Scope.Update.Payload(
            accessKey: credential.accessKey,
            scopeMode: .init(rawValue: scope),
            description: description.isEmpty ? .null : .value(description),
            enforceBudgetForLocalRequests: localBudget,
            selectedVaultIDs: scope == "vault_allowlist" ? selected.sorted().map { .integer($0) } : nil,
            defaultVaultRoleID: policy ? roleID.map { .value($0) } : nil)
        saved = await change.run(Ws.S3.Gateway.Credentials.Scope.Update.self, payload)
    }
}

/// The overrides on one vault's grant.
private struct VaultOverrides: View {
    var credentialID: Int64
    var vaultID: Int64
    var queries: NodeQueries
    var permissions: [String]
    var change: GatewayChange

    var body: some View {
        let list = queries.query(Ws.S3.Gateway.Credentials.Roles.Overrides.List.self,
                                 .init(credentialID: credentialID, vaultID: vaultID))
        Group {
            if let error = list.error, list.value == nil {
                InlineProblem(error: error, subject: "this vault's overrides")
            }
            OverrideRows(rows: (list.value?.overrides ?? []).map(OverrideRow.init), empty: "No overrides for this vault.",
                         busy: change.busy) { row in
                Task { await change.run(Ws.S3.Gateway.Credentials.Roles.Overrides.Remove.self,
                                        .init(credentialID: credentialID, vaultID: vaultID, overrideID: row.id)) }
            }
            OverrideForm(permissions: permissions, disabled: change.busy) { spec in
                await change.run(Ws.S3.Gateway.Credentials.Roles.Overrides.Add.self,
                                 .init(credentialID: credentialID, vaultID: vaultID, permissionQualified: spec.permission,
                                       effect: .init(rawValue: spec.effect.rawValue), globPath: spec.glob,
                                       enabled: spec.enabled))
            }
        }
        .observing(list)
    }
}

/// A path override as the sheets list it, from either override model.
nonisolated struct OverrideRow: Identifiable {
    var id: Int64
    var permission: String
    var glob: String
    var effect: String
    var enabled: Bool

    init(_ override: WsModel.S3GatewayDefaultRoleOverride) {
        id = override.id
        permission = override.permissionQualified
        glob = override.globPath
        effect = override.effect
        enabled = override.enabled
    }

    init(_ override: WsModel.S3GatewayRoleOverride) {
        id = override.id
        permission = override.permissionQualified
        glob = override.globPath
        effect = override.effect
        enabled = override.enabled
    }
}

private struct OverrideRows: View {
    var rows: [OverrideRow]
    var empty: String
    var busy: Bool
    var onRemove: (OverrideRow) -> Void

    var body: some View {
        if rows.isEmpty {
            Text(empty)
                .foregroundStyle(.fgSubtle)
        }
        ForEach(rows) { row in
            HStack(spacing: 8) {
                DeviceTag(text: row.effect == "deny" ? "Deny" : "Allow", tone: row.effect == "deny" ? .unknown : .info)
                Text(row.permission)
                    .font(.callout.monospaced())
                Text(row.glob)
                    .font(.callout.monospaced())
                    .foregroundStyle(.fgMuted)
                if !row.enabled { DeviceTag(text: "Off", tone: .unknown) }
                Spacer()
                Button("Remove", systemImage: "trash") { onRemove(row) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .help("Remove this override")
            }
        }
    }
}

private struct OverrideForm: View {
    struct Spec {
        var permission: String
        var glob: String
        var effect: Ws.S3.Gateway.Credentials.DefaultRole.Overrides.Add.Payload.Effect
        var enabled: Bool
    }

    var permissions: [String]
    var disabled: Bool
    var onAdd: (Spec) async -> Bool

    @State private var permission: String?
    @State private var glob = "**"
    @State private var effect = Ws.S3.Gateway.Credentials.DefaultRole.Overrides.Add.Payload.Effect.deny
    @State private var enabled = true

    var body: some View {
        let chosen = permission ?? permissions.first
        HStack(spacing: 8) {
            Picker("Permission", selection: Binding(get: { chosen }, set: { permission = $0 })) {
                ForEach(permissions, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .frame(minWidth: 150)
            TextField("Path pattern", text: $glob)
                .font(.callout.monospaced())
                .frame(width: 110)
            Picker("Effect", selection: $effect) {
                Text("Deny").tag(Ws.S3.Gateway.Credentials.DefaultRole.Overrides.Add.Payload.Effect.deny)
                Text("Allow").tag(Ws.S3.Gateway.Credentials.DefaultRole.Overrides.Add.Payload.Effect.allow)
            }
            .labelsHidden()
            .fixedSize()
            Toggle("On", isOn: $enabled)
                .toggleStyle(.checkbox)
            Button("Add") {
                guard let chosen else { return }
                let spec = Spec(permission: chosen, glob: glob.trimmingCharacters(in: .whitespaces), effect: effect,
                                enabled: enabled)
                Task { if await onAdd(spec) { glob = "**" } }
            }
            .disabled(disabled || chosen == nil || glob.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

// MARK: - Budget

/// Monthly caps on what requests through a key may cost, whole-key and per vault, with the key's recorded charges.
struct GatewayBudgetSheet: View {
    var credential: WsModel.S3GatewayCredential
    var queries: NodeQueries

    @State private var mode = "enforce"
    @State private var keyAmount = ""
    @State private var vaultID: Int64?
    @State private var vaultAmount = ""
    @State private var problem: String?
    @State private var disabling: (scope: Ws.S3.Gateway.Budget.Policy.Disable.Payload.Scope, vault: Int64?)?
    @State private var change: GatewayChange
    @Environment(\.dismiss) private var dismiss

    init(credential: WsModel.S3GatewayCredential, queries: NodeQueries) {
        self.credential = credential
        self.queries = queries
        _change = State(initialValue: GatewayChange(queries: queries, invalidating: ["s3.gateway.budget"]))
    }

    var body: some View {
        let id = credential.id
        let policies = queries.query(Ws.S3.Gateway.Budget.Policy.List.self, .init(includeInactive: true))
        let status = queries.query(Ws.S3.Gateway.Budget.Status.self, .init(gatewayCredentialID: .value(id), limit: 20))
        let ledger = queries.query(Ws.S3.Gateway.Budget.Ledger.List.self, .init(gatewayCredentialID: .value(id), limit: 50))
        let vaults = queries.query(Ws.Storage.Vault.List.self)

        let all = (policies.value?.policies ?? []).filter { $0.gatewayCredentialID == id && $0.isActive }
        let keyPolicy = all.first { $0.scope == "gateway_credential" }
        let vaultPolicies = all.filter { $0.scope == "gateway_credential_vault" }
        let trends = (status.value?.trends ?? []).filter { $0.windowType == "monthly" }
        let vaultList = vaults.value?.vaults ?? []

        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Mode for new caps", selection: $mode) {
                        ForEach(GatewayFormat.budgetModes, id: \.value) { Text($0.label).tag($0.value) }
                    }
                } header: {
                    Text("Budget of “\(credential.name)”")
                } footer: {
                    Text(GatewayFormat.budgetModes.first { $0.value == mode }?.hint ?? "")
                        .foregroundStyle(.fgSubtle)
                }

                Section("Whole key") {
                    if let keyPolicy {
                        GatewayBudgetMeter(policy: keyPolicy, trend: trends.first { $0.policyID == keyPolicy.id },
                                           title: "Whole key")
                    } else {
                        Text("No cap on the whole key.")
                            .foregroundStyle(.fgSubtle)
                    }
                    HStack {
                        TextField("Monthly cap (USD)", text: $keyAmount, prompt: Text("e.g. 25"))
                        Button("Save Cap") { Task { await upsert(.gatewayCredential, amount: keyAmount, vault: nil) } }
                            .disabled(keyAmount.trimmingCharacters(in: .whitespaces).isEmpty || change.busy)
                        Button("Disable", role: .destructive) { disabling = (.gatewayCredential, nil) }
                            .disabled(keyPolicy == nil || change.busy)
                    }
                }

                Section("Per vault") {
                    ForEach(vaultPolicies, id: \.id) { policy in
                        GatewayBudgetMeter(policy: policy, trend: trends.first { $0.policyID == policy.id },
                                           title: vaultList.first { $0.id == policy.vaultID }?.name ?? "Vault #\(policy.vaultID ?? 0)")
                    }
                    Picker("Vault", selection: $vaultID) {
                        Text("Choose a vault…").tag(Int64?.none)
                        ForEach(vaultList, id: \.id) { Text($0.name).tag(Int64?.some($0.id)) }
                    }
                    HStack {
                        TextField("Monthly cap (USD)", text: $vaultAmount, prompt: Text("e.g. 10"))
                        Button("Save Cap") { Task { await upsert(.gatewayCredentialVault, amount: vaultAmount, vault: vaultID) } }
                            .disabled(vaultID == nil || vaultAmount.trimmingCharacters(in: .whitespaces).isEmpty || change.busy)
                        Button("Disable", role: .destructive) { disabling = (.gatewayCredentialVault, vaultID) }
                            .disabled(vaultID == nil || !vaultPolicies.contains { $0.vaultID == vaultID } || change.busy)
                    }
                }

                Section("Recent charges") {
                    InlineQuery(query: ledger, subject: "this key's charges") { response in
                        GatewayLedgerRows(entries: response.ledger, vaults: vaultList, limit: 12,
                                          empty: "No charges recorded for this key yet.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            VStack(alignment: .leading, spacing: 6) {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .foregroundStyle(StatusTone.danger.color)
                }
                MutationError(error: change.failure)
            }
            .padding(.horizontal, 20)

            HStack {
                if change.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 600, height: 660)
        .observing(policies)
        .observing(status)
        .observing(ledger)
        .observing(vaults)
        .confirmationDialog("Disable the \(disabling?.vault == nil ? "whole-key" : "per-vault") budget?",
                            isPresented: Binding(get: { disabling != nil }, set: { if !$0 { disabling = nil } }),
                            titleVisibility: .visible, presenting: disabling) { target in
            Button("Disable Budget", role: .destructive) {
                Task {
                    await change.run(Ws.S3.Gateway.Budget.Policy.Disable.self,
                                     .init(scope: target.scope, gatewayCredentialID: id,
                                           vaultID: target.vault.map { .value($0) }))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its cap stops applying immediately. Spend already recorded stays in the ledger.")
        }
    }

    private func upsert(_ scope: Ws.S3.Gateway.Budget.Policy.Upsert.Payload.Scope, amount: String, vault: Int64?) async {
        let trimmed = amount.trimmingCharacters(in: .whitespaces)
        guard GatewayFormat.isAmount(trimmed) else {
            problem = "Invalid amount: use a plain number like 12.50."
            return
        }
        problem = nil
        let payload = Ws.S3.Gateway.Budget.Policy.Upsert.Payload(
            scope: scope, gatewayCredentialID: credential.id, vaultID: vault.map { .value($0) } ?? .null,
            mode: Ws.S3.Gateway.Budget.Policy.Upsert.Payload.Mode(rawValue: mode).map { Nullable.value($0) }, currency: .value("USD"), maxRunCost: .null,
            maxDailyCost: .null, maxMonthlyCost: .value(trimmed), requireVerifiedCatalog: true,
            allowStaleCatalog: false, maxCatalogAgeSeconds: .value(43_200))
        if await change.run(Ws.S3.Gateway.Budget.Policy.Upsert.self, payload) {
            if vault == nil { keyAmount = "" } else { vaultAmount = "" }
        }
    }
}

/// Recorded gateway charges, newest first.
struct GatewayLedgerRows: View {
    var entries: [WsModel.PriceBudgetLedgerEntry]
    var vaults: [WsModel.Vault]
    var limit: Int
    var empty: String
    var credentialName: ((Int64) -> String)?

    var body: some View {
        if entries.isEmpty {
            Text(empty)
                .font(.callout)
                .foregroundStyle(.fgSubtle)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(entries.prefix(limit), id: \.id) { entry in
                    GridRow {
                        Text(Format.moment(iso: entry.createdAt) ?? entry.createdAt)
                            .foregroundStyle(.fgSubtle)
                            .monospacedDigit()
                        Text(entry.operation.map(Format.words) ?? "Request")
                            .foregroundStyle(.fg)
                        if let credentialName {
                            Text(entry.gatewayCredentialID.map(credentialName) ?? "—")
                                .foregroundStyle(.fgMuted)
                        }
                        Text(vaults.first { $0.id == entry.vaultID }?.name ?? "Vault #\(entry.vaultID)")
                            .foregroundStyle(.fgMuted)
                            .lineLimit(1)
                        Text(GatewayFormat.money(entry.committedCost ?? entry.reservedCost, currency: entry.currency) ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.fg)
                            .gridColumnAlignment(.trailing)
                        Text(Format.words(entry.status))
                            .font(.caption)
                            .foregroundStyle(entry.status == "blocked" || entry.status == "denied" ? StatusTone.warn.color : .fgSubtle)
                    }
                }
            }
            .font(.callout)
        }
    }
}

// MARK: - Expiry

/// When a key stops working (`s3.gateway.credentials.scope.update` with `expires_at`): a date, never, or now.
struct GatewayExpirySheet: View {
    var credential: WsModel.S3GatewayCredential

    @State private var expires: Bool
    @State private var date: Date
    @State private var confirmingNow = false
    @State private var change: GatewayChange
    @Environment(\.dismiss) private var dismiss

    init(credential: WsModel.S3GatewayCredential, queries: NodeQueries) {
        self.credential = credential
        _expires = State(initialValue: credential.expiresAt != nil)
        _date = State(initialValue: GatewayFormat.epoch(credential.expiresAt)
                      ?? Calendar.current.date(byAdding: .day, value: 90, to: .now) ?? .now)
        _change = State(initialValue: GatewayChange(queries: queries, invalidating: ["s3.gateway.credentials"]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Toggle("Expires", isOn: $expires)
                    if expires {
                        DatePicker("Expires on", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    }
                } header: {
                    Text("Expiry of “\(credential.name)”")
                } footer: {
                    Text("After it expires, clients using this key are refused. An expired key can be given a later date again; a revoked one can't.")
                        .foregroundStyle(.fgSubtle)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            MutationError(error: change.failure)
                .padding(.horizontal, 20)

            HStack {
                Button("Expire Now…", role: .destructive) { confirmingNow = true }
                    .disabled(change.busy)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save(expires ? Int64(date.timeIntervalSince1970) : nil) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(change.busy)
            }
            .padding(20)
        }
        .frame(width: 460)
        .confirmationDialog("Expire “\(credential.name)” now?", isPresented: $confirmingNow, titleVisibility: .visible) {
            Button("Expire Now", role: .destructive) { Task { await save(Int64(Date.now.timeIntervalSince1970)) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clients using this key are refused from now on, until it is given a later expiry.")
        }
    }

    private func save(_ expiresAt: Int64?) async {
        let payload = Ws.S3.Gateway.Credentials.Scope.Update.Payload(
            accessKey: credential.accessKey, expiresAt: expiresAt.map { .value($0) } ?? .null)
        if await change.run(Ws.S3.Gateway.Credentials.Scope.Update.self, payload) { dismiss() }
    }
}
