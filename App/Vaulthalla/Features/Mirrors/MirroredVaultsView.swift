import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// A node's Mirrored Vaults page (the web console's Linked servers › Mirrored vaults): every vault mirrored with a
/// linked server and every start in progress (`mirror.list`, super admins), and one vault's detail
/// (``MirrorDetailView``). Read-only for now: the actions arrive in ``MirrorActionsBar``.
struct MirroredVaultsView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        if let queries = model.liveQueries(for: node) {
            Group {
                if let focus = model.mirrorFocus, focus.node == node.id {
                    MirrorDetailView(node: node, queries: queries, vaultID: focus.vaultID)
                        .id(focus.vaultID)
                } else {
                    MirrorListScreen(node: node, queries: queries)
                }
            }
            .environment(queries)
            #if DEBUG
            .task { openDebugMirror() }
            #endif
        } else {
            PlaceholderSection(node: node, section: .mirroredVaults)
        }
    }

    #if DEBUG
    /// `-VHDebugMirror <vault id>` opens that vault's mirror detail (DebugSnapshot).
    private func openDebugMirror() {
        let id = Int64(UserDefaults.standard.integer(forKey: "VHDebugMirror"))
        guard id > 0, model.mirrorFocus == nil else { return }
        model.openMirror(id, on: node.id)
    }
    #endif
}

// MARK: - List

/// The polls: a mirror's state moves on its own (the link, the first copy, the core), so a light one, faster on a
/// detail while something runs (the console's 15 s and 5 s).
enum MirrorPolling {
    static let list: Duration = .seconds(15)
    static let running: Duration = .seconds(5)
}

private struct MirrorListScreen: View {
    var node: Node
    var queries: NodeQueries

    @Environment(AppModel.self) private var model
    @State private var selection: MirrorListRow.ID?
    @State private var sortOrder: [KeyPathComparator<MirrorListRow>] = [KeyPathComparator(\.order)]
    @State private var filter = ""

    var body: some View {
        let list = queries.query(Ws.Mirror.List.self)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(eyebrow: node.displayName, title: MirrorCopy.title, subtitle: MirrorCopy.description) {
                let status = model.status(for: node)
                StatusBadge(label: status.label, tone: status.tone, pulse: status.isTransitional)
            }
            .padding([.horizontal, .top], Theme.pagePadding)
            .padding(.bottom, 16)

            switch list.state {
            case .idle, .loading:
                LoadingPanel(subject: "mirrored vaults")
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .failed(let error):
                failure(error, list: list)
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .loaded(let value, let at):
                StaleBanner(node: node, updatedAt: at, refreshError: list.refreshError, connected: queries.isConnected)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 12)
                if value.vaults.isEmpty {
                    MirrorsEmptyState(queries: queries)
                        .padding(.horizontal, Theme.pagePadding)
                    Spacer(minLength: 0)
                } else {
                    table(rows(value.vaults))
                }
            }
        }
        .observing(list, polling: MirrorPolling.list)
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter Vaults")
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    @ViewBuilder
    private func failure(_ error: WsError, list: NodeQuery<Ws.Mirror.List>) -> some View {
        if case .denied = error {
            Panel {
                EmptyState("Super admins only", systemImage: "lock", message: MirrorCopy.denied)
            }
        } else {
            ProblemPanel(problem: QueryProblem(error), node: node, subject: "mirrored vaults") {
                Task { await list.refresh() }
            }
        }
    }

    // MARK: Table

    private func table(_ rows: [MirrorListRow]) -> some View {
        Table(rows, selection: selectionOpening(rows), sortOrder: $sortOrder) {
            TableColumn(MirrorCopy.colVault, value: \.sortName) { row in
                HStack(spacing: 10) {
                    MirrorGlyph(role: row.vault.role)
                    Text(row.vault.displayName)
                        .foregroundStyle(.fg)
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
                .help(row.vault.vaultID > 0 ? "" : "Not created on this server yet")
            }
            .width(min: 150, ideal: 190)

            TableColumn(MirrorCopy.colServer, value: \.sortServer) { row in
                Text(MirrorModel.peerName(row.vault))
                    .foregroundStyle(row.vault.peer == nil ? Color.fgFaint : Color.fgMuted)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 130, max: 200)

            TableColumn(MirrorCopy.colRole, value: \.sortRole) { row in
                MirrorRoleBadge(role: row.vault.role)
            }
            .width(min: 80, ideal: 100, max: 130)

            TableColumn(MirrorCopy.colState, value: \.status.label) { row in
                VStack(alignment: .leading, spacing: 3) {
                    StatusBadge(label: row.status.label, tone: row.status.tone.statusTone)
                    Text(row.status.sentence)
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help(row.status.sentence)
            }
            .width(min: 180, ideal: 260)

            TableColumn(MirrorCopy.colPending, value: \.sortPending) { row in
                pending(row.vault)
            }
            .width(min: 56, ideal: 64, max: 90)

            TableColumn(MirrorCopy.colConfirmed, value: \.sortConfirmed) { row in
                confirmed(row.vault)
            }
            .width(min: 100, ideal: 140, max: 180)

            TableColumn(MirrorCopy.colLink, value: \.sortLink) { row in
                MirrorLinkLabel(link: row.vault.link)
            }
            .width(min: 100, ideal: 110, max: 140)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: MirrorListRow.ID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }), row.vault.vaultID > 0 {
                Button("Show Details") { model.openMirror(row.vault.vaultID, on: node.id) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }), row.vault.vaultID > 0 {
                model.openMirror(row.vault.vaultID, on: node.id)
            }
        }
    }

    /// A row opens its detail when picked, as the console's rows are links; a start whose vault doesn't exist here
    /// yet has none and only selects.
    private func selectionOpening(_ rows: [MirrorListRow]) -> Binding<MirrorListRow.ID?> {
        Binding(
            get: { selection },
            set: { id in
                selection = id
                if let id, let row = rows.first(where: { $0.id == id }), row.vault.vaultID > 0 {
                    model.openMirror(row.vault.vaultID, on: node.id)
                }
            })
    }

    @ViewBuilder
    private func pending(_ vault: MirroredVault) -> some View {
        if !vault.hasMirrorRecord {
            Text("—").foregroundStyle(.fgFaint)
        } else if vault.pendingChanges > 0 {
            Text(Format.count(vault.pendingChanges))
                .foregroundStyle(StatusTone.warn.color)
                .monospacedDigit()
                .help(vault.role == .core ? "Changes numbered here that the mirror hasn't acknowledged yet"
                    : "Changes made here that the core hasn't confirmed yet")
        } else {
            Text(MirrorCopy.pendingNone).foregroundStyle(.fgFaint)
        }
    }

    @ViewBuilder
    private func confirmed(_ vault: MirroredVault) -> some View {
        if !vault.hasMirrorRecord {
            Text("—").foregroundStyle(.fgFaint)
        } else if let at = vault.confirmedAt {
            Text(Format.relative(epoch: at))
                .foregroundStyle(.fgMuted)
                .help(MirrorFormat.date(at))
        } else {
            Text(MirrorCopy.confirmedNever).foregroundStyle(.fgSubtle)
        }
    }

    private func rows(_ vaults: [Ws.Mirror.List.Response.Vault]) -> [MirrorListRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let ordered = MirrorModel.sorted(vaults.map(MirroredVault.init))
        return ordered.enumerated()
            .map { MirrorListRow(vault: $1, order: $0) }
            .filter { needle.isEmpty || $0.searchText.contains(needle) }
            .sorted(using: sortOrder)
    }
}

