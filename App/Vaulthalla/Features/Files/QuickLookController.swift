import AppKit
import Foundation
import QuickLookUI
import VHNodes
import VHTransport

/// Space bar Quick Look over vault files: the selected files are downloaded (`/download/content`) into a private
/// temporary folder (0700, one per app run) and handed to `QLPreviewPanel`, which shows images, PDFs, media and text
/// natively. The copies are deleted when the browser closes and when the app quits.
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// Larger files are offered for download instead: Quick Look needs the whole file on disk first.
    static let sizeLimit: Int64 = 1024 * 1024 * 1024

    private let lanes: any FileLaneService
    private var vaultID: Int64?
    private var items: [FileItem] = []
    private var previews: [String: PreviewItem] = [:]
    private var downloads: [String: Task<Void, Never>] = [:]
    /// Forwards keys the panel doesn't handle (arrows) to the browser, so the selection moves under the panel.
    weak var keyTarget: NSResponder?

    init(lanes: any FileLaneService) {
        self.lanes = lanes
    }

    // MARK: Panel control

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Space: shows the panel for `selected`, or closes it.
    func toggle(_ selected: [FileItem], vaultID: Int64) {
        if isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        update(selected, vaultID: vaultID)
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    /// The selection changed: the panel (if open) follows it.
    func update(_ selected: [FileItem], vaultID: Int64) {
        self.vaultID = vaultID
        let files = selected.filter { !$0.isDirectory }
        guard files.map(\.contentSignature) != items.map(\.contentSignature) else { return }
        items = files
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible else { return }
        QLPreviewPanel.shared().reloadData()
    }

    /// The browser view calls these from its `QLPreviewPanelController` methods.
    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        for task in downloads.values { task.cancel() }
        downloads.removeAll()
    }

    // MARK: Data source

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard items.indices.contains(index) else { return nil }
        return preview(for: items[index])
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, let keyTarget else { return false }
        keyTarget.keyDown(with: event)
        return true
    }

    // MARK: Copies

    private func preview(for item: FileItem) -> PreviewItem {
        let key = item.contentSignature
        if let existing = previews[key] { return existing }
        let made = PreviewItem(title: item.name)
        previews[key] = made
        guard let vaultID else { return made }
        if let size = item.size, size > Self.sizeLimit {
            made.title = "\(item.name): too large to preview here. Download it instead."
            return made
        }
        guard let folder = Self.copiesFolder() else {
            made.title = "\(item.name): no private temporary folder for previews."
            return made
        }
        // One folder per copy, so the file keeps its own name (and extension) and names never collide.
        let target = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let destination = target.appending(path: item.name, directoryHint: .notDirectory)
        made.title = "\(item.name): downloading…"
        let lanes = lanes
        downloads[key] = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                _ = try await lanes.download(vaultID: vaultID, path: item.path.rawValue, isDirectory: false,
                                             to: destination) { _, _ in }
                made.url = destination
                made.title = item.name
            } catch let error as TransferError {
                made.title = "\(item.name): \(error.message)"
                if case .cancelled = error { self?.previews[key] = nil }
            } catch {
                made.title = "\(item.name): \(error.localizedDescription)"
            }
            self?.downloads[key] = nil
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().refreshCurrentPreviewItem()
            }
        }
        return made
    }

    /// Deletes this browser's copies (the browser closed).
    func discardCopies() {
        for task in downloads.values { task.cancel() }
        downloads.removeAll()
        let urls = previews.values.compactMap(\.url)
        previews.removeAll()
        items.removeAll()
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    // MARK: Temporary folder

    private static let runFolder: URL = FileManager.default.temporaryDirectory
        .appending(path: "Vaulthalla Quick Look", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    /// This run's private folder for copies: created 0700 inside a 0700 parent, nil if that can't be guaranteed.
    static func copiesFolder() -> URL? {
        let manager = FileManager.default
        let parent = runFolder.deletingLastPathComponent()
        do {
            for folder in [parent, runFolder] {
                if !manager.fileExists(atPath: folder.path(percentEncoded: false)) {
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                }
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path(percentEncoded: false))
            }
            return runFolder
        } catch {
            return nil
        }
    }

    /// Deletes this run's copies (the app quits).
    static func removeAllCopies() {
        try? FileManager.default.removeItem(at: runFolder)
    }
}

/// One file in the Quick Look panel: its local copy once downloaded, and a title saying what's happening until then.
final class PreviewItem: NSObject, QLPreviewItem {
    var url: URL?
    var title: String

    init(title: String) {
        self.title = title
    }

    var previewItemURL: URL! { url }
    var previewItemTitle: String! { title }
}
