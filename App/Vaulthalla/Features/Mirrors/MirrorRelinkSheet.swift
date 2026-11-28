import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Reconnect a vault both servers hold since their mirror ended (detached, orphaned, rejoining, forked), as the
/// console's RelinkDialog (`mirror.relink.*`). Both servers agree, each by a super admin: opening asks the other server
/// (the person's click on Reconnect… is the request), and the sheet waits ("waiting for the other server's admin")
/// until its admin accepts in that server's own Relink requests; this server then compares the two trees, shows the
/// drift, and offers the two hard overrides (one server's tree wins everywhere) and the step-through (a choice per
/// entry, in bulk by kind, the plan's gains and losses). Nothing overwriting is chosen for the person. Applying names
/// the winning server and asks for the vault's name; it proposes the outcome, which the other server's admin approves
/// before anything changes, and the server then carries it out. A refusal is the server's sentence.
struct MirrorRelinkSheet: View {
    /// The console's 2 s while the relink moves or waits.
    static let poll: Duration = .seconds(2)

    enum Step: Hashable { case summary, review, confirm }

    var row: MirroredVault
    var queries: NodeQueries

    @State private var chosenPeer: Int64?
    @State private var step: Step = .summary
    @State private var keep: RelinkCore?
    @State private var typed = ""
    @State private var kind: RelinkKind?
    @State private var offset: Int64 = 0
    /// The relink and phase this sheet compared for (at most once each), and whether a compare has finished.
    @State private var comparedFor: String?
    @State private var comparedOnce = false
    @State private var notice: MirrorChange.Notice?
    @State private var compare: NodeMutation<Ws.Mirror.Relink.Compare>
    @State private var plan: NodeMutation<Ws.Mirror.Relink.Plan>
    @State private var apply: NodeMutation<Ws.Mirror.Relink.Apply>
    private let status: NodeQuery<Ws.Mirror.Relink.Get>
    private let peers: NodeQuery<Ws.Peer.List>

    init(row: MirroredVault, queries: NodeQueries) {
        self.row = row
        self.queries = queries
        status = queries.query(Ws.Mirror.Relink.Get.self, .init(vaultID: row.vaultID))
        peers = queries.query(Ws.Peer.List.self, .init(all: true))
        _compare = State(initialValue: NodeMutation(Ws.Mirror.Relink.Compare.self, on: queries, invalidating: ["mirror.relink"]))
        _plan = State(initialValue: NodeMutation(Ws.Mirror.Relink.Plan.self, on: queries, invalidating: ["mirror.relink"]))
        _apply = State(initialValue: NodeMutation(Ws.Mirror.Relink.Apply.self, on: queries,
                                                  invalidating: MirrorActions.invalidating))
    }

    // MARK: Derived

    private var linked: [Ws.Peer.List.Response.Peer] { (peers.value?.peers ?? []).filter { !$0.revoked } }

    private var ownPeer: Int64? {
        MirrorRelink.ownPeer(row, linked: linked.map { (id: $0.id, nodeID: $0.nodeID) })
    }

    private var peerID: Int64? { ownPeer ?? chosenPeer }

    private var peer: String {
        if let id = peerID, let p = (peers.value?.peers ?? []).first(where: { $0.id == id }) {
            return MirrorOffers.peerLabel(p.name)
        }
        return MirrorModel.peerName(row)
    }

    private var current: RelinkStatus? { status.value.map(RelinkStatus.init) }

