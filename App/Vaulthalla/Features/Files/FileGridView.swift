import AppKit
import QuickLookUI
import SwiftUI
import VHNodes

/// The icon grid: an NSCollectionView with thumbnails for files whose plan has one (``ThumbnailStore``, asked only for
/// the items on screen) and Finder icons for the rest. Same keys, drags and drops as the list.
struct FileGridView: NSViewRepresentable {
    var items: [FileItem]
    var generation: Int
    @Binding var selection: Set<String>
    var folder: VaultPath
    var vaultID: Int64
    var actions: BrowserActions
    var quickLook: QuickLookController
    var thumbnails: ThumbnailStore

    /// Thumbnail pixels on the long side: tiles are 112 pt, 2x on Retina.
    static let thumbnailSize = 256

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 124, height: 138)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        let grid = BrowserCollectionView()
        grid.coordinator = context.coordinator
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.allowsEmptySelection = true
        grid.backgroundColors = [.clear]
        grid.register(FileGridItem.self, forItemWithIdentifier: FileGridItem.identifier)
        grid.dataSource = context.coordinator
        grid.delegate = context.coordinator
        grid.registerForDraggedTypes([.vaulthallaEntry, .fileURL])
        grid.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        grid.setAccessibilityLabel("Files")

        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.grid = grid
        context.coordinator.apply(self, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self, force: false)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        weak var grid: BrowserCollectionView?
        var view: FileGridView?
        private(set) var items: [FileItem] = []
        private var rows: [String: Int] = [:]
        private var generation = -1
        private var applying = false
        private lazy var promises = PromiseWriter { [weak self] path, url in
            await self?.view?.actions.promiseDownload(path, url) ?? false
        }

        var actions: BrowserActions? { view?.actions }

        func apply(_ view: FileGridView, force: Bool) {
            self.view = view
            guard let grid else { return }
            applying = true
            defer { applying = false }
            if force || view.generation != generation {
                generation = view.generation
                items = view.items
                rows = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
                grid.reloadData()
                DispatchQueue.main.async { [weak self] in self?.reportVisible() }
            }
            let wanted = Set(view.selection.compactMap { rows[$0] }.map { IndexPath(item: $0, section: 0) })
            if grid.selectionIndexPaths != wanted {
                grid.selectionIndexPaths = wanted
                if let first = wanted.min() { grid.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge) }
            }
            view.quickLook.keyTarget = grid
            view.thumbnails.onChange = { [weak self] keys in self?.refresh(keys) }
        }

        var selectedItems: [FileItem] {
            guard let grid else { return [] }
            return grid.selectionIndexPaths.sorted().compactMap { items.indices.contains($0.item) ? items[$0.item] : nil }
        }

        // MARK: Data

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
            -> NSCollectionViewItem
        {
            let cell = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath)
            if let cell = cell as? FileGridItem, items.indices.contains(indexPath.item) {
                configure(cell, with: items[indexPath.item])
            }
            return cell
        }

        private func configure(_ cell: FileGridItem, with item: FileItem) {
            guard let view else { return }
            let thumbnail = item.hasThumbnail
                ? view.thumbnails.image(for: item, vaultID: view.vaultID, size: FileGridView.thumbnailSize) : nil
            cell.show(item, thumbnail: thumbnail)
            cell.onDoubleClick = { [weak self] in self?.actions?.open(item) }
        }

        @objc func scrolled(_ notification: Notification) {
            reportVisible()
        }

        private func reportVisible() {
            guard let grid, let view else { return }
            let visible = grid.indexPathsForVisibleItems().compactMap {
                items.indices.contains($0.item) ? items[$0.item] : nil
            }
            view.actions.visible(visible)
            view.thumbnails.want(visible, vaultID: view.vaultID, size: FileGridView.thumbnailSize)
        }

        /// Redraws the visible cells whose thumbnail arrived.
        private func refresh(_ keys: Set<String>) {
            guard let grid, let view else { return }
            for path in grid.indexPathsForVisibleItems() where items.indices.contains(path.item) {
                let item = items[path.item]
                let key = ThumbnailStore.key(item, vaultID: view.vaultID, size: FileGridView.thumbnailSize)
                guard keys.contains(key), let cell = grid.item(at: path) as? FileGridItem else { continue }
                configure(cell, with: item)
            }
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        private func selectionChanged() {
            guard !applying, let view else { return }
            let selected = selectedItems
            view.selection = Set(selected.map(\.id))
            view.quickLook.update(selected, vaultID: view.vaultID)
        }

        // MARK: Drag out

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                            with event: NSEvent) -> Bool { true }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath)
            -> (any NSPasteboardWriting)?
        {
            guard items.indices.contains(indexPath.item), let view else { return nil }
            return EntryPromiseProvider(item: items[indexPath.item], vaultID: view.vaultID, delegate: promises)
        }

        // MARK: Drop in

        func collectionView(_ collectionView: NSCollectionView, validateDrop info: any NSDraggingInfo,
                            proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard let view else { return [] }
            let index = proposedIndexPath.pointee.item
            var target = view.folder
            if dropOperation.pointee == .on, items.indices.contains(index), items[index].isDirectory {
                target = items[index].path
            } else {
                // Anywhere else: the open folder (the whole grid highlights).
                proposedIndexPath.pointee = NSIndexPath(forItem: items.count, inSection: 0)
                dropOperation.pointee = .before
            }
            if let paths = BrowserDrop.entries(info.draggingPasteboard, vaultID: view.vaultID) {
                return BrowserDrop.operation(moving: paths, into: target, copy: BrowserDrop.isCopyModifierDown)
            }
            return BrowserDrop.fileURLs(info.draggingPasteboard).isEmpty ? [] : .copy
        }

        func collectionView(_ collectionView: NSCollectionView, acceptDrop info: any NSDraggingInfo,
                            indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            guard let view else { return false }
            let target = dropOperation == .on && items.indices.contains(indexPath.item) && items[indexPath.item].isDirectory
                ? items[indexPath.item].path : view.folder
            if let paths = BrowserDrop.entries(info.draggingPasteboard, vaultID: view.vaultID) {
                let copy = BrowserDrop.isCopyModifierDown
                guard !BrowserDrop.operation(moving: paths, into: target, copy: copy).isEmpty else { return false }
                view.actions.dropEntries(paths, target, copy)
                return true
            }
            let urls = BrowserDrop.fileURLs(info.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            view.actions.dropFiles(urls, target)
            return true
        }

        // MARK: Type-to-select

        private var typed = ""
        private var typedAt = Date.distantPast

        /// Selects the first item whose name starts with what was typed in the last second.
        func typeSelect(_ characters: String) {
            let now = Date.now
            typed = now.timeIntervalSince(typedAt) > 1 ? characters : typed + characters
            typedAt = now
            guard let index = items.firstIndex(where: {
                $0.name.range(of: typed, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
            }), let grid else { return }
            let path = IndexPath(item: index, section: 0)
            grid.selectionIndexPaths = [path]
            grid.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
            selectionChanged()
        }
    }
}

