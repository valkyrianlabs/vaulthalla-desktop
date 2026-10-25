#if DEBUG
import Foundation
import Synchronization
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: share links for `#Preview`s and `DebugSnapshot`. "Home lab (preview)" has links in its
/// preview vaults; "Studio (preview)" has none and may not manage any vault's shares. Labels say "(preview)".
///
/// It also answers, when no other feature does, the reads the share screens lean on: the sharing policy, vault role
/// templates, users and directory listings.
nonisolated enum SharesPreviewData: PreviewFeature {
    private static let links = Mutex(SharesPreviewData.seed)
    private static let tokens = Mutex(0)

    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any?
    {
        let full = transport.scenario == .full
        switch command {
        case .shareLinkList:
            let vaultID = (payload as? Ws.Share.Link.List.Payload)?.vaultID?.wrapped
            guard full else {
                if vaultID != nil { throw .denied("Permission denied: this account may not manage this vault's shares.") }
                return Ws.Share.Link.List.Response(shares: [])
            }
            let all = links.withLock { $0 }
            return Ws.Share.Link.List.Response(
                shares: vaultID.map { id in all.filter { $0.vaultID == id } } ?? all.filter { $0.createdBy == 11 })
        case .shareLinkGet:
            guard let id = (payload as? Ws.Share.Link.Get.Payload)?.id else { throw .invalid("Bad payload.") }
            return Ws.Share.Link.Get.Response(share: try find(id))
        case .shareLinkCreate:
            guard full else { throw .denied("Permission denied: this account may not share in this vault.") }
            guard let create = payload as? Ws.Share.Link.Create.Payload else { throw .invalid("Bad payload.") }
            let mask: Int64 = switch create.allowedOps {
            case .integer(let value): value
            case .array(let items): items.reduce(0) { $0 | (ShareOperation(rawValue: $1.rawValue)?.bit ?? 0) }
            }
            let expires: String? = switch create.expiresAt?.wrapped {
            case .string(let text): text
            case .integer(let seconds): Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(.iso8601)
            case nil: nil
            }
            let id = "preview-\(UUID().uuidString.prefix(8).lowercased())"
            let share = link(id, vault: create.vaultID, path: create.rootPath, label: create.publicLabel?.wrapped ?? "Shared",
                             directory: create.targetType == .directory, type: create.linkType.rawValue,
                             access: create.accessMode.rawValue, ops: mask, created: 0,
                             expires: expires, maxDownloads: create.maxDownloads?.wrapped)
            links.withLock { $0.insert(share, at: 0) }
            return Ws.Share.Link.Create.Response(share: share, publicToken: token(), publicURLPath: "/share/\(token())")
        case .shareLinkUpdate:
            guard let update = payload as? Ws.Share.Link.Update.Payload else { throw .invalid("Bad payload.") }
            var share = try find(update.id)
            if let name = update.name { share.name = name.wrapped }
            if let label = update.publicLabel { share.publicLabel = label.wrapped }
            if let description = update.description { share.description = description.wrapped }
            if let expires = update.expiresAt {
                share.expiresAt = switch expires.wrapped {
                case .string(let text): text
                case .integer(let seconds): Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(.iso8601)
                case nil: nil
                }
            }
            if let limit = update.maxDownloads { share.maxDownloads = limit.wrapped }
            if let access = update.accessMode?.wrapped { share.accessMode = access.rawValue }
            share.updatedAt = Date.now.formatted(.iso8601)
            share.updatedBy = 11
            store(share)
            return Ws.Share.Link.Update.Response(share: share)
        case .shareLinkRotateToken:
            guard let id = (payload as? Ws.Share.Link.RotateToken.Payload)?.id else { throw .invalid("Bad payload.") }
            let share = try find(id)
            let token = token()
            return Ws.Share.Link.RotateToken.Response(share: share, publicToken: token, publicURLPath: "/share/\(token)")
        case .shareLinkRevoke:
            guard let id = (payload as? Ws.Share.Link.Revoke.Payload)?.id else { throw .invalid("Bad payload.") }
            var share = try find(id)
            share.revokedAt = Date.now.formatted(.iso8601)
            share.revokedBy = 11
            store(share)
            return Ws.Share.Link.Revoke.Response(revoked: true)

        // Fallbacks for reads other features may answer first.
        case .settingsPolicyGet:
            return Ws.Settings.Policy.Get.Response(policy: .init(
                sharing: WsModel.SharingConfig(enabled: true, enableAnonymous: true, enableEmailValidated: full),
                vaults: WsModel.VaultsConfig(
                    retentionWindow: "30d", tpmRetentionWindow: "90d",
                    s3: WsModel.VaultsS3Config(defaultRemoteSyncStrategy: "sync", defaultRemoteConflictPolicy: "ask",
                                               tpmRetentionWindow: "90d"))))
        case .rolesVaultList:
            return Ws.Roles.Vault.List.Response(roles: [
                role(21, "share_browse_download"), role(22, "share_download_only"), role(23, "share_upload_dropbox"),
                role(24, "implicit_deny"),
            ])
        case .authUsersList:
            guard full else { throw .denied("Permission denied: this account may not list users.") }
            return Ws.Auth.Users.List.Response(users: [user(11, "cooper"), user(13, "admin"), user(14, "studio")])
        case .fsDirList:
            guard let list = payload as? Ws.Fs.Dir.List.Payload else { throw .invalid("Bad payload.") }
            return try listing(list.vaultID, path: list.path ?? "/", transport: transport)
        default:
            return nil
        }
    }

    // MARK: Links

    private static let now = Date.now

    private static func iso(_ offset: TimeInterval) -> String {
        now.addingTimeInterval(offset).formatted(.iso8601)
    }

    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86_400

    private static let seed: [WsModel.ShareLink] = [
        link("preview-a1", vault: 1, path: "/Albums/2026 Summer", label: "Summer album (preview)", directory: true,
             type: "access", access: "public", ops: 15, created: -12 * day, expires: iso(10 * day),
             lastAccess: iso(-2 * hour), opens: 41, downloads: 12),
        link("preview-b2", vault: 2, path: "/Taxes/2025 return.pdf", label: "2025 tax return (preview)",
             directory: false, type: "download", access: "email_validated", ops: 9, created: -6 * day,
             expires: iso(3 * day), maxDownloads: 5, lastAccess: iso(-1 * day), opens: 7, downloads: 5),
        link("preview-c3", vault: 4, path: "/Incoming/Client uploads", label: "Client uploads (preview)",
             directory: true, type: "upload", access: "public", ops: 16, created: -30 * day,
             lastAccess: iso(-20 * 60), opens: 18, uploads: 23, maxUploadSize: 2_000_000_000,
             allowedExtensions: ["mov", "mp4", "wav"], description: "Drop finished renders here."),
        link("preview-d4", vault: 2, path: "/Invoices/2026-03.pdf", label: "March invoice (preview)", directory: false,
             type: "download", access: "public", ops: 9, created: -60 * day, lastAccess: iso(-45 * day), opens: 3,
             downloads: 2, revoked: iso(-40 * day)),
        link("preview-e5", vault: 1, path: "/Albums/Wedding", label: "Wedding photos (preview)", directory: true,
             type: "access", access: "public", ops: 15, created: -90 * day, expires: iso(-20 * day),
             lastAccess: iso(-21 * day), opens: 112, downloads: 64),
        link("preview-f6", vault: 4, path: "/Projects/Spring promo", label: "Spring promo review (preview)",
             directory: true, type: "access", access: "public", ops: 7, creator: 14, created: -4 * day, opens: 0),
    ]

    private static func link(
        _ id: String, vault: Int64, path: String, label: String, directory: Bool, type: String, access: String,
        ops: Int64, creator: Int64 = 11, created: TimeInterval, expires: String? = nil, maxDownloads: Int64? = nil,
        lastAccess: String? = nil, opens: Int64 = 0, downloads: Int64 = 0, uploads: Int64 = 0,
        maxUploadSize: Int64? = nil, allowedExtensions: [String] = [], description: String? = nil,
        revoked: String? = nil
    ) -> WsModel.ShareLink {
        WsModel.ShareLink(
            id: id, vaultID: vault, rootEntryID: Int64(abs(path.hashValue % 10_000)), rootPath: path,
            targetType: directory ? "directory" : "file", linkType: type, accessMode: access, allowedOps: ops,
            name: label, publicLabel: label, description: description, createdBy: creator,
            revokedBy: revoked == nil ? nil : creator, createdAt: iso(created), updatedAt: iso(created),
            expiresAt: expires, revokedAt: revoked, lastAccessedAt: lastAccess, accessCount: opens,
            downloadCount: downloads, uploadCount: uploads, maxDownloads: maxDownloads,
            maxUploadSizeBytes: maxUploadSize, duplicatePolicy: "reject", allowedMimeTypes: [], blockedMimeTypes: [],
            allowedExtensions: allowedExtensions, blockedExtensions: [], metadata: [:])
    }

    private static func find(_ id: String) throws(WsError) -> WsModel.ShareLink {
        guard let share = links.withLock({ $0.first { $0.id == id } }) else { throw .notFound("No such share link.") }
        return share
    }

    private static func store(_ share: WsModel.ShareLink) {
        links.withLock { list in list = list.map { $0.id == share.id ? share : $0 } }
    }

    private static func token() -> String {
        let n = tokens.withLock { value in
            value += 1
            return value
        }
        return "preview-token-\(n)-not-a-real-link"
    }

    // MARK: Fallback reads

    private static func role(_ id: Int64, _ name: String) -> WsModel.VaultRole {
        WsModel.VaultRole(id: id, name: name, description: "", createdAt: 0, updatedAt: 0, permissions: [])
    }

    private static func user(_ id: Int64, _ name: String) -> WsModel.UserSummary {
        WsModel.UserSummary(id: id, name: name, isProtected: false, systemOnly: false, isActive: true,
                            createdAt: iso(-200 * day), updatedAt: iso(-200 * day), vaultRoles: [])
    }

    private static func listing(_ vaultID: Int64, path: String, transport: PreviewTransport)
        throws(WsError) -> Ws.Fs.Dir.List.Response
    {
        guard let vault = transport.vaults.withLock({ $0.first { $0.id == vaultID } }) else {
            throw .notFound("No such vault.")
        }
        let tree: [String: [(String, Bool, Int64)]] = [
            "/": [("Albums", true, 0), ("Incoming", true, 0), ("Projects", true, 0), ("Taxes", true, 0),
                  ("README.md", false, 2_400), ("budget-2026.numbers", false, 380_000)],
            "/Albums": [("2026 Summer", true, 0), ("Wedding", true, 0), ("cover.jpg", false, 4_100_000)],
            "/Projects": [("Spring promo", true, 0), ("brief.pdf", false, 820_000)],
        ]
        let base = WsModel.FsEntryBase(
            id: 1000 + vaultID, name: path == "/" ? vault.name : String(path.split(separator: "/").last ?? ""),
            path: path, absPath: "/mnt/vaulthalla/\(vault.slug)\(path)", sizeBytes: 0, isHidden: false,
            isSystem: false, createdAt: iso(-100 * day), updatedAt: iso(-day), metadataVersion: "m\(1000 + vaultID)-0")
        let files = (tree[path] ?? []).enumerated().map { index, item in
            let child = path == "/" ? "/\(item.0)" : "\(path)/\(item.0)"
            return WsModel.FsEntry(
                id: 2000 + vaultID * 100 + Int64(index) + Int64(path.count * 10), name: item.0, path: child,
                absPath: "/mnt/vaulthalla/\(vault.slug)\(child)", sizeBytes: item.2, isHidden: false, isSystem: false,
                createdAt: iso(-50 * day), updatedAt: iso(-2 * day), metadataVersion: "m\(index)-0",
                contentVersion: item.1 ? nil : "\"g\(index)-0\"",
                type: item.1 ? WsModel.FsEntry.TypeValue.directory : WsModel.FsEntry.TypeValue.file)
        }
        return Ws.Fs.Dir.List.Response(vault: vault.name, path: path, entry: base, files: files)
    }
}
#endif