    var body: some View {
        let s = current
        let phase = MirrorRelink.phaseText(s, peer: peer)

        MirrorActionSheet(systemImage: "link", title: MirrorRelinkCopy.title(row.vaultName),
                          description: MirrorRelinkCopy.description(peer), width: 680) {
            if ownPeer == nil, peers.value != nil {
                peerPicker
            }
            if let notice {
                Callout(tone: .info, systemImage: "hourglass") {
                    Text(notice.title).fontWeight(.medium).foregroundStyle(.fg)
                    if let hint = notice.hint { Text(hint).foregroundStyle(.fgMuted) }
                }
            }
            if let s, !compare.isRunning {
                loaded(s, phase: phase)
            } else if status.error == nil || compare.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(MirrorRelinkCopy.comparing)
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            MirrorRefusal(title: MirrorRelinkCopy.compareFailed, error: compare.error ?? (status.value == nil ? status.error : nil))
            MirrorRefusal(title: MirrorRelinkCopy.applyFailed, error: apply.error)
        } buttons: {
            if step == .confirm {
                Button(MirrorRelinkCopy.back) { step = keep == nil ? .review : .summary }
                    .disabled(apply.isRunning)
                MirrorActionButton(label: keep.map { MirrorRelinkCopy.keepTree(MirrorRelink.coreName($0, peer: peer)) }
                                       ?? MirrorRelinkCopy.applyThePlan,
                                   destructive: true, running: apply.isRunning, enabled: ready(s)) {
                    Task { await submit() }
                }
            } else {
                MirrorCloseButton(label: MirrorRelinkCopy.close, disabled: apply.isRunning)
            }
        }
        .task(id: phase.running) { await status.observe(polling: phase.running ? Self.poll : nil) }
        .observing(peers)
        // Asked (and compared) once on opening when there is no relink to show, and compared once the other
        // server's admin accepted. A relink waiting or running is shown as it is.
        .task(id: compareTrigger(s)) { await autoCompare(s) }
        .serverConfirmation(apply, title: MirrorRelinkCopy.title(row.vaultName),
                            confirmLabel: MirrorRelinkCopy.applyThePlan, role: .destructive)
        .interactiveDismissDisabled(apply.isRunning)
        #if DEBUG
        .task { openDebugStep() }
        #endif
    }

    // MARK: Loaded

    @ViewBuilder
    private func loaded(_ s: RelinkStatus, phase: MirrorRelink.PhaseText) -> some View {
        let isOpen = MirrorRelink.isOpen(s)
        let waiting = MirrorRelink.isWaiting(s)
        HStack(alignment: .center, spacing: 10) {
            RelinkPhaseLine(text: phase.text, tone: phase.tone.statusTone, running: phase.running)
            if !phase.running, s.relink?.side != .responder {
                Button(MirrorRelink.compareAgainLabel(s)) { Task { await runCompare() } }
                    .controlSize(.small)
                    .disabled(peerID == nil)
            }
            if waiting {
                Button(MirrorRelinkCopy.cancelRequest) { Task { await edit(.discard) } }
                    .controlSize(.small)
                    .disabled(plan.isRunning)
            }
        }
        if waiting, s.relink?.phase == .proposed, let p = s.handshake?.proposal {
            MirrorBullets(lines: [
                MirrorRelinkCopy.proposedCore(MirrorRelink.coreName(p.core ?? .this, peer: peer), override: p.isOverride),
                MirrorRelinkCopy.serverSays("This server", MirrorRelink.gainsText(p.this)),
                MirrorRelinkCopy.serverSays(peer, MirrorRelink.gainsText(p.theirs)),
            ])
        }
        if let relink = s.relink, relink.phase == .bring || relink.phase == .copying, let bring = s.bring {
            Text(MirrorRelinkCopy.brought(Format.count(bring.done), Format.count(bring.total)))
                .font(.callout)
                .foregroundStyle(.fgMuted)
                .monospacedDigit()
        }
        if step == .summary, isOpen { summary(s) }
        if step == .review, isOpen { review(s) }
        if step == .confirm { confirmStep(s) }
    }

