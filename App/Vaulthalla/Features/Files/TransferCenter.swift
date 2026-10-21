import AppKit
import Foundation
import Observation
import Synchronization
import UniformTypeIdentifiers
import VHNodes
import VHTransport

/// The node's transfers for the Transfers panel: downloads and uploads with their progress, cancel, retry and errors
/// in plain words. Bytes go over the device listener's HTTP lanes (``FileLaneService``), never ws.
///
/// Main-actor state; each transfer runs in its own task. At most ``concurrency`` run at once, the rest wait.
@Observable
final class TransferCenter {
    enum Kind { case download, upload }

    enum Status: Equatable {
        case queued
        case running
        case done
        case failed(String)
        case cancelled

        var isActive: Bool { self == .queued || self == .running }
    }

    struct Item: Identifiable {
        let id = UUID()
        let kind: Kind
        var title: String
        var detail: String
        var status: Status = .queued
        var bytesDone: Int64 = 0
        var bytesTotal: Int64?
        var filesDone = 0
        var filesTotal = 1
        let startedAt = Date.now
        var finishedAt: Date?
        /// Where a finished download is, for "Show in Finder".
        var destination: URL?

        var fraction: Double? {
            guard let total = bytesTotal, total > 0 else { return nil }
            return min(1, Double(bytesDone) / Double(total))
        }
    }

    private(set) var items: [Item] = []
    var isPanelShown = false

    @ObservationIgnored let concurrency = 3
    @ObservationIgnored private let lanes: any FileLaneService
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// What each transfer does, kept so a failed or cancelled one can run again.
    @ObservationIgnored private var jobs: [UUID: Job] = [:]
    /// Callers waiting for a transfer to settle (a Finder drop's file promise).
    @ObservationIgnored private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    /// Called after an upload changed folders of a vault, so their listings refresh.
    @ObservationIgnored var onFoldersChanged: (Int64, Set<String>) -> Void = { _, _ in }

    private enum Job {
        case download(vaultID: Int64, path: String, isDirectory: Bool, to: URL)
        case upload(files: [VaultLanes.UploadFile], vaultID: Int64, into: String)
    }

    init(lanes: any FileLaneService) {
        self.lanes = lanes
    }

    var activeCount: Int { items.count(where: { $0.status.isActive }) }
    var failedCount: Int { items.count(where: { if case .failed = $0.status { true } else { false } }) }

    /// Overall progress of what is running, for the toolbar button.
    var overallFraction: Double? {
        let active = items.filter { $0.status.isActive }
        let total = active.compactMap(\.bytesTotal).reduce(0, +)
        guard !active.isEmpty, total > 0 else { return nil }
        return min(1, Double(active.reduce(0) { $0 + $1.bytesDone }) / Double(total))
    }

    // MARK: Starting

    /// Downloads `item` into the folder `folder` (a folder as `<name>.zip`), not replacing anything already there.
    func download(_ item: FileItem, vaultID: Int64, into folder: URL) {
        let name = Self.downloadName(for: item)
        let destination = Self.freeURL(in: folder, name: name)
        enqueue(.download(vaultID: vaultID, path: item.path.rawValue, isDirectory: item.isDirectory, to: destination),
                kind: .download, title: name, detail: "to \(folder.lastPathComponent)", total: item.size)
    }

    /// Downloads `item` to exactly `destination` (a save panel's choice, or a Finder drop) and returns when it has
    /// settled; true when the file is there.
    @discardableResult
    func download(_ item: FileItem, vaultID: Int64, to destination: URL) async -> Bool {
        let id = enqueue(.download(vaultID: vaultID, path: item.path.rawValue, isDirectory: item.isDirectory,
                                   to: destination),
                         kind: .download, title: destination.lastPathComponent,
                         detail: "to \(destination.deletingLastPathComponent().lastPathComponent)", total: item.size)
        if items.first(where: { $0.id == id })?.status.isActive == true {
            await withCheckedContinuation { continuation in waiters[id, default: []].append(continuation) }
        }
        return items.first { $0.id == id }?.status == .done
    }

    /// Uploads local files into `folder` of the vault (the node's upload sessions, split as the web does).
    func upload(_ files: [VaultLanes.UploadFile], vaultID: Int64, into folder: VaultPath, folderName: String) {
        guard !files.isEmpty else { return }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let title = files.count == 1 ? (files[0].relativePath as NSString).lastPathComponent : "\(files.count) files"
        let id = enqueue(.upload(files: files, vaultID: vaultID, into: folder.rawValue), kind: .upload,
                         title: title, detail: "to \(folderName)", total: total)
        update(id) { $0.filesTotal = files.count }
        isPanelShown = true
    }

    @discardableResult
    private func enqueue(_ job: Job, kind: Kind, title: String, detail: String, total: Int64?) -> UUID {
        var item = Item(kind: kind, title: title, detail: detail)
        item.bytesTotal = total
        if case .download(_, _, _, let destination) = job { item.destination = destination }
        items.insert(item, at: 0)
        jobs[item.id] = job
        trim()
        pump()
        return item.id
    }

    // MARK: Control

    func cancel(_ id: UUID) {
        if let task = tasks[id] {
            task.cancel()
        } else if items.first(where: { $0.id == id })?.status == .queued {
            update(id) {
                $0.status = .cancelled
                $0.finishedAt = .now
            }
            settle(id)
        }
    }

    private func settle(_ id: UUID) {
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    func cancelAll() {
        for item in items where item.status.isActive { cancel(item.id) }
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].status.isActive,
              jobs[id] != nil
        else { return }
        items[index].status = .queued
        items[index].bytesDone = 0
        items[index].filesDone = 0
        items[index].finishedAt = nil
        pump()
    }

