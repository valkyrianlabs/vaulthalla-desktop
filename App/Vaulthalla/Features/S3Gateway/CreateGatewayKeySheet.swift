import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Create a gateway key (`s3.gateway.credentials.create`). The node answers with the secret access key once; this
/// sheet shows it in a copyable field until the person confirms they saved it, then drops every copy it holds.
struct CreateGatewayKeySheet: View {
    var queries: NodeQueries
    var onCreated: () -> Void

    private struct Created {
        var credential: WsModel.S3GatewayCredential
        var secret: String
    }

    @State private var name = ""
    @State private var principal: Int64?
    @State private var scope = "user_access"
    @State private var roleID: Int64?
    @State private var selectedVaults: Set<Int64> = []
    @State private var expires = false
    @State private var expiry = Calendar.current.date(byAdding: .day, value: 90, to: .now) ?? .now
    @State private var summary = ""
    @State private var localBudget = false
    @State private var touched = false
    @State private var created: Created?
    @State private var create: NodeMutation<Ws.S3.Gateway.Credentials.Create>
    @Environment(\.dismiss) private var dismiss

    init(queries: NodeQueries, onCreated: @escaping () -> Void) {
        self.queries = queries
        self.onCreated = onCreated
        _create = State(initialValue: NodeMutation(Ws.S3.Gateway.Credentials.Create.self, on: queries,
                                                   invalidating: ["s3.gateway.credentials"]))
    }

    var body: some View {
        Group {
            if let created {
                secret(created)
            } else {
                form
            }
        }
        .interactiveDismissDisabled(created != nil || create.isRunning)
        .onDisappear {
            // Whatever way the sheet goes away, the secret goes with it.
            created = nil
            create.reset()
        }
    }

    // MARK: Form

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var problems: [String] {
        var out: [String] = []
        if trimmedName.isEmpty { out.append("Give the key a name.") }
        if scope != "user_access" && roleID == nil { out.append("Pick the vault role this key gets.") }
        if scope == "vault_allowlist" && selectedVaults.isEmpty { out.append("Select at least one vault.") }
        if expires && expiry <= .now { out.append("Pick an expiry in the future.") }
        return out
    }

