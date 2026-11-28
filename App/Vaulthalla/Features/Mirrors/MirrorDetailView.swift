import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// One vault's mirror (`mirror.get`), as the console's detail page shows it: the state with its reason and what to
/// do next, where the two copies stand, the link, the per-link settings (read-only here) and, on a held copy, what
/// `mirror.detach.preview` (it changes nothing) says about it. The actions sit in ``MirrorActionsBar``.
struct MirrorDetailView: View {
    var node: Node
    var queries: NodeQueries
    var vaultID: Int64

    @Environment(AppModel.self) private var model

    var body: some View {
        let get = queries.query(Ws.Mirror.Get.self, .init(vaultID: vaultID))
        let row = get.value.map { MirroredVault($0.vault) }

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.stackSpacing + 4) {
                Button {
                    model.closeMirror()
                } label: {
                    Label(MirrorCopy.back, systemImage: "chevron.left")
                        .font(.callout)
                }
                .buttonStyle(.link)
                .foregroundStyle(.fgSubtle)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to the list (⌘[)")

                switch get.state {
                case .idle, .loading:
                    header(nil)
                    LoadingPanel(subject: "this mirror")
                case .failed(let error):
                    header(nil)
                    if case .denied = error {
                        Panel { EmptyState("Super admins only", systemImage: "lock", message: MirrorCopy.denied) }
                    } else {
                        ProblemPanel(problem: QueryProblem(error), node: node, subject: "this mirror") {
                            Task { await get.refresh() }
                        }
                    }
                case .loaded(_, let at):
                    if let row {
                        header(row)
                        StaleBanner(node: node, updatedAt: at, refreshError: get.refreshError,
                                    connected: queries.isConnected)
                        if row.role == .none {
                            Panel {
                                EmptyState(MirrorCopy.notMirroredTitle, systemImage: NodeSection.mirroredVaults.systemImage,
                                           message: MirrorCopy.notMirroredBody)
                            }
                        } else {
                            MirrorDetailBody(node: node, queries: queries, row: row)
                        }
                    }
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .modifier(MirrorActionPresenter(node: node, queries: queries))
        .observing(get, polling: Self.isRunning(row) ? MirrorPolling.running : MirrorPolling.list)
    }

    /// A first copy, a switch or a start moves quickly: poll faster.
    private static func isRunning(_ row: MirroredVault?) -> Bool {
        guard let row else { return false }
        return row.role == .starting || row.state == .starting || row.state == .switching
            || row.firstCopy.map { !$0.finished } == true
    }

    private func header(_ row: MirroredVault?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(node.displayName.uppercased())
                .font(.caption.weight(.medium))
                .tracking(0.8)
                .foregroundStyle(Color.accentText.opacity(0.8))
            HStack(alignment: .center, spacing: 10) {
                Text(row?.displayName ?? MirrorCopy.title)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.fg)
                    .lineLimit(1)
                if let row { MirrorRoleBadge(role: row.role) }
            }
            if let row {
                Text(MirrorModel.roleSentence(row))
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .frame(maxWidth: Theme.proseWidth, alignment: .leading)
            }
        }
    }
}

/// The loaded detail: status and details on the left, the actions on the right (stacked when narrow).
private struct MirrorDetailBody: View {
    var node: Node
    var queries: NodeQueries
    var row: MirroredVault

    var body: some View {
        let preview = row.role.holdsCopy && queries.supports(command: .mirrorDetachPreview) != .no
            ? queries.query(Ws.Mirror.Detach.Preview.self, .init(vaultID: row.vaultID)) : nil
        let heldCopy = preview?.value.map { MirrorHeldCopyFacts($0.preview) }

        AdaptiveColumns(weights: [2, 1], minColumnWidth: 300) {
            VStack(alignment: .leading, spacing: Theme.stackSpacing) {
                statusPanel(heldCopy: heldCopy)
                Panel(title: MirrorCopy.detailFacts) {
                    MirrorFactsGrid(items: facts(heldCopy: heldCopy, preview: preview))
                }
                if let settings = row.settings {
                    Panel(title: MirrorCopy.settingsTitle, subtitle: MirrorCopy.settingsBody) {
                        MirrorFactsGrid(items: settingsItems(settings))
                    }
                }
            }
            MirrorActionsBar(node: node, queries: queries, row: row, heldCopy: heldCopy)
        }
        .modifier(ObservingIfPresent(query: preview))
    }

