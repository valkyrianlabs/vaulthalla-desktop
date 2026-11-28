import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Take over as the vault's core on a mirror whose core is gone (`mirror.takeover {vault_id, confirm}`), as the
/// console's TakeoverDialog: what it does, the warning that the old core may hold changes this server never received,
/// what the detach preview says becomes of the changes and missing files here, then the vault's name typed. A refusal
/// (the core still answers: `mirror_core_reachable`) or a step-up this Mac can't give shows the server's sentence.
struct MirrorTakeoverSheet: View {
    var row: MirroredVault

    @State private var typed = ""
    @State private var outcome: MirrorActions.TakeoverOutcome?
    @State private var take: NodeMutation<Ws.Mirror.Takeover>
    private let preview: NodeQuery<Ws.Mirror.Detach.Preview>

    init(row: MirroredVault, queries: NodeQueries) {
        self.row = row
        preview = queries.query(Ws.Mirror.Detach.Preview.self, .init(vaultID: row.vaultID))
        _take = State(initialValue: NodeMutation(Ws.Mirror.Takeover.self, on: queries,
                                                 invalidating: MirrorActions.invalidating))
    }

    var body: some View {
        let peer = MirrorModel.peerName(row)
        MirrorActionSheet(destructive: true, systemImage: "shield.lefthalf.filled",
                          title: MirrorCopy.takeoverTitle(row.vaultName),
                          description: outcome == nil ? MirrorCopy.takeoverBody(peer) : nil) {
            if let outcome {
                MirrorOutcome(label: MirrorCopy.tookOver, tone: .ok) {
                    Text(outcome.body).foregroundStyle(.fg)
                    if let missing = outcome.missing { Text(missing).foregroundStyle(.fgMuted) }
                    if let warning = outcome.warning { Text(warning).foregroundStyle(.fgMuted) }
                }
            } else {
                MirrorWarning(title: MirrorCopy.takeoverWarnTitle(peer)) {
                    Text(MirrorCopy.takeoverWarnBody(peer))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let p = preview.value?.preview, !MirrorActions.takeoverLines(p).isEmpty {
                    MirrorBullets(lines: MirrorActions.takeoverLines(p))
                }
                Text(MirrorCopy.takeoverSwitchHint(peer))
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
                MirrorTypedName(label: MirrorCopy.takeoverType(row.vaultName), name: row.vaultName, text: $typed)
                MirrorRefusal(title: MirrorCopy.takeoverFailed, error: take.error)
            }
        } buttons: {
            if outcome != nil {
                MirrorCloseButton(label: MirrorCopy.done)
            } else {
                MirrorCloseButton(disabled: take.isRunning)
                MirrorActionButton(label: take.isRunning ? MirrorCopy.takingOver : MirrorCopy.takeoverConfirm,
                                   destructive: true, running: take.isRunning,
                                   enabled: MirrorActions.takeoverPayload(row, typed: typed) != nil) {
                    Task { await submit() }
                }
            }
        }
        .observing(preview)
        .serverConfirmation(take, title: MirrorCopy.takeoverTitle(row.vaultName),
                            confirmLabel: MirrorCopy.takeoverConfirm, role: .destructive)
        .interactiveDismissDisabled(take.isRunning)
        .mirrorDebugConfirm {
            typed = row.vaultName
            await submit()
        }
    }

    private func submit() async {
        guard let payload = MirrorActions.takeoverPayload(row, typed: typed) else { return }
        if let response = await take.run(payload) {
            outcome = MirrorActions.TakeoverOutcome(response)
        }
    }
}
