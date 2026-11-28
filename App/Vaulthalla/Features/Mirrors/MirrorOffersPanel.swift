import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// The Mirrored Vaults page's Offers (the console's OffersPanel): offers linked servers made this server
/// (`mirror.pending`), each with what accepting grants and where the copy lives, to accept or decline; and the offers
/// this server made that haven't finished (`mirror.list` starts on the core side), to cancel. Shown only while one
/// waits. Each answer is asked once more, with what it does, before it is sent.
struct MirrorOffersPanel: View {
    var queries: NodeQueries
    /// The page's `mirror.list` rows.
    var rows: [MirroredVault]
    /// Linked servers' names by their row id here (`peer.list`).
    var peerNames: [Int64: String]

    @State private var change: MirrorChange
    @State private var ask: Ask?

    init(queries: NodeQueries, rows: [MirroredVault], peerNames: [Int64: String]) {
        self.queries = queries
        self.rows = rows
        self.peerNames = peerNames
        _change = State(initialValue: MirrorChange(queries: queries))
    }

    private enum Ask: Identifiable {
        case accept(MirrorOffer)
        case decline(MirrorOffer)
        case cancel(MirroredVault)

        var id: String {
            switch self {
            case .accept(let o): "accept-\(o.id)"
            case .decline(let o): "decline-\(o.id)"
            case .cancel(let row): "cancel-\(row.id)"
            }
        }
    }

