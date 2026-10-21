import Foundation
import VHContract

/// What the share screens know about links, as the web console words it (features/shares/shareMeta.ts, policy.ts).
/// Nothing here decides access: the daemon authorizes every create, change and use.
nonisolated enum ShareOperation: String, CaseIterable, Hashable, Sendable {
    case metadata, list, preview, download, upload, mkdir, overwrite

    /// Bit i of `allowed_ops` is the i-th operation in this order (the contract's bitmask).
    var bit: Int64 {
        switch self {
        case .metadata: 1 << 0
        case .list: 1 << 1
        case .preview: 1 << 2
        case .download: 1 << 3
        case .upload: 1 << 4
        case .mkdir: 1 << 5
        case .overwrite: 1 << 6
        }
    }

    var label: String {
        switch self {
        case .metadata: "details"
        case .list: "browse"
        case .preview: "preview"
        case .download: "download"
        case .upload: "upload"
        case .mkdir: "create folders"
        case .overwrite: "overwrite"
        }
    }

    static func decode(_ mask: Int64) -> [ShareOperation] {
        allCases.filter { mask & $0.bit != 0 }
    }

    /// "browse, preview, download"; details are implied and not listed.
    static func describe(_ mask: Int64) -> String {
        let list = decode(mask).filter { $0 != .metadata }
        return list.isEmpty ? "nothing" : list.map(\.label).joined(separator: ", ")
    }

    var payloadItem: Ws.Share.Link.Create.Payload.AllowedOps.AllowedOpItem {
        switch self {
        case .metadata: .metadata
        case .list: .list
        case .preview: .preview
        case .download: .download
        case .upload: .upload
        case .mkdir: .mkdir
        case .overwrite: .overwrite
        }
    }
}

/// The three kinds of link the console creates; each pairs a link type with a seeded vault role template.
nonisolated enum SharePreset: String, CaseIterable, Identifiable, Hashable, Sendable {
    case access, download, upload

    var id: Self { self }

    var title: String {
        switch self {
        case .access: "Browse & download"
        case .download: "Download only"
        case .upload: "Upload dropbox"
        }
    }

    var summary: String {
        switch self {
        case .access: "Recipients can open folders, preview and download."
        case .download: "A direct download handoff with no browsing."
        case .upload: "Recipients can drop files in. They can't see what's already there."
        }
    }

    var systemImage: String {
        switch self {
        case .access: "eye"
        case .download: "arrow.down.circle"
        case .upload: "tray.and.arrow.down"
        }
    }

    /// The seeded vault role template the preset applies.
    var roleName: String {
        switch self {
        case .access: "share_browse_download"
        case .download: "share_download_only"
        case .upload: "share_upload_dropbox"
        }
    }

    var linkType: Ws.Share.Link.Create.Payload.LinkType {
        switch self {
        case .access: .access
        case .download: .download
        case .upload: .upload
        }
    }

    var directoriesOnly: Bool { self == .upload }

    func operations(isDirectory: Bool) -> [ShareOperation] {
        switch self {
        case .upload: [.upload]
        case .download: isDirectory ? [.metadata, .list, .download] : [.metadata, .download]
        case .access: isDirectory ? [.metadata, .list, .preview, .download] : [.metadata, .preview, .download]
        }
    }

    /// A link's kind in words, for a link type the daemon sent.
    static func title(linkType: String) -> String {
        SharePreset(rawValue: linkType)?.title ?? Format.words(linkType)
    }
}

nonisolated enum ShareAccess {
    static func title(_ mode: String) -> String {
        switch mode {
        case WsModel.ShareLink.AccessMode.public: "Anyone with the link"
        case WsModel.ShareLink.AccessMode.emailValidated: "Verified email only"
        default: Format.words(mode)
        }
    }
}

/// Where a link stands. The daemon refuses a link that isn't active; the console only labels it.
nonisolated enum ShareState: String, Hashable, Sendable {
    case active, expired, disabled, revoked

    init(_ share: WsModel.ShareLink, now: Date = .now) {
        if share.revokedAt != nil {
            self = .revoked
        } else if share.disabledAt != nil {
            self = .disabled
        } else if let expires = Format.date(iso: share.expiresAt), expires < now {
            self = .expired
        } else {
            self = .active
        }
    }

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    var tone: StatusTone {
        switch self {
        case .active: .ok
        case .expired, .disabled: .warn
        case .revoked: .unknown
        }
    }
}

