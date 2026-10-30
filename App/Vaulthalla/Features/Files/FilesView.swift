import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Files: a Mac file browser over the node's vaults. Listings and changes go over ws (`fs.*`); bytes go over the
/// device listener's HTTP lanes (downloads, uploads, thumbnails, Quick Look copies), never ws.
struct FilesView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        if let queries = model.liveQueries(for: node) {
            FilesScreen(node: node, queries: Self.queries(for: node, live: queries, model: model),
                        workspace: FilesWorkspaces.workspace(for: node, model: model))
                .environment(Self.queries(for: node, live: queries, model: model))
        } else {
            PlaceholderSection(node: node, section: .files)
        }
    }

    private static func queries(for node: Node, live: NodeQueries, model: AppModel) -> NodeQueries {
        #if DEBUG
        // PREVIEW DATA (no sessions): a vault tree of its own, the shared preview transport has no fs answers.
        if model.sessions == nil {
            if let existing = previewQueries[node.id] { return existing }
            let made = NodeQueries(transport: FilesPreviewTransport(vaults: PreviewData.vaults.filter(\.isActive)))
            previewQueries[node.id] = made
            return made
        }
        #endif
        return live
    }

    #if DEBUG
    private static var previewQueries: [NodeID: NodeQueries] = [:]
    #endif
}

private struct FilesScreen: View {
    var node: Node
    var queries: NodeQueries
    @Bindable var workspace: FilesWorkspace

    @Environment(AppModel.self) private var model
    @State private var contents = FolderContents()
    @State private var confirmingDelete: [FileItem] = []
    @State private var renaming: FileItem?
    @State private var openingByID = false
    @State private var recoveryTarget: FileItem?
    @State private var problem: String?

