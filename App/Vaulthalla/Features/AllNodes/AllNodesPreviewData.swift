#if DEBUG
import Foundation
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: each preview vault's recent activity, for the All Nodes cards. Restricted accounts see
/// only the vaults they own (none in the preview), so they get the daemon's refusal.
nonisolated enum AllNodesPreviewData: PreviewFeature {
    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        if command == .storageVaultAccessibleList, transport.scenario == .restricted {
            return Ws.Storage.Vault.Accessible.List.Response(vaults: [])
        }
        guard command == .statsVaultActivity else { return nil }
        guard transport.scenario == .full else { throw .denied("Permission denied: you don't own this vault.") }
        let id = (payload as? Ws.Stats.Vault.Activity.Payload)?.vaultID ?? 0
        return Ws.Stats.Vault.Activity.Response(stats: activity(id))
    }

    private static let samples: [Int64: [(action: String, path: String, minutesAgo: Int64)]] = [
        1: [("upload", "/2026/10/IMG_4182.HEIC", 4), ("upload", "/2026/10/IMG_4181.HEIC", 5), ("rename", "/Albums/Lake", 52)],
        2: [("upload", "/Taxes/2026-estimates.pdf", 18), ("delete", "/Scratch/old-draft.docx", 95)],
        3: [("upload", "/nightly/documents-2026-11-01.tar.zst", 240)],
        4: [("restore", "/projects/aurora/final.mov", 610)],
    ]

    private static func activity(_ id: Int64) -> WsModel.VaultActivity {
        let now = PreviewData.now
        let events = samples[id] ?? []
        let uploads = Int64(events.filter { $0.action == "upload" }.count) * (id == 1 ? 21 : 3)
        return WsModel.VaultActivity(
            vaultID: id, lastActivityAt: events.first.map { now - $0.minutesAgo * 60 },
            lastActivityAction: events.first?.action, uploads24h: uploads, uploads7d: uploads * 6,
            deletes24h: Int64(events.filter { $0.action == "delete" }.count), deletes7d: 4, renames24h: id == 1 ? 1 : 0,
            renames7d: 2, moves24h: 0, moves7d: 1, copies24h: 0, copies7d: 0,
            restores24h: Int64(events.filter { $0.action == "restore" }.count), restores7d: 1,
            bytesAdded24h: uploads * 3_400_000, bytesRemoved24h: 1_200_000, topActiveUsers: [], topTouchedPaths: [],
            recentActivity: events.map {
                .init(source: "fs", action: $0.action, path: $0.path, userName: "cooper", bytes: 3_400_000,
                      occurredAt: now - $0.minutesAgo * 60)
            },
            checkedAt: now)
    }
}
#endif
