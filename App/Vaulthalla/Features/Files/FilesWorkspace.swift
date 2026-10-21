import AppKit
import Foundation
import Observation
import Synchronization
import UniformTypeIdentifiers
import VHContract
import VHCore
import VHNodes
import VHTransport

/// One node's file browser state, kept while the app runs so switching sections (or nodes) and coming back finds the
/// same vault, folder, selection and transfers. Views get it from ``FilesWorkspaces``.
@Observable
final class FilesWorkspace {
    enum ViewMode: String, CaseIterable, Identifiable {
        case list, grid
        var id: Self { self }
    }

    /// Entries copied with ⌘C, pasted with ⌘V (copy) or ⌥⌘V (move) through the node's own commands.
    struct Clipboard: Equatable {
        var vaultID: Int64
        var paths: [VaultPath]
    }

    let nodeID: NodeID
    var vaultID: Int64?
    /// The vault's name as the last listing said it, for the path bar's root.
    var vaultName: String?
    private(set) var path: VaultPath = .root
    var viewMode: ViewMode = .list
    var sort = FileSort()
    var selection: Set<String> = []
    var filter = ""
    var showHidden = false
    var clipboard: Clipboard?
    /// A folder just created, to rename in place once the listing shows it.
    var pendingRename: VaultPath?
    /// Asked by the toolbar, menus or keys; the active browser view performs it.
    var renameRequest: VaultPath?

    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []

    struct Location: Equatable {
        var vaultID: Int64
        var path: VaultPath
    }

    let transfers: TransferCenter
    let thumbnails: ThumbnailStore
    let quickLook: QuickLookController
    let lanes: any FileLaneService

    init(nodeID: NodeID, lanes: any FileLaneService) {
        self.nodeID = nodeID
        self.lanes = lanes
        transfers = TransferCenter(lanes: lanes)
        thumbnails = ThumbnailStore(lanes: lanes)
        quickLook = QuickLookController(lanes: lanes)
    }

    // MARK: Navigation

    func open(vault id: Int64, name: String?) {
        guard id != vaultID else { return }
        if let vaultID { backStack.append(Location(vaultID: vaultID, path: path)) }
        forwardStack.removeAll()
        vaultID = id
        vaultName = name
        path = .root
        selection = []
        filter = ""
    }

    func navigate(to folder: VaultPath, selecting child: VaultPath? = nil) {
        guard let vaultID, folder != path else { return }
        backStack.append(Location(vaultID: vaultID, path: path))
        forwardStack.removeAll()
        path = folder
        selection = child.map { [$0.rawValue] } ?? []
        filter = ""
    }

    /// ⌘↑: the enclosing folder, with the folder we came from selected.
    func goToParent() {
        guard !path.isRoot else { return }
        navigate(to: path.parent, selecting: path)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let previous = backStack.popLast(), let vaultID else { return }
        forwardStack.append(Location(vaultID: vaultID, path: path))
        restore(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast(), let vaultID else { return }
        backStack.append(Location(vaultID: vaultID, path: path))
        restore(next)
    }

    private func restore(_ location: Location) {
        let left = path
        if location.vaultID != vaultID { vaultName = nil }
        vaultID = location.vaultID
        path = location.path
        selection = location.path.contains(left) && location.path != left
            ? [location.path.appending(left.components[location.path.components.count]).rawValue] : []
    }

    /// The vault is gone or unreachable: forget it.
    func closeVault() {
        vaultID = nil
        vaultName = nil
        path = .root
        selection = []
        backStack.removeAll()
        forwardStack.removeAll()
    }
}

/// The workspaces, one per node, for the app's lifetime. Removing a node drops its workspace with the next lookup.
enum FilesWorkspaces {
    private static var byNode: [NodeID: FilesWorkspace] = [:]
    private static var terminationObserver: (any NSObjectProtocol)?

    static func workspace(for node: Node, model: AppModel) -> FilesWorkspace {
        if let existing = byNode[node.id] { return existing }
        let lanes: any FileLaneService
        #if DEBUG
        if model.sessions == nil {
            lanes = PreviewFileLanes()
        } else {
            lanes = NodeFileLanes { [weak model] in model?.sessions?.session(for: node.id) }
        }
        #else
        lanes = NodeFileLanes { [weak model] in model?.sessions?.session(for: node.id) }
        #endif
        let made = FilesWorkspace(nodeID: node.id, lanes: lanes)
        byNode[node.id] = made
        observeTermination()
        return made
    }