    var body: some View {
        let vaults = VaultChoices(queries: queries)
        VStack(spacing: 0) {
            if let vaultID = workspace.vaultID {
                browser(vaultID: vaultID)
            } else {
                chooseVault(vaults)
            }
        }
        // A daemon without storage.vault.accessible.list: keep the older list fresh instead.
        .task(id: vaults.observation) { await vaults.observe() }
        .toolbar { toolbar(vaults) }
        .searchable(text: $workspace.filter, placement: .toolbar, prompt: "Search This Folder")
        .task(id: vaults.openable.map(\.id)) { pickFirstVault(vaults) }
        .sheet(isPresented: $openingByID) {
            OpenVaultSheet { id in workspace.open(vault: id, name: nil) }
        }
        .sheet(item: $renaming) { item in
            RenameSheet(item: item) { name in Task { await rename(item, to: name) } }
        }
        .sheet(item: $recoveryTarget) { item in
            if let vaultID = workspace.vaultID {
                RecoveryHistorySheet(item: item, vaultID: vaultID, node: node, queries: queries)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !confirmingDelete.isEmpty },
                                                              set: { if !$0 { confirmingDelete = [] } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let items = confirmingDelete
                Task { await delete(items) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmingDelete.contains(where: \.isDirectory)
                 ? "Folders are deleted with everything inside them. Deleted items move to the vault's trash retention."
                 : "Deleted items move to the vault's trash retention.")
        }
        .alert("Couldn't finish that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .onAppear {
            let queries = queries
            workspace.transfers.onFoldersChanged = { _, _ in queries.invalidate(prefix: "fs.dir") }
        }
        .onDisappear { workspace.quickLook.discardCopies() }
        #if DEBUG
        .task { await debugSetup() }
        #endif
    }

    // MARK: Vaults

    @ViewBuilder
    private func chooseVault(_ vaults: VaultChoices) -> some View {
        ScrollView {
            Group {
                switch vaults.state {
                case .idle, .loading:
                    LoadingPanel(subject: "vaults")
                case .failed(let error):
                    ProblemPanel(problem: QueryProblem(error), node: node, subject: "vaults") {
                        Task { await vaults.refresh() }
                    }
                case .loaded(let choices, _):
                    if choices.contains(where: \.canOpen) {
                        LoadingPanel(subject: "files")
                    } else {
                        Panel {
                            EmptyState(
                                vaults.usesLegacy ? "No vaults listed for this account" : "No vaults to open",
                                systemImage: "folder.badge.questionmark",
                                message: Self.noVaultsMessage(choices, legacy: vaults.usesLegacy)
                            ) {
                                Button("Open Vault by ID…") { openingByID = true }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
    }

    private static func noVaultsMessage(_ choices: [VaultChoice], legacy: Bool) -> String {
        if legacy {
            return "This node lists only the vaults this account may manage. Vaults shared with it through a role can still be opened by their ID."
        }
        let manageOnly = choices.filter { $0.access == .manageOnly }.count
        if choices.isEmpty {
            return "No vault is shared with this account. Ask an administrator for a vault role."
        }
        if choices.allSatisfy({ $0.access == .browse }) {
            return "Every vault this account can open is inactive."
        }
        if manageOnly == choices.count {
            return manageOnly == 1
                ? "This account can manage a vault but can't open its files. A vault role gives file access."
                : "This account can manage \(manageOnly) vaults but can't open their files. A vault role gives file access."
        }
        return choices.count == 1
            ? "This account reaches a vault, but its roles don't let it open the files. A vault role gives file access."
            : "This account reaches \(choices.count) vaults, but its roles don't let it open their files. A vault role gives file access."
    }

    private func pickFirstVault(_ vaults: VaultChoices) {
        guard workspace.vaultID == nil, let first = vaults.openable.first else { return }
        workspace.open(vault: first.id, name: first.name)
    }

    // MARK: Browser

    @ViewBuilder
    private func browser(vaultID: Int64) -> some View {
        let listing = queries.query(Ws.Fs.Dir.List.self, .init(vaultID: vaultID, path: workspace.path.rawValue))
        PathBar(vaultName: workspace.vaultName ?? listing.value?.vault ?? "Vault #\(vaultID)", path: workspace.path,
                onSelect: { workspace.navigate(to: $0) },
                onDrop: { urls, folder in upload(urls, into: folder) })
        Divider().opacity(0.5)
        if let error = listing.refreshError ?? (queries.isConnected ? nil : WsError.disconnected),
           let at = listing.updatedAt {
            StaleBanner(node: node, updatedAt: at, refreshError: error, connected: queries.isConnected)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        ZStack {
            switch listing.state {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let error):
                ScrollView {
                    ProblemPanel(problem: QueryProblem(error), node: node, subject: "this folder") {
                        Task { await listing.refresh() }
                    }
                    .padding(Theme.pagePadding)
                }
            case .loaded:
                folderView(vaultID: vaultID)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .center) { emptyFolderNote }
        StatusBar(shown: contents.items.count, total: contents.total, selected: workspace.selection.count,
                  filtered: !workspace.filter.isEmpty)
        .observing(listing)
        .onChange(of: listing.updatedAt) { refreshContents(listing) }
        .onChange(of: workspace.sort) { refreshContents(listing) }
        .onChange(of: workspace.filter) { refreshContents(listing) }
        .onChange(of: workspace.showHidden) { refreshContents(listing) }
        .onChange(of: listing.value?.vault) { _, name in if let name { workspace.vaultName = name } }
        .onChange(of: contents.generation) { renamePendingFolder() }
        .onAppear { refreshContents(listing) }
    }

    private func refreshContents(_ listing: NodeQuery<Ws.Fs.Dir.List>) {
        contents.update(listing: listing.value, listedAt: listing.updatedAt, folder: workspace.path, sort: workspace.sort,
                        filter: workspace.filter, showHidden: workspace.showHidden)
    }

    @ViewBuilder
    private var emptyFolderNote: some View {
        if contents.items.isEmpty, !contents.isComputing, contents.generation > 0 {
            VStack(spacing: 6) {
                Image(systemName: workspace.filter.isEmpty ? "folder" : "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.fgFaint)
                Text(workspace.filter.isEmpty ? "This folder is empty" : "No matches in this folder")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                if workspace.filter.isEmpty {
                    Text("Drop files here, or use Upload, to add them.")
                        .font(.caption)
                        .foregroundStyle(.fgFaint)
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func folderView(vaultID: Int64) -> some View {
        switch workspace.viewMode {
        case .list:
            FileListView(items: contents.items, generation: contents.generation, selection: $workspace.selection,
                         sort: $workspace.sort, renameRequest: $workspace.renameRequest, folder: workspace.path,
                         vaultID: vaultID, actions: actions(vaultID: vaultID), quickLook: workspace.quickLook)
        case .grid:
            FileGridView(items: contents.items, generation: contents.generation, selection: $workspace.selection,
                         folder: workspace.path, vaultID: vaultID, actions: actions(vaultID: vaultID),
                         quickLook: workspace.quickLook, thumbnails: workspace.thumbnails)
        }
    }

    private var selectedItems: [FileItem] {
        contents.items.filter { workspace.selection.contains($0.id) }
    }

    // MARK: Actions

    private func actions(vaultID: Int64) -> BrowserActions {
        let transfers = workspace.transfers
        let lookup = contents
        return BrowserActions(
            open: { open($0) },
            quickLook: { workspace.quickLook.toggle(selectedItems, vaultID: vaultID) },
            requestRename: { item in
                if workspace.viewMode == .list { workspace.renameRequest = item.path } else { renaming = item }
            },
            commitRename: { item, name in Task { await rename(item, to: name) } },
            delete: { confirmingDelete = selectedItems },
            parent: { workspace.goToParent() },
            copy: { copySelection() },
            paste: { move in Task { await paste(move: move) } },
            dropFiles: { urls, folder in upload(urls, into: folder) },
            dropEntries: { paths, folder, copy in Task { await transfer(paths, into: folder, copy: copy) } },
            promiseDownload: { path, url in
                guard let item = lookup.items.first(where: { $0.path == path }) else { return false }
                return await transfers.download(item, vaultID: vaultID, to: url)
            },
            menu: { items in menu(for: items, vaultID: vaultID) },
            visible: { _ in })
    }

    private func open(_ item: FileItem) {
        if item.isDirectory {
            workspace.navigate(to: item.path)
        } else if let vaultID = workspace.vaultID {
            workspace.selection = [item.id]
            if !workspace.quickLook.isVisible { workspace.quickLook.toggle([item], vaultID: vaultID) }
        }
    }

    private func copySelection() {
        guard let vaultID = workspace.vaultID, !selectedItems.isEmpty else { return }
        workspace.clipboard = .init(vaultID: vaultID, paths: selectedItems.map(\.path))
    }

    private func paste(move: Bool) async {
        guard let clipboard = workspace.clipboard, clipboard.vaultID == workspace.vaultID else { return }
        await transfer(clipboard.paths, into: workspace.path, copy: !move, duplicating: true)
        if move { workspace.clipboard = nil }
    }

    /// Moves or copies entries with the node's `fs.entry.move` / `fs.entry.copy`. A copy into the folder it came
    /// from gets Finder's "name copy".
    private func transfer(_ paths: [VaultPath], into folder: VaultPath, copy: Bool, duplicating: Bool = false) async {
        guard let vaultID = workspace.vaultID else { return }
        var taken = Set(contents.items.map(\.name))
        var failures: [String] = []
        for path in paths {
            if !copy, path.parent == folder { continue }
            if !copy, path.contains(folder) {
                failures.append("“\(path.name)” can't be moved into itself.")
                continue
            }
            var name = path.name
            if copy, duplicating, path.parent == folder {
                let ext = (name as NSString).pathExtension
                let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
                let isDirectory = contents.items.first { $0.path == path }?.isDirectory ?? ext.isEmpty
                name = VaultPath.uniqueName(isDirectory || ext.isEmpty ? "\(stem) copy" : "\(stem) copy.\(ext)",
                                            taken: taken, isDirectory: isDirectory)
                taken.insert(name)
            }
            let target = folder.appending(name)
            let result: WsError?
            if copy {
                result = await runMutation(Ws.Fs.Entry.Copy.self,
                                           .init(vaultID: vaultID, from: path.rawValue, to: target.rawValue))
            } else {
                result = await runMutation(Ws.Fs.Entry.Move.self,
                                           .init(vaultID: vaultID, from: path.rawValue, to: target.rawValue))
            }
            if let result { failures.append("“\(path.name)”: \(result.message)") }
        }
        if !failures.isEmpty {
            problem = "\(copy ? "Copying" : "Moving") didn't finish.\n" + failures.prefix(5).joined(separator: "\n")
        }
    }

    private func rename(_ item: FileItem, to name: String) async {
        guard let vaultID = workspace.vaultID, name != item.name else { return }
        if let reason = VaultPath.problem(withName: name) {
            problem = reason
            return
        }
        let target = item.path.parent.appending(name)
        if let error = await runMutation(Ws.Fs.Entry.Rename.self,
                                         .init(vaultID: vaultID, from: item.path.rawValue, to: target.rawValue)) {
            problem = "“\(item.name)” wasn't renamed: \(error.message)"
        } else {
            workspace.selection = [target.rawValue]
        }
    }

    private func delete(_ items: [FileItem]) async {
        guard let vaultID = workspace.vaultID else { return }
        var failures: [String] = []
        for item in items {
            if let error = await runMutation(Ws.Fs.Entry.Delete.self, .init(vaultID: vaultID, path: item.path.rawValue)) {
                failures.append("“\(item.name)”: \(error.message)")
            }
        }
        workspace.selection.subtract(items.map(\.id))
        if !failures.isEmpty { problem = "Some items weren't deleted.\n" + failures.prefix(5).joined(separator: "\n") }
    }

    /// ⇧⌘N: a new folder named like Finder's, renamed in place once it shows.
    private func newFolder() async {
        guard let vaultID = workspace.vaultID else { return }
        let name = VaultPath.uniqueName("untitled folder", taken: Set(contents.items.map(\.name)))
        let path = workspace.path.appending(name)
        if let error = await runMutation(Ws.Fs.Dir.Create.self, .init(vaultID: vaultID, path: path.rawValue)) {
            problem = "The folder wasn't created: \(error.message)"
        } else {
            workspace.pendingRename = path
            workspace.selection = [path.rawValue]
        }
    }

    private func renamePendingFolder() {
        guard let pending = workspace.pendingRename,
              let item = contents.items.first(where: { $0.path == pending }) else { return }
        workspace.pendingRename = nil
        if workspace.viewMode == .list { workspace.renameRequest = pending } else { renaming = item }
    }

    /// Runs a mutation with the data layer (invalidating listings), asking the daemon's confirmation when it wants
    /// one. Returns the failure, nil on success.
    private func runMutation<R: WsRequest>(_ request: R.Type, _ payload: R.Payload) async -> WsError?
    where R.Payload: Decodable {
        var result = await queries.perform(R.self, payload, invalidating: ["fs.dir", "fs.list", "recovery.list"])
        while true {
            switch result {
            case .success: return nil
            case .failure(let error): return error
            case .needsConfirmation(let request):
                guard request.isAcceptable, await ServerConfirmationPrompt.ask(request.message) else {
                    return .cancelled
                }
                result = await queries.accept(request)
            }
        }
    }

    // MARK: Transfers

    private func upload(_ urls: [URL], into folder: VaultPath) {
        guard let vaultID = workspace.vaultID else { return }
        let transfers = workspace.transfers
        let folderName = folder.isRoot ? (workspace.vaultName ?? "the vault") : folder.name
        Task {
            let files = await LocalFiles.uploadItems(from: urls)
            guard !files.isEmpty else {
                problem = "Nothing to upload: the dropped items contain no files."
                return
            }
            transfers.upload(files, vaultID: vaultID, into: folder, folderName: folderName)
        }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to \(workspace.path.isRoot ? (workspace.vaultName ?? "the vault") : workspace.path.name)."
        guard panel.runModal() == .OK else { return }
        upload(panel.urls, into: workspace.path)
    }

    /// Downloads the selection: one item to a place chosen in a save panel, several into a chosen folder. Folders
    /// come as the node's ZIP.
    private func download(_ items: [FileItem]) {
        guard let vaultID = workspace.vaultID, !items.isEmpty else { return }
        let transfers = workspace.transfers
        if items.count == 1, let item = items.first {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = TransferCenter.downloadName(for: item)
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.prompt = "Download"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            transfers.isPanelShown = true
            Task { await transfers.download(item, vaultID: vaultID, to: url) }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.prompt = "Download Here"
            panel.message = "Choose where to save \(items.count) items."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            transfers.isPanelShown = true
            for item in items { transfers.download(item, vaultID: vaultID, into: folder) }
        }
    }

    // MARK: Menus

    private func menu(for items: [FileItem], vaultID: Int64) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String? = nil, enabled: Bool = true, _ action: @escaping () -> Void) {
            let entry = ClosureMenuItem.make(title: title, action: action)
            if let symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            entry.isEnabled = enabled
            menu.addItem(entry)
        }
        if items.isEmpty {
            add("New Folder", "folder.badge.plus") { Task { await newFolder() } }
            add("Upload…", "square.and.arrow.up") { chooseUpload() }
            if let clipboard = workspace.clipboard, clipboard.vaultID == vaultID {
                menu.addItem(.separator())
                let count = clipboard.paths.count
                add(count == 1 ? "Paste Item" : "Paste \(count) Items") { Task { await paste(move: false) } }
                add(count == 1 ? "Move Item Here" : "Move \(count) Items Here") { Task { await paste(move: true) } }
            }
            return menu
        }
        let single = items.count == 1 ? items.first : nil
        if let single {
            add(single.isDirectory ? "Open" : "Quick Look", single.isDirectory ? "folder" : "eye") { open(single) }
        } else {
            add("Quick Look \(items.count) Items", "eye") { workspace.quickLook.toggle(items, vaultID: vaultID) }
        }
        add(items.count == 1 ? "Download…" : "Download \(items.count) Items…", "arrow.down.circle") { download(items) }
        menu.addItem(.separator())
        if let single {
            add("Rename", "pencil") {
                if workspace.viewMode == .list { workspace.renameRequest = single.path } else { renaming = single }
            }
        }
        add(items.count == 1 ? "Copy" : "Copy \(items.count) Items", "doc.on.doc") {
            workspace.clipboard = .init(vaultID: vaultID, paths: items.map(\.path))
        }
        if let single {
            menu.addItem(.separator())
            add("Recovery History…", "clock.arrow.circlepath") { recoveryTarget = single }
        }
        menu.addItem(.separator())
        add(items.count == 1 ? "Delete…" : "Delete \(items.count) Items…", "trash") { confirmingDelete = items }
        return menu
    }

    private var deleteTitle: String {
        confirmingDelete.count == 1 ? "Delete “\(confirmingDelete[0].name)”?" : "Delete \(confirmingDelete.count) items?"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ vaults: VaultChoices) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button("Back", systemImage: "chevron.left") { workspace.goBack() }
                    .disabled(!workspace.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward", systemImage: "chevron.right") { workspace.goForward() }
                    .disabled(!workspace.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
            }
            .help("Go back or forward")
        }
        ToolbarItem(placement: .principal) {
            vaultMenu(vaults)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $workspace.viewMode) {
                Label("List", systemImage: "list.bullet").tag(FilesWorkspace.ViewMode.list)
                Label("Icons", systemImage: "square.grid.2x2").tag(FilesWorkspace.ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("Show items as a list or as icons")

            Button("New Folder", systemImage: "folder.badge.plus") { Task { await newFolder() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(workspace.vaultID == nil)
                .help("New folder (⇧⌘N)")
            Button("Upload", systemImage: "square.and.arrow.up") { chooseUpload() }
                .disabled(workspace.vaultID == nil)
                .help("Upload files or folders to this folder")
            Button("Download", systemImage: "arrow.down.circle") { download(selectedItems) }
                .disabled(selectedItems.isEmpty)
                .help("Download the selection (folders as ZIP)")
            TransfersButton(transfers: workspace.transfers)
            Menu("More", systemImage: "ellipsis.circle") {
                Toggle("Show Hidden Files", isOn: $workspace.showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Divider()
                Button("Enclosing Folder") { workspace.goToParent() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(workspace.path.isRoot)
                Button("Recovery History…") { recoveryTarget = selectedItems.first }
                    .disabled(selectedItems.count != 1)
                Divider()
                Button("Open Vault by ID…") { openingByID = true }
            }
            .help("More")
        }
    }

    private func vaultMenu(_ vaults: VaultChoices) -> some View {
        Menu {
            let openable = vaults.choices.filter { $0.access == .browse }
            let others = vaults.choices.filter { $0.access != .browse }
            ForEach(openable) { vault in
                Button {
                    workspace.open(vault: vault.id, name: vault.name)
                } label: {
                    if vault.id == workspace.vaultID {
                        Label(vault.name, systemImage: "checkmark")
                    } else {
                        Text(vault.name)
                    }
                }
                .disabled(!vault.isActive)
                .help(vault.reasons)
            }
            if !others.isEmpty {
                Section("Can't Open Files") {
                    ForEach(others) { vault in
                        Button {} label: {
                            Text(vault.name)
                            Text(vault.access == .manageOnly ? "Manage only" : "No file access")
                        }
                        .disabled(true)
                        .help(vault.reasons)
                    }
                }
            }
            if !vaults.choices.isEmpty { Divider() }
            Button("Open Vault by ID…") { openingByID = true }
        } label: {
            Label(workspace.vaultName ?? (workspace.vaultID.map { "Vault #\($0)" } ?? "Choose a Vault"),
                  systemImage: "externaldrive")
        }
        .menuIndicator(.visible)
        .help("Choose a vault")
    }

    #if DEBUG
    /// `-VHDebugFilesPath /Photos`, `-VHDebugFilesView grid`, `-VHDebugFilesSelect <name>`, `-VHDebugTransfers YES`
    /// (DebugSnapshot, with PREVIEW DATA).
    private func debugSetup() async {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "VHDebugSnapshot") != nil else { return }
        while workspace.vaultID == nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        if let mode = defaults.string(forKey: "VHDebugFilesView"), let view = FilesWorkspace.ViewMode(rawValue: mode) {
            workspace.viewMode = view
        }
        if let path = defaults.string(forKey: "VHDebugFilesPath") {
            workspace.navigate(to: VaultPath(normalizing: path))
        }
        if let name = defaults.string(forKey: "VHDebugFilesSelect") {
            try? await Task.sleep(for: .milliseconds(600))
            if let item = contents.items.first(where: { $0.name.hasPrefix(name) }) {
                workspace.selection = [item.id]
                if defaults.bool(forKey: "VHDebugRecovery") { recoveryTarget = item }
            }
        }
        if defaults.bool(forKey: "VHDebugTransfers"), let vaultID = workspace.vaultID {
            try? await Task.sleep(for: .milliseconds(500))
            let folder = FileManager.default.temporaryDirectory.appending(path: "vh-files-debug-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in contents.items.filter({ !$0.isDirectory }).prefix(2) {
                workspace.transfers.download(item, vaultID: vaultID, into: folder)
            }
            let source = folder.appending(path: "Upload (preview).bin")
            try? Data(count: 4_000_000).write(to: source)
            workspace.transfers.upload([.init(source: source, relativePath: "Upload (preview).bin", size: 4_000_000)],
                                       vaultID: vaultID, into: workspace.path, folderName: "Photos")
            workspace.transfers.isPanelShown = true
        }
    }
    #endif
}

/// Menu items that run a closure (the browser's context menus are built per click).
enum ClosureMenuItem {
    static func make(title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Target.run(_:)), keyEquivalent: "")
        item.target = Target.shared
        item.representedObject = Box(action)
        return item
    }

    private final class Box: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    private final class Target: NSObject {
        static let shared = Target()
        @objc func run(_ sender: NSMenuItem) { (sender.representedObject as? Box)?.action() }
    }
}

/// The daemon's own confirmation question (`needsConfirmation`) for browser actions that run without a sheet.
enum ServerConfirmationPrompt {
    static func ask(_ message: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Continue?"
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}

#if DEBUG
#Preview("Files (preview data)") {
    let model = PreviewSamples.liveModel()
    FilesView(node: PreviewSamples.nodes[1])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1100, height: 640)
}
#endif
