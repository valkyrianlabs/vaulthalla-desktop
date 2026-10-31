#if DEBUG
import AppKit
import Foundation
import Synchronization
import VHContract
import VHNodes
import VHTransport

/// PREVIEW DATA, DEBUG only: a vault tree answering `fs.*` and `recovery.*` for `#Preview`s and `DebugSnapshot`
/// (`-VHDebugPreviewData YES`). Names say "(preview)"; nothing here reaches a real node.
nonisolated final class FilesPreviewTransport: NodeTransport {
    private struct Node {
        var entry: WsModel.FsEntry
    }

    private let tree: Mutex<[String: [WsModel.FsEntry]]>
    private let vaults: [WsModel.Vault]

    init(vaults: [WsModel.Vault]) {
        self.vaults = vaults
        tree = Mutex(Self.makeTree())
    }

    func send<R: WsRequest>(_ request: R.Type, payload: R.Payload) async throws(WsError) -> R.Response {
        try? await Task.sleep(for: .milliseconds(90))
        let answer = try self.answer(R.command, payload)
        guard let typed = answer as? R.Response else {
            throw .contractMismatch("preview data has no \(R.command.rawValue) answer")
        }
        return typed
    }

    private func answer(_ command: WsCommand, _ payload: some Sendable) throws(WsError) -> Any {
        switch command {
        case .storageVaultList:
            return Ws.Storage.Vault.List.Response(vaults: vaults)
        case .storageVaultAccessibleList:
            // The last vault is one this account may only manage: the picker lists it without opening it.
            return Ws.Storage.Vault.Accessible.List.Response(vaults: vaults.enumerated().map { index, vault in
                let manageOnly = index == vaults.count - 1 && vaults.count > 1
                return Self.accessible(vault, browse: !manageOnly, manage: index != 1,
                                       via: manageOnly ? ["admin_policy"] : (index == 1 ? ["vault_role"] : ["owner"]))
            })
        case .fsDirList:
            guard let list = payload as? Ws.Fs.Dir.List.Payload else { throw .invalid("Bad payload.") }
            guard let vault = vaults.first(where: { $0.id == list.vaultID }) else {
                throw .denied("Permission denied: no access to this vault (preview).")
            }
            let path = VaultPath(normalizing: list.path ?? "/")
            guard let files = tree.withLock({ $0[path.rawValue] }) else { throw .notFound("No such folder (preview).") }
            return Ws.Fs.Dir.List.Response(vault: vault.name, path: path.rawValue,
                                           entry: Self.base(Self.folder(path.name, at: path)), files: files)
        case .fsDirCreate:
            guard let create = payload as? Ws.Fs.Dir.Create.Payload else { throw .invalid("Bad payload.") }
            let path = VaultPath(normalizing: create.path)
            try insert(Self.folder(path.name, at: path))
            tree.withLock { $0[path.rawValue] = $0[path.rawValue] ?? [] }
            return Ws.Fs.Dir.Create.Response(path: path.rawValue)
        case .fsEntryRename:
            guard let rename = payload as? Ws.Fs.Entry.Rename.Payload else { throw .invalid("Bad payload.") }
            try move(rename.from, rename.to, copy: false)
            return Ws.Fs.Entry.Rename.Response(from: rename.from, to: rename.to)
        case .fsEntryMove:
            guard let move = payload as? Ws.Fs.Entry.Move.Payload else { throw .invalid("Bad payload.") }
            try self.move(move.from, move.to, copy: false)
            return Ws.Fs.Entry.Move.Response(from: move.from, to: move.to)
        case .fsEntryCopy:
            guard let copy = payload as? Ws.Fs.Entry.Copy.Payload else { throw .invalid("Bad payload.") }
            try move(copy.from, copy.to, copy: true)
            return Ws.Fs.Entry.Copy.Response(from: copy.from, to: copy.to)
        case .fsEntryDelete:
            guard let delete = payload as? Ws.Fs.Entry.Delete.Payload else { throw .invalid("Bad payload.") }
            let path = VaultPath(normalizing: delete.path)
            tree.withLock { $0[path.parent.rawValue]?.removeAll { $0.path == path.rawValue } }
            return Ws.Fs.Entry.Delete.Response(path: path.rawValue)
        case .recoveryList:
            guard let list = payload as? Ws.Recovery.List.Payload else { throw .invalid("Bad payload.") }
            return Ws.Recovery.List.Response(points: Self.points(vaultID: list.vaultID, path: list.path ?? "/"))
        case .recoveryPlan:
            guard let plan = payload as? Ws.Recovery.Plan.Payload else { throw .invalid("Bad payload.") }
            return Ws.Recovery.Plan.Response(plan: Self.plan(plan.recoveryID ?? "lv-1"))
        case .recoveryRestore:
            guard let restore = payload as? Ws.Recovery.Restore.Payload else { throw .invalid("Bad payload.") }
            return Ws.Recovery.Restore.Response(result: .init(
                planID: restore.planID, state: "done", items: [], restored: 1, skipped: 0, conflicts: 0, failed: 0,
                removed: 0, unavailable: 0))
        default:
            throw .notFound("The preview has no answer for \(command.rawValue).")
        }
    }

    /// A storage.vault.accessible.list row for a preview vault.
    private static func accessible(_ vault: WsModel.Vault, browse: Bool, manage: Bool,
                                   via: [String]) -> WsModel.AccessibleVault {
        WsModel.AccessibleVault(
            id: vault.id, name: vault.name, slug: vault.slug, effectiveFuseName: vault.effectiveFuseName,
            type: vault.type, description: vault.description, quota: vault.quota, ownerID: vault.ownerID,
            owner: vault.owner ?? "", isActive: vault.isActive, createdAt: vault.createdAt, browse: browse,
            manage: manage, via: via)
    }

    private func insert(_ entry: WsModel.FsEntry) throws(WsError) {
        let parent = VaultPath(normalizing: entry.path).parent.rawValue
        let exists = tree.withLock { $0[parent]?.contains { $0.name.lowercased() == entry.name.lowercased() } ?? false }
        if exists { throw .conflict("An entry named “\(entry.name)” already exists (preview).") }
        tree.withLock { $0[parent, default: []].append(entry) }
    }

    private func move(_ from: String, _ to: String, copy: Bool) throws(WsError) {
        let source = VaultPath(normalizing: from)
        let target = VaultPath(normalizing: to)
        guard var entry = tree.withLock({ $0[source.parent.rawValue]?.first { $0.path == source.rawValue } }) else {
            throw .notFound("No such entry (preview).")
        }
        entry.name = target.name
        entry.path = target.rawValue
        entry.id = Int64.random(in: 10_000...99_999)
        try insert(entry)
        if !copy { tree.withLock { $0[source.parent.rawValue]?.removeAll { $0.path == source.rawValue } } }
    }

    // MARK: The tree

    private static func makeTree() -> [String: [WsModel.FsEntry]] {
        var tree: [String: [WsModel.FsEntry]] = [:]
        let root = VaultPath.root
        tree["/"] = [
            folder("Photos", at: root.appending("Photos"), files: 248, folders: 3),
            folder("Documents", at: root.appending("Documents"), files: 31, folders: 2),
            folder("Large folder (12,000 files)", at: root.appending("Large folder (12,000 files)"), files: 12_000),
            file("Budget 2026 (preview).numbers", at: root, size: 482_113, days: 2),
            file("Floor plan (preview).pdf", at: root, size: 3_481_002, days: 9, mime: "application/pdf", thumbnail: true),
            file("Notes (preview).md", at: root, size: 6_220, days: 0, mime: "text/markdown"),
            file("Kitchen render (preview).png", at: root, size: 2_204_998, days: 14, mime: "image/png", thumbnail: true),
            file("Holiday clip (preview).mov", at: root, size: 912_440_118, days: 30, mime: "video/quicktime"),
            file("Taxes 2025 (preview).zip", at: root, size: 41_002_918, days: 120, mime: "application/zip"),
        ]
        let photos = root.appending("Photos")
        tree[photos.rawValue] = (1...48).map { index in
            file("IMG_\(4100 + index) (preview).jpg", at: photos, size: Int64(1_800_000 + index * 91_337),
                 days: index, mime: "image/jpeg", thumbnail: true)
        } + [folder("2024", at: photos.appending("2024")), folder("2025", at: photos.appending("2025")),
             folder("Scans", at: photos.appending("Scans"))]
        let documents = root.appending("Documents")
        tree[documents.rawValue] = [
            file("Lease (preview).pdf", at: documents, size: 1_204_331, days: 40, mime: "application/pdf", thumbnail: true),
            file("Resume (preview).docx", at: documents, size: 88_120, days: 200),
            folder("Receipts", at: documents.appending("Receipts")),
        ]
        let large = root.appending("Large folder (12,000 files)")
        tree[large.rawValue] = (0..<12_000).map { index in
            file("log-\(String(format: "%05d", index)) (preview).txt", at: large, size: Int64(1_000 + (index * 7919) % 90_000),
                 days: index % 365, mime: "text/plain")
        }
        for path in [photos.appending("2024"), photos.appending("2025"), photos.appending("Scans"),
                     documents.appending("Receipts")] {
            tree[path.rawValue] = []
        }
        return tree
    }

    private static let epoch = Date(timeIntervalSince1970: 1_792_500_000)

    private static func stamp(daysAgo days: Int) -> String {
        epoch.addingTimeInterval(TimeInterval(-days * 86_400 - days * 3_731)).formatted(.iso8601)
    }

    static func folder(_ name: String, at path: VaultPath, files: Int64 = 0, folders: Int64 = 0) -> WsModel.FsEntry {
        WsModel.FsEntry(id: Int64(abs(path.rawValue.hashValue % 100_000)), name: name, path: path.rawValue,
                        absPath: "/mnt/vaulthalla/preview\(path.rawValue)", sizeBytes: 0, isHidden: false,
                        isSystem: false, createdAt: stamp(daysAgo: 400), updatedAt: stamp(daysAgo: 3),
                        metadataVersion: "m\(path.rawValue.count)-0", type: WsModel.FsEntry.TypeValue.directory, fileCount: files, subdirectoryCount: folders)
    }

    static func file(_ name: String, at folder: VaultPath, size: Int64, days: Int, mime: String? = nil,
                     thumbnail: Bool = false) -> WsModel.FsEntry {
        let path = folder.appending(name)
        return WsModel.FsEntry(
            id: Int64(abs(path.rawValue.hashValue % 1_000_000)), name: name, path: path.rawValue,
            absPath: "/mnt/vaulthalla/preview\(path.rawValue)", sizeBytes: size, isHidden: false, isSystem: false,
            createdAt: stamp(daysAgo: days + 10), updatedAt: stamp(daysAgo: days), metadataVersion: "m\(days)-0",
            contentVersion: "\"g\(days)-0\"", type: WsModel.FsEntry.TypeValue.file,
            mimeType: mime.map { .value($0) } ?? .null,
            preview: .init(kind: thumbnail ? "rendered_image" : "unsupported", renderer: thumbnail ? "image" : "none",
                           requires: "preview", thumbnail: thumbnail))
    }

    static func base(_ entry: WsModel.FsEntry) -> WsModel.FsEntryBase {
        WsModel.FsEntryBase(id: entry.id, name: entry.name, path: entry.path, absPath: entry.absPath,
                            sizeBytes: entry.sizeBytes, isHidden: false, isSystem: false, createdAt: entry.createdAt,
                            updatedAt: entry.updatedAt, metadataVersion: entry.metadataVersion,
                            contentVersion: entry.contentVersion)
    }

    // MARK: Recovery

    private static func points(vaultID: Int64, path: String) -> [WsModel.RecoveryPoint] {
        (1...4).map { index in
            WsModel.RecoveryPoint(
                id: "lv-\(index)", backend: "local_version", vaultID: vaultID, path: path, originalEntryID: 1,
                kind: "file", name: nil, createdAt: stamp(daysAgo: index * 3), validFrom: stamp(daysAgo: index * 3 + 2),
                validUntil: stamp(daysAgo: index * 3), sizeBytes: Int64(400_000 + index * 12_345), contentHash: nil,
                encryption: .init(encrypted: true, keyVersion: 1, keyAvailable: true, keyCurrent: true),
                retention: .init(policy: "keep_last:10", expiresAt: nil, note: nil), estimatedMonthlyCost: nil,
                isCurrent: false, isDeleteMarker: false, origin: "vaulthalla",
                reason: index == 4 ? "delete" : "overwrite", upstreamState: "none", storageClass: nil, fileCount: nil,
                restorable: true, unavailableReason: nil)
        }
    }

    private static func plan(_ recoveryID: String) -> WsModel.RecoveryPlan {
        WsModel.RecoveryPlan(
            id: 7, vaultID: 1, token: "preview-token", sourceLabel: recoveryID, pointInTime: false, at: nil, atomic: true,
            consistencyNote: "", destination: nil, prune: false,
            items: [.init(sourceID: recoveryID, sourcePath: "/Notes (preview).md", destinationPath: "/Notes (preview).md",
                          action: "overwrite", sizeBytes: 5_120, destinationSourceID: "g1", method: "local_copy", notes: [])],
            creates: 0, overwrites: 1, skips: 0, conflicts: 0, removals: 0, unavailable: 0,
            estimate: .init(getRequests: 0, headRequests: 0, putRequests: 0, copyRequests: 0, listRequests: 0,
                            downloadBytes: 0, uploadBytes: 0, cost: nil, unpricedReason: nil),
            warnings: [], blockers: [], createdAt: stamp(daysAgo: 0), expiresAt: nil, state: "planned")
    }
}

