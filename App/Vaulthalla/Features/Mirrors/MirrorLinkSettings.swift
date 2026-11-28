import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// The Mirrored Vaults page's Per linked server panel (the console's, below its table), kept to one line so the
/// table keeps its room: each linked server's Settings opens ``MirrorLinkSettingsSheet`` (a menu past two servers).
struct MirrorLinkSettingsPanel: View {
    var queries: NodeQueries
    var peers: [Ws.Peer.List.Response.Peer]
    var rows: [MirroredVault]

    @State private var open: Ws.Peer.List.Response.Peer?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.accentText)
                .frame(width: 30, height: 30)
                .background(.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(MirrorOfferCopy.settingsTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.fg)
                Text(MirrorOfferCopy.settingsBody)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if peers.count <= 2 {
                ForEach(peers, id: \.id) { peer in
                    Button {
                        open = peer
                    } label: {
                        HStack(spacing: 6) {
                            StatusDot(tone: peer.health.connected ? .ok : .warn, size: 6)
                            Text("\(MirrorOffers.peerLabel(peer.name)) \(MirrorOfferCopy.settingsOpen)…")
                                .lineLimit(1)
                        }
                    }
                    .help("\(MirrorOffers.peerLabel(peer.name)): \(peer.health.connected ? MirrorCopy.linkUp : MirrorCopy.linkDown)")
                }
            } else {
                Menu(MirrorOfferCopy.settingsOpen + "…") {
                    ForEach(peers, id: \.id) { peer in
                        Button("\(MirrorOffers.peerLabel(peer.name)) (\(peer.health.connected ? MirrorCopy.linkUp : MirrorCopy.linkDown))") {
                            open = peer
                        }
                    }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(.line, lineWidth: 1)
        }
        .sheet(item: $open) { peer in
            MirrorLinkSettingsSheet(queries: queries, peer: peer, rows: rows)
        }
        #if DEBUG
        .task(id: peers.count) {
            if open == nil, MirrorDebugSheet.requested?.hasPrefix("settings") == true { open = peers.first }
        }
        #endif
    }
}

extension Ws.Peer.List.Response.Peer: @retroactive Identifiable {}

/// One linked server's mirror settings (the console's LinkSettingsDialog, plus mirroring every vault): each switch
/// with the console's sentence on what it does. The server reports a setting only on a mirrored vault's row and in
/// the answer to setting it, so one nobody reported starts unchosen. Accept all and mirror all let vaults and keys
/// move without a further question: turning either on says so and waits for one more click.
struct MirrorLinkSettingsSheet: View {
    var queries: NodeQueries
    var peer: Ws.Peer.List.Response.Peer
    var rows: [MirroredVault]

    @Environment(\.dismiss) private var dismiss

    private var name: String { MirrorOffers.peerLabel(peer.name) }

    var body: some View {
        let unknown = MirrorLinkSetting.allCases.contains {
            MirrorOffers.current($0, peerID: peer.id, rows: rows) == nil
        }
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(systemImage: "gearshape", title: MirrorOfferCopy.settingsDialogTitle(name),
                        subtitle: unknown ? MirrorOfferCopy.settingsUnknown : MirrorOfferCopy.settingsBody)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(MirrorLinkSetting.allCases, id: \.self) { setting in
                    MirrorSettingRow(queries: queries, peer: peer, setting: setting,
                                     reported: MirrorOffers.current(setting, peerID: peer.id, rows: rows))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 22)
            SheetFooter {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 580)
    }
}

/// One switch: Off and On, neither chosen while unknown. Turning on a widening one first shows what it does.
private struct MirrorSettingRow: View {
    var queries: NodeQueries
    var peer: Ws.Peer.List.Response.Peer
    var setting: MirrorLinkSetting
    /// What a mirror row with that server reports; nil: unknown.
    var reported: Bool?