    var body: some View {
        let pending = queries.query(Ws.Mirror.Pending.self)
        let incoming = (pending.value?.offers ?? []).map(MirrorOffer.init)
        let outgoing = MirrorOffers.outgoing(rows)

        // A container that exists while empty, so the read below runs before anything shows.
        VStack(alignment: .leading, spacing: 0) {
            if !incoming.isEmpty || !outgoing.isEmpty || change.problem != nil || change.notice != nil {
                Panel(title: MirrorOfferCopy.offersTitle, subtitle: incoming.isEmpty ? nil : MirrorOfferCopy.offersBody) {
                    VStack(alignment: .leading, spacing: 12) {
                        MirrorChangeNote(change: change)
                        ForEach(incoming) { offer in
                            incomingRow(offer)
                            if offer.id != incoming.last?.id || !outgoing.isEmpty { Divider().overlay(Color.line) }
                        }
                        if !outgoing.isEmpty {
                            Text(MirrorOfferCopy.outgoingTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.fgSubtle)
                                .textCase(.uppercase)
                            ForEach(outgoing) { row in outgoingRow(row) }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .observing(pending, polling: MirrorPolling.list)
        .sheet(item: $ask) { ask in question(ask) }
        #if DEBUG
        .task(id: incoming.count + outgoing.count) { openDebugQuestion(incoming: incoming, outgoing: outgoing) }
        #endif
    }

    private func peer(_ id: Int64) -> String { MirrorOffers.peerLabel(peerNames[id]) }

    // MARK: Rows

    private func incomingRow(_ offer: MirrorOffer) -> some View {
        HStack(alignment: .center, spacing: 14) {
            MirrorGlyph(role: .starting)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(offer.name)
                        .fontWeight(.medium)
                        .foregroundStyle(.fg)
                        .lineLimit(1)
                    Text(MirrorOfferCopy.offerFrom(peer(offer.peerID)))
                        .foregroundStyle(.fgSubtle)
                        .lineLimit(1)
                }
                .font(.callout)
                Text(facts(offer).joined(separator: "  ·  "))
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .lineLimit(2)
                if !offer.description.isEmpty {
                    Text(offer.description)
                        .font(.caption)
                        .foregroundStyle(.fgMuted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(MirrorOfferCopy.decline) { ask = .decline(offer) }
                .disabled(change.isBusy)
            Button(MirrorOfferCopy.accept) { ask = .accept(offer) }
                .buttonStyle(.borderedProminent)
                .tint(.accentFill)
                .disabled(change.isBusy)
                .overlay {
                    if change.working == "offer-\(offer.id)" { ProgressView().controlSize(.small) }
                }
        }
    }

    private func facts(_ offer: MirrorOffer) -> [String] {
        var out = [MirrorOfferCopy.offerSize(Format.bytes(offer.sizeBytes), Format.count(offer.fileCount))]
        if let owner = offer.ownerName { out.append(MirrorOfferCopy.offerOwner(owner, peer(offer.peerID))) }
        if let role = offer.roleName { out.append(MirrorOfferCopy.offerGrant(role)) }
        if offer.history { out.append(MirrorOfferCopy.offerHistory) }
        if let expires = offer.expiresAt { out.append(MirrorOfferCopy.offerExpires(Format.relative(epoch: expires))) }
        return out
    }

    private func outgoingRow(_ row: MirroredVault) -> some View {
        let status = MirrorModel.status(row, MirrorFormat.facts(row))
        return HStack(alignment: .center, spacing: 14) {
            MirrorGlyph(role: .core)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.fg)
                        .lineLimit(1)
                    StatusBadge(label: status.label, tone: status.tone.statusTone)
                }
                Text(status.sentence)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .lineLimit(2)
                    .help(status.sentence)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(MirrorCopy.cancelStartAction) { ask = .cancel(row) }
                .disabled(change.isBusy)
                .help(MirrorCopy.cancelStartHint)
        }
    }

    // MARK: Questions

    @ViewBuilder
    private func question(_ ask: Ask) -> some View {
        switch ask {
        case .accept(let offer):
            MirrorQuestionSheet(systemImage: "tray.and.arrow.down", title: MirrorOfferCopy.acceptTitle(offer.name),
                                message: acceptMessage(offer), confirmLabel: MirrorOfferCopy.accept) {
                Task { await accept(offer) }
            }
        case .decline(let offer):
            MirrorQuestionSheet(systemImage: "xmark.circle", title: MirrorOfferCopy.declineTitle(offer.name),
                                message: MirrorOfferCopy.declineBody(peer(offer.peerID)),
                                confirmLabel: MirrorOfferCopy.decline, destructive: true) {
                Task { await decline(offer) }
            }
        case .cancel(let row):
            MirrorQuestionSheet(systemImage: "xmark.circle", title: MirrorOfferCopy.cancelStartTitle(row.displayName),
                                message: MirrorOfferCopy.cancelStartBody(MirrorModel.peerName(row)),
                                confirmLabel: MirrorOfferCopy.cancelStartConfirm, cancelLabel: MirrorOfferCopy.keepGoing,
                                destructive: true) {
                Task { await cancel(row) }
            }
        }
    }

    /// The console's sentence, then what the offer grants here (its proposed role), so it is read before Accept.
    private func acceptMessage(_ offer: MirrorOffer) -> String {
        var text = MirrorOfferCopy.acceptBody(offer.name, peer(offer.peerID))
        if let role = offer.roleName { text += "\n\n" + MirrorOfferCopy.offerGrant(role) + "." }
        return text
    }

    private func accept(_ offer: MirrorOffer) async {
        if let done = await change.run(Ws.Mirror.Accept.self, MirrorOffers.acceptPayload(offer), item: "offer-\(offer.id)",
                                       failed: MirrorOfferCopy.acceptFailed) {
            change.notice = .init(title: MirrorOfferCopy.accepted(done.offer.name), hint: MirrorOfferCopy.acceptedHint)
        }
    }

    private func decline(_ offer: MirrorOffer) async {
        if let done = await change.run(Ws.Mirror.Decline.self, MirrorOffers.declinePayload(offer),
                                       item: "offer-\(offer.id)", failed: MirrorOfferCopy.declineFailed) {
            change.notice = .init(title: MirrorOfferCopy.declined(done.offer.name))
        }
    }

    private func cancel(_ row: MirroredVault) async {
        if await change.run(Ws.Mirror.Cancel.self, MirrorOffers.cancelPayload(row), item: "start-\(row.id)",
                            failed: MirrorOfferCopy.cancelFailed) != nil {
            change.notice = .init(title: MirrorOfferCopy.startCancelled)
        }
    }

    #if DEBUG
    private func openDebugQuestion(incoming: [MirrorOffer], outgoing: [MirroredVault]) {
        guard ask == nil else { return }
        switch MirrorDebugSheet.requested {
        case "accept": if let offer = incoming.last { ask = .accept(offer) }
        case "decline": if let offer = incoming.first { ask = .decline(offer) }
        case "cancel": if let row = outgoing.first { ask = .cancel(row) }
        default: break
        }
    }
    #endif
}