/// The operator's sharing switches (`settings.policy.get`). Until the policy loads, or when the daemon can't answer,
/// nothing is hidden: the daemon still refuses with a readable message.
nonisolated struct SharingPolicy: Equatable {
    var loaded: Bool
    var enabled: Bool
    /// The access modes a new link can use now, in the order the create sheet offers them.
    var modes: [Ws.Share.Link.Create.Payload.AccessMode]

    init(_ sharing: WsModel.SharingConfig?) {
        guard let sharing else {
            loaded = false
            enabled = true
            modes = [.public, .emailValidated]
            return
        }
        loaded = true
        enabled = sharing.enabled
        modes = []
        if sharing.enabled && sharing.enableAnonymous { modes.append(.public) }
        if sharing.enabled && sharing.enableEmailValidated { modes.append(.emailValidated) }
    }

    /// One line for the list when a kind of link is switched off, or nil when every kind works.
    var notice: String? {
        guard loaded else { return nil }
        if !enabled {
            return "Sharing is turned off on this node. Links can't be created or opened until an administrator turns it back on; existing links are kept."
        }
        if !modes.contains(.public) {
            return "Anyone-with-the-link shares are turned off on this node. Existing ones can't be opened until they are turned back on."
        }
        if !modes.contains(.emailValidated) {
            return "Verified-email shares are turned off on this node. Existing ones can't be opened until they are turned back on."
        }
        return nil
    }
}

/// The full address of a link. The daemon returns only the path (`/share/<token>`), and the web console puts its
/// own origin in front. Desktop knows the console's origin only from `email.base_url` (the address the daemon puts
/// in the links it emails), which `settings.get` reveals to super admins; otherwise the path is all there is.
nonisolated struct IssuedLink: Hashable, Sendable {
    var path: String
    var url: URL?

    init(path: String, origin: String?) {
        self.path = path
        url = Self.url(path: path, origin: origin)
    }

    /// What Copy puts on the pasteboard.
    var text: String { url?.absoluteString ?? path }

    static func url(path: String, origin: String?) -> URL? {
        guard let origin = origin?.trimmingCharacters(in: .whitespaces), !origin.isEmpty,
              let base = URL(string: origin), let scheme = base.scheme, ["http", "https"].contains(scheme),
              base.host() != nil
        else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }
}

/// One row of the share table.
nonisolated struct ShareRow: Identifiable, Hashable {
    var share: WsModel.ShareLink
    var vaultName: String
    var creatorName: String
    var state: ShareState

    var id: String { share.id }

    var title: String {
        for candidate in [share.publicLabel, share.name] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty { return candidate }
        }
        let last = share.rootPath.split(separator: "/").last.map(String.init)
        return last ?? share.rootPath
    }

    var isDirectory: Bool { share.targetType == WsModel.ShareLink.TargetType.directory }
    var kindTitle: String { SharePreset.title(linkType: share.linkType) }
    var accessTitle: String { ShareAccess.title(share.accessMode) }
    var operations: String { ShareOperation.describe(share.allowedOps) }
    var isEmailValidated: Bool { share.accessMode == WsModel.ShareLink.AccessMode.emailValidated }

    var downloads: String {
        if let limit = share.maxDownloads { return "\(share.downloadCount.formatted()) of \(limit.formatted())" }
        return share.downloadCount.formatted()
    }

    var downloadsAtLimit: Bool {
        guard let limit = share.maxDownloads else { return false }
        return share.downloadCount >= limit
    }

    // Sort keys.
    var sortTitle: String { title.lowercased() }
    var sortVault: String { vaultName.lowercased() }
    var sortKind: String { kindTitle }
    var sortState: String { state.rawValue }
    /// No expiry sorts after every date.
    var sortExpires: String { share.expiresAt ?? "~" }
    var sortDownloads: Int64 { share.downloadCount }
    /// Never used sorts first.
    var sortLastAccess: String { share.lastAccessedAt ?? "" }
    var sortCreated: String { share.createdAt }

    var searchText: String {
        [title, share.rootPath, vaultName, creatorName, kindTitle, accessTitle, share.description ?? ""]
            .joined(separator: " ").lowercased()
    }
}