/// The grid's collection view: Finder's keys, type-to-select, the context menu and Quick Look panel control.
final class BrowserCollectionView: NSCollectionView {
    weak var coordinator: FileGridView.Coordinator?

    override func keyDown(with event: NSEvent) {
        if BrowserKeys.handle(event, actions: coordinator?.actions, selected: { coordinator?.selectedItems ?? [] }) {
            return
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags.isEmpty, let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            coordinator?.typeSelect(characters)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(path) {
                selectionIndexPaths = [path]
                delegate?.collectionView?(self, didSelectItemsAt: [path])
            }
            return coordinator?.actions?.menu(coordinator?.selectedItems ?? [])
        }
        selectionIndexPaths = []
        delegate?.collectionView?(self, didDeselectItemsAt: [])
        return coordinator?.actions?.menu([])
    }

    @objc func copy(_ sender: Any?) { coordinator?.actions?.copy() }
    @objc func paste(_ sender: Any?) { coordinator?.actions?.paste(false) }

    // Quick Look asks these on the main thread.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { if let panel { coordinator?.view?.quickLook.begin(panel) } }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { if let panel { coordinator?.view?.quickLook.end(panel) } }
    }
}

/// One tile: the thumbnail (or icon) above the name, highlighted when selected.
final class FileGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileGridItem")

    private let picture = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let highlight = NSView()
    var onDoubleClick: () -> Void = {}

    override func loadView() {
        view = NSView()
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 10
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 6
        picture.layer?.masksToBounds = true
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        for subview in [highlight, picture, label] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: view.topAnchor),
            highlight.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            highlight.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            picture.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            picture.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            picture.widthAnchor.constraint(equalToConstant: 100),
            picture.heightAnchor.constraint(equalToConstant: 84),
            label.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
        ])
    }

    func show(_ item: FileItem, thumbnail: NSImage?) {
        picture.image = thumbnail ?? FileIcons.icon(for: item)
        picture.imageScaling = thumbnail == nil ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
        label.stringValue = item.name
        label.toolTip = item.name
        view.alphaValue = item.entry.isHidden || item.name.hasPrefix(".") ? 0.6 : 1
        view.setAccessibilityLabel(item.name)
        updateHighlight()
    }

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    private func updateHighlight() {
        highlight.layer?.backgroundColor = isSelected
            ? NSColor(srgbRed: 0.13, green: 0.83, blue: 0.93, alpha: 0.16).cgColor : NSColor.clear.cgColor
        highlight.layer?.borderWidth = isSelected ? 1 : 0
        highlight.layer?.borderColor = NSColor(srgbRed: 0.13, green: 0.83, blue: 0.93, alpha: 0.45).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick() }
    }
}
