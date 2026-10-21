import AppKit
import QuickLookUI
import SwiftUI
import VHNodes

/// The list: an NSTableView (Name, Date Modified, Size, Kind) with sortable columns, multiple selection, native
/// type-to-select, in-place rename on Return, drags to Finder as file promises, drops from Finder as uploads and
/// drops onto folders as moves. Only visible rows exist, so a folder of 10k+ entries scrolls smoothly.
struct FileListView: NSViewRepresentable {
    var items: [FileItem]
    var generation: Int
    @Binding var selection: Set<String>
    @Binding var sort: FileSort
    @Binding var renameRequest: VaultPath?
    var folder: VaultPath
    var vaultID: Int64
    var actions: BrowserActions
    var quickLook: QuickLookController

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = BrowserTableView()
        table.coordinator = context.coordinator
        table.style = .inset
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.allowsColumnReordering = true
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Files")

        for column in Coordinator.Column.allCases {
            let made = NSTableColumn(identifier: column.identifier)
            made.title = column.title
            made.minWidth = column.minWidth
            made.width = column.width
            made.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column.ascendsFirst)
            if column == .size { made.headerCell.alignment = .right }
            table.addTableColumn(made)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.vaulthallaEntry, .fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        context.coordinator.apply(self, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(self, force: false)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        enum Column: String, CaseIterable {
            case name, modified, size, kind

            var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
            var title: String {
                switch self {
                case .name: "Name"
                case .modified: "Date Modified"
                case .size: "Size"
                case .kind: "Kind"
                }
            }
            var width: CGFloat {
                switch self {
                case .name: 320
                case .modified: 180
                case .size: 90
                case .kind: 150
                }
            }
            var minWidth: CGFloat { self == .name ? 160 : 70 }
            /// Finder starts dates and sizes newest/largest first.
            var ascendsFirst: Bool { self == .name || self == .kind }
            var sortKey: FileSort.Key {
                switch self {
                case .name: .name
                case .modified: .modified
                case .size: .size
                case .kind: .kind
                }
            }
        }

        weak var table: BrowserTableView?
        var view: FileListView?
        private(set) var items: [FileItem] = []
        private var rows: [String: Int] = [:]
        private var generation = -1
        private var applying = false
        private var editing: FileItem?
        private lazy var promises = PromiseWriter { [weak self] path, url in
            await self?.view?.actions.promiseDownload(path, url) ?? false
        }

        var actions: BrowserActions? { view?.actions }

        func apply(_ view: FileListView, force: Bool) {
            self.view = view
            guard let table else { return }
            applying = true
            defer { applying = false }
            let descriptor = NSSortDescriptor(key: Self.column(for: view.sort.key).rawValue, ascending: view.sort.ascending)
            if table.sortDescriptors.first != descriptor { table.sortDescriptors = [descriptor] }
            if force || view.generation != generation {
                generation = view.generation
                items = view.items
                rows = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
                if editing != nil { table.abortEditing() }
                editing = nil
                table.reloadData()
            }
            let wanted = IndexSet(view.selection.compactMap { rows[$0] })
            if table.selectedRowIndexes != wanted {
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                if let first = wanted.first { table.scrollRowToVisible(first) }
            }
            view.quickLook.keyTarget = table
            if let request = view.renameRequest, let row = rows[request.rawValue] {
                DispatchQueue.main.async { [weak self] in
                    self?.view?.renameRequest = nil
                    self?.beginRename(row: row)
                }
            }
        }

        static func column(for key: FileSort.Key) -> Column {
            switch key {
            case .name: .name
            case .modified: .modified
            case .size: .size
            case .kind: .kind
            }
        }

        var selectedItems: [FileItem] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
                  items.indices.contains(row) else { return nil }
            let item = items[row]
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? FileCellView)
                ?? FileCellView(column: column, identifier: tableColumn.identifier)
            switch column {
            case .name:
                cell.textField?.stringValue = item.name
                cell.imageView?.image = FileIcons.icon(for: item)
                cell.textField?.delegate = self
                cell.alphaValue = item.entry.isHidden || item.name.hasPrefix(".") ? 0.6 : 1
            case .modified: cell.textField?.stringValue = BrowserFormat.modified(item)
            case .size: cell.textField?.stringValue = BrowserFormat.size(item)
            case .kind: cell.textField?.stringValue = item.kind
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            guard tableColumn?.identifier == Column.name.identifier, items.indices.contains(row) else { return nil }
            return items[row].name
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applying, let first = tableView.sortDescriptors.first, let key = first.key,
                  let column = Column(rawValue: key) else { return }
            view?.sort.key = column.sortKey
            view?.sort.ascending = first.ascending
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let view else { return }
            let selected = selectedItems
            view.selection = Set(selected.map(\.id))
            view.quickLook.update(selected, vaultID: view.vaultID)
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard items.indices.contains(row) else { return }
            actions?.open(items[row])
        }

