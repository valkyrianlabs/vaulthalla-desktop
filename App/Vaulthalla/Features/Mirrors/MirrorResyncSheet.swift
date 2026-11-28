import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Starts a stopped copy over from its core's files (`mirror.resync`), as the console's resync confirmation: what it
/// does, then, once it started, how many changes made here were kept as held changes. The actions bar offers it only
/// while the link is up (the server refuses without it).
struct MirrorResyncSheet: View {
    var row: MirroredVault

    @State private var answer: Ws.Mirror.Resync.Response?
    @State private var resync: NodeMutation<Ws.Mirror.Resync>

    init(row: MirroredVault, queries: NodeQueries) {
        self.row = row
        _resync = State(initialValue: NodeMutation(Ws.Mirror.Resync.self, on: queries,
                                                   invalidating: MirrorActions.invalidating))
    }

    var body: some View {
        MirrorActionSheet(systemImage: "arrow.triangle.2.circlepath", title: MirrorCopy.resyncTitle(row.vaultName),
                          description: answer == nil ? MirrorCopy.resyncBody(MirrorModel.peerName(row)) : nil) {
            if let answer {
                MirrorOutcome(label: MirrorCopy.resynced(row.vaultName), tone: .info) {
                    Text(MirrorCopy.resyncedHint(held: answer.held)).foregroundStyle(.fgMuted)
                }
            } else {
                MirrorRefusal(title: MirrorCopy.resyncFailed, error: resync.error)
            }
        } buttons: {
            if answer != nil {
                MirrorCloseButton(label: MirrorCopy.done)
            } else {
                MirrorCloseButton(disabled: resync.isRunning)
                MirrorActionButton(label: MirrorCopy.resyncConfirm, running: resync.isRunning) {
                    Task { answer = await resync.run(MirrorActions.resyncPayload(row)) }
                }
            }
        }
        .serverConfirmation(resync, title: MirrorCopy.resyncTitle(row.vaultName), confirmLabel: MirrorCopy.resyncConfirm)
        .interactiveDismissDisabled(resync.isRunning)
        .mirrorDebugConfirm { answer = await resync.run(MirrorActions.resyncPayload(row)) }
    }
}
