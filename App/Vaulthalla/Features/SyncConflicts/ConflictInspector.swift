import SwiftUI
import VHContract
import VHCore

/// The selected conflict: why the sides disagree, the two copies' metadata side by side (differences highlighted),
/// a preview of both when the file type allows one, and the two ways to resolve it.
struct ConflictInspector: View {
    var conflict: WsModel.SyncConflict
    var node: Node
    var busy: Bool
    var onResolve: (ConflictResolution.Choice) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                ShareInspectorSection("Compare") {
                    ConflictComparison(conflict: conflict)
                }

                ShareInspectorSection("Preview") {
                    ConflictPreview(conflict: conflict, node: node)
                }

                ShareInspectorSection("Details") {
                    DefinitionList(items: details, monospacedValues: ["File ID", "Conflict ID"], termWidth: 110)
                }
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(StatusTone.warn.color)
                    .frame(width: 34, height: 34)
                    .background(StatusTone.warn.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(conflict.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                        .lineLimit(2)
                    Text(conflict.place)
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            if !conflict.reasons.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(conflict.reasons, id: \.code) { reason in
                        StatusBadge(label: reason.message.isEmpty ? Format.words(reason.code) : reason.message, tone: .warn)
                            .help(reason.code)
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach([ConflictResolution.Choice.keepLocal, .keepRemote], id: \.self) { choice in
                    Button(ConflictResolution.label(choice)) { onResolve(choice) }
                        .help(ConflictResolution.effect(choice))
                }
                if busy { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            .disabled(!conflict.canOverwrite || busy)
            if !conflict.canOverwrite {
                Label(ConflictResolution.noOverwrite, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }
        }
    }

    private var details: [(term: String, value: String)] {
        [
            ("Detected", Format.moment(iso: conflict.createdAt) ?? "Unknown"),
            ("Last seen", Format.moment(iso: conflict.updatedAt) ?? "Unknown"),
            ("Kind", Format.words(conflict.type)),
            ("File ID", String(conflict.fileID)),
            ("Conflict ID", String(conflict.id)),
        ]
    }
}

/// The two copies' metadata in a grid; a value that differs between them is highlighted.
private struct ConflictComparison: View {
    var conflict: WsModel.SyncConflict

    private struct Line {
        var label: String
        var value: (WsModel.SyncConflictSide) -> String?
        var full: (WsModel.SyncConflictSide) -> String? = { _ in nil }
        var mono = false
    }

    private static let lines: [Line] = [
        Line(label: "Size", value: { Format.bytes($0.sizeBytes) }, full: { "\($0.sizeBytes.formatted()) bytes" }),
        Line(label: "Modified", value: { Format.moment(iso: $0.modifiedAt) }),
        Line(label: "Hash", value: { short($0.contentHash) }, full: { $0.contentHash }, mono: true),
        Line(label: "Type", value: { $0.mimeType }),
        Line(label: "ETag", value: { short($0.etag) }, full: { $0.etag }, mono: true),
        Line(label: "Encrypted", value: { $0.encrypted.map { $0 ? "Yes" : "No" } }),
    ]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                Text("")
                Text("Local (vault)")
                Text("Remote (bucket)")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.fgSubtle)
            Divider()
            ForEach(Self.lines, id: \.label) { line in
                let local = line.value(conflict.local)
                let remote = line.value(conflict.remote)
                let localFull = line.full(conflict.local) ?? local
                let remoteFull = line.full(conflict.remote) ?? remote
                let differs = local != nil && remote != nil && localFull != remoteFull
                GridRow {
                    Text(line.label)
                        .foregroundStyle(.fgSubtle)
                    cell(local, full: line.full(conflict.local), mono: line.mono, differs: differs)
                    cell(remote, full: line.full(conflict.remote), mono: line.mono, differs: differs)
                }
            }
        }
        .font(.callout)
    }

    private func cell(_ value: String?, full: String?, mono: Bool, differs: Bool) -> some View {
        Text(value ?? "—")
            .font(mono ? .caption.monospaced() : .callout)
            .foregroundStyle(value == nil ? Color.fgFaint : differs ? StatusTone.warn.color : Color.fg)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(full ?? value ?? "Not known")
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func short(_ hash: String?) -> String? {
        guard let hash, !hash.isEmpty else { return nil }
        return hash.count > 16 ? "\(hash.prefix(12))…" : hash
    }
}