/// One row of the table: the vault with its state in words, and what the columns sort by.
private nonisolated struct MirrorListRow: Identifiable {
    var vault: MirroredVault
    /// The console's order (live ones first, then starts, orphans and ended ones).
    var order: Int
    var status: MirrorModel.Status

    init(vault: MirroredVault, order: Int) {
        self.vault = vault
        self.order = order
        self.status = MirrorModel.status(vault, MirrorFormat.facts(vault))
    }

    var id: String { vault.id }
    var sortName: String { vault.displayName.lowercased() }
    var sortServer: String { MirrorModel.peerName(vault).lowercased() }
    var sortRole: String { MirrorModel.roleText(vault.role).label }
    var sortPending: Int64 { vault.hasMirrorRecord ? vault.pendingChanges : -1 }
    var sortConfirmed: Int64 { vault.hasMirrorRecord ? vault.confirmedAt ?? 0 : -1 }
    var sortLink: String { vault.link.text }

    var searchText: String {
        [vault.displayName, MirrorModel.peerName(vault), vault.role.rawValue, status.label].joined(separator: " ").lowercased()
    }
}

/// The list's empty state: no linked server yet, or none of its vaults mirrored. Asks `peer.list` only to choose.
private struct MirrorsEmptyState: View {
    var queries: NodeQueries

    var body: some View {
        let peers = queries.query(Ws.Peer.List.self, .init(all: true))
        let noLinks = peers.value.map { $0.peers.allSatisfy(\.revoked) } ?? false
        Panel {
            if noLinks {
                EmptyState(MirrorCopy.noLinksTitle, systemImage: "link", message: MirrorCopy.noLinksBody)
            } else {
                EmptyState(MirrorCopy.emptyTitle, systemImage: NodeSection.mirroredVaults.systemImage,
                           message: MirrorCopy.emptyBody)
            }
        }
        .observing(peers)
    }
}

/// A role's small glyph in the vault column: the core owns, a mirror copies.
struct MirrorGlyph: View {
    var role: MirrorRole
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(.accentText)
            .frame(width: size, height: size)
            .background(.accentSoft, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.accentLine, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch role {
        case .core: "externaldrive.fill"
        case .mirror: "rectangle.on.rectangle"
        case .orphaned: "rectangle.dashed"
        case .starting: "hourglass"
        case .detached: "rectangle.portrait.and.arrow.right"
        case .none, .other: "questionmark"
        }
    }
}

#if DEBUG
#Preview("Mirrored Vaults (preview data)") {
    let model = PreviewSamples.liveModel(selecting: PreviewSamples.nodes[1].id)
    MirroredVaultsView(node: PreviewSamples.nodes[1])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1200, height: 700)
}
#endif
