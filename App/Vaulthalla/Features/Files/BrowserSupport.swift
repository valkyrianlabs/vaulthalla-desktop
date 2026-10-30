import AppKit
import UniformTypeIdentifiers
import VHNodes

/// What the list and grid views ask of the browser. The views are AppKit (NSTableView, NSCollectionView): native
/// type-to-select, virtualization for folders with tens of thousands of entries, file promises to Finder and the
/// Quick Look panel all come from there.
struct BrowserActions {
    /// Double-click or ⌘↓: a folder opens, a file shows in Quick Look.
    var open: (FileItem) -> Void
    /// Space.
    var quickLook: () -> Void
    /// Return in the grid (the list renames in place).
    var requestRename: (FileItem) -> Void
    var commitRename: (FileItem, String) -> Void
    /// ⌘⌫.
    var delete: () -> Void
    /// ⌘↑.
    var parent: () -> Void
    /// ⌘C.
    var copy: () -> Void
    /// ⌘V (copy) or ⌥⌘V (move).
    var paste: (_ move: Bool) -> Void
    /// Files from Finder dropped on a folder (or the background: the open folder).
    var dropFiles: ([URL], VaultPath) -> Void
    /// Entries of this vault dragged onto a folder: moved, or copied with ⌥.
    var dropEntries: ([VaultPath], VaultPath, _ copy: Bool) -> Void
    /// A Finder drop's file promise: download `item` to the URL; true when the file is there.
    var promiseDownload: @MainActor @Sendable (_ path: VaultPath, _ to: URL) async -> Bool
    /// The context menu for these items (empty: the folder's background).
    var menu: ([FileItem]) -> NSMenu?
    /// Items now on screen (thumbnails for the grid).
    var visible: ([FileItem]) -> Void
}

extension NSPasteboard.PasteboardType {
    /// One dragged vault entry: `{"vault": <id>, "path": "<path>"}`. Only this app reads it.
    nonisolated static let vaulthallaEntry = NSPasteboard.PasteboardType("sh.vaulthalla.app.entry")
}

/// A dragged entry: a file promise for Finder (written on drop, through the Transfers panel) plus the entry itself
/// for drops inside the browser.
nonisolated final class EntryPromiseProvider: NSFilePromiseProvider {
    let entryData: Data

    init(item: FileItem, vaultID: Int64, delegate: any NSFilePromiseProviderDelegate) {
        let type: UTType = item.isDirectory
            ? .zip : FileKinds.type(name: item.name, mime: item.mimeType, isDirectory: false)
        entryData = (try? JSONSerialization.data(withJSONObject: ["vault": vaultID, "path": item.path.rawValue])) ?? Data()
        super.init()
        fileType = type.identifier
        self.delegate = delegate
        userInfo = PromiseInfo(path: item.path, fileName: TransferCenter.downloadName(for: item))
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.vaulthallaEntry]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .vaulthallaEntry ? entryData : super.pasteboardPropertyList(forType: type)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard)
        -> NSPasteboard.WritingOptions
    {
        type == .vaulthallaEntry ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

nonisolated struct PromiseInfo: Sendable {
    var path: VaultPath
    var fileName: String
}

/// Writes promised files when Finder asks: on its own queue, waiting for the download to finish.
nonisolated final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate, Sendable {
    private let download: @MainActor @Sendable (VaultPath, URL) async -> Bool
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "sh.vaulthalla.app.file-promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 3
        return queue
    }()

    init(download: @escaping @MainActor @Sendable (VaultPath, URL) async -> Bool) {
        self.download = download
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? PromiseInfo)?.fileName ?? "Download"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping ((any Error)?) -> Void) {
        guard let info = provider.userInfo as? PromiseInfo else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        let done = CompletionBox(completionHandler)
        let download = download
        // Finder waits on this queue's operation; the transfer itself runs (and shows) in the Transfers panel.
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let ok = await download(info.path, url)
            done.call(ok ? nil : CocoaError(.fileWriteUnknown))
            semaphore.signal()
        }
        semaphore.wait()
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }
}

private nonisolated final class CompletionBox: @unchecked Sendable {
    private let handler: ((any Error)?) -> Void
    init(_ handler: @escaping ((any Error)?) -> Void) { self.handler = handler }
    func call(_ error: (any Error)?) { handler(error) }
}

/// Reading drops.
enum BrowserDrop {
    /// Vault entries dragged from this browser, when they come from `vaultID`.
    static func entries(_ pasteboard: NSPasteboard, vaultID: Int64) -> [VaultPath]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        var paths: [VaultPath] = []
        for item in items {
            guard let data = item.data(forType: .vaulthallaEntry),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let vault = (object["vault"] as? NSNumber)?.int64Value, vault == vaultID,
                  let path = object["path"] as? String
            else { return nil }
            paths.append(VaultPath(normalizing: path))
        }
        return paths
    }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// What dropping `paths` on `folder` would do: nothing for a drop into its own folder or into itself.
    static func operation(moving paths: [VaultPath], into folder: VaultPath, copy: Bool) -> NSDragOperation {
        if paths.isEmpty || paths.contains(where: { $0.parent == folder || $0.contains(folder) }) { return [] }
        return copy ? .copy : .move
    }

    static var isCopyModifierDown: Bool { NSEvent.modifierFlags.contains(.option) }
}

/// Keys the browser views share (Finder's): Space, Return, ⌘⌫, ⌘↓, ⌘↑, ⌥⌘V.
enum BrowserKeys {
    /// Handles `event` with `actions`; false lets the view do its default (arrows, type-to-select).
    static func handle(_ event: NSEvent, actions: BrowserActions?, selected: () -> [FileItem]) -> Bool {
        guard let actions else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        switch (event.keyCode, flags) {
        case (49, []):
            actions.quickLook()
        case (36, []), (76, []):
            guard let item = selected().first, selected().count == 1 else { return true }
            actions.requestRename(item)
        case (51, .command), (117, .command):
            guard !selected().isEmpty else { return true }
            actions.delete()
        case (125, .command):
            guard let item = selected().first, selected().count == 1 else { return true }
            actions.open(item)
        case (126, .command):
            actions.parent()
        case (9, [.command, .option]):
            actions.paste(true)
        default:
            return false
        }
        return true
    }
}

/// Finder-style dates: "Today at 10:12", "Oct 3, 2026 at 09:00".
enum BrowserFormat {
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func size(_ item: FileItem) -> String {
        guard let size = item.size else { return "--" }
        return Format.bytes(size)
    }

    static func modified(_ item: FileItem) -> String {
        item.modified.map { date.string(from: $0) } ?? "--"
    }
}