    private var form: some View {
        let users = queries.query(Ws.Auth.Users.List.self)
        let roles = queries.query(Ws.Roles.Vault.List.self)
        let vaults = queries.query(Ws.Storage.Vault.List.self)

        return VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. nightly-backup"))
                    Picker("Acts as", selection: $principal) {
                        Text("You (the account this Mac acts for)").tag(Int64?.none)
                        ForEach(users.value?.users ?? [], id: \.id) { user in
                            Text(user.name).tag(Int64?.some(user.id))
                        }
                    }
                    .disabled(users.value == nil)
                    .help(users.value == nil ? "Choosing another user needs admin.s3_gateway.assign_principal." : "The user whose access the key uses.")
                    TextField("Description", text: $summary, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Create Gateway Key")
                } footer: {
                    Text("An access key and secret an S3 client uses to reach bound buckets.")
                        .foregroundStyle(.fgSubtle)
                }

                Section("Access") {
                    Picker("Access", selection: $scope) {
                        ForEach(GatewayFormat.scopeModes, id: \.value) { mode in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.label)
                                Text(mode.hint)
                                    .font(.caption)
                                    .foregroundStyle(.fgSubtle)
                            }
                            .tag(mode.value)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if scope != "user_access" {
                        Picker("Default vault role", selection: $roleID) {
                            Text("Choose a role…").tag(Int64?.none)
                            ForEach(roles.value?.roles ?? [], id: \.id) { role in
                                Text(role.name).tag(Int64?.some(role.id))
                            }
                        }
                        if let error = roles.error {
                            InlineProblem(error: error, subject: "vault roles")
                        }
                    }

                    if scope == "vault_allowlist" {
                        if let list = vaults.value?.vaults, !list.isEmpty {
                            ForEach(list, id: \.id) { vault in
                                Toggle(isOn: Binding(
                                    get: { selectedVaults.contains(vault.id) },
                                    set: { on in if on { selectedVaults.insert(vault.id) } else { selectedVaults.remove(vault.id) } }
                                )) {
                                    HStack {
                                        Text(vault.name)
                                        Spacer()
                                        Text(vault.type == WsModel.Vault.TypeValue.s3 ? "S3" : "Local")
                                            .font(.caption)
                                            .foregroundStyle(.fgFaint)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        } else if let error = vaults.error {
                            InlineProblem(error: error, subject: "vaults")
                        } else if vaults.value != nil {
                            Text("No vaults you can see.")
                                .foregroundStyle(.fgSubtle)
                        }
                    }
                }

                Section {
                    Toggle("Expires", isOn: $expires)
                    if expires {
                        DatePicker("Expires on", selection: $expiry, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    }
                    Toggle(isOn: $localBudget) {
                        Text("Count cache and local hits against this key's budget")
                        Text("Off: requests served without an upstream S3 call don't use up budgets. On: every request is gateway usage for this key.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            VStack(alignment: .leading, spacing: 8) {
                if touched, let first = problems.first {
                    Label(first, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(StatusTone.danger.color)
                }
                MutationError(error: create.error)
            }
            .padding(.horizontal, 20)

            HStack {
                if create.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Key") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(create.isRunning)
            }
            .padding(20)
        }
        .frame(width: 560, height: 640)
        .observing(users)
        .observing(roles)
        .observing(vaults)
        .serverConfirmation(create, title: "Create the key?", confirmLabel: "Create")
    }

    private func submit() async {
        touched = true
        guard problems.isEmpty else { return }
        let description = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = Ws.S3.Gateway.Credentials.Create.Payload(
            name: trimmedName,
            principalUserID: principal.map { .value($0) },
            scopeMode: .init(rawValue: scope),
            description: description.isEmpty ? .null : .value(description),
            expiresAt: expires ? .value(Int64(expiry.timeIntervalSince1970)) : .null,
            defaultVaultRoleID: scope != "user_access" ? roleID.map { .value($0) } : nil,
            selectedVaultIDs: scope == "vault_allowlist" ? selectedVaults.sorted().map { .integer($0) } : nil,
            enforceBudgetForLocalRequests: localBudget)
        guard let response = await create.run(payload) else { return }
        created = Created(credential: response.credential, secret: response.secretAccessKey)
        // The mutation kept the answer (and so the secret) as its outcome: let it go.
        create.reset()
    }

    // MARK: One-time secret

    private func secret(_ created: Created) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.accentText)
                    .frame(width: 36, height: 36)
                    .background(.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Key created. Copy the secret now.")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                    Text("“\(created.credential.name)” acts as \(created.credential.principalName).")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                }
            }

            Callout(tone: .warn, systemImage: "eye.slash") {
                Text("You won't see this secret again")
                    .fontWeight(.semibold)
                Text("The node shows the secret access key only once. If it's lost, revoke the key and create a new one.")
                    .foregroundStyle(.fgMuted)
            }

            VStack(alignment: .leading, spacing: 12) {
                GatewayCopyField(label: "Access key ID", value: created.credential.accessKey)
                GatewayCopyField(label: "Secret access key", value: created.secret, secret: true)
            }
            .padding(14)
            .background(.accentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(.accentLine, lineWidth: 1)
            }

            Text("Configure clients under Client Setup.")
                .font(.caption)
                .foregroundStyle(.fgSubtle)

            HStack {
                Spacer()
                Button("I've Saved It") {
                    self.created = nil
                    onCreated()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

/// A value to copy, such as an access key, in a monospaced well with a Copy button.
struct GatewayCopyField: View {
    var label: String
    var value: String
    var secret = false

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.fgSubtle)
            HStack(spacing: 8) {
                Text(value)
                    .font(.callout.monospaced())
                    .foregroundStyle(secret ? Color.accentText : Color.fg)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .privacySensitive(secret)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(.line, lineWidth: 1)
                    }
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    GatewayFormat.copy(value)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .accessibilityLabel("Copy \(label)")
            }
        }
    }
}
