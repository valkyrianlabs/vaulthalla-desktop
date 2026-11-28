import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Detach a copy (`mirror.detach.copy {vault_id, name, owner}`), as the console's DetachCopyDialog: a new, separate
/// vault written from the copy held here, which stays as it is. The newest job (`mirror.detach.copy.get`) decides what
/// shows: a running one its progress and Cancel (`mirror.detach.copy.cancel`, asked first), one this sheet started
/// its outcome with the files left out, otherwise the form. The copy runs on the server: closing the sheet leaves it
/// running, the actions bar shows its progress, and opening the sheet again shows it.
struct MirrorDetachCopySheet: View {
    /// The copy's progress while it runs (the console's 1.5 s).
    static let poll: Duration = .milliseconds(1500)
    /// How many skipped files the sheet lists; the copy button carries every one the server listed.
    static let shownSkipped = 50

    var row: MirroredVault
    var node: Node
    var queries: NodeQueries

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var owner = ""
    /// The job this sheet started: its outcome stays shown once it ends.
    @State private var followed: Int64?
    @State private var started: MirrorCopyJob?
    @State private var askingCancel = false
    @State private var start: NodeMutation<Ws.Mirror.Detach.Copy>
    @State private var cancel: NodeMutation<Ws.Mirror.Detach.Copy.Cancel>
    private let job: NodeQuery<Ws.Mirror.Detach.Copy.Get>

    init(row: MirroredVault, node: Node, queries: NodeQueries) {
        self.row = row
        self.node = node
        self.queries = queries
        job = queries.query(Ws.Mirror.Detach.Copy.Get.self, .init(vaultID: row.vaultID))
        _start = State(initialValue: NodeMutation(Ws.Mirror.Detach.Copy.self, on: queries,
                                                  invalidating: MirrorActions.invalidating))
        _cancel = State(initialValue: NodeMutation(Ws.Mirror.Detach.Copy.Cancel.self, on: queries,
                                                   invalidating: MirrorActions.invalidating))
    }

