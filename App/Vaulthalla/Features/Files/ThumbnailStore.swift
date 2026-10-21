import AppKit
import Foundation
import VHNodes
import VHTransport

/// Grid thumbnails, the way the web console fetches them (web/src/features/files/thumbnails.ts): only for files on
/// screen whose plan says a thumbnail exists, readiness first through `/preview/batch` (at most 100 per request), then
/// the image from `/preview?size=`. Files the node is still rendering are asked again with backoff; `failed`,
/// `unsupported` and `missing` are final. Images are kept in memory, least recently used dropped first.
final class ThumbnailStore {
    /// Thumbnails kept in memory.
    let capacity = 600
    /// Called with the signatures whose image arrived, so the grid can redraw those cells.
    var onChange: (Set<String>) -> Void = { _ in }

    private let lanes: any FileLaneService
    private var images: [String: (image: NSImage, used: UInt64)] = [:]
    private var tick: UInt64 = 0
    /// Answers that won't change (no thumbnail), so they're not asked again.
    private var settled: Set<String> = []
    private var inflight: Set<String> = []
    private var wanted: [String: (item: FileItem, vaultID: Int64, size: Int)] = [:]
    private var debounce: Task<Void, Never>?
    private let maxPolls = 12

    init(lanes: any FileLaneService) {
        self.lanes = lanes
    }

    static func key(_ item: FileItem, vaultID: Int64, size: Int) -> String {
        "\(vaultID)\u{1F}\(item.contentSignature)\u{1F}\(size)"
    }

    /// The cached thumbnail, if any (marks it recently used).
    func image(for item: FileItem, vaultID: Int64, size: Int) -> NSImage? {
        let key = Self.key(item, vaultID: vaultID, size: size)
        guard var cached = images[key] else { return nil }
        tick += 1
        cached.used = tick
        images[key] = cached
        return cached.image
    }

    /// The files now on screen. Asks for the missing ones after a short pause (scrolling settles first).
    func want(_ items: [FileItem], vaultID: Int64, size: Int) {
        wanted = [:]
        for item in items where item.hasThumbnail {
            let key = Self.key(item, vaultID: vaultID, size: size)
            guard images[key] == nil, !settled.contains(key), !inflight.contains(key) else { continue }
            wanted[key] = (item, vaultID, size)
        }
        guard !wanted.isEmpty else { return }
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        let pending = wanted
        wanted = [:]
        // One batch request per vault and size, at most 100 files each.
        let groups = Dictionary(grouping: pending) { "\($0.value.vaultID)/\($0.value.size)" }
        for group in groups.values {
            let entries = group.map { (key: $0.key, item: $0.value.item) }
            guard let first = group.first?.value else { continue }
            for start in stride(from: 0, to: entries.count, by: 100) {
                let slice = Array(entries[start..<min(start + 100, entries.count)])
                for entry in slice { inflight.insert(entry.key) }
                Task { await ask(slice, vaultID: first.vaultID, size: first.size, attempt: 0) }
            }
        }
    }

    private func ask(_ entries: [(key: String, item: FileItem)], vaultID: Int64, size: Int, attempt: Int) async {
        let statuses: [String: VaultLanes.ThumbnailStatus]
        do {
            statuses = try await lanes.thumbnailStatus(
                vaultID: vaultID, items: entries.map { .init(key: $0.key, path: $0.item.path.rawValue) }, size: size)
        } catch {
            // The lanes aren't reachable now: let a later scroll ask again.
            for entry in entries { inflight.remove(entry.key) }
            return
        }
        var requeue: [(key: String, item: FileItem)] = []
        for entry in entries {
            switch statuses[entry.key] ?? .error {
            case .ready, .error:
                // `error`: the batch couldn't say; the image request answers for itself. URLSession keeps the
                // requests to a few connections.
                Task { await fetch(entry, vaultID: vaultID, size: size) }
            case .queued:
                requeue.append(entry)
            case .missing, .unsupported, .failed:
                settled.insert(entry.key)
                inflight.remove(entry.key)
            }
        }
        guard !requeue.isEmpty else { return }
        guard attempt < maxPolls else {
            for entry in requeue { inflight.remove(entry.key) }
            return
        }
        try? await Task.sleep(for: .milliseconds(min(5000, 250 << attempt)))
        await ask(requeue, vaultID: vaultID, size: size, attempt: attempt + 1)
    }

    private func fetch(_ entry: (key: String, item: FileItem), vaultID: Int64, size: Int) async {
        defer { inflight.remove(entry.key) }
        do {
            let data = try await lanes.thumbnail(vaultID: vaultID, path: entry.item.path.rawValue, size: size)
            guard let image = NSImage(data: data) else {
                settled.insert(entry.key)
                return
            }
            store(image, for: entry.key)
            onChange([entry.key])
        } catch {
            if !error.isRetryable { settled.insert(entry.key) }
        }
    }

    private func store(_ image: NSImage, for key: String) {
        tick += 1
        images[key] = (image, tick)
        guard images.count > capacity else { return }
        // Drop the least recently used tenth in one pass.
        let drop = images.sorted { $0.value.used < $1.value.used }.prefix(capacity / 10)
        for (key, _) in drop { images[key] = nil }
    }

    /// Forgets everything (the node's identity changed, or the workspace closed).
    func removeAll() {
        images.removeAll()
        settled.removeAll()
    }
}
