import AppKit
import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Both copies of a conflicted file, the way the web console's conflict sheet shows them: images one above the
/// other, text as a line diff, anything else by its details only. Bytes come from the device listener's
/// `GET /download/conflict` lane. The vault's copy loads with the inspector; the bucket's copy is metered (the
/// daemon fetches it from S3), so above 2 MiB it waits for an explicit click and above 32 MiB it isn't offered.
struct ConflictPreview: View {
    var conflict: WsModel.SyncConflict
    var node: Node

    @Environment(AppModel.self) private var model
    @State private var local: SideLoad = .idle
    @State private var remote: SideLoad = .idle
    @State private var remoteAllowed = false

    private var kind: ConflictPreviewKind { ConflictPreviewKind(conflict) }
    private var remoteSize: Int64 { conflict.remote.sizeBytes }
    private var remoteTooLarge: Bool { remoteSize > ConflictPreviewKind.remotePreviewLimit }
    private var textTooLarge: Bool {
        kind == .text && max(conflict.local.sizeBytes, remoteSize) > ConflictPreviewKind.textDiffLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch kind {
            case .none:
                note("There's no side-by-side preview for this file type; compare the details above.")
            case .media:
                note("Audio and video are compared by their details above.")
            case .text where textTooLarge:
                note("One of the copies is larger than \(Format.bytes(ConflictPreviewKind.textDiffLimit)), too large for a line diff.")
            case .text:
                loadButton
                if remoteTooLarge {
                    note("The bucket copy is too large to preview.")
                } else {
                    ConflictTextDiff(local: local, remote: remoteAllowed ? remote : .idle)
                }
            case .image:
                side("Local (vault)", local) { ConflictImage(data: $0) }
                if remoteTooLarge {
                    note("Larger than \(Format.bytes(ConflictPreviewKind.remotePreviewLimit)): too large to preview from the bucket.")
                } else if remoteAllowed {
                    side("Remote (bucket)", remote) { ConflictImage(data: $0) }
                } else {
                    sideTitle("Remote (bucket)")
                    loadButton
                }
            }
        }
        .task(id: conflict.id) { await load() }
        .task(id: remoteAllowed) {
            guard remoteAllowed, case .idle = remote else { return }
            remote = .loading
            remote = await fetch(.remote)
        }
    }

    // MARK: Parts

    @ViewBuilder
    private var loadButton: some View {
        if !remoteAllowed && !remoteTooLarge && kind != .none && !textTooLarge {
            Button("Load the Bucket Copy (\(Format.bytes(remoteSize)))", systemImage: "icloud.and.arrow.down") {
                remoteAllowed = true
            }
            .controlSize(.small)
            .help("Fetches the copy from the bucket; it counts against the vault's S3 request and price budgets.")
        }
    }

    private func side(_ title: String, _ load: SideLoad, @ViewBuilder content: (Data) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sideTitle(title)
            switch load {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .loaded(let data):
                content(data)
            case .failed(let message):
                note(message)
            }
        }
    }

    private func sideTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.fgSubtle)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.fgSubtle)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Loading

    private func load() async {
        local = .idle
        remote = .idle
        // Bucket bytes are metered: small copies load with the inspector, larger ones on a click.
        remoteAllowed = !remoteTooLarge && remoteSize <= ConflictPreviewKind.remoteAutoloadLimit
        guard kind == .image || (kind == .text && !textTooLarge) else { return }
        local = .loading
        local = await fetch(.local)
    }

    private enum Side: String { case local, remote }

    private func fetch(_ side: Side) async -> SideLoad {
        #if DEBUG
        if let canned = SyncConflictsPreviewData.bytes(conflictID: conflict.id, side: side.rawValue, node: node) {
            try? await Task.sleep(for: .milliseconds(150))
            return .loaded(canned)
        }
        #endif
        guard let session = model.sessions?.session(for: node.id),
              let configuration = await session.laneConfiguration(timeout: .seconds(60))
        else {
            return .failed("Previews need a live connection to \(node.displayName).")
        }
        do throws(DeviceHTTPError) {
            let client = try DeviceHTTPClient(configuration: configuration)
            defer { client.invalidate() }
            let url = try client.url(path: "/download/conflict", query: [
                URLQueryItem(name: "conflict_id", value: String(conflict.id)),
                URLQueryItem(name: "side", value: side.rawValue),
            ])
            let (data, response) = try await client.data(for: URLRequest(url: url))
            if (200..<300).contains(response.statusCode) { return .loaded(data) }
            return .failed(Self.message(status: response.statusCode, body: data, side: side))
        } catch {
            return .failed(error.message)
        }
    }

    /// The daemon's refusal in words (web: features/syncConflicts/fetchSide.ts).
    private static func message(status: Int, body: Data, side: Side) -> String {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let reason = (object?["reason"] as? String) ?? (object?["error"] as? String)
        switch status {
        case 403: return "You don't have permission to read this file."
        case 404: return "This file or conflict no longer exists."
        case 409: return "This conflict was already resolved or closed."
        case 413: return "Too large to preview from the bucket (limit \(Format.bytes(ConflictPreviewKind.remotePreviewLimit)))."
        case 503:
            let copy = side == .remote ? "bucket" : "local"
            if let reason, reason != "content_unavailable" { return "The \(copy) copy is unavailable right now: \(reason)" }
            return "The \(copy) copy is unavailable right now."
        default:
            return "Loading failed (HTTP \(status)\(reason.map { ": \($0)" } ?? ""))."
        }
    }
}

