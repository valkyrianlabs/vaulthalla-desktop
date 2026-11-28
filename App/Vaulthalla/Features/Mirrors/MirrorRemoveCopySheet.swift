import SwiftUI
import VHContract
import VHCore
import VHNodes

/// `mirror.cancel` for what isn't a running mirror, as the console's confirmations on the detail page: removing an
/// orphaned copy with its keys (the vault's name typed, since it is gone for good) or cancelling a start. Once done,
/// Done goes back to the list, as the console does.
struct MirrorRemoveCopySheet: View {
    var row: MirroredVault

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var done = false
    @State private var cancel: NodeMutation<Ws.Mirror.Cancel>

    init(row: MirroredVault, queries: NodeQueries) {
        self.row = row
        _cancel = State(initialValue: NodeMutation(Ws.Mirror.Cancel.self, on: queries,
                                                   invalidating: MirrorActions.invalidating))
    }

    private var orphan: Bool { MirrorModel.cancelKind(row) == .removeOrphan }
    private var name: String { row.vaultName.isEmpty ? (row.start?.name ?? "") : row.vaultName }

    var body: some View {
        MirrorActionSheet(destructive: true, systemImage: orphan ? "trash" : "nosign",
                          title: orphan ? MirrorCopy.removeOrphanTitle(name) : MirrorCopy.cancelStartTitle(name),
                          description: done ? nil
                              : orphan ? MirrorCopy.removeOrphanBody : MirrorCopy.cancelStartBody(MirrorModel.peerName(row))) {
            if done {
                MirrorOutcome(label: orphan ? MirrorCopy.orphanRemoved(name) : MirrorCopy.startCancelled,
                              tone: .neutralTone) { EmptyView() }
            } else {
                if orphan {
                    MirrorTypedName(label: MirrorCopy.detachType(row.vaultName), name: row.vaultName, text: $typed)
                }
                MirrorRefusal(title: MirrorCopy.cancelFailed, error: cancel.error)
            }
        } buttons: {
            if done {
                Button(MirrorCopy.done) {
                    dismiss()
                    model.closeMirror()
                }
                .keyboardShortcut(.cancelAction)
            } else {
                MirrorCloseButton(disabled: cancel.isRunning)
                MirrorActionButton(label: orphan ? MirrorCopy.removeOrphanConfirm : MirrorCopy.cancelStartConfirm,
                                   destructive: true, running: cancel.isRunning,
                                   enabled: !orphan || MirrorActions.nameMatches(typed, row)) {
                    Task { await submit() }
                }
            }
        }
        .serverConfirmation(cancel, title: orphan ? MirrorCopy.removeOrphanTitle(name) : MirrorCopy.cancelStartTitle(name),
                            confirmLabel: orphan ? MirrorCopy.removeOrphanConfirm : MirrorCopy.cancelStartConfirm,
                            role: .destructive)
        .interactiveDismissDisabled(cancel.isRunning || done)
        .mirrorDebugConfirm {
            typed = row.vaultName
            await submit()
        }
    }

    private func submit() async {
        if orphan, !MirrorActions.nameMatches(typed, row) { return }
        done = await cancel.run(MirrorActions.cancelPayload(row)) != nil
    }
}
