#if DEBUG
import AppKit
import Foundation
import Synchronization
import VHContract
import VHCore
import VHTransport

/// PREVIEW DATA, DEBUG only: sync conflicts for `#Preview`s and `DebugSnapshot`. "Home lab (preview)" has open
/// conflicts in its two S3 preview vaults; "Studio (preview)" has none it may resolve. Resolving removes them, except
/// "todo (preview).txt", which the preview daemon refuses as changed since it was recorded.
nonisolated enum SyncConflictsPreviewData: PreviewFeature {
    private static let conflicts = Mutex(SyncConflictsPreviewData.seed)

    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        let full = transport.scenario == .full
        switch command {
        case .syncConflictsSummary:
            let open = full ? conflicts.withLock { $0 } : []
            let grouped = Dictionary(grouping: open, by: \.vaultID)
            let vaults = grouped.map { id, items in
                WsModel.SyncConflictSummary.Vault(vaultID: id, vaultName: items[0].vaultName, count: Int64(items.count))
            }
            return WsModel.SyncConflictSummary(total: Int64(open.count),
                                               vaults: vaults.sorted { $0.vaultName < $1.vaultName })
        case .syncConflictsList:
            let vaultID = (payload as? Ws.Sync.Conflicts.List.Payload)?.vaultID?.wrapped
            let open = full ? conflicts.withLock { $0 } : []
            return Ws.Sync.Conflicts.List.Response(conflicts: vaultID.map { id in open.filter { $0.vaultID == id } } ?? open)
        case .syncConflictsResolve:
            guard let resolve = payload as? Ws.Sync.Conflicts.Resolve.Payload else { throw .invalid("Bad payload.") }
            typealias Result = WsModel.SyncConflictResolveResult.Result
            let results: [Result] = conflicts.withLock { list in
                resolve.conflictIDs.map { id in
                    guard let conflict = list.first(where: { $0.id == id }) else {
                        return Result(conflictID: id, ok: false, status: "not_found", message: "No such open conflict.")
                    }
                    if !conflict.canOverwrite {
                        return Result(conflictID: id, ok: false, status: "denied",
                                      message: "Overwrite permission on this file is required.")
                    }
                    if conflict.name.hasPrefix("todo") {
                        return Result(conflictID: id, ok: false, status: "conflict",
                                      message: "The vault's copy changed again since the conflict was recorded.")
                    }
                    list.removeAll { $0.id == id }
                    return Result(conflictID: id, ok: true, status: "resolved")
                }
            }
            let resolved = Int64(results.filter(\.ok).count)
            return WsModel.SyncConflictResolveResult(resolution: resolve.resolution.rawValue, resolved: resolved,
                                                     failed: Int64(results.count) - resolved, results: results)
        default:
            return nil
        }
    }

    // MARK: Conflicts

    private static func iso(_ offset: TimeInterval) -> String {
        Date.now.addingTimeInterval(offset).formatted(.iso8601)
    }

    private static let seed: [WsModel.SyncConflict] = [
        conflict(101, vault: 3, "/Documents/notes (preview).md", local: (3_240, -2 * 3600, "text/markdown"),
                 remote: (3_410, -5 * 3600, "text/markdown"), renderer: "markdown", age: -4 * 3600),
        conflict(102, vault: 4, "/Renders/poster (preview).png", local: (1_240_000, -26 * 3600, "image/png"),
                 remote: (1_310_000, -30 * 3600, "image/png"), renderer: "image", age: -20 * 3600),
        conflict(103, vault: 4, "/Renders/storyboard (preview).jpg", local: (2_900_000, -50 * 3600, "image/jpeg"),
                 remote: (6_400_000, -49 * 3600, "image/jpeg"), renderer: "image", age: -48 * 3600),
        conflict(104, vault: 4, "/Renders/final cut (preview).mov", local: (1_820_000_000, -3 * 86_400, "video/quicktime"),
                 remote: (1_790_000_000, -3 * 86_400 + 900, "video/quicktime"), renderer: "video", age: -2 * 86_400),
        conflict(105, vault: 3, "/Contracts/lease (preview).pdf", local: (512_000, -6 * 86_400, "application/pdf"),
                 remote: (498_000, -6 * 86_400, "application/pdf"), renderer: "pdf", age: -5 * 86_400,
                 canOverwrite: false),
        conflict(106, vault: 3, "/Documents/todo (preview).txt", local: (880, -600, "text/plain"),
                 remote: (912, -7 * 3600, "text/plain"), renderer: "text", age: -6 * 3600),
    ]

    private static func conflict(
        _ id: Int64, vault: Int64, _ path: String, local: (Int64, TimeInterval, String),
        remote: (Int64, TimeInterval, String), renderer: String, age: TimeInterval, canOverwrite: Bool = true
    ) -> WsModel.SyncConflict {
        let vaultName = vault == 3 ? "Offsite Backup (preview)" : "Media Archive (preview)"
        let name = String(path.split(separator: "/").last ?? "")
        return WsModel.SyncConflict(
            id: id, vaultID: vault, vaultName: vaultName, fileID: 5000 + id, path: path, name: name, type: "mismatch",
            reasons: [
                .init(code: "content_changed", message: "Both copies changed since the last sync"),
                .init(code: local.0 == remote.0 ? "mtime_mismatch" : "size_mismatch",
                      message: local.0 == remote.0 ? "Modification times differ" : "Sizes differ"),
            ],
            createdAt: iso(age), updatedAt: iso(age / 2),
            local: WsModel.SyncConflictSide(sizeBytes: local.0, mimeType: local.2,
                                            contentHash: "b3:\(String(repeating: "7f3a", count: 8))\(id)",
                                            modifiedAt: iso(local.1)),
            remote: WsModel.SyncConflictSide(sizeBytes: remote.0, mimeType: remote.2,
                                             contentHash: "b3:\(String(repeating: "c91e", count: 8))\(id)",
                                             modifiedAt: iso(remote.1), etag: "\"9b2cf535f27731c974343645a3985328-\(id)\"",
                                             encrypted: vault == 3),
            canOverwrite: canOverwrite,
            preview: WsModel.PreviewPlan(kind: renderer == "pdf" ? "rendered_image" : "native_media",
                                         renderer: renderer, requires: "download", thumbnail: renderer != "markdown"))
    }

    // MARK: Bytes

    /// Canned bytes for the preview lane, for the preview nodes only.
    static func bytes(conflictID: Int64, side: String, node: Node) -> Data? {
        guard node.id.rawValue.hasPrefix("preview-") else { return nil }
        let local = side == "local"
        switch conflictID {
        case 101:
            return Data((local ? notesLocal : notesRemote).utf8)
        case 106:
            return Data((local ? "- [x] Renew the domain\n- [ ] Book the venue\n- [ ] Call the bank\n"
                               : "- [x] Renew the domain\n- [x] Book the venue\n- [ ] Send the invites\n").utf8)
        case 102, 103:
            return image(local ? "LOCAL" : "REMOTE", hue: local ? 0.52 : 0.08)
        default:
            return nil
        }
    }

    private static let notesLocal = """
        # Offsite backup notes (preview)

        The nightly job copies Documents to the bucket at 02:00.
        Retention: 30 days of snapshots.

        ## Checklist
        - Verify the restore drill monthly
        - Rotate the upstream key every quarter
        - Keep the export of the vault key in 1Password
        """

    private static let notesRemote = """
        # Offsite backup notes (preview)

        The nightly job copies Documents to the bucket at 03:30.
        Retention: 30 days of snapshots.

        ## Checklist
        - Verify the restore drill monthly
        - Keep the export of the vault key in 1Password
        - Check the bucket's lifecycle rules
        """

    private static func image(_ label: String, hue: CGFloat) -> Data? {
        let size = NSSize(width: 480, height: 300)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: NSColor(hue: hue, saturation: 0.7, brightness: 0.55, alpha: 1),
                       ending: NSColor(hue: hue + 0.1, saturation: 0.6, brightness: 0.25, alpha: 1))?
                .draw(in: rect, angle: -35)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: NSColor.white,
            ]
            let text = NSAttributedString(string: "\(label)\n(preview)", attributes: attributes)
            let bounds = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin])
            text.draw(with: NSRect(x: (rect.width - bounds.width) / 2, y: (rect.height - bounds.height) / 2,
                                   width: bounds.width, height: bounds.height), options: [.usesLineFragmentOrigin])
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