enum SideLoad {
    case idle, loading
    case loaded(Data)
    case failed(String)
}

/// An image copy, fitted to the inspector's width.
private struct ConflictImage: View {
    var data: Data

    var body: some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(.line)
                }
        } else {
            Text("This copy isn't an image this Mac can show.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
        }
    }
}

/// A unified line diff of the two copies: lines only in the vault's copy marked L, only in the bucket's marked R.
/// Long unchanged runs fold to their first and last lines.
private struct ConflictTextDiff: View {
    var local: SideLoad
    var remote: SideLoad

    @State private var diff: TextDiff?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch (local, remote) {
            case (.failed(let message), _):
                status("Local copy: \(message)")
            case (.loaded, .failed(let message)):
                status("Bucket copy: \(message)")
            case (.loaded(let a), .loaded(let b)):
                if let diff {
                    if let problem = diff.problem {
                        status(problem)
                    } else {
                        legend(diff)
                        lines(diff)
                    }
                } else {
                    ProgressView().controlSize(.small)
                        .task(id: [a, b]) { diff = await TextDiff.make(a, b) }
                }
            case (.loaded, .idle):
                status("The diff appears once the bucket copy is loaded.")
            default:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.fgSubtle)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func legend(_ diff: TextDiff) -> some View {
        HStack(spacing: 12) {
            Label("\(diff.localOnly) only in local", systemImage: "minus.square")
                .foregroundStyle(StatusTone.danger.color)
            Label("\(diff.remoteOnly) only in remote", systemImage: "plus.square")
                .foregroundStyle(StatusTone.ok.color)
        }
        .font(.caption)
    }

    private func lines(_ diff: TextDiff) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.rows) { row in
                    HStack(spacing: 6) {
                        Text(row.marker)
                            .foregroundStyle(row.tone?.color ?? .fgFaint)
                            .frame(width: 10)
                        Text(row.text.isEmpty ? " " : row.text)
                            .foregroundStyle(row.kind == .fold ? Color.fgFaint : Color.fg)
                            .lineLimit(1)
                            .help(row.text)
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(row.tone?.soft ?? .clear)
                }
            }
            .font(.caption.monospaced())
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 320)
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(.line) }
    }
}

/// The line diff, computed off the main actor.
nonisolated struct TextDiff: Sendable {
    enum Kind: Sendable { case same, local, remote, fold }

    struct Row: Identifiable, Sendable {
        var id: Int
        var kind: Kind
        var text: String

        var marker: String {
            switch kind {
            case .same, .fold: ""
            case .local: "L"
            case .remote: "R"
            }
        }

        var tone: StatusTone? {
            switch kind {
            case .local: .danger
            case .remote: .ok
            case .same, .fold: nil
            }
        }
    }

    var rows: [Row] = []
    var localOnly = 0
    var remoteOnly = 0
    /// Set when there's nothing to diff: binary, identical, or too many changes to show.
    var problem: String?

    static let context = 3
    static let maxRows = 4000

    static func make(_ a: Data, _ b: Data) async -> TextDiff {
        await Task.detached(priority: .userInitiated) { compute(a, b) }.value
    }

    static func compute(_ a: Data, _ b: Data) -> TextDiff {
        var result = TextDiff()
        guard let left = text(a), let right = text(b) else {
            result.problem = "One of the copies isn't UTF-8 text; compare the details above."
            return result
        }
        let old = left.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = right.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        result.localOnly = removed.count
        result.remoteOnly = inserted.count
        if removed.isEmpty && inserted.isEmpty {
            result.problem = "The two copies have the same text; they differ only in their details above."
            return result
        }

        // Walk both sides in step: lines only in the old (local) side, then only in the new (remote) side, else shared.
        var merged: [(Kind, String)] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                merged.append((.local, old[i])); i += 1
            } else if j < new.count, inserted.contains(j) {
                merged.append((.remote, new[j])); j += 1
            } else {
                if i < old.count { merged.append((.same, old[i])) }
                i += 1; j += 1
            }
        }

        // Keep `context` shared lines around each change; fold the rest.
        var keep = [Bool](repeating: false, count: merged.count)
        for (index, line) in merged.enumerated() where line.0 != .same {
            for k in max(0, index - context)...min(merged.count - 1, index + context) { keep[k] = true }
        }
        var index = 0
        while index < merged.count, result.rows.count < maxRows {
            if keep[index] {
                result.rows.append(Row(id: result.rows.count, kind: merged[index].0, text: merged[index].1))
                index += 1
            } else {
                var end = index
                while end < merged.count, !keep[end] { end += 1 }
                let count = end - index
                result.rows.append(Row(id: result.rows.count, kind: .fold,
                                       text: "⋯ \(count) unchanged line\(count == 1 ? "" : "s")"))
                index = end
            }
        }
        if index < merged.count {
            result.rows.append(Row(id: result.rows.count, kind: .fold, text: "⋯ the rest isn't shown"))
        }
        return result
    }

    /// Strict UTF-8 without NUL bytes, or nil (binary or another encoding).
    private static func text(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") else { return nil }
        return text
    }
}
