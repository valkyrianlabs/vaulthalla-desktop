import SwiftUI
import VHContract

/// The selected link: what it shares and how, its limits and filters, how it has been used, and its history.
/// The contract has no per-link access log, so usage is the link's own counters and last access.
struct ShareInspector: View {
    var row: ShareRow
    /// The address issued for it while the screen was open; nil once the token can't be shown again.
    var link: IssuedLink?
    var updaterName: (Int64) -> String
    var onCopy: () -> Void
    var onEdit: () -> Void
    var onRotate: () -> Void
    var onRevoke: () -> Void

    private static let termWidth: CGFloat = 118

    var body: some View {
        let share = row.share
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                ShareInspectorSection("Shares") {
                    DefinitionList(items: [
                        ("Vault", row.vaultName),
                        ("Path", share.rootPath),
                        ("Target", row.isDirectory ? "Folder" : "File"),
                    ], monospacedValues: ["Path"], termWidth: Self.termWidth)
                }

                ShareInspectorSection("Access") {
                    DefinitionList(items: access, termWidth: Self.termWidth)
                }

                ShareInspectorSection("Limits") {
                    DefinitionList(items: limits, termWidth: Self.termWidth)
                }

                if !filters.isEmpty {
                    ShareInspectorSection("File filters") {
                        DefinitionList(items: filters, termWidth: Self.termWidth)
                    }
                }

                ShareInspectorSection("Activity") {
                    DefinitionList(items: [
                        ("Opens", share.accessCount.formatted()),
                        ("Downloads", share.downloadCount.formatted()),
                        ("Uploads", share.uploadCount.formatted()),
                        ("Last access", Format.moment(iso: share.lastAccessedAt) ?? "Never"),
                    ], termWidth: Self.termWidth)
                }

                ShareInspectorSection("History") {
                    DefinitionList(items: history, monospacedValues: ["ID"], termWidth: Self.termWidth)
                }
            }
            .padding(16)
        }
    }

    // MARK: Parts

    private var header: some View {
        let share = row.share
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ShareGlyph(isDirectory: row.isDirectory, state: row.state, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                        .lineLimit(2)
                    StatusBadge(label: row.state.label, tone: row.state.tone)
                }
            }
            if let description = share.description, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link {
                IssuedLinkField(link: link)
            }
            HStack(spacing: 8) {
                Button("Copy Link", systemImage: "doc.on.doc", action: onCopy)
                    .disabled(link == nil)
                    .help(link == nil
                          ? "The full link is only shown when it's created or rotated. Rotate it to get a new one."
                          : "Copy the link")
                if row.state != .revoked {
                    Button("Edit…", action: onEdit)
                    Button("Rotate…", action: onRotate)
                    Button("Revoke…", role: .destructive, action: onRevoke)
                }
            }
            .controlSize(.small)
            if row.state == .revoked {
                Text("A revoked link can't be changed or opened again.")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }
        }
    }

    private var access: [(term: String, value: String)] {
        let share = row.share
        var items: [(term: String, value: String)] = [
            ("Kind", row.kindTitle),
            ("Who", row.accessTitle),
            ("Allows", row.operations.capitalizedFirst),
        ]
        if ShareOperation.decode(share.allowedOps).contains(.upload) {
            items.append(("Duplicates", Self.duplicatePolicy(share.duplicatePolicy)))
        }
        return items
    }

    private var limits: [(term: String, value: String)] {
        let share = row.share
        var items: [(term: String, value: String)] = [
            ("Expires", share.expiresAt.map { Format.moment(iso: $0) ?? $0 } ?? "Never"),
            ("Downloads", share.maxDownloads.map { "\(share.downloadCount.formatted()) of \($0.formatted())" }
                ?? "No limit"),
        ]
        if let files = share.maxUploadFiles { items.append(("Upload files", files.formatted())) }
        if let size = share.maxUploadSizeBytes { items.append(("Per file", Format.bytes(size))) }
        if let total = share.maxUploadTotalBytes { items.append(("Upload total", Format.bytes(total))) }
        return items
    }

    private var filters: [(term: String, value: String)] {
        let share = row.share
        var items: [(term: String, value: String)] = []
        if !share.allowedMimeTypes.isEmpty { items.append(("Allowed types", share.allowedMimeTypes.joined(separator: ", "))) }
        if !share.blockedMimeTypes.isEmpty { items.append(("Blocked types", share.blockedMimeTypes.joined(separator: ", "))) }
        if !share.allowedExtensions.isEmpty { items.append(("Allowed ext.", share.allowedExtensions.joined(separator: ", "))) }
        if !share.blockedExtensions.isEmpty { items.append(("Blocked ext.", share.blockedExtensions.joined(separator: ", "))) }
        return items
    }

    private var history: [(term: String, value: String)] {
        let share = row.share
        var items: [(term: String, value: String)] = [
            ("Created", "\(Format.moment(iso: share.createdAt) ?? share.createdAt) by \(row.creatorName)"),
        ]
        if share.updatedAt != share.createdAt {
            let by = share.updatedBy.map { " by \(updaterName($0))" } ?? ""
            items.append(("Updated", "\(Format.moment(iso: share.updatedAt) ?? share.updatedAt)\(by)"))
        }
        if let disabled = share.disabledAt {
            items.append(("Disabled", Format.moment(iso: disabled) ?? disabled))
        }
        if let revoked = share.revokedAt {
            let by = share.revokedBy.map { " by \(updaterName($0))" } ?? ""
            items.append(("Revoked", "\(Format.moment(iso: revoked) ?? revoked)\(by)"))
        }
        items.append(("ID", share.id))
        return items
    }

    private static func duplicatePolicy(_ policy: String) -> String {
        switch policy {
        case WsModel.ShareLink.DuplicatePolicy.reject: "Refuse a file that exists"
        case WsModel.ShareLink.DuplicatePolicy.rename: "Rename the new file"
        case WsModel.ShareLink.DuplicatePolicy.overwrite: "Overwrite"
        default: Format.words(policy)
        }
    }
}

/// The issued address as a compact copyable field.
private struct IssuedLinkField: View {
    var link: IssuedLink

    var body: some View {
        Text(link.text)
            .font(.caption.monospaced())
            .foregroundStyle(.accentText)
            .lineLimit(2)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.accentSoft, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(.accentLine)
            }
    }
}

/// A titled group in the inspector.
struct ShareInspectorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.fgSubtle)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
