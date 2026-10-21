import SwiftUI
import VHContract
import VHCore
import VHNodes

/// The node's vaults (`storage.vault.list`) in a sortable table, with usage and backend status from
/// `stats.system.storage` when this account may read it, and an inspector for the selected vault.
struct VaultsView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        if let queries = model.liveQueries(for: node) {
            VaultsScreen(node: node, queries: queries)
                .environment(queries)
        } else {
            PlaceholderSection(node: node, section: .vaults)
        }
    }
}

private struct VaultsScreen: View {
    var node: Node
    var queries: NodeQueries

    @Environment(AppModel.self) private var model
    @State private var selection: Int64?
    @State private var sortOrder = [KeyPathComparator(\VaultRow.sortName)]
    @State private var filter = ""
    @State private var showsInspector = true
    @State private var editing: VaultRow?
    @State private var deleting: VaultRow?

    var body: some View {
        let list = queries.query(Ws.Storage.Vault.List.self)
        let storage = queries.query(Ws.Stats.System.Storage.self)
        let rows = rows(list: list, storage: storage)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(eyebrow: node.displayName, title: "Vaults", subtitle: NodeSection.vaults.summary) {
                let status = model.status(for: node)
                StatusBadge(label: status.label, tone: status.tone, pulse: status.isTransitional)
            }
            .padding([.horizontal, .top], Theme.pagePadding)
            .padding(.bottom, 16)

            switch list.state {
            case .idle, .loading:
                LoadingPanel(subject: "vaults")
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .failed(let error):
                ProblemPanel(problem: QueryProblem(error), node: node, subject: "vaults") {
                    Task { await list.refresh() }
                }
                .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .loaded(let value, let at):
                StaleBanner(node: node, updatedAt: at, refreshError: list.refreshError, connected: queries.isConnected)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 12)
                if value.vaults.isEmpty {
                    Panel {
                        EmptyState(
                            "No vaults you can manage on \(node.displayName)",
                            systemImage: "lock.rectangle.stack",
                            message: "The node lists the vaults the account this Mac acts for may manage. Vaults it owns can be missing when its role's vault policy doesn't cover them."
                        )
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    Spacer(minLength: 0)
                } else {
                    table(rows)
                }
            }
        }
        .observing(list)
        .observing(storage, polling: .seconds(30))
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter Vaults")
        // Nothing to inspect without vaults.
        .inspector(isPresented: Binding(get: { showsInspector && !rows.isEmpty }, set: { showsInspector = $0 })) {
            inspector(rows: rows)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                    .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
        .sheet(item: $editing) { row in
            EditVaultSheet(vault: row.vault, queries: queries)
        }
        .sheet(item: $deleting) { row in
            DeleteVaultSheet(vault: row.vault, node: node, queries: queries) {
                if selection == row.id { selection = nil }
            }
        }
        #if DEBUG
        .task { await selectDebugVault() }
        #endif
    }

    // MARK: Table

    private func table(_ rows: [VaultRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.sortName) { row in
                HStack(spacing: 10) {
                    VaultGlyph(isS3: row.isS3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.vault.name)
                            .foregroundStyle(.fg)
                        if !row.vault.description.isEmpty {
                            Text(row.vault.description)
                                .font(.caption)
                                .foregroundStyle(.fgSubtle)
                        }
                    }
                    .lineLimit(1)
                }
                .padding(.vertical, 3)
            }
            .width(min: 180, ideal: 240)

