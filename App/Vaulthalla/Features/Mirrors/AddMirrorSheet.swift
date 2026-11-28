import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Mirror a vault (`mirror.add`), the console's AddMirrorDialog: one of this server's vaults to one linked server,
/// with what the other server will hold and the two steps that follow. Nothing is chosen for the person; it only
/// creates an offer, and nothing is copied until the other server accepts it. The server checks every precondition
/// and refuses with its own sentence (an approval this Mac can't give included).
struct AddMirrorSheet: View {
    var queries: NodeQueries
    /// The page's `mirror.list` rows (vaults already mirrored aren't offered).
    var mirrored: [MirroredVault]
    /// The linked servers (`peer.list`, not unlinked).
    var peers: [Ws.Peer.List.Response.Peer]

    @State private var change: MirrorChange
    @State private var vaultID: Int64?
    @State private var peerID: Int64?
    @State private var offered: Ws.Mirror.Add.Response.Offer?
    @Environment(\.dismiss) private var dismiss

    init(queries: NodeQueries, mirrored: [MirroredVault], peers: [Ws.Peer.List.Response.Peer]) {
        self.queries = queries
        self.mirrored = mirrored
        self.peers = peers
        _change = State(initialValue: MirrorChange(queries: queries))
    }

    var body: some View {
        let vaults = queries.query(Ws.Storage.Vault.List.self)
        let choices = MirrorOffers.offerable(vaults.value?.vaults ?? [], id: \.id, mirrored: mirrored)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let payload = MirrorOffers.addPayload(vaultID: vaultID, peerID: peerID)

        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(systemImage: "rectangle.on.rectangle", title: MirrorOfferCopy.addTitle,
                        subtitle: MirrorOfferCopy.addDescription)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 18) {
                if let offered {
                    Callout(tone: .ok, systemImage: "checkmark.circle") {
                        Text(MirrorOfferCopy.offered(offered.name, peerName(offered.peerID)))
                            .fontWeight(.medium)
                            .foregroundStyle(.fg)
                        Text(MirrorOfferCopy.offeredHint).foregroundStyle(.fgMuted)
                    }
                } else {
                    field(MirrorOfferCopy.addVault, hint: choices.isEmpty ? nil : MirrorOfferCopy.addVaultHint) {
                        switch vaults.state {
                        case .idle, .loading:
                            ProgressView().controlSize(.small)
                        case .failed(let error):
                            Text(InlineProblemText.text(error)).foregroundStyle(.fgSubtle)
                        case .loaded:
                            if choices.isEmpty {
                                Text(MirrorOfferCopy.addVaultNone).foregroundStyle(.fgSubtle)
                            } else {
                                Picker(MirrorOfferCopy.addVault, selection: $vaultID) {
                                    Text(MirrorOfferCopy.addChoose).tag(Int64?.none)
                                    ForEach(choices, id: \.id) { Text($0.name).tag(Int64?.some($0.id)) }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 320, alignment: .leading)
                            }
                        }
                    }
                    field(MirrorOfferCopy.addServer, hint: MirrorOfferCopy.addServerHint) {
                        Picker(MirrorOfferCopy.addServer, selection: $peerID) {
                            Text(MirrorOfferCopy.addChoose).tag(Int64?.none)
                            ForEach(peers, id: \.id) { Text(MirrorOffers.peerLabel($0.name)).tag(Int64?.some($0.id)) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(MirrorOfferCopy.addSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1).")
                                    .monospacedDigit()
                                    .foregroundStyle(.fgSubtle)
                                Text(step)
                                    .foregroundStyle(.fgMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.callout)
                    MirrorChangeNote(change: change)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 22)

            SheetFooter {
                if offered != nil {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    if change.isBusy { ProgressView().controlSize(.small) }
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(MirrorOfferCopy.addSubmit) {
                        guard let payload else { return }
                        Task { await offer(payload) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentFill)
                    .disabled(payload == nil || change.isBusy)
                }
            }
        }
        .frame(width: 540)
        .observing(vaults)
        .interactiveDismissDisabled(change.isBusy)
    }

    private func peerName(_ id: Int64) -> String {
        MirrorOffers.peerLabel(peers.first { $0.id == id }?.name)
    }

    private func field<Content: View>(_ label: String, hint: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.fg)
            content()
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }
        }
    }

    private func offer(_ payload: Ws.Mirror.Add.Payload) async {
        if let done = await change.run(Ws.Mirror.Add.self, payload, item: "add", failed: MirrorOfferCopy.addFailed) {
            offered = done.offer
        }
    }
}
