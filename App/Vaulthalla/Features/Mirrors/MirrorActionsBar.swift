import SwiftUI
import VHContract
import VHCore
import VHNodes

/// THE place a mirrored vault's actions go (the console's detail "Actions" panel). It lists the actions
/// ``MirrorModel/actions(_:firstCopyFinished:)`` allows for this server's role and the vault's state, with the
/// console's labels and hints, in the console's order.
///
/// Read-only for now: every button is disabled and nothing is sent. The action pieces wire them here, in this file:
/// give `perform(_:)` a case per action that opens its sheet (each in its own file beside this one) and drop the
/// `.disabled(true)`. `held` is not a button: it becomes the held-changes list under the details.
struct MirrorActionsBar: View {
    var node: Node
    var queries: NodeQueries
    var row: MirroredVault
    /// What `mirror.detach.preview` says about a held copy; nil while unknown or for other roles.
    var heldCopy: MirrorHeldCopyFacts?

    var body: some View {
        let actions = MirrorModel.actions(row).filter { $0 != .held }
        Panel(title: MirrorCopy.detailActions) {
            if actions.isEmpty {
                Text(MirrorCopy.noActions)
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(actions, id: \.self) { action in
                        actionRow(action, MirrorModel.actionText(action, row))
                    }
                    Text("Actions on mirrored vaults arrive in a coming version of Vaulthalla Desktop. Until then, use the web console on \(node.displayName).")
                        .font(.caption)
                        .foregroundStyle(.fgFaint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func actionRow(_ action: MirrorAction, _ text: MirrorModel.ActionText) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(role: text.danger ? .destructive : nil) {
                perform(action)
            } label: {
                Label(text.label, systemImage: text.systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)
            .disabled(true)
            Text(text.hint)
                .font(.caption)
                .foregroundStyle(.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Not wired yet: the action pieces open their sheets from here.
    private func perform(_ action: MirrorAction) {}
}