    // MARK: Status

    private func statusPanel(heldCopy: MirrorHeldCopyFacts?) -> some View {
        let status = MirrorModel.status(row, MirrorFormat.facts(row))
        let advice = MirrorModel.advice(row, linkUp: row.linkIsUp, held: heldCopy?.heldChanges ?? 0)
        let progress = MirrorModel.firstCopyProgress(row.firstCopy)
        return Panel {
            VStack(alignment: .leading, spacing: 14) {
                MirrorStatusView(status: status, sentenceFont: .callout)
                if let progress {
                    VStack(alignment: .leading, spacing: 6) {
                        if let ratio = progress.ratio {
                            MirrorMeter(ratio: ratio)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(.accentFill)
                        }
                        Text(progress.text)
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                }
                if let advice {
                    Callout(tone: .info, systemImage: "lightbulb") {
                        Text(MirrorCopy.adviceLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.fgSubtle)
                        Text(advice)
                            .foregroundStyle(.fg)
                            .textSelection(.enabled)
                    }
                }
                if status.tone == .danger, let error = row.start?.lastError, !error.isEmpty,
                   !status.sentence.contains(error) {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.fgSubtle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Details

    private func facts(heldCopy: MirrorHeldCopyFacts?, preview: NodeQuery<Ws.Mirror.Detach.Preview>?)
        -> [MirrorFactsGrid.Item]
    {
        var items: [MirrorFactsGrid.Item] = [
            .init(MirrorCopy.detailServer, MirrorModel.peerName(row), faint: row.peer == nil),
            .init(MirrorCopy.detailLink, row.link.text, tone: row.link.tone),
        ]
        if row.hasMirrorRecord {
            let behind = MirrorModel.unconfirmed(row)
            let position = MirrorModel.positionText(row) + (behind.map { $0 > 0 ? " · \(MirrorCopy.unconfirmed($0))" : "" } ?? "")
            items.append(.init(MirrorCopy.detailPosition, position, monospacedDigits: true))
            items.append(.init(MirrorCopy.detailConfirmed,
                               row.confirmedAt.map(MirrorFormat.moment) ?? MirrorCopy.confirmedNever))
        }
        // What the held copy holds: the row says the pending changes on a mirror; the preview says the rest.
        if row.role.holdsCopy {
            let unknown = MirrorCopy.unknownValue
            let pending = row.role == .mirror ? row.pendingChanges : heldCopy?.pendingChanges
            items.append(.init(MirrorCopy.detailPending, pending.map(Format.count) ?? unknown,
                               tone: (pending ?? 0) > 0 ? .warn : nil, faint: pending == nil))
            items.append(.init(MirrorCopy.detailDigest, digestText(heldCopy),
                               tone: heldCopy?.digestMatched == false ? .danger : nil, faint: heldCopy == nil))
            items.append(.init(MirrorCopy.detailMissing, heldCopy.map { Format.count($0.missingCount) } ?? unknown,
                               tone: (heldCopy?.missingCount ?? 0) > 0 ? .warn : nil, faint: heldCopy == nil))
            items.append(.init(MirrorCopy.detailHeld, heldCopy.map { Format.count($0.heldChanges) } ?? unknown,
                               tone: (heldCopy?.heldChanges ?? 0) > 0 ? .warn : nil, faint: heldCopy == nil))
            if heldCopy == nil, let error = preview?.error {
                items.append(.init("", InlineProblemText.text(error), faint: true))
            }
        }
        if row.role == .mirror {
            items.append(.init(MirrorCopy.detailGrant, row.grant.map {
                "\(MirrorCopy.grantBy($0.roleName)) · \(MirrorFormat.date($0.grantedAt))"
            } ?? MirrorCopy.grantNone))
        }
        if let created = row.createdAt, created > 0 {
            items.append(.init(MirrorCopy.detailSince, MirrorFormat.date(created)))
        }
        return items
    }

    private func digestText(_ heldCopy: MirrorHeldCopyFacts?) -> String {
        guard let heldCopy else { return MirrorCopy.unknownValue }
        switch heldCopy.digestMatched {
        case true?: return MirrorCopy.digestMatched
        case false?: return MirrorCopy.digestDiffered
        case nil: return MirrorCopy.digestNotYet
        }
    }

    private func settingsItems(_ settings: MirroredVault.Settings) -> [MirrorFactsGrid.Item] {
        let peer = MirrorModel.peerName(row)
        let onOff = { (on: Bool) in on ? MirrorCopy.settingOn : MirrorCopy.settingOff }
        var items: [MirrorFactsGrid.Item] = [
            .init(MirrorCopy.acceptAllLabel(peer), onOff(settings.acceptAll)),
            .init(MirrorCopy.keepRemovedLabel(peer), onOff(settings.keepRemoved)),
        ]
        if row.role == .mirror {
            items.append(.init(MirrorCopy.versionsTitle, settings.versions.map {
                MirrorModel.versionsText($0, bytes: Format.bytes)
            } ?? MirrorCopy.unknownValue, faint: settings.versions == nil))
        }
        return items
    }
}

/// A key/value grid whose values may carry a status dot (the link) or read faint (unknown).
struct MirrorFactsGrid: View {
    struct Item: Identifiable {
        var term: String
        var value: String
        var tone: StatusTone?
        var faint = false
        var monospacedDigits = false

        var id: String { term + value }

        init(_ term: String, _ value: String, tone: StatusTone? = nil, faint: Bool = false,
             monospacedDigits: Bool = false) {
            self.term = term
            self.value = value
            self.tone = tone
            self.faint = faint
            self.monospacedDigits = monospacedDigits
        }
    }

    var items: [Item]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 10) {
            ForEach(items) { item in
                GridRow {
                    Text(item.term)
                        .foregroundStyle(.fgSubtle)
                        .gridColumnAlignment(.leading)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let tone = item.tone {
                            StatusDot(tone: tone, size: 7)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        }
                        Text(item.value)
                            .foregroundStyle(item.faint ? Color.fgSubtle : Color.fg)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.callout)
    }
}

/// The first copy's progress: a thin accent bar (the vault table's usage bar).
private struct MirrorMeter: View {
    var ratio: Double

    var body: some View {
        Capsule()
            .fill(.surface3)
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.accentFill)
                        .frame(width: proxy.size.width * min(max(ratio, 0), 1))
                }
            }
            .accessibilityElement()
            .accessibilityLabel(MirrorCopy.detailFirstCopy)
            .accessibilityValue(Format.percent(ratio, digits: 0))
    }
}

/// A failed read's words for a line in a grid.
enum InlineProblemText {
    static func text(_ error: WsError) -> String {
        switch QueryProblem(error) {
        case .denied: "This account can't read what detaching would give."
        case .notFound(let message), .failed(let message): message
        case .offline: "Not connected."
        case .noAnswerYet: "No answer yet."
        case .mismatch: "Not readable by this version."
        }
    }
}

/// Observes a query only when there is one (a read that applies to some rows).
private struct ObservingIfPresent<R: WsRequest>: ViewModifier {
    var query: NodeQuery<R>?

    func body(content: Content) -> some View {
        if let query {
            content.observing(query, polling: MirrorPolling.list)
        } else {
            content
        }
    }
}
