import AppKit
import SwiftUI
import VHContract
import VHCore
import VHNodes

/// The selected vault: what it is, its usage, sync policy (S3), recovery mode and key, each from its own read so
/// one denial doesn't hide the rest.
struct VaultInspector: View {
    var row: VaultRow
    var node: Node
    var queries: NodeQueries
    var onEdit: () -> Void
    var onDelete: () -> Void

    private static let termWidth: CGFloat = 128

    var body: some View {
        let vault = row.vault
        let detail = queries.query(Ws.Storage.Vault.Get.self, .init(id: vault.id))
        let stats = queries.query(Ws.Stats.Vault.self, .init(vaultID: vault.id))
        let recovery = queries.query(Ws.Vault.Recovery.Status.self, .init(vaultID: vault.id))
        let plan = queries.query(Ws.Storage.Vault.Remove.Plan.self, .init(id: vault.id))

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(vault)

                InspectorSection("Details") {
                    DefinitionList(items: details(detail.value?.vault ?? vault), monospacedValues: ["Slug", "Bucket", "Mount"],
                                   termWidth: Self.termWidth)
                }

                InspectorSection("Usage") {
                    InlineQuery(query: stats, subject: "this vault's usage") { response in
                        usage(response.stats, quota: vault.quota)
                    }
                }

                if row.isS3 {
                    InspectorSection("Sync") {
                        InlineQuery(query: detail, subject: "this vault") { response in
                            sync(response.vault.sync, latest: stats.value?.stats.latestSyncEvent)
                        }
                    }
                }

                InspectorSection("Recovery") {
                    InlineQuery(query: recovery, subject: "this vault's recovery settings") { response in
                        recoverySummary(response.status)
                    }
                }

                InspectorSection("Encryption key") {
                    InlineQuery(query: plan, subject: "this vault's key status") { response in
                        key(response.plan)
                    }
                }
            }
            .padding(16)
        }
        .observing(detail)
        .observing(stats, polling: .seconds(30))
        .observing(recovery)
        .observing(plan)
    }

    // MARK: Parts

    private func header(_ vault: WsModel.Vault) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VaultGlyph(isS3: row.isS3, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vault.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        StatusDot(tone: row.statusTone, size: 6)
                        Text("\(row.storageLabel) · \(row.statusText)")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }
            }
            if !vault.description.isEmpty {
                Text(vault.description)
                    .font(.callout)
                    .foregroundStyle(.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Edit…", action: onEdit)
                Button("Delete…", role: .destructive, action: onDelete)
            }
            .controlSize(.small)
        }
    }

    private func details(_ vault: WsModel.Vault) -> [(term: String, value: String)] {
        var items: [(term: String, value: String)] = [
            ("Owner", row.ownerName),
            ("Slug", vault.slug),
            ("Mount", vault.effectiveFuseName),
            ("FUSE writes", vault.allowFsWrite ? "Allowed" : "Read-only"),
        ]
        if row.isS3 {
            items.append(("Bucket", vault.bucket ?? "not available"))
            items.append(("Encrypted upstream", vault.encryptUpstream.map { $0 ? "Yes" : "No" } ?? "not available"))
        }
        items.append(("Quota", vault.quota > 0 ? Format.bytes(vault.quota) : "Unlimited"))
        items.append(("Created", Format.moment(iso: vault.createdAt) ?? vault.createdAt))
        items.append(("ID", String(vault.id)))
        return items
    }

    private func usage(_ stat: WsModel.VaultStat, quota: Int64) -> some View {
        let capacity = stat.capacity
        return VStack(alignment: .leading, spacing: 10) {
            if quota > 0 {
                UsageCell(used: capacity.logicalSize, quota: quota)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                StatTile(label: "Size", value: Format.bytes(capacity.logicalSize))
                StatTile(label: "On disk", value: Format.bytes(capacity.physicalSize))
                StatTile(label: "Files", value: capacity.fileCount.formatted())
                StatTile(label: "Folders", value: capacity.directoryCount.formatted())
            }
        }
    }

    @ViewBuilder
    private func sync(_ policy: WsModel.RemoteSyncPolicy?, latest: WsModel.SyncEvent?) -> some View {
        if let policy {
            VStack(alignment: .leading, spacing: 10) {
                DefinitionList(items: [
                    ("Strategy", Format.words(policy.strategy)),
                    ("Conflicts", Format.words(policy.conflictPolicy)),
                    ("Every", policy.interval),
                    ("Enabled", policy.enabled ? "Yes" : "No"),
                    ("Last success", Format.moment(iso: policy.lastSuccessAt) ?? "Never"),
                ], termWidth: Self.termWidth)
                if let latest {
                    HStack(spacing: 6) {
                        StatusDot(tone: StatusTone(severity: latest.status), size: 6)
                        Text("Latest run: \(Format.words(latest.status))")
                        if latest.timestampEnd > 0 {
                            Text("· \(Format.relative(epoch: latest.timestampEnd))")
                                .foregroundStyle(.fgSubtle)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.fgMuted)
                }
            }
        } else {
            Text("The node sent no sync policy for this vault.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
        }
    }

    private func recoverySummary(_ status: WsModel.RecoveryStatus) -> some View {
        var items: [(term: String, value: String)] = [("Mode", Self.recoveryMode(status.mode))]
        let local = status.localVersioning
        items.append(("Local versions", local.enabled
            ? (local.keepLast.map { "Keep last \($0)" } ?? "On") : "Off"))
        if status.mode == WsModel.RecoveryStatus.Mode.providerVersioning {
            items.append(("Provider", Format.words(status.provider.status)))
        }
        items.append(("Snapshots", status.snapshots.count == 0 ? "None"
            : "\(status.snapshots.count) · \(Format.bytes(status.snapshots.storedBytes))"))
        if status.backlog.pendingVersions > 0 || status.backlog.failing > 0 {
            items.append(("Backlog", "\(status.backlog.pendingVersions) pending, \(status.backlog.failing) failing"))
        }
        if !status.retainedKeyVersions.isEmpty {
            items.append(("Keys kept", status.retainedKeyVersions.map { "v\($0)" }.joined(separator: ", ")))
        }
        return VStack(alignment: .leading, spacing: 8) {
            DefinitionList(items: items, termWidth: Self.termWidth)
            ForEach(status.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(StatusTone.warn.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static func recoveryMode(_ mode: String) -> String {
        switch mode {
        case WsModel.RecoveryStatus.Mode.off: "Off"
        case WsModel.RecoveryStatus.Mode.localSnapshots: "Local snapshots"
        case WsModel.RecoveryStatus.Mode.providerVersioning: "Provider versioning"
        default: Format.words(mode)
        }
    }

    private func key(_ plan: WsModel.VaultRemovalPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DefinitionList(items: [
                ("Version", "v\(plan.keyVersion)"),
                ("Exported", plan.keyExported ? (Format.moment(iso: plan.keyExportedAt) ?? "Yes") : "Never"),
            ], termWidth: Self.termWidth)
            if !plan.keyExported {
                Text("Export it from a terminal on the node; Desktop never moves keys through the browser:")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
                CommandSnippet(command: plan.exportCommand)
            }
        }
    }
}

/// A titled group in the inspector.
private struct InspectorSection<Content: View>: View {
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

/// A read inside a larger view: a small spinner, its value, or a one-line reason.
struct InlineQuery<R: WsRequest, Content: View>: View {
    var query: NodeQuery<R>
    var subject: String
    @ViewBuilder var content: (R.Response) -> Content

    var body: some View {
        switch query.state {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
        case .loaded(let value, _):
            content(value)
        case .failed(let error):
            InlineProblem(error: error, subject: subject)
        }
    }
}

/// A shell command to copy, such as the key export.
struct CommandSnippet: View {
    var command: String

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.caption.monospaced())
                .foregroundStyle(.fgMuted)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Copy the command")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.surface2, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
    }
}
