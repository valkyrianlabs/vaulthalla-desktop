import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// The Mirrored Vaults page's Relink requests (the console's RelinkRequestsPanel): the relinks linked servers ask of
/// this server's vaults (`mirror.relink.pending`). Both servers agree, each by a super admin: a request is accepted
/// first (the other server may then compare its copy with this vault: names, places, hashes, never contents), then the
/// outcome it proposes is approved (which server becomes the core, and what this vault gains and loses) before anything
/// changes here. Declining ends it on both servers. Shown only while one is listed, on THIS node's page: Desktop never
/// answers for a server on anything but a click here, even when this Mac is paired with the asking server too.
struct MirrorRelinkRequestsPanel: View {
    var queries: NodeQueries

    @State private var change: MirrorChange
    @State private var ask: Ask?

    init(queries: NodeQueries) {
        self.queries = queries
        _change = State(initialValue: MirrorChange(queries: queries))
    }

    private enum Ask: Identifiable {
        case accept(RelinkRequest)
        case decline(RelinkRequest)
        case approve(RelinkRequest)

        var id: String {
            switch self {
            case .accept(let q): "accept-\(q.id)"
            case .decline(let q): "decline-\(q.id)"
            case .approve(let q): "approve-\(q.id)"
            }
        }
    }

    var body: some View {
        let supported = queries.supports(command: .mirrorRelinkPending) != .no
        let pending = supported ? queries.query(Ws.Mirror.Relink.Pending.self, WsEmpty()) : nil
        let requests = (pending?.value?.requests ?? []).map(RelinkRequest.init)

        // A container that exists while empty, so the read below runs before anything shows.
        VStack(alignment: .leading, spacing: 0) {
            if !requests.isEmpty || change.problem != nil || change.notice != nil {
                Panel(title: MirrorRelinkCopy.requestsTitle, subtitle: requests.isEmpty ? nil : MirrorRelinkCopy.requestsBody) {
                    VStack(alignment: .leading, spacing: 12) {
                        MirrorChangeNote(change: change)
                        ForEach(requests) { q in
                            requestRow(q)
                            if q.id != requests.last?.id { Divider().overlay(Color.line) }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .task(id: supported) { await pending?.observe(polling: MirrorPolling.list) }
        .sheet(item: $ask) { ask in question(ask) }
        #if DEBUG
        .task(id: requests.count) { openDebugQuestion(requests) }
        #endif
    }

    private func requestRow(_ q: RelinkRequest) -> some View {
        HStack(alignment: .top, spacing: 14) {
            MirrorGlyph(role: .detached)
            VStack(alignment: .leading, spacing: 4) {
                (Text(q.vaultName).fontWeight(.medium).foregroundStyle(.fg)
                    + Text("  ") + Text(MirrorRelink.requestAsk(q)).foregroundStyle(.fgSubtle))
                    .font(.callout)
                    .lineLimit(2)
                // The page keeps its table: two lines here, the whole sentence in the tooltip and in the dialog.
                if q.phase == .requested, let discloses = q.handshake?.discloses {
                    Text(discloses)
                        .font(.caption)
                        .foregroundStyle(.fgMuted)
                        .lineLimit(2)
                        .help(discloses)
                }
                if q.phase == .proposed, let outcome = q.handshake?.outcome {
                    Text(outcome)
                        .font(.caption)
                        .foregroundStyle(.fgMuted)
                        .lineLimit(3)
                        .help(outcome)
                }
                HStack(spacing: 10) {
                    StatusBadge(label: q.phase.raw, tone: q.phase == .requested || q.phase == .proposed ? .warn : .info)
                    if let status = q.status { Text(MirrorRelinkCopy.thisServerStatus(status)) }
                    if let expires = q.handshake?.expiresAt {
                        Text(MirrorRelinkCopy.expires(Format.relative(epoch: expires)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.fgSubtle)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button(MirrorRelinkCopy.decline) { ask = .decline(q) }
                    .disabled(change.isBusy)
                if q.phase == .requested {
                    Button(MirrorRelinkCopy.accept) { ask = .accept(q) }
                        .buttonStyle(.borderedProminent)
                        .tint(.accentFill)
                        .disabled(change.isBusy)
                        .overlay {
                            if change.working == "relink-\(q.id)" { ProgressView().controlSize(.small) }
                        }
                }
                if q.phase == .proposed {
                    Button(MirrorRelinkCopy.reviewApprove) { ask = .approve(q) }
                        .buttonStyle(.borderedProminent)
                        .tint(.accentFill)
                        .disabled(change.isBusy)
                }
            }
            .fixedSize()
        }
    }

    // MARK: Questions

    @ViewBuilder
    private func question(_ ask: Ask) -> some View {
        switch ask {
        case .accept(let q):
            MirrorQuestionSheet(systemImage: "eye", title: MirrorRelinkCopy.acceptTitle(q.peerName, q.vaultName),
                                message: q.handshake?.discloses ?? "", confirmLabel: MirrorRelinkCopy.acceptConfirm) {
                Task { await accept(q) }
            }
        case .decline(let q):
            MirrorQuestionSheet(systemImage: "xmark.circle", title: MirrorRelinkCopy.declineTitle(q.peerName, q.vaultName),
                                message: MirrorRelinkCopy.declineBody, confirmLabel: MirrorRelinkCopy.decline,
                                destructive: true) {
                Task { await decline(q) }
            }
        case .approve(let q):
            MirrorRelinkApproveSheet(request: q, queries: queries) {
                change.problem = nil
                change.notice = .init(title: MirrorRelinkCopy.approved(q.peerName, q.vaultName),
                                      hint: MirrorRelinkCopy.approvedHint(q.peerName))
            }
        }
    }

    private func accept(_ q: RelinkRequest) async {
        if let done = await change.run(Ws.Mirror.Relink.Accept.self, MirrorRelink.acceptPayload(q), item: "relink-\(q.id)",
                                       failed: MirrorRelinkCopy.acceptFailed) {
            change.notice = .init(title: MirrorRelinkCopy.accepted(MirrorOffers.peerLabel(done.peer.name), done.vaultName),
                                  hint: MirrorRelinkCopy.acceptedHint)
        }
    }

    private func decline(_ q: RelinkRequest) async {
        if let done = await change.run(Ws.Mirror.Relink.Decline.self, MirrorRelink.declinePayload(q),
                                       item: "relink-\(q.id)", failed: MirrorRelinkCopy.declineFailed) {
            change.notice = .init(title: MirrorRelinkCopy.declined(MirrorOffers.peerLabel(done.peer.name), done.vaultName),
                                  hint: MirrorRelinkCopy.declinedHint)
        }
    }

    #if DEBUG
    private func openDebugQuestion(_ requests: [RelinkRequest]) {
        guard ask == nil else { return }
        switch MirrorRelinkDebug.state {
        case "approve": if let q = requests.first(where: { $0.phase == .proposed }) { ask = .approve(q) }
        case "accept": if let q = requests.first(where: { $0.phase == .requested }) { ask = .accept(q) }
        default: break
        }
    }
    #endif
}

/// The outcome a linked server proposes for one of this server's vaults, in the server's plain words and counts:
/// what approving overwrites or keeps aside here. Approved with the vault's name typed (`mirror.relink.approve`); the
/// keys step-up the server may ask for is said plainly when this Mac can't give it. Nothing changes on either server
/// before the click.
struct MirrorRelinkApproveSheet: View {
    var request: RelinkRequest
    var onApproved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var approve: NodeMutation<Ws.Mirror.Relink.Approve>

    init(request: RelinkRequest, queries: NodeQueries, onApproved: @escaping () -> Void) {
        self.request = request
        self.onApproved = onApproved
        _approve = State(initialValue: NodeMutation(Ws.Mirror.Relink.Approve.self, on: queries,
                                                    invalidating: MirrorActions.invalidating))
    }

    var body: some View {
        let q = request
        MirrorActionSheet(destructive: true, systemImage: "checkmark.shield",
                          title: MirrorRelinkCopy.approveTitle(q.peerName, q.vaultName),
                          description: MirrorRelinkCopy.approveBody, width: 580) {
            if let outcome = q.handshake?.outcome {
                Callout(tone: .warn, systemImage: "exclamationmark.triangle.fill") {
                    Text(outcome)
                        .foregroundStyle(.fg)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let p = q.handshake?.proposal {
                MirrorBullets(lines: [
                    MirrorRelinkCopy.serverSays("This server", MirrorRelink.gainsText(p.this)),
                    MirrorRelinkCopy.serverSays(q.peerName, MirrorRelink.gainsText(p.theirs)),
                    p.isOverride ? MirrorRelinkCopy.overrideLine : MirrorRelinkCopy.planLine(p.entries),
                ])
            }
            MirrorTypedName(label: MirrorRelinkCopy.typeToConfirm(q.vaultName), name: q.vaultName, text: $typed)
            MirrorRefusal(title: MirrorRelinkCopy.approveFailed, error: approve.error)
        } buttons: {
            MirrorCloseButton(label: MirrorRelinkCopy.cancel, disabled: approve.isRunning)
            MirrorActionButton(label: MirrorRelinkCopy.approve, destructive: true, running: approve.isRunning,
                               enabled: MirrorRelink.approvePayload(q, typed: typed) != nil) {
                Task { await submit() }
            }
        }
        .serverConfirmation(approve, title: MirrorRelinkCopy.approveTitle(q.peerName, q.vaultName),
                            confirmLabel: MirrorRelinkCopy.approve, role: .destructive)
        .interactiveDismissDisabled(approve.isRunning)
        .mirrorDebugConfirm {
            typed = q.vaultName
            await submit()
        }
    }

    private func submit() async {
        guard let payload = MirrorRelink.approvePayload(request, typed: typed) else { return }
        if await approve.run(payload) != nil {
            onApproved()
            dismiss()
        }
    }
}
