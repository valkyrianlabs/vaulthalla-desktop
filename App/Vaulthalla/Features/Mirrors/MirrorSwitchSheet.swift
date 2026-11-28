import SwiftUI
import VHContract
import VHCore
import VHNodes

/// A planned switch of the core role (`mirror.switch`), as the console's SwitchDialog: what it does, then the
/// outcome it waits for (switched, with the access the old core keeps; abandoned, with the reason; still running).
/// When the server refuses because the old core would keep no role on the vault, its sentence shows with a box to
/// tick; the switch is asked again only once the person ticks it and clicks Switch.
struct MirrorSwitchSheet: View {
    var row: MirroredVault

    @State private var flow = MirrorActions.SwitchFlow()
    @State private var run: NodeMutation<Ws.Mirror.Switch>

    init(row: MirroredVault, queries: NodeQueries) {
        self.row = row
        _run = State(initialValue: NodeMutation(Ws.Mirror.Switch.self, on: queries,
                                                invalidating: MirrorActions.invalidating))
    }

    var body: some View {
        let (from, to) = MirrorActions.switchSides(row)
        MirrorActionSheet(systemImage: "arrow.left.arrow.right", title: MirrorCopy.switchTitle(row.vaultName),
                          description: flow.outcome == nil
                              ? MirrorActions.capitalized(MirrorCopy.switchBody(from: from, to: to)) : nil) {
            if let outcome = flow.outcome {
                result(outcome)
            } else {
                if let noRole = flow.noRole {
                    MirrorWarning(title: MirrorCopy.switchNoAccessTitle) {
                        Text(noRole)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(MirrorActions.capitalized(MirrorCopy.switchNoAccess(from: from, to: to)))
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle(MirrorCopy.switchNoAccessAccept, isOn: $flow.acceptNoAccess)
                            .toggleStyle(.checkbox)
                            .foregroundStyle(.fg)
                            .padding(.top, 4)
                    }
                }
                MirrorRefusal(title: MirrorCopy.switchFailed, error: flow.failure)
            }
        } buttons: {
            if flow.outcome != nil {
                MirrorCloseButton(label: MirrorCopy.done)
            } else {
                MirrorCloseButton(disabled: run.isRunning)
                MirrorActionButton(label: run.isRunning ? MirrorCopy.switching : MirrorCopy.switchConfirm,
                                   running: run.isRunning, enabled: flow.canConfirm) {
                    Task { await start() }
                }
            }
        }
        .serverConfirmation(run, title: MirrorCopy.switchTitle(row.vaultName), confirmLabel: MirrorCopy.switchConfirm)
        .interactiveDismissDisabled(run.isRunning)
        .mirrorDebugConfirm { await start() }
    }

    @ViewBuilder
    private func result(_ outcome: MirrorActions.SwitchFlow.Outcome) -> some View {
        switch outcome {
        case .switched(let body, let access):
            MirrorOutcome(label: MirrorCopy.switched, tone: .ok) {
                Text(body).foregroundStyle(.fg)
                Text(access).foregroundStyle(.fgMuted)
            }
        case .abandoned(let body):
            MirrorOutcome(label: MirrorCopy.switchAbandoned, tone: .warn) {
                Text(body).foregroundStyle(.fgMuted)
            }
        case .running:
            MirrorOutcome(label: MirrorCopy.switchRunning, tone: .info) {
                Text(MirrorCopy.switchRunningBody).foregroundStyle(.fgMuted)
            }
        }
    }

    private func start() async {
        if let response = await run.run(flow.payload(row)) {
            flow.answered(response, row: row)
        } else if let error = run.error {
            flow.failed(error)
        }
    }
}