            TableColumn("Storage", value: \.storageLabel) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.storageLabel)
                        .foregroundStyle(.fgMuted)
                    if let bucket = row.vault.bucket, row.isS3 {
                        Text(bucket)
                            .font(.caption.monospaced())
                            .foregroundStyle(.fgSubtle)
                    }
                }
                .lineLimit(1)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Owner", value: \.ownerName) { row in
                Text(row.ownerName)
                    .foregroundStyle(row.vault.ownerID == 0 ? Color.fgFaint : Color.fgMuted)
            }
            .width(min: 70, ideal: 110)

            TableColumn("Usage", value: \.usageSort) { row in
                UsageCell(used: row.usedBytes, quota: row.vault.quota)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Status", value: \.statusText) { row in
                HStack(spacing: 6) {
                    StatusDot(tone: row.statusTone, size: 7)
                    Text(row.statusText)
                        .foregroundStyle(.fgMuted)
                }
            }
            .width(min: 80, ideal: 100)

            TableColumn("Created", value: \.vault.createdAt) { row in
                Text(Format.day(iso: row.vault.createdAt) ?? row.vault.createdAt)
                    .foregroundStyle(.fgSubtle)
                    .monospacedDigit()
            }
            .width(min: 96, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Rename…") { editing = row }
                Divider()
                Button("Delete…", role: .destructive) { deleting = row }
            }
        } primaryAction: { ids in
            selection = ids.first
            showsInspector = true
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(rows: [VaultRow]) -> some View {
        if let selection, let row = rows.first(where: { $0.id == selection }) {
            VaultInspector(row: row, node: node, queries: queries,
                           onEdit: { editing = row }, onDelete: { deleting = row })
                .id(row.id)
        } else {
            EmptyState("No vault selected", systemImage: "sidebar.trailing",
                       message: "Select a vault to see its usage, sync policy, recovery and key.")
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: Rows

    private func rows(list: NodeQuery<Ws.Storage.Vault.List>,
                      storage: NodeQuery<Ws.Stats.System.Storage>) -> [VaultRow] {
        let backends = Dictionary((storage.value?.stats.vaults ?? []).map { ($0.vaultID, $0) },
                                  uniquingKeysWith: { first, _ in first })
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return (list.value?.vaults ?? [])
            .map { VaultRow(vault: $0, backend: backends[$0.id]) }
            .filter { needle.isEmpty || $0.searchText.contains(needle) }
            .sorted(using: sortOrder)
    }

    #if DEBUG
    /// `-VHDebugVault <id>` selects a vault; `-VHDebugDeleteVault YES` then opens its delete sheet (DebugSnapshot).
    private func selectDebugVault() async {
        let id = Int64(UserDefaults.standard.integer(forKey: "VHDebugVault"))
        guard id > 0 else { return }
        selection = id
        guard UserDefaults.standard.bool(forKey: "VHDebugDeleteVault") else { return }
        let list = queries.query(Ws.Storage.Vault.List.self)
        while list.value == nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        if let vault = list.value?.vaults.first(where: { $0.id == id }) {
            deleting = VaultRow(vault: vault, backend: nil)
        }
    }
    #endif
}

/// One row of the vault table: the list row plus its backend figures when the account may read them.
nonisolated struct VaultRow: Identifiable {
    var vault: WsModel.Vault
    var backend: WsModel.StorageVaultBackendStats?

    var id: Int64 { vault.id }
    var sortName: String { vault.name.lowercased() }
    var isS3: Bool { vault.type == WsModel.Vault.TypeValue.s3 }

    var storageLabel: String {
        switch vault.type {
        case WsModel.Vault.TypeValue.s3: "S3"
        case WsModel.Vault.TypeValue.local: "Local"
        default: Format.words(vault.type)
        }
    }

    var ownerName: String {
        if let owner = vault.owner, !owner.isEmpty { return owner }
        return vault.ownerID == 0 ? "No owner" : "User #\(vault.ownerID)"
    }

    var usedBytes: Int64? { backend?.vaultSizeBytes }
    /// Unknown usage sorts below every known size.
    var usageSort: Int64 { usedBytes ?? -1 }

    /// The backend's own status word; "Active" (never green) when it isn't readable.
    var statusText: String {
        guard vault.isActive else { return "Inactive" }
        return backend.map { Format.words($0.backendStatus) } ?? "Active"
    }

    var statusTone: StatusTone {
        guard vault.isActive, let backend else { return .unknown }
        return StatusTone(severity: backend.backendStatus)
    }

    var searchText: String {
        [vault.name, vault.description, vault.slug, vault.bucket ?? "", storageLabel, ownerName]
            .joined(separator: " ").lowercased()
    }
}

struct VaultGlyph: View {
    var isS3: Bool
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: isS3 ? "cloud" : "externaldrive")
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(.accentText)
            .frame(width: size, height: size)
            .background(.accentSoft, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(.accentLine, lineWidth: 1)
            }
    }
}

/// Used space against the quota: "1.2 GB of 50 GB" with a bar, or "1.2 GB" when unlimited.
struct UsageCell: View {
    var used: Int64?
    var quota: Int64

    var body: some View {
        if let used {
            VStack(alignment: .leading, spacing: 3) {
                Text(quota > 0 ? "\(Format.bytes(used)) of \(Format.bytes(quota))" : Format.bytes(used))
                    .foregroundStyle(.fgMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                if quota > 0 {
                    let fraction = min(Double(used) / Double(quota), 1)
                    Capsule()
                        .fill(.surface3)
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(fraction >= 0.9 ? StatusTone.warn.color : Color.accentFill)
                                    .frame(width: proxy.size.width * fraction)
                            }
                        }
                }
            }
        } else {
            Text("not available")
                .foregroundStyle(.fgFaint)
                .help("Usage needs the node's stats permission (admin.stats.view).")
        }
    }
}

#if DEBUG
#Preview("Vaults (preview data)") {
    let model = PreviewSamples.liveModel()
    VaultsView(node: PreviewSamples.nodes[1])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1100, height: 640)
}

#Preview("Nothing to manage (preview data)") {
    let model = PreviewSamples.liveModel()
    VaultsView(node: PreviewSamples.nodes[3])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 900, height: 520)
}
#endif