    /// Quick Look's downloaded copies go when the app quits.
    private static func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                for workspace in byNode.values {
                    workspace.transfers.cancelAll()
                    workspace.quickLook.discardCopies()
                }
                QuickLookController.removeAllCopies()
            }
        }
    }
}

// MARK: - Folder contents

/// A folder's entries for display: mapped, filtered and sorted off the main actor (a folder can hold tens of
/// thousands of entries), published together with a generation the AppKit views compare to know when to reload.
@Observable
final class FolderContents {
    private(set) var items: [FileItem] = []
    /// Entries in the folder before filtering.
    private(set) var total = 0
    private(set) var generation = 0
    private(set) var isComputing = false

    @ObservationIgnored private var mapped: (key: String, items: [FileItem])?
    @ObservationIgnored private var lastInput: Input?
    @ObservationIgnored private var task: Task<Void, Never>?

    struct Input: Equatable {
        var listingKey: String
        var sort: FileSort
        var filter: String
        var showHidden: Bool
    }

    /// Recomputes when the listing or how it is shown changed.
    func update(listing: Ws.Fs.Dir.List.Response?, listedAt: Date?, folder: VaultPath, sort: FileSort, filter: String,
                showHidden: Bool) {
        guard let listing, let listedAt else {
            if !items.isEmpty || total != 0 {
                items = []
                total = 0
                generation += 1
            }
            lastInput = nil
            return
        }
        let key = "\(listing.path)|\(listedAt.timeIntervalSinceReferenceDate)|\(listing.files.count)"
        let input = Input(listingKey: key, sort: sort, filter: filter, showHidden: showHidden)
        guard input != lastInput else { return }
        lastInput = input
        let reuse = mapped?.key == key ? mapped?.items : nil
        task?.cancel()
        isComputing = true
        task = Task {
            let computed = await Self.compute(entries: reuse == nil ? listing.files : [], reuse: reuse, folder: folder,
                                              sort: sort, filter: filter, showHidden: showHidden)
            guard !Task.isCancelled else { return }
            mapped = (key, computed.all)
            items = computed.shown
            total = computed.all.count
            generation += 1
            isComputing = false
        }
    }

    @concurrent
    private static func compute(entries: [WsModel.FsEntry], reuse: [FileItem]?, folder: VaultPath, sort: FileSort,
                                filter: String, showHidden: Bool) async -> (all: [FileItem], shown: [FileItem]) {
        let all = reuse ?? entries.map { FileItem(entry: $0, in: folder, kind: FileKinds.kind) }
        let shown = sort.sorted(FileFilter.apply(all, query: filter, showHidden: showHidden))
        return (all, shown)
    }
}

// MARK: - Kinds and icons

/// The Kind column and icons, from the name's extension (then the node's MIME type) through `UTType`.
nonisolated enum FileKinds {
    private static let cache = Mutex<[String: String]>([:])

    static func type(name: String, mime: String?, isDirectory: Bool) -> UTType {
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) { return type }
        if let mime, let type = UTType(mimeType: mime) { return type }
        return .data
    }

    static func kind(_ entry: WsModel.FsEntry, isDirectory: Bool) -> String {
        if isDirectory { return "Folder" }
        if entry.type == WsModel.FsEntry.TypeValue.symlink { return "Symbolic link" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let mime = entry.mimeType?.wrapped
        let key = ext.isEmpty ? "mime:\(mime ?? "")" : ext
        if let known = cache.withLock({ $0[key] }) { return known }
        let type = type(name: entry.name, mime: mime, isDirectory: false)
        let text = type == .data ? (ext.isEmpty ? "Document" : "\(ext.uppercased()) file")
            : (type.localizedDescription ?? "Document")
        cache.withLock { $0[key] = text }
        return text
    }
}

/// File icons as Finder draws them, cached per type.
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: FileItem) -> NSImage {
        let type = FileKinds.type(name: item.name, mime: item.mimeType, isDirectory: item.isDirectory)
        if let cached = cache[type.identifier] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache[type.identifier] = image
        return image
    }
}