    @ViewBuilder
    private func summary(_ s: RelinkStatus) -> some View {
        let lines = MirrorRelink.countLines(s.counts, peer: peer)
        let blocked = !s.blockers.isEmpty
        VStack(alignment: .leading, spacing: 12) {
            if let total = MirrorRelink.totalText(s.total, count: Format.count) {
                Text(total)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.fg)
            }
            if !lines.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 5) {
                    ForEach(Array(stride(from: 0, to: lines.count, by: 2)), id: \.self) { i in
                        GridRow {
                            countCell(lines[i])
                            if i + 1 < lines.count { countCell(lines[i + 1]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        }
                    }
                }
                .font(.callout)
            }
            if blocked {
                MirrorWarning(title: s.blockers.count == 1 ? s.blockers[0].message : MirrorRelinkCopy.compareFailed) {
                    if s.blockers.count > 1 { MirrorBullets(lines: s.blockers.map(\.message)) }
                }
            }
            HStack(spacing: 8) {
                Button { toConfirm(.this) } label: {
                    Text(MirrorRelinkCopy.keepThis).frame(maxWidth: .infinity)
                }
                .disabled(blocked)
                Button { toConfirm(.theirs) } label: {
                    Text(MirrorRelinkCopy.keepTheirs(peer)).lineLimit(1).frame(maxWidth: .infinity)
                }
                .disabled(blocked)
                Button { step = .review } label: {
                    Text(MirrorRelinkCopy.review).frame(maxWidth: .infinity)
                }
                .disabled(blocked || s.total == 0)
            }
            .controlSize(.large)
        }
    }

    private func countCell(_ line: MirrorRelink.CountLine) -> some View {
        HStack(spacing: 12) {
            Text(line.label).foregroundStyle(.fgMuted).lineLimit(1)
            Spacer(minLength: 8)
            Text(Format.count(line.count)).foregroundStyle(.fg).monospacedDigit()
        }
        .frame(width: 286)
    }

    // MARK: Review

    @ViewBuilder
    private func review(_ s: RelinkStatus) -> some View {
        let core = s.plan?.core ?? .this
        let entries = queries.query(Ws.Mirror.Relink.Entries.self,
                                    MirrorRelink.entriesPayload(vaultID: row.vaultID, kind: kind, offset: offset))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                MirrorField(label: MirrorRelinkCopy.coreLabel) {
                    Picker(MirrorRelinkCopy.coreLabel, selection: Binding(
                        get: { core },
                        set: { value in Task { await edit(.core(value)) } })) {
                        Text(MirrorRelinkCopy.thisServerOption).tag(RelinkCore.this)
                        Text(peer).tag(RelinkCore.theirs)
                    }
                    .labelsHidden()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MirrorField(label: MirrorRelinkCopy.leftUnset) {
                    Picker(MirrorRelinkCopy.leftUnset, selection: Binding(
                        get: { s.plan?.defaultChoice },
                        set: { value in Task { await edit(.defaultChoice(value)) } })) {
                        Text(MirrorRelinkCopy.coresVersion).tag(RelinkChoice?.none)
                        ForEach(RelinkChoice.allCases, id: \.self) {
                            Text(MirrorRelink.choiceText($0, peer: peer)).tag(RelinkChoice?.some($0))
                        }
                    }
                    .labelsHidden()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(plan.isRunning)
            MirrorBullets(lines: [
                MirrorRelinkCopy.serverSays("This server", MirrorRelink.gainsText(s.plan?.this)),
                MirrorRelinkCopy.serverSays(peer, MirrorRelink.gainsText(s.plan?.theirs)),
            ])
            HStack(alignment: .bottom, spacing: 10) {
                MirrorField(label: MirrorRelinkCopy.show) {
                    Picker(MirrorRelinkCopy.show, selection: Binding(
                        get: { kind },
                        set: { kind = $0; offset = 0 })) {
                        Text(MirrorRelinkCopy.everyKind).tag(RelinkKind?.none)
                        ForEach(RelinkKind.known, id: \.self) {
                            Text(MirrorRelink.kindText($0, peer: peer)).tag(RelinkKind?.some($0))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                Menu(MirrorRelinkCopy.setAllShown) {
                    ForEach(RelinkChoice.allCases, id: \.self) { choice in
                        let text = MirrorRelink.choiceText(choice, peer: peer)
                        Button(choice == .both ? MirrorRelinkCopy.bothFiles(text) : text) {
                            Task { await edit(.shown(kind: kind, choice: choice)) }
                        }
                    }
                    Divider()
                    Button(MirrorRelinkCopy.theDefault) { Task { await edit(.shown(kind: kind, choice: nil)) } }
                }
                .fixedSize()
                .disabled(plan.isRunning)
                Spacer(minLength: 0)
            }
            entryList(entries, core: core)
            HStack {
                Button(MirrorRelinkCopy.back) { step = .summary }
                Spacer()
                Button(MirrorRelinkCopy.applyPlan) { toConfirm(nil) }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentFill)
                    .disabled(!s.blockers.isEmpty)
            }
            MirrorRefusal(title: MirrorRelinkCopy.planFailed, error: plan.error)
        }
        .task(id: "\(kind?.raw ?? "")-\(offset)") { await entries.observe(polling: nil) }
    }

    @ViewBuilder
    private func entryList(_ entries: NodeQuery<Ws.Mirror.Relink.Entries>, core: RelinkCore) -> some View {
        if let page = entries.value {
            let rows = page.entries.map(RelinkEntry.init)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { entry in
                        entryRow(entry, core: core)
                        if entry.id != rows.last?.id { Divider().overlay(Color.line) }
                    }
                }
            }
            .frame(height: min(CGFloat(max(rows.count, 1)) * 49, 288))
            .background(Color.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Color.line, lineWidth: 1)
            }
            if let text = MirrorRelink.pageText(offset: offset, total: page.total, count: Format.count) {
                HStack {
                    Text(text)
                    Spacer()
                    Button(MirrorRelinkCopy.previous) { offset = max(0, offset - MirrorRelink.page) }
                        .disabled(offset == 0)
                    Button(MirrorRelinkCopy.next) { offset += MirrorRelink.page }
                        .disabled(offset + MirrorRelink.page >= page.total)
                }
                .font(.caption)
                .foregroundStyle(.fgSubtle)
                .monospacedDigit()
                .controlSize(.small)
            }
        } else if let error = entries.error {
            MirrorRefusal(title: MirrorRelinkCopy.compareFailed, error: error)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    private func entryRow(_ e: RelinkEntry, core: RelinkCore) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.fg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(e.path)
                Text(MirrorRelink.kindText(e.kind, peer: peer) + (e.aspects.isEmpty ? "" : " · " + e.aspects.joined(separator: ", ")))
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Choice for \(e.path)", selection: Binding(
                get: { e.choice },
                set: { value in Task { await edit(.entry(uid: e.uid, choice: value)) } })) {
                // The console lowercases the whole label ("keep offsite’s"); only its first word here, so a server
                // keeps its name's spelling.
                let winner = MirrorRelink.winnerOf(e.resolution, core: core)
                    .map { MirrorRelink.choiceText($0, peer: peer).replacingOccurrences(of: "Keep ", with: "keep ") }
                Text(MirrorRelinkCopy.defaultChoice(winner)).tag(RelinkChoice?.none)
                Text(MirrorRelink.choiceText(.this, peer: peer)).tag(RelinkChoice?.some(.this))
                Text(MirrorRelink.choiceText(.theirs, peer: peer)).tag(RelinkChoice?.some(.theirs))
                if MirrorRelink.canKeepBoth(e) {
                    Text(MirrorRelink.choiceText(.both, peer: peer)).tag(RelinkChoice?.some(.both))
                }
            }
            .labelsHidden()
            .frame(width: 270, alignment: .trailing)
            .disabled(plan.isRunning)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: Confirm

    @ViewBuilder
    private func confirmStep(_ s: RelinkStatus) -> some View {
        let core = s.plan?.core ?? .this
        let winner = keep ?? core
        MirrorWarning(title: keep != nil ? MirrorRelinkCopy.winsTitle(MirrorActions.capitalized(MirrorRelink.coreName(winner, peer: peer)))
                                         : MirrorRelinkCopy.planTitle(MirrorActions.capitalized(MirrorRelink.coreName(core, peer: peer)))) {
            Text(MirrorRelinkCopy.confirmBody(MirrorActions.capitalized(MirrorRelink.coreName(winner, peer: peer)), peer: peer))
                .fixedSize(horizontal: false, vertical: true)
        }
        MirrorTypedName(label: MirrorRelinkCopy.typeToConfirm(row.vaultName), name: row.vaultName, text: $typed)
    }

    private var peerPicker: some View {
        MirrorField(label: MirrorRelinkCopy.linkedServer) {
            Picker(MirrorRelinkCopy.linkedServer, selection: $chosenPeer) {
                Text(MirrorRelinkCopy.choose).tag(Int64?.none)
                ForEach(linked, id: \.id) { Text(MirrorOffers.peerLabel($0.name)).tag(Int64?.some($0.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)
        }
    }

    // MARK: Actions

    private func ready(_ s: RelinkStatus?) -> Bool {
        MirrorRelink.applyPayload(row, typed: typed, keep: keep, peerID: peerID) != nil && !apply.isRunning
            && (s?.blockers.isEmpty ?? true)
    }

    private func toConfirm(_ which: RelinkCore?) {
        keep = which
        typed = ""
        step = .confirm
    }

    private func compareTrigger(_ s: RelinkStatus?) -> String {
        "\(s.map(MirrorRelink.compareKey) ?? "unread")|\(peerID.map(String.init) ?? "-")"
    }

    private func autoCompare(_ s: RelinkStatus?) async {
        guard let s, peerID != nil, !compare.isRunning, comparedFor != MirrorRelink.compareKey(s),
              MirrorRelink.shouldCompare(s, comparedOnce: comparedOnce) else { return }
        comparedFor = MirrorRelink.compareKey(s)
        await runCompare()
    }

    private func runCompare() async {
        guard let payload = MirrorRelink.comparePayload(row, peerID: peerID) else { return }
        notice = nil
        _ = await compare.run(payload)
        comparedOnce = true
        await status.refresh()
    }

    private func edit(_ edit: MirrorRelink.PlanEdit) async {
        _ = await plan.run(MirrorRelink.planPayload(vaultID: row.vaultID, edit))
    }

    private func submit() async {
        guard let payload = MirrorRelink.applyPayload(row, typed: typed, keep: keep, peerID: peerID) else { return }
        if let response = await apply.run(payload) {
            let phase = response.relink.map { RelinkPhase($0.phase) }
            notice = phase == .proposed || phase == .requested
                ? .init(title: MirrorRelinkCopy.waitingTitle(peer), hint: MirrorRelinkCopy.waitingBody(peer))
                : .init(title: MirrorRelinkCopy.relinkingTitle(row.vaultName, peer), hint: MirrorRelinkCopy.relinkingBody)
            step = .summary
            typed = ""
            await status.refresh()
        }
    }

    #if DEBUG
    /// `-VHDebugRelink plan|confirm` opens the sheet on that step (DebugSnapshot); PREVIEW DATA only.
    private func openDebugStep() {
        switch MirrorRelinkDebug.state {
        case "plan": step = .review
        case "confirm":
            keep = .theirs
            step = .confirm
        default: break
        }
    }
    #endif
}

/// The relink's phase in words, wrapping, with its tone's dot.
struct RelinkPhaseLine: View {
    var text: String
    var tone: StatusTone
    var running = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(tone: tone, size: 7, pulse: running)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .font(.callout)
                .foregroundStyle(.fg)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.soft, in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous).strokeBorder(tone.line, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// `-VHDebugRelink <state>` (DebugSnapshot): which relink PREVIEW DATA answers and which step or dialog opens:
/// `requested`, `waiting`, `comparison`, `plan`, `confirm`, `approve`, `panel`, `applied`, `refused`.
enum MirrorRelinkDebug {
    static var state: String? {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "VHDebugPreviewData") else { return nil }
        return UserDefaults.standard.string(forKey: "VHDebugRelink")
        #else
        nil
        #endif
    }
}