    func clearFinished() {
        let finished = items.filter { !$0.status.isActive }.map(\.id)
        items.removeAll { !$0.status.isActive }
        for id in finished { jobs[id] = nil }
    }

    func showInFinder(_ id: UUID) {
        guard let url = items.first(where: { $0.id == id })?.destination,
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Whether quitting would interrupt something (asked by the app before it terminates).
    var hasActiveUploads: Bool {
        items.contains { $0.kind == .upload && $0.status.isActive }
    }

    // MARK: Running

    private func pump() {
        let running = items.count(where: { $0.status == .running })
        var free = concurrency - running
        for item in items.reversed() where item.status == .queued && free > 0 {
            guard let job = jobs[item.id] else { continue }
            free -= 1
            start(item.id, job)
        }
    }

    private func start(_ id: UUID, _ job: Job) {
        update(id) { $0.status = .running }
        let throttle = ProgressThrottle()
        let lanes = lanes
        tasks[id] = Task { [weak self] in
            let outcome: Result<Set<String>, TransferError>
            switch job {
            case .download(let vaultID, let path, let isDirectory, let destination):
                do throws(TransferError) {
                    let length = try await lanes.download(
                        vaultID: vaultID, path: path, isDirectory: isDirectory, to: destination
                    ) { done, total in
                        guard throttle.allow() else { return }
                        Task { @MainActor in
                            self?.update(id) {
                                $0.bytesDone = done
                                if let total { $0.bytesTotal = total }
                            }
                        }
                    }
                    self?.update(id) {
                        $0.bytesDone = length
                        $0.bytesTotal = length
                        $0.filesDone = 1
                    }
                    outcome = .success([])
                } catch {
                    outcome = .failure(error)
                }
            case .upload(let files, let vaultID, let folder):
                do throws(TransferError) {
                    let touched = try await lanes.upload(files, vaultID: vaultID, into: folder) { progress in
                        guard throttle.allow() || progress.files == files.count else { return }
                        Task { @MainActor in
                            self?.update(id) {
                                $0.bytesDone = progress.bytes
                                $0.filesDone = progress.files
                            }
                        }
                    }
                    self?.onFoldersChanged(vaultID, touched)
                    outcome = .success(touched)
                } catch {
                    // Some sessions may have finished before the failure: their folders changed.
                    self?.onFoldersChanged(vaultID, [folder])
                    outcome = .failure(error)
                }
            }
            self?.finish(id, outcome)
        }
    }

    private func finish(_ id: UUID, _ outcome: Result<Set<String>, TransferError>) {
        tasks[id] = nil
        update(id) { item in
            item.finishedAt = .now
            switch outcome {
            case .success:
                item.status = .done
                if let total = item.bytesTotal { item.bytesDone = total }
                item.filesDone = item.filesTotal
            case .failure(.cancelled):
                item.status = .cancelled
            case .failure(let error):
                item.status = .failed(error.message)
                isPanelShown = true
            }
        }
        settle(id)
        pump()
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    /// Keeps the 50 most recent, dropping finished ones first.
    private func trim() {
        while items.count > 50, let index = items.lastIndex(where: { !$0.status.isActive }) {
            jobs[items[index].id] = nil
            items.remove(at: index)
        }
    }

    // MARK: Names

    /// A folder downloads as the node's ZIP.
    nonisolated static func downloadName(for item: FileItem) -> String {
        item.isDirectory ? "\(item.name).zip" : item.name
    }

    /// `name` in `folder`, or Finder's "name 2.ext" when that is taken.
    static func freeURL(in folder: URL, name: String) -> URL {
        let manager = FileManager.default
        let existing = Set((try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
        let free = VaultPath.uniqueName(name, taken: existing, isDirectory: false)
        return folder.appending(path: free, directoryHint: .notDirectory)
    }
}

/// Lets a progress report through at most every 100 ms (reports arrive from the transfer's queue).
nonisolated final class ProgressThrottle: Sendable {
    private let last = Mutex<ContinuousClock.Instant?>(nil)

    func allow() -> Bool {
        let now = ContinuousClock.now
        return last.withLock { last in
            if let previous = last, now - previous < .milliseconds(100) { return false }
            last = now
            return true
        }
    }
}

// MARK: - Local files

/// Turns files and folders from Finder (a drop, the Upload panel) into upload items, keeping folder structure
/// ("Photos/2026/a.jpg"). Runs off the main actor: a dropped folder can hold many files.
nonisolated enum LocalFiles {
    static func uploadItems(from urls: [URL]) async -> [VaultLanes.UploadFile] {
        await Task.detached(priority: .userInitiated) { collect(urls) }.value
    }

    static func collect(_ urls: [URL]) -> [VaultLanes.UploadFile] {
        var files: [VaultLanes.UploadFile] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentTypeKey, .isSymbolicLinkKey]
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let base = url.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
                guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                                  options: [.skipsPackageDescendants]) else { continue }
                for case let child as URL in walker {
                    guard let item = file(child, relativeTo: base) else { continue }
                    files.append(item)
                }
            } else if let item = file(url, relativeTo: url.deletingLastPathComponent().standardizedFileURL
                .path(percentEncoded: false)) {
                files.append(item)
            }
        }
        return files
    }

    private static func file(_ url: URL, relativeTo base: String) -> VaultLanes.UploadFile? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
              values.isRegularFile == true
        else { return nil }
        let path = url.standardizedFileURL.path(percentEncoded: false)
        var relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
        while relative.hasPrefix("/") { relative.removeFirst() }
        // Finder's metadata files never go up.
        if url.lastPathComponent == ".DS_Store" { return nil }
        return VaultLanes.UploadFile(source: url, relativePath: relative, size: Int64(values.fileSize ?? 0),
                                     mimeType: values.contentType?.preferredMIMEType)
    }
}
