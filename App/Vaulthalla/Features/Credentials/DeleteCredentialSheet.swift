import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Deletes a provider credential (`storage.apiKey.remove`). The node refuses while a vault uses the key (naming the
/// vaults) or while it runs an event subscription; that refusal is shown in its own words.
struct DeleteCredentialSheet: View {
    var row: CredentialRow
    var onDeleted: () -> Void

    @State private var remove: NodeMutation<Ws.Storage.ApiKey.Remove>
    @Environment(\.dismiss) private var dismiss

    init(row: CredentialRow, queries: NodeQueries, onDeleted: @escaping () -> Void) {
        self.row = row
        self.onDeleted = onDeleted
        _remove = State(initialValue: NodeMutation(Ws.Storage.ApiKey.Remove.self, on: queries,
                                                   invalidating: ["storage.apiKey", "storage.vault"]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(StatusTone.danger.color)
                    .frame(width: 36, height: 36)
                    .background(StatusTone.danger.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("Delete “\(row.key.name)”?")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.fg)
            }

            Text("The stored access key and secret are destroyed on the node. This can't be undone.")
                .font(.callout)
                .foregroundStyle(.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            if !row.usedBy.isEmpty {
                Callout(tone: .warn, systemImage: "externaldrive.badge.exclamationmark") {
                    Text("Used by \(row.usedBy.map(\.name).formatted(.list(type: .and)))")
                        .fontWeight(.semibold)
                    Text("The node refuses to delete a credential while vaults use it. Move \(row.usedBy.count == 1 ? "that vault" : "those vaults") to another credential or delete \(row.usedBy.count == 1 ? "it" : "them") first.")
                        .foregroundStyle(.fgMuted)
                }
            }

            MutationError(error: remove.error)

            HStack {
                if remove.isRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete Credential", role: .destructive) { Task { await delete() } }
                    .buttonStyle(.borderedProminent)
                    .tint(StatusTone.danger.color)
                    .keyboardShortcut(.defaultAction)
                    .disabled(remove.isRunning)
            }
        }
        .padding(22)
        .frame(width: 480)
        .serverConfirmation(remove, title: "Delete “\(row.key.name)” anyway?", confirmLabel: "Delete Anyway",
                            role: .destructive)
        .interactiveDismissDisabled(remove.isRunning)
    }

    private func delete() async {
        if await remove.run(.init(id: row.key.apiKeyID)) != nil {
            onDeleted()
            dismiss()
        }
    }
}