    @State private var change: MirrorChange
    /// What the server answered once set here, and when.
    @State private var answered: (enabled: Bool, at: Int64?)?
    /// Asking before turning a widening setting on.
    @State private var confirming = false

    init(queries: NodeQueries, peer: Ws.Peer.List.Response.Peer, setting: MirrorLinkSetting, reported: Bool?) {
        self.queries = queries
        self.peer = peer
        self.setting = setting
        self.reported = reported
        _change = State(initialValue: MirrorChange(queries: queries))
    }

    private var name: String { MirrorOffers.peerLabel(peer.name) }
    private var value: Bool? { answered?.enabled ?? reported }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(setting.label(name))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(setting.hint(name))
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(nowText)
                        .font(.caption)
                        .foregroundStyle(value == nil ? Color.fgFaint : Color.fgMuted)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker(setting.label(name), selection: Binding(get: { confirming ? true : value }, set: choose)) {
                    Text(MirrorOfferCopy.turnOff).tag(Bool?.some(false))
                    Text(MirrorOfferCopy.turnOn).tag(Bool?.some(true))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(change.isBusy)
            }
            if confirming, let warning = setting.turnOnWarning(name) {
                Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                    Text(setting == .acceptAll ? MirrorOfferCopy.acceptAllConfirmTitle(name)
                         : MirrorOfferCopy.mirrorAllConfirmTitle(name))
                        .fontWeight(.medium)
                        .foregroundStyle(.fg)
                    Text(warning)
                        .foregroundStyle(.fgMuted)
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Cancel") { confirming = false }
                            .keyboardShortcut(.cancelAction)
                        Button(MirrorOfferCopy.turnItOn) {
                            confirming = false
                            Task { await apply(true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StatusTone.warn.color)
                    }
                    .padding(.top, 6)
                }
            }
            MirrorChangeNote(change: change)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous).strokeBorder(.line, lineWidth: 1)
        }
        #if DEBUG
        .task {
            if MirrorDebugSheet.requested == "settings-confirm", setting == .acceptAll, value != true { confirming = true }
            // Shows a refusal: PREVIEW DATA answers turning mirror all on with an approval this Mac can't give.
            if MirrorDebugSheet.requested == "settings-refuse", setting == .mirrorAll,
               UserDefaults.standard.bool(forKey: "VHDebugPreviewData") {
                await apply(true)
            }
        }
        #endif
    }

    private var nowText: String {
        if let answered {
            return MirrorOfferCopy.settingIs(answered.enabled,
                                             Format.relative(epoch: answered.at ?? Int64(Date.now.timeIntervalSince1970)))
        }
        if let reported { return MirrorOfferCopy.settingNow(reported) }
        return MirrorOfferCopy.settingNotReported
    }

    private func choose(_ next: Bool?) {
        guard let next, next != value || confirming else { return }
        if next, setting.widens {
            confirming = true
            return
        }
        confirming = false
        Task { await apply(next) }
    }

    private func apply(_ enabled: Bool) async {
        let p = MirrorOffers.settingPayload(peerID: peer.id, enabled: enabled)
        let item = setting.rawValue
        let failed = MirrorOfferCopy.settingFailed
        let answer: (Bool, Int64?)?
        switch setting {
        case .acceptAll:
            answer = await change.run(Ws.Mirror.AcceptAll.Set.self, .init(peer: p.peer, enabled: p.enabled), item: item,
                                      failed: failed).map { ($0.enabled, $0.setAt) }
        case .keepRemoved:
            answer = await change.run(Ws.Mirror.KeepRemoved.Set.self, .init(peer: p.peer, enabled: p.enabled), item: item,
                                      failed: failed).map { ($0.enabled, $0.setAt) }
        case .mirrorAll:
            answer = await change.run(Ws.Mirror.MirrorAll.Set.self, .init(peer: p.peer, enabled: p.enabled), item: item,
                                      failed: failed).map { ($0.enabled, $0.setAt) }
        }
        if let answer { answered = (answer.0, answer.1) }
    }
}
