import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Files that changed both in a vault and in its S3 bucket since they were last in sync, in vaults whose conflict
/// policy is Ask (`sync.conflicts.list`, counted by `sync.conflicts.summary`). Each waits for Keep Local or Keep
/// Remote; the daemon handles every file on its own and says which it couldn't resolve.
struct SyncConflictsView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        if let queries = model.liveQueries(for: node) {
            SyncConflictsScreen(node: node, queries: queries)
                .environment(queries)
        } else {
            PlaceholderSection(node: node, section: .syncConflicts)
        }
    }
}

private struct SyncConflictsScreen: View {
    typealias Choice = ConflictResolution.Choice

    var node: Node
    var queries: NodeQueries

    @Environment(AppModel.self) private var model
    @State private var vaultID: Int64?
    @State private var selection: Set<Int64> = []
    @State private var sortOrder = [KeyPathComparator(\ConflictRow.sortDetected, order: .reverse)]
    @State private var filter = ""
    @State private var showsInspector = true
    @State private var bulkChoice: Choice?
    @State private var resolver: ConflictResolver

    init(node: Node, queries: NodeQueries) {
        self.node = node
        self.queries = queries
        _resolver = State(initialValue: ConflictResolver(queries: queries))
    }

    var body: some View {
        let summary = queries.query(Ws.Sync.Conflicts.Summary.self)
        let list = queries.query(Ws.Sync.Conflicts.List.self, .init(vaultID: vaultID.map { .value($0) }))
        let rows = rows(list)
        let resolvable = Set(rows.filter(\.conflict.canOverwrite).map(\.id))
        let chosen = selection.intersection(resolvable)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(eyebrow: node.displayName, title: "Sync Conflicts",
                          subtitle: "Files that changed both in the vault and in its S3 bucket since they were last in sync, in vaults whose conflict policy is Ask. Each waits for a decision; everything else keeps syncing.") {
                let status = model.status(for: node)
                StatusBadge(label: status.label, tone: status.tone, pulse: status.isTransitional)
            }
            .padding([.horizontal, .top], Theme.pagePadding)
            .padding(.bottom, 16)

            if let run = resolver.lastRun {
                ConflictResultsPanel(run: run) { resolver.lastRun = nil }
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 12)
            }

