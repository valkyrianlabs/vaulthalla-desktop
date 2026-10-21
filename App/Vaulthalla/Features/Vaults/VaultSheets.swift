import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Rename a vault or change its description (`storage.vault.update` with only the changed members).
struct EditVaultSheet: View {
    var vault: WsModel.Vault

    @State private var name: String
    @State private var summary: String
    @State private var update: NodeMutation<Ws.Storage.Vault.Update>
    @Environment(\.dismiss) private var dismiss

    init(vault: WsModel.Vault, queries: NodeQueries) {
        self.vault = vault
        _name = State(initialValue: vault.name)
        _summary = State(initialValue: vault.description)
        _update = State(initialValue: NodeMutation(Ws.Storage.Vault.Update.self, on: queries,
                                                   invalidating: ["storage.vault", "stats.system.storage"]))
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { trimmedName != vault.name || summary != vault.description }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description", text: $summary, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Edit “\(vault.name)”")
                } footer: {
                    Text("The name shows in Files, shares and the web console. The vault's mount and slug don't change.")
                        .foregroundStyle(.fgSubtle)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            MutationError(error: update.error)
                .padding(.horizontal, 20)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!changed || trimmedName.isEmpty || update.isRunning)
            }
            .padding(20)
        }
        .frame(width: 460)
        .serverConfirmation(update, title: "Save the change?", confirmLabel: "Save")
    }

    private func save() async {
        var payload = Ws.Storage.Vault.Update.Payload(id: vault.id)
        if trimmedName != vault.name { payload.name = .value(trimmedName) }
        if summary != vault.description { payload.description = .value(summary) }
        if await update.run(payload) != nil { dismiss() }
    }
}

/// Deleting a vault the way the web console's DeleteVaultDialog does (#162): the server's plan says what happens
/// and for how long; S3 upstream data is kept unless the person chooses otherwise; "Delete now" needs the vault's
/// name typed. The daemon's own confirmations (`vault_upstream_key_loss`, `vault_delete_now`) come back through
/// the data layer: the typed name accepts `vault_delete_now`, and key loss is asked in the daemon's words.
struct DeleteVaultSheet: View {
    var vault: WsModel.Vault
    var node: Node
    var onDeleted: () -> Void

    private enum Step { case choose, now }

    @State private var step = Step.choose
    @State private var deleteUpstream = false
    @State private var typedName = ""
    @State private var remove: NodeMutation<Ws.Storage.Vault.Remove>
    private let plan: NodeQuery<Ws.Storage.Vault.Remove.Plan>
    @Environment(\.dismiss) private var dismiss