    var body: some View {
        let read = job.value?.copy.flatMap(MirrorCopyJob.init)
        let (latest, shown) = MirrorCopyJob.shown(read: read, started: started, followed: followed)
        let running = shown?.isRunning == true

        MirrorActionSheet(systemImage: "doc.on.doc", title: MirrorCopy.copyTitle(row.vaultName),
                          description: shown == nil
                              ? MirrorCopy.copyBody(MirrorModel.peerName(row), follows: row.role == .mirror) : nil,
                          width: 580) {
            if job.value == nil, job.error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(MirrorCopy.copyLoading)
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                }
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            } else if let shown {
                outcome(shown)
            } else {
                form(latest)
            }
            if let error = job.error, job.value == nil {
                MirrorRefusal(title: MirrorCopy.loadFailed, error: error)
            }
            MirrorRefusal(title: MirrorCopy.copyCancelFailed, error: cancel.error)
        } buttons: {
            if let shown, shown.isRunning {
                MirrorCloseButton(label: MirrorCopy.done)
                Button(role: .destructive) {
                    askingCancel = true
                } label: {
                    HStack(spacing: 6) {
                        if cancel.isRunning || shown.cancelRequested { ProgressView().controlSize(.small) }
                        Text(shown.cancelRequested ? MirrorCopy.copyCancelling : MirrorCopy.copyCancel)
                    }
                }
                .disabled(cancel.isRunning || shown.cancelRequested)
            } else if shown != nil {
                Button(MirrorCopy.copyAgain) { again() }
                MirrorCloseButton(label: MirrorCopy.done)
            } else {
                MirrorCloseButton(disabled: start.isRunning)
                MirrorActionButton(label: MirrorCopy.copyStart, running: start.isRunning,
                                   enabled: job.value != nil || job.error != nil) {
                    Task { await submit() }
                }
            }
        }
        .confirmationDialog(MirrorCopy.copyCancelTitle(shown?.name ?? ""), isPresented: $askingCancel,
                            titleVisibility: .visible) {
            Button(MirrorCopy.copyCancel, role: .destructive) { Task { await cancelCopy() } }
            Button(MirrorCopy.keepGoing, role: .cancel) {}
        } message: {
            Text(MirrorCopy.copyCancelBody)
        }
        // Polls while a copy runs; a read when it opens either way.
        .task(id: running) { await job.observe(polling: running ? Self.poll : nil) }
        .task { await job.refresh() }
        .serverConfirmation(start, title: MirrorCopy.copyTitle(row.vaultName), confirmLabel: MirrorCopy.copyStart)
        .interactiveDismissDisabled(start.isRunning)
        .mirrorDebugConfirm {
            while job.value == nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            if job.value?.copy.flatMap(MirrorCopyJob.init)?.isRunning != true { await submit() }
        }
    }

    // MARK: Form

    @ViewBuilder
    private func form(_ last: MirrorCopyJob?) -> some View {
        Text(MirrorCopy.copyWhat)
            .font(.callout)
            .foregroundStyle(.fgMuted)
            .fixedSize(horizontal: false, vertical: true)
        if let last {
            Text(MirrorCopy.copyLast(last.name, MirrorFormat.date(last.finishedAt ?? last.updatedAt)))
                .font(.caption)
                .foregroundStyle(.fgSubtle)
        }
        MirrorField(label: MirrorCopy.copyName, hint: MirrorCopy.copyNameHint(row.vaultName)) {
            TextField("", text: $name, prompt: Text("\(row.vaultName) copy"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .frame(maxWidth: 360)
        }
        MirrorOwnerField(queries: queries, label: MirrorCopy.copyOwner, hint: MirrorCopy.copyOwnerHint, owner: $owner)
        MirrorRefusal(title: MirrorCopy.copyFailed, error: start.error)
    }

    // MARK: Outcome

    @ViewBuilder
    private func outcome(_ job: MirrorCopyJob) -> some View {
        let progress = job.progress(bytes: Format.bytes)
        switch job.state {
        case .running:
            MirrorOutcome(label: MirrorCopy.copyRunning, tone: .info) {
                Text(MirrorCopy.copyRunningBody(job.name)).foregroundStyle(.fgMuted)
                MirrorProgressBar(ratio: progress.ratio, label: MirrorCopy.copyRunning)
                    .padding(.top, 4)
                Text(progress.text)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .monospacedDigit()
            }
        case .finished:
            MirrorOutcome(label: MirrorCopy.copyFinished, tone: .ok) {
                Text(MirrorCopy.copyFinishedBody(job.name)).foregroundStyle(.fg)
                Text(progress.text)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .monospacedDigit()
                if job.vaultID != nil {
                    // The console opens the new vault; Desktop has no way to focus one vault yet, so this goes to the
                    // node's Vaults, where it is listed.
                    Button {
                        dismiss()
                        model.closeMirror()
                        model.selectNode(node.id, section: .vaults)
                    } label: {
                        Label("Go to Vaults", systemImage: "externaldrive")
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
        case .failed:
            MirrorOutcome(label: MirrorCopy.copyFailedState, tone: .danger) {
                Text(MirrorCopy.copyFailedBody(job.error.flatMap { $0.isEmpty ? nil : $0 })).foregroundStyle(.fgMuted)
            }
        case .cancelled:
            MirrorOutcome(label: MirrorCopy.copyCancelledState, tone: .neutralTone) {
                Text(MirrorCopy.copyCancelledBody).foregroundStyle(.fgMuted)
            }
        case .other(let state):
            MirrorOutcome(label: state, tone: .neutralTone) { Text(progress.text).foregroundStyle(.fgSubtle) }
        }
        skipped(job)
    }

    @ViewBuilder
    private func skipped(_ job: MirrorCopyJob) -> some View {
        if job.skippedCount > 0 {
            MirrorWarning(title: MirrorCopy.copySkippedTitle(job.skippedCount)) {
                if !job.skipped.isEmpty {
                    MirrorCopyListButton(label: MirrorCopy.copySkippedList,
                                         text: job.skipped.map(\.path).joined(separator: "\n"))
                }
            } content: {
                if !job.skipped.isEmpty {
                    let listed = min(job.skipped.count, Self.shownSkipped)
                    MirrorPathList(
                        items: job.skipped.prefix(Self.shownSkipped).map {
                            .init(id: $0.path, path: $0.path,
                                  detail: "\(MirrorCopyJob.skipText($0.reason)) · \(Format.bytes($0.sizeBytes))")
                        },
                        more: job.skippedCount > Int64(listed)
                            ? MirrorCopy.copySkippedMore(job.skippedCount - Int64(listed)) : nil)
                }
            }
        } else if job.state == .finished {
            Text(MirrorCopy.copyNoneSkipped)
                .font(.callout)
                .foregroundStyle(.fgMuted)
        }
    }

    // MARK: Actions

    private func submit() async {
        guard let response = await start.run(MirrorActions.copyPayload(row, name: name, owner: owner)),
              let copy = MirrorCopyJob(response.copy) else { return }
        started = copy
        followed = copy.id
        await job.refresh()
    }

    private func cancelCopy() async {
        if let response = await cancel.run(.init(vaultID: row.vaultID)), let copy = MirrorCopyJob(response.copy) {
            if copy.id == followed { started = copy }
            await job.refresh()
        }
    }

    private func again() {
        followed = nil
        started = nil
        name = ""
        start.reset()
        cancel.reset()
    }
}