            switch list.state {
            case .idle, .loading:
                LoadingPanel(subject: "sync conflicts")
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .failed(let error):
                ProblemPanel(problem: QueryProblem(error), node: node, subject: "sync conflicts") {
                    Task { await list.refresh() }
                }
                .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .loaded(let value, let at):
                StaleBanner(node: node, updatedAt: at, refreshError: list.refreshError, connected: queries.isConnected)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 12)
                if value.conflicts.isEmpty {
                    Panel {
                        EmptyState(
                            "No sync conflicts",
                            systemImage: "checkmark.circle",
                            message: "Nothing is waiting for a decision in the vaults where this account can resolve conflicts."
                        )
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    Spacer(minLength: 0)
                } else {
                    selectionBar(rows: rows, resolvable: resolvable, chosen: chosen)
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.bottom, 8)
                    table(rows, resolvable: resolvable)
                }
            }
        }
        .observing(summary, polling: .seconds(60))
        .observing(list, polling: .seconds(60))
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter by Path or Vault")
        .inspector(isPresented: Binding(get: { showsInspector && !rows.isEmpty }, set: { showsInspector = $0 })) {
            inspector(rows: rows)
                .inspectorColumnWidth(min: 340, ideal: 420, max: 620)
        }
        .toolbar { toolbar(summary: summary.value) }
        .confirmationDialog(bulkTitle(chosen.count), isPresented: present($bulkChoice), titleVisibility: .visible,
                            presenting: bulkChoice) { choice in
            Button(ConflictResolution.label(choice)) {
                let targets = rows.filter { chosen.contains($0.id) }
                Task { await resolve(choice, targets) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            Text("\(ConflictResolution.effect(choice)) Each file is handled on its own: one that changed since it was recorded is refused and stays in the list. Transfers count against the vault's S3 request and price budgets.")
        }
        .confirmationDialog("Resolve anyway?", isPresented: confirmationShown, titleVisibility: .visible,
                            presenting: resolver.confirmation) { request in
            if request.isAcceptable {
                Button("Continue") { resolver.answer(true) }
            }
            Button(request.isAcceptable ? "Cancel" : "OK", role: .cancel) { resolver.answer(false) }
        } message: { request in
            Text(request.isAcceptable ? request.message : "\(request.message)\n\n\(request.confirmation?.summary ?? "")")
        }
        .onChange(of: summary.value) { _, value in
            // A vault filter that no longer has conflicts falls back to all vaults.
            if let vaultID, let value, !value.vaults.contains(where: { $0.vaultID == vaultID }) { self.vaultID = nil }
        }
        .onChange(of: rows.map(\.id)) { _, ids in
            let listed = Set(ids)
            if !selection.isSubset(of: listed) { selection.formIntersection(listed) }
        }
        #if DEBUG
        .task { await debugHooks() }
        #endif
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(summary: WsModel.SyncConflictSummary?) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Vault", selection: $vaultID) {
                Text("All Vaults\(summary.map { " (\($0.total))" } ?? "")").tag(Int64?.none)
                if let summary, !summary.vaults.isEmpty {
                    Divider()
                    ForEach(summary.vaults, id: \.vaultID) { vault in
                        Text("\(vault.vaultName) (\(vault.count))").tag(Int64?.some(vault.vaultID))
                    }
                }
            }
            .pickerStyle(.menu)
            .help("Show the conflicts of one vault")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                .help(showsInspector ? "Hide the inspector" : "Show the inspector")
        }
    }

    /// Above the table: how many are selected, Select All, and the bulk resolutions.
    private func selectionBar(rows: [ConflictRow], resolvable: Set<Int64>, chosen: Set<Int64>) -> some View {
        let locked = rows.count - resolvable.count
        return HStack(spacing: 10) {
            Text(countText(rows.count, chosen: chosen.count, locked: locked))
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .monospacedDigit()
            Spacer(minLength: 0)
            if resolver.isRunning {
                ProgressView().controlSize(.small)
            }
            Button(chosen.count == resolvable.count && !resolvable.isEmpty ? "Deselect All" : "Select All") {
                selection = chosen.count == resolvable.count ? [] : resolvable
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(resolvable.isEmpty)
            .help("Select every conflict you can resolve (⌘A)")
            ForEach([Choice.keepLocal, .keepRemote], id: \.self) { choice in
                Button(ConflictResolution.label(choice)) { bulkChoice = choice }
                    .disabled(chosen.isEmpty || resolver.isRunning)
                    .help("\(ConflictResolution.effect(choice)) Asks first.")
            }
        }
        .controlSize(.small)
    }

    private func countText(_ total: Int, chosen: Int, locked: Int) -> String {
        var parts = ["\(total) conflict\(total == 1 ? "" : "s")"]
        if chosen > 0 { parts.append("\(chosen) selected") }
        if locked > 0 { parts.append("\(locked) without Overwrite permission") }
        return parts.joined(separator: " · ")
    }

    private func bulkTitle(_ count: Int) -> String {
        guard let bulkChoice else { return "" }
        return "\(ConflictResolution.label(bulkChoice)) for \(count) file\(count == 1 ? "" : "s")?"
    }

    // MARK: Table

    private func table(_ rows: [ConflictRow], resolvable: Set<Int64>) -> some View {
        Table(rows, selection: selectionBinding(resolvable), sortOrder: $sortOrder) {
            TableColumn("File", value: \.sortPath) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.conflict.canOverwrite ? "arrow.triangle.2.circlepath.doc.on.clipboard" : "lock.doc")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(row.conflict.canOverwrite ? StatusTone.warn.color : Color.fgFaint)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.conflict.name)
                            .foregroundStyle(row.conflict.canOverwrite ? Color.fg : Color.fgSubtle)
                        Text(row.conflict.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.fgSubtle)
                            .truncationMode(.middle)
                    }
                    .lineLimit(1)
                }
                .padding(.vertical, 3)
                .help(row.conflict.canOverwrite ? row.conflict.path : ConflictResolution.noOverwrite)
            }
            .width(min: 200, ideal: 280)

            TableColumn("Vault", value: \.sortVault) { row in
                Text(row.conflict.vaultName)
                    .foregroundStyle(.fgMuted)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Local", value: \.sortLocal) { row in
                ConflictSideCell(side: row.conflict.local)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Remote", value: \.sortRemote) { row in
                ConflictSideCell(side: row.conflict.remote)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Detected", value: \.sortDetected) { row in
                Text(Format.date(iso: row.conflict.createdAt).map { Format.relative($0) } ?? "Unknown")
                    .foregroundStyle(.fgMuted)
                    .help(Format.moment(iso: row.conflict.createdAt) ?? "")
            }
            .width(min: 70, ideal: 90)

            TableColumn("Resolve") { row in
                HStack(spacing: 6) {
                    ForEach([Choice.keepLocal, .keepRemote], id: \.self) { choice in
                        Button(choice == .keepLocal ? "Local" : "Remote") {
                            Task { await resolve(choice, [row]) }
                        }
                        .help(row.conflict.canOverwrite
                              ? "\(ConflictResolution.label(choice)): \(ConflictResolution.effect(choice))"
                              : ConflictResolution.noOverwrite)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!row.conflict.canOverwrite || resolver.busy.contains(row.id))
            }
            .width(min: 130, ideal: 140)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int64.self) { ids in
            let targets = rows.filter { ids.contains($0.id) && $0.conflict.canOverwrite }
            ForEach([Choice.keepLocal, .keepRemote], id: \.self) { choice in
                Button(targets.count > 1 ? "\(ConflictResolution.label(choice)) for \(targets.count) Files…"
                                         : ConflictResolution.label(choice)) {
                    if targets.count > 1 {
                        selection = Set(targets.map(\.id))
                        bulkChoice = choice
                    } else {
                        Task { await resolve(choice, targets) }
                    }
                }
                .disabled(targets.isEmpty || resolver.isRunning)
            }
            if let row = rows.first(where: { ids.contains($0.id) }) {
                Divider()
                Button("Copy Path") { ShareClipboard.copy(row.conflict.path) }
            }
        } primaryAction: { ids in
            if let id = ids.first { selection = [id] }
            showsInspector = true
        }
    }

    /// A row without Overwrite permission can be selected alone, to inspect it, but never joins a multiple
    /// selection that a bulk resolution would act on.
    private func selectionBinding(_ resolvable: Set<Int64>) -> Binding<Set<Int64>> {
        Binding(get: { selection }, set: { new in
            selection = new.count <= 1 ? new : new.intersection(resolvable)
        })
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(rows: [ConflictRow]) -> some View {
        let picked = rows.filter { selection.contains($0.id) }
        if picked.count == 1, let row = picked.first {
            ConflictInspector(conflict: row.conflict, node: node, busy: resolver.busy.contains(row.id)) { choice in
                Task { await resolve(choice, [row]) }
            }
            .id(row.id)
        } else if picked.count > 1 {
            EmptyState("\(picked.count) conflicts selected", systemImage: "square.stack",
                       message: "Keep Local or Keep Remote applies to all of them, one file at a time.")
                .frame(maxHeight: .infinity)
        } else {
            EmptyState("No conflict selected", systemImage: "sidebar.trailing",
                       message: "Select a conflict to compare the vault's copy with the bucket's.")
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func resolve(_ choice: Choice, _ targets: [ConflictRow]) async {
        let resolvable = targets.filter(\.conflict.canOverwrite)
        guard !resolvable.isEmpty else { return }
        let run = await resolver.resolve(choice, resolvable.map { ($0.id, $0.conflict.place) })
        let failed = Set(run.failures.map(\.id))
        selection.subtract(resolvable.map(\.id).filter { !failed.contains($0) })
    }

    private var confirmationShown: Binding<Bool> {
        Binding(get: { resolver.confirmation != nil }, set: { if !$0, resolver.confirmation != nil { resolver.answer(false) } })
    }

    private func present(_ item: Binding<Choice?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    private func rows(_ list: NodeQuery<Ws.Sync.Conflicts.List>) -> [ConflictRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return (list.value?.conflicts ?? [])
            .map(ConflictRow.init)
            .filter { needle.isEmpty || $0.searchText.contains(needle) }
            .sorted(using: sortOrder)
    }

    #if DEBUG
    /// `-VHDebugConflict <id>` selects a conflict; `-VHDebugConflicts all` selects every resolvable one and
    /// `-VHDebugConflictRun keep_local` resolves them (DebugSnapshot).
    private func debugHooks() async {
        let defaults = UserDefaults.standard
        let id = Int64(defaults.integer(forKey: "VHDebugConflict"))
        if id > 0 { selection = [id] }
        guard defaults.string(forKey: "VHDebugConflicts") == "all" else { return }
        let list = queries.query(Ws.Sync.Conflicts.List.self, .init(vaultID: vaultID.map { .value($0) }))
        while list.value == nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        let rows = (list.value?.conflicts ?? []).map(ConflictRow.init).filter(\.conflict.canOverwrite)
        selection = Set(rows.map(\.id))
        if let raw = defaults.string(forKey: "VHDebugConflictRun"), let choice = Choice(rawValue: raw) {
            await resolve(choice, rows)
        }
    }
    #endif
}

/// One row of the conflict table.
nonisolated struct ConflictRow: Identifiable {
    var conflict: WsModel.SyncConflict

    var id: Int64 { conflict.id }
    var sortPath: String { conflict.path.lowercased() }
    var sortVault: String { conflict.vaultName.lowercased() }
    var sortLocal: String { conflict.local.modifiedAt ?? "" }
    var sortRemote: String { conflict.remote.modifiedAt ?? "" }
    var sortDetected: String { conflict.createdAt ?? "" }
    var searchText: String { "\(conflict.path) \(conflict.vaultName)".lowercased() }
}

/// A side's size and when it changed.
private struct ConflictSideCell: View {
    var side: WsModel.SyncConflictSide

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Format.bytes(side.sizeBytes))
                .foregroundStyle(.fgMuted)
                .monospacedDigit()
            Text(Format.date(iso: side.modifiedAt).map { Format.relative($0) } ?? "Unknown")
                .font(.caption)
                .foregroundStyle(.fgSubtle)
        }
        .lineLimit(1)
        .help(Format.moment(iso: side.modifiedAt).map { "Modified \($0)" } ?? "Modification time unknown")
    }
}