    init(vault: WsModel.Vault, node: Node, queries: NodeQueries, onDeleted: @escaping () -> Void) {
        self.vault = vault
        self.node = node
        self.onDeleted = onDeleted
        plan = queries.query(Ws.Storage.Vault.Remove.Plan.self, .init(id: vault.id))
        _remove = State(initialValue: NodeMutation(
            Ws.Storage.Vault.Remove.self, on: queries,
            invalidating: ["storage.vault", "stats.system.storage", "stats.vault", "vault.recovery"]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(StatusTone.danger.color)
                    .frame(width: 36, height: 36)
                    .background(StatusTone.danger.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("Delete “\(vault.name)”?")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.fg)
            }

            switch plan.state {
            case .idle, .loading:
                ProgressView("Asking \(node.displayName) what deleting it would do…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .failed(let error):
                InlineProblem(error: error, subject: "deleting this vault")
            case .loaded(let response, _):
                switch step {
                case .choose: choose(response.plan)
                case .now: now(response.plan)
                }
            }

            MutationError(error: remove.error)

            buttons
        }
        .padding(22)
        .frame(width: 500)
        .task { await plan.refresh() }
        // The facts can change underneath (a key exported from a terminal): re-read them when the daemon asks.
        .onChange(of: remove.confirmation?.id) { _, id in
            if id != nil { Task { await plan.refresh() } }
        }
        .serverConfirmation(remove, title: "Delete “\(vault.name)” anyway?", confirmLabel: "Delete Anyway",
                            role: .destructive)
        .interactiveDismissDisabled(remove.isRunning)
    }

    // MARK: Steps

    private func choose(_ plan: WsModel.VaultRemovalPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("It disappears now. You can restore it for \(plan.retentionWindow); then its data is purged. Its encryption key is kept for \(plan.keyRetentionWindow) either way.")
                .font(.callout)
                .foregroundStyle(.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            if plan.type == WsModel.VaultRemovalPlan.TypeValue.s3 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("It's backed by S3. What about the data in \(Self.where(plan))?")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.fg)
                    Picker("Upstream data", selection: $deleteUpstream) {
                        Text("Keep the upstream data").tag(false)
                        Text("Delete the upstream data too (can't be undone)").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }

            if Self.keyAtRisk(plan, deleteUpstream: deleteUpstream) {
                Callout(tone: .danger, systemImage: "exclamationmark.triangle") {
                    Text("The data in \(plan.bucket ?? "the bucket") can't be decrypted without this vault's key")
                        .fontWeight(.semibold)
                    Text("The key has never been exported. Export it from a terminal on the node first; it stays exportable for \(plan.keyRetentionWindow) after the deletion, then it is destroyed.")
                        .foregroundStyle(.fgMuted)
                    CommandSnippet(command: plan.exportCommand)
                        .padding(.top, 4)
                }
            } else if !plan.keyExported {
                Callout(tone: .warn, systemImage: "key") {
                    Text("No export of this vault's key has been recorded. Encrypted backups of its contents can't be read without it.")
                        .foregroundStyle(.fgMuted)
                    CommandSnippet(command: plan.exportCommand)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func now(_ plan: WsModel.VaultRemovalPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Its data is removed within moments\(deleteUpstream ? ", including the objects in the bucket," : "") and it can't be restored. Its encryption key is still kept for \(plan.keyRetentionWindow).")
                .font(.callout)
                .foregroundStyle(StatusTone.danger.color)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Type “\(vault.name)” to confirm", text: $typedName)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        let ready = plan.value != nil && !remove.isRunning
        HStack {
            if remove.isRunning {
                ProgressView().controlSize(.small)
            }
            Spacer()
            switch step {
            case .choose:
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete Now…") { step = .now }
                    .disabled(!ready)
                Button("Delete", role: .destructive) { Task { await submit(now: false) } }
                    .buttonStyle(.borderedProminent)
                    .tint(StatusTone.danger.color)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            case .now:
                Button("Back") { step = .choose; typedName = "" }
                    .keyboardShortcut(.cancelAction)
                Button("Delete Now", role: .destructive) { Task { await submit(now: true) } }
                    .buttonStyle(.borderedProminent)
                    .tint(StatusTone.danger.color)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || typedName != vault.name)
            }
        }
    }

    private func submit(now: Bool) async {
        guard let plan = plan.value?.plan else { return }
        let payload = Ws.Storage.Vault.Remove.Payload(
            id: vault.id, now: now ? true : nil,
            deleteUpstream: plan.type == WsModel.VaultRemovalPlan.TypeValue.s3 ? .value(deleteUpstream) : nil)
        // The typed name is the person's acceptance of deleting now; anything else the daemon asks is put to them.
        let accepted: Set<String> = now ? ["vault_delete_now"] : []
        if await remove.run(payload, accepting: accepted) != nil {
            onDeleted()
            dismiss()
        } else if now, remove.confirmation == nil {
            step = .choose
        }
    }

    private static func keyAtRisk(_ plan: WsModel.VaultRemovalPlan, deleteUpstream: Bool) -> Bool {
        plan.type == WsModel.VaultRemovalPlan.TypeValue.s3 && plan.encryptedUpstream && !deleteUpstream
            && !plan.keyExported
    }

    private static func `where`(_ plan: WsModel.VaultRemovalPlan) -> String {
        let bucket = plan.bucket ?? "the bucket"
        return plan.provider.map { "\(bucket) (\($0))" } ?? bucket
    }
}