        // MARK: Rename in place

        func beginRename(row: Int) {
            guard let table, items.indices.contains(row),
                  let cell = table.view(atColumn: table.column(withIdentifier: Column.name.identifier), row: row,
                                        makeIfNecessary: true) as? FileCellView,
                  let field = cell.textField
            else { return }
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
            editing = items[row]
            field.isEditable = true
            table.window?.makeFirstResponder(field)
            // Select the name without its extension, as Finder does.
            if let editor = field.currentEditor() {
                let name = items[row].name as NSString
                let stem = items[row].isDirectory || name.pathExtension.isEmpty ? name.length
                    : name.length - name.pathExtension.count - 1
                editor.selectedRange = NSRange(location: 0, length: max(0, stem))
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let item = editing,
                  let field = control as? NSTextField else { return false }
            editing = nil
            field.stringValue = item.name
            field.isEditable = false
            table?.window?.makeFirstResponder(table)
            return true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            field.isEditable = false
            guard let item = editing else { return }
            editing = nil
            let name = field.stringValue
            table?.window?.makeFirstResponder(table)
            guard name != item.name else { return }
            if VaultPath.problem(withName: name) != nil {
                field.stringValue = item.name
            }
            actions?.commitRename(item, name)
        }

        // MARK: Drag out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard items.indices.contains(row), let view else { return nil }
            return EntryPromiseProvider(item: items[row], vaultID: view.vaultID, delegate: promises)
        }

        // MARK: Drop in

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard let view else { return [] }
            var target = view.folder
            if dropOperation == .on, items.indices.contains(row), items[row].isDirectory {
                target = items[row].path
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
            }
            if let paths = BrowserDrop.entries(info.draggingPasteboard, vaultID: view.vaultID) {
                return BrowserDrop.operation(moving: paths, into: target, copy: BrowserDrop.isCopyModifierDown)
            }
            return BrowserDrop.fileURLs(info.draggingPasteboard).isEmpty ? [] : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let view else { return false }
            let target = dropOperation == .on && items.indices.contains(row) && items[row].isDirectory
                ? items[row].path : view.folder
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
    }
}

/// The list's table: Finder's keys, the context menu, and Quick Look panel control.
final class BrowserTableView: NSTableView {
    weak var coordinator: FileListView.Coordinator?

    override func keyDown(with event: NSEvent) {
        if BrowserKeys.handle(event, actions: coordinator?.actions, selected: { coordinator?.selectedItems ?? [] }) {
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes([row], byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        return coordinator?.actions?.menu(row < 0 ? [] : coordinator?.selectedItems ?? [])
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

/// A list cell: an icon and the name, or one secondary text.
final class FileCellView: NSTableCellView {
    init(column: FileListView.Coordinator.Column, identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        text.drawsBackground = false
        text.isBordered = false
        text.isEditable = false
        text.focusRingType = .none
        addSubview(text)
        textField = text
        switch column {
        case .name:
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)
            imageView = icon
            text.textColor = .labelColor
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        default:
            text.textColor = .secondaryLabelColor
            text.lineBreakMode = .byTruncatingTail
            if column == .size {
                text.alignment = .right
                text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { nil }
}
