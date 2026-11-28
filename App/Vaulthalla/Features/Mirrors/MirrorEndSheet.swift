import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Ends a mirror on its core (`mirror.cancel {vault_id, remove_copy}`), as the console's EndMirrorDialog: what
/// happens to the other server's copy is chosen here, kept (orphaned) by default as `vh mirror cancel` does; removing
/// it is never picked for the person. A step-up this Mac can't give shows the server's sentence.
struct MirrorEndSheet: View {
    enum Copy: Hashable { case leave, remove }

    var row: MirroredVault

    @State private var copy: Copy? = .leave
    @State private var answer: Ws.Mirror.Cancel.Response?
    @State private var end: NodeMutation<Ws.Mirror.Cancel>

    init(row: MirroredVault, queries: NodeQueries) {
        self.row = row
        _end = State(initialValue: NodeMutation(Ws.Mirror.Cancel.self, on: queries,
                                                invalidating: MirrorActions.invalidating))
    }

    var body: some View {
        let peer = MirrorModel.peerName(row)
        MirrorActionSheet(destructive: true, systemImage: "nosign", title: MirrorCopy.endTitle(row.vaultName),
                          description: answer == nil ? MirrorCopy.endBody(peer) : nil) {
            if let answer {
                MirrorOutcome(label: MirrorCopy.ended(row.vaultName), tone: .neutralTone) {
                    Text(MirrorCopy.endedHint(remove: answer.removeCopy)).foregroundStyle(.fgMuted)
                }
            } else {
                MirrorChoiceCards(legend: MirrorCopy.endLegend(peer), options: [
                    .init(value: .leave, title: MirrorCopy.endLeave, hint: MirrorCopy.endLeaveHint(peer)),
                    .init(value: .remove, title: MirrorCopy.endRemove, hint: MirrorCopy.endRemoveHint(peer)),
                ], selection: $copy)
                MirrorRefusal(title: MirrorCopy.cancelFailed, error: end.error)
            }
        } buttons: {
            if answer != nil {
                MirrorCloseButton(label: MirrorCopy.done)
            } else {
                MirrorCloseButton(disabled: end.isRunning)
                MirrorActionButton(label: MirrorCopy.endConfirm, destructive: true, running: end.isRunning,
                                   enabled: copy != nil) {
                    Task { await submit() }
                }
            }
        }
        .serverConfirmation(end, title: MirrorCopy.endTitle(row.vaultName), confirmLabel: MirrorCopy.endConfirm,
                            role: .destructive)
        .interactiveDismissDisabled(end.isRunning)
        .mirrorDebugConfirm { await submit() }
    }

    private func submit() async {
        guard let copy else { return }
        answer = await end.run(MirrorActions.endPayload(row, removeCopy: copy == .remove))
    }
}

extension StatusTone {
    /// An ended thing: gray, never green.
    static var neutralTone: StatusTone { .unknown }
}
