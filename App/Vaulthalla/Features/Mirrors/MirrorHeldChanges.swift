import AppKit
import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// A mirror's Held changes, under its details (the console's HeldChanges): changes made on this server that the core
/// refused (`mirror.held.list`), each with what was done to which file, the core's reason in its words, and Retry,
/// Discard (asked first, with the console's warning) and saving the person's version (`mirror.held.get`).
struct MirrorHeldChangesPanel: View {
    var queries: NodeQueries
    var row: MirroredVault

    @State private var change: MirrorChange
    @State private var showAll = false
    @State private var discarding: MirrorHeldChange?
    @State private var tooLarge: MirrorHeldChange?

    init(queries: NodeQueries, row: MirroredVault) {
        self.queries = queries
        self.row = row
        _change = State(initialValue: MirrorChange(queries: queries))
    }

    var body: some View {
        let list = queries.query(Ws.Mirror.Held.List.self, MirrorOffers.heldListPayload(vaultID: row.vaultID, all: showAll))
        let held = MirrorOffers.sortedHeld((list.value?.held ?? []).map(MirrorHeldChange.init))
        let live = MirrorOffers.retryIsLive(row)

        Panel(title: MirrorOfferCopy.heldTitle, subtitle: MirrorOfferCopy.heldBody) {
            VStack(alignment: .leading, spacing: 12) {
                MirrorChangeNote(change: change)
                if let tooLarge { tooLargeNote(tooLarge) }
                switch list.state {
                case .idle, .loading:
                    ProgressView().controlSize(.small)
                case .failed(let error):
                    Text(InlineProblemText.text(error))
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                case .loaded:
                    if held.isEmpty {
                        Text(MirrorOfferCopy.heldEmpty)
                            .font(.callout)
                            .foregroundStyle(.fgSubtle)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(held) { item in
                                heldRow(item, live: live)
                                if item.id != held.last?.id { Divider().overlay(Color.line) }
                            }
                        }
                    }
                }
            }
        } actions: {
            Toggle(MirrorOfferCopy.heldShowAll, isOn: $showAll)
                .toggleStyle(.checkbox)
                .font(.callout)
                .foregroundStyle(.fgMuted)
        }
        .observing(list, polling: MirrorPolling.list)
        .sheet(item: $discarding) { item in
            MirrorQuestionSheet(systemImage: "trash", title: MirrorOfferCopy.heldDiscardTitle,
                                message: MirrorOffers.discardBody(item), confirmLabel: MirrorOfferCopy.heldDiscard,
                                destructive: true) {
                Task { await discard(item) }
            }
        }
        #if DEBUG
        .task(id: held.count) {
            if discarding == nil, MirrorDebugSheet.requested == "discard" { discarding = held.first(where: \.isOpen) }
        }
        #endif
    }

    private func heldRow(_ item: MirrorHeldChange, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(MirrorOffers.heldPath(item))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(MirrorOffers.heldPath(item))
                    .textSelection(.enabled)
                StatusBadge(label: MirrorOffers.heldStateText(item.state),
                            tone: MirrorOffers.heldStateTone(item.state).statusTone)
                Spacer(minLength: 12)
                buttons(item, live: live)
            }
            Text("\(MirrorOffers.heldWhat(item)) · \(MirrorOfferCopy.heldBy(item.personID)) · \(Format.relative(epoch: item.createdAt))")
                .font(.caption)
                .foregroundStyle(.fgSubtle)
                .help(MirrorFormat.date(item.createdAt))
            (Text(MirrorOfferCopy.heldReasonHeader + ": ").foregroundStyle(.fgSubtle)
                + Text(MirrorOffers.heldReason(item)).foregroundStyle(.fgMuted))
                .font(.caption)
                .textSelection(.enabled)
        }
        .padding(.vertical, 9)
    }

    private func buttons(_ item: MirrorHeldChange, live: Bool) -> some View {
        HStack(spacing: 6) {
            if MirrorOffers.canSave(item) {
                Button {
                    Task { await save(item) }
                } label: {
                    Label(MirrorOfferCopy.heldDownload, systemImage: "arrow.down.doc")
                }
                .help(MirrorOfferCopy.heldDownload)
            }
            if MirrorOffers.canRetry(item) {
                Button {
                    Task { await retry(item) }
                } label: {
                    Label(MirrorOfferCopy.heldRetry, systemImage: "arrow.clockwise")
                }
                .disabled(!live)
                .help(live ? MirrorOfferCopy.heldRetryHint : MirrorOfferCopy.heldRetryNeedsLive)
            }
            if MirrorOffers.canDiscard(item) {
                Button(role: .destructive) {
                    discarding = item
                } label: {
                    Label(MirrorOfferCopy.heldDiscard, systemImage: "trash")
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .disabled(change.isBusy)
        .fixedSize()
    }

    private func tooLargeNote(_ item: MirrorHeldChange) -> some View {
        Callout(tone: .info, systemImage: "terminal") {
            Text(MirrorOfferCopy.heldTooLarge).foregroundStyle(.fgMuted)
            HStack(spacing: 8) {
                Text(MirrorOffers.saveCommand(item))
                    .font(.callout.monospaced())
                    .foregroundStyle(.fg)
                    .textSelection(.enabled)
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MirrorOffers.saveCommand(item), forType: .string)
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Actions

    private func retry(_ item: MirrorHeldChange) async {
        tooLarge = nil
        if await change.run(Ws.Mirror.Held.Retry.self, .init(id: item.id), item: "held-\(item.id)",
                            failed: MirrorOfferCopy.heldFailed) != nil {
            change.notice = .init(title: MirrorOfferCopy.heldRetried, hint: MirrorOfferCopy.heldRetriedHint)
        }
    }

    private func discard(_ item: MirrorHeldChange) async {
        tooLarge = nil
        if await change.run(Ws.Mirror.Held.Discard.self, .init(id: item.id), item: "held-\(item.id)",
                            failed: MirrorOfferCopy.heldFailed) != nil {
            change.notice = .init(title: MirrorOfferCopy.heldDiscarded)
        }
    }

    /// Fetches the person's version and asks where to save it. Too large to send inline: the server's command.
    private func save(_ item: MirrorHeldChange) async {
        tooLarge = nil
        change.problem = nil
        switch await queries.perform(Ws.Mirror.Held.Get.self, .init(id: item.id)) {
        case .success(let answer):
            guard let data = Data(base64Encoded: answer.contentB64) else {
                change.problem = .init(lead: MirrorOfferCopy.heldSaveFailed,
                                       message: "The server's answer wasn't readable.")
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = answer.name.isEmpty ? (item.name.isEmpty ? "held-version" : item.name) : answer.name
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                change.problem = .init(lead: MirrorOfferCopy.heldSaveFailed, message: error.localizedDescription)
            }
        case .failure(let error) where error.code == "too_large":
            tooLarge = item
        case .failure(let error):
            change.problem = .init(lead: MirrorOfferCopy.heldSaveFailed, message: MirrorRefusal.sentence(error))
        case .needsConfirmation(let request):
            change.problem = .init(lead: MirrorOfferCopy.heldSaveFailed, message: request.message)
        }
    }
}