/// What the last Keep Local / Keep Remote did, and every file it couldn't resolve, in the daemon's words.
private struct ConflictResultsPanel: View {
    var run: ConflictRun
    var onDismiss: () -> Void

    private var failures: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(run.failures) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusBadge(label: item.status, tone: item.tone)
                    Text(item.place)
                        .foregroundStyle(.fg)
                        .textSelection(.enabled)
                    if let message = item.message, !message.isEmpty {
                        Text(message)
                            .foregroundStyle(.fgSubtle)
                    }
                }
                .font(.callout)
                .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        Panel(title: run.title, size: .card) {
            VStack(alignment: .leading, spacing: 8) {
                if let stopped = run.stopped {
                    HeaderBanner(tone: .warn, systemImage: "exclamationmark.triangle", text: stopped)
                }
                if run.failures.isEmpty {
                    Label("Every selected conflict was resolved.", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.fgMuted)
                } else if run.failures.count > 6 {
                    ScrollView { failures }
                        .frame(height: 160)
                } else {
                    failures
                }
            }
        } actions: {
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Dismiss the results")
        }
    }
}

#if DEBUG
#Preview("Sync conflicts (preview data)") {
    let model = PreviewSamples.liveModel()
    SyncConflictsView(node: PreviewSamples.nodes[1])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1200, height: 640)
}

#Preview("No conflicts (preview data)") {
    let model = PreviewSamples.liveModel()
    SyncConflictsView(node: PreviewSamples.nodes[3])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 900, height: 520)
}
#endif