/// PREVIEW DATA lanes: drawn thumbnails, a placeholder file for downloads, uploads that only report progress.
nonisolated struct PreviewFileLanes: FileLaneService {
    func thumbnailStatus(vaultID: Int64, items: [VaultLanes.ThumbnailItem], size: Int)
        async throws(TransferError) -> [String: VaultLanes.ThumbnailStatus]
    {
        Dictionary(uniqueKeysWithValues: items.map { ($0.key, .ready) })
    }

    func thumbnail(vaultID: Int64, path: String, size: Int) async throws(TransferError) -> Data {
        try? await Task.sleep(for: .milliseconds(60))
        return Self.drawn(seed: abs(path.hashValue), size: size)
    }

    func download(vaultID: Int64, path: String, isDirectory: Bool, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws(TransferError) -> Int64 {
        let text = Data("PREVIEW DATA: \(path) is not a real file.\n".utf8)
        for step in 1...5 {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { throw .cancelled }
            progress(Int64(text.count * step / 5), Int64(text.count))
        }
        do { try text.write(to: destination) } catch { throw .disk(error.localizedDescription) }
        return Int64(text.count)
    }

    func upload(_ files: [VaultLanes.UploadFile], vaultID: Int64, into directory: String, id: UUID,
                control: UploadControl, progress: @escaping @Sendable (VaultLanes.UploadProgress) -> Void)
        async throws(TransferError) -> Set<String>
    {
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        for step in 1...10 {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { throw .cancelled }
            let bytes: Int64 = total * Int64(step) / 10
            let done: Int = files.count * step / 10
            progress(VaultLanes.UploadProgress(bytes: bytes, files: done))
        }
        return [directory]
    }

    /// A soft two-color gradient with a diagonal band, standing in for a photo.
    static func drawn(seed: Int, size: Int) -> Data {
        let hues = [0.52, 0.58, 0.08, 0.33, 0.75, 0.95]
        let hue = hues[seed % hues.count]
        let image = NSImage(size: NSSize(width: size, height: size * 3 / 4), flipped: false) { rect in
            let gradient = NSGradient(colors: [
                NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1),
                NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.35, alpha: 1),
            ])
            gradient?.draw(in: rect, angle: CGFloat(seed % 90) - 60)
            NSColor.white.withAlphaComponent(0.18).setFill()
            let band = NSBezierPath()
            band.move(to: NSPoint(x: 0, y: rect.height * 0.35))
            band.line(to: NSPoint(x: rect.width, y: rect.height * 0.75))
            band.line(to: NSPoint(x: rect.width, y: rect.height * 0.55))
            band.line(to: NSPoint(x: 0, y: rect.height * 0.15))
            band.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { return Data() }
        return jpeg
    }
}
#endif
