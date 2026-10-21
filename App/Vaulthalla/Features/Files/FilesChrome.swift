import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VHNodes

/// The folder's location, Finder's path bar style: the vault, then each folder; click one to go there, drop Finder
/// files on one to upload into it.
struct PathBar: View {
    var vaultName: String
    var path: VaultPath
    var onSelect: (VaultPath) -> Void
    var onDrop: ([URL], VaultPath) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(path.ancestry.enumerated()), id: \.element) { index, folder in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right")
                            .font(.caption)
                            .foregroundStyle(.fgFaint)
                    }
                    Segment(title: folder.isRoot ? vaultName : folder.name, isRoot: folder.isRoot,
                            isCurrent: folder == path) { onSelect(folder) } onDrop: { urls in onDrop(urls, folder) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    private struct Segment: View {
        var title: String
        var isRoot: Bool
        var isCurrent: Bool
        var action: () -> Void
        var onDrop: ([URL]) -> Void
        @State private var targeted = false

        var body: some View {
            Button(action: action) {
                Label(title, systemImage: isRoot ? "externaldrive" : "folder")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.fg : Color.fgMuted)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(targeted ? Color.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                onDrop(files)
                return true
            } isTargeted: { targeted = $0 }
            .help(isCurrent ? title : "Go to \(title)")
        }
    }
}

/// "1,204 items, 3 selected" under the browser.
struct StatusBar: View {
    var shown: Int
    var total: Int
    var selected: Int
    var filtered: Bool

    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.caption)
                .foregroundStyle(.fgSubtle)
                .monospacedDigit()
            Spacer()
        }
        .padding(.vertical, 5)
        .background(.surface1)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    private var text: String {
        let count = filtered ? "\(shown.formatted()) of \(total.formatted()) items" :
            "\(shown.formatted()) item\(shown == 1 ? "" : "s")"
        return selected > 0 ? "\(selected.formatted()) of \(count) selected" : count
    }
}

// MARK: - Transfers

/// The toolbar's Transfers button: progress while anything runs, a badge for failures, the panel on click.
struct TransfersButton: View {
    @Bindable var transfers: TransferCenter

    var body: some View {
        Button {
            transfers.isPanelShown.toggle()
        } label: {
            Label {
                Text("Transfers")
            } icon: {
                ZStack {
                    if let fraction = transfers.overallFraction {
                        Circle().stroke(Color.surface3, lineWidth: 2.5)
                        Circle().trim(from: 0, to: fraction)
                            .stroke(Color.accentFill, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 8, weight: .bold))
                    } else {
                        Image(systemName: transfers.failedCount > 0 ? "exclamationmark.arrow.triangle.2.circlepath"
                                : "arrow.up.arrow.down.circle")
                    }
                }
                .frame(width: 18, height: 18)
            }
        }
        .badge(transfers.activeCount)
        .help(transfers.activeCount > 0 ? "\(transfers.activeCount) transfers in progress" : "Transfers")
        .popover(isPresented: $transfers.isPanelShown, arrowEdge: .bottom) {
            TransfersPanel(transfers: transfers)
        }
    }
}

/// Downloads and uploads of this node, newest first, with progress, cancel, retry and Show in Finder.
struct TransfersPanel: View {
    var transfers: TransferCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.headline)
                Spacer()
                if transfers.items.contains(where: { !$0.status.isActive }) {
                    Button("Clear") { transfers.clearFinished() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if transfers.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No transfers")
                        .font(.callout)
                    Text("Downloads and uploads show here. Drag files between Finder and the browser to start one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(transfers.items) { item in
                            TransferRow(item: item, transfers: transfers)
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 380)
    }
}

private struct TransferRow: View {
    var item: TransferCenter.Item
    var transfers: TransferCenter

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.status == .running || item.status == .queued {
                    if let fraction = item.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(.accentFill)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(isFailure ? StatusTone.danger.color : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var actions: some View {
        switch item.status {
        case .queued, .running:
            Button("Cancel", systemImage: "xmark.circle.fill") { transfers.cancel(item.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel")
        case .failed, .cancelled:
            Button("Retry", systemImage: "arrow.clockwise.circle") { transfers.retry(item.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Try again")
        case .done:
            if item.kind == .download {
                Button("Show in Finder", systemImage: "magnifyingglass.circle") { transfers.showInFinder(item.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = item.status { return true }
        return false
    }

    private var tint: Color {
        switch item.status {
        case .failed: StatusTone.danger.color
        case .cancelled: .secondary
        case .done: StatusTone.ok.color
        default: .accentFill
        }
    }

    private var statusLine: String {
        let bytes: String = {
            guard let total = item.bytesTotal, total > 0 else { return Format.bytes(item.bytesDone) }
            return "\(Format.bytes(item.bytesDone)) of \(Format.bytes(total))"
        }()
        let files = item.filesTotal > 1 ? " · \(item.filesDone) of \(item.filesTotal) files" : ""
        switch item.status {
        case .queued: return "Waiting · \(item.detail)"
        case .running: return "\(bytes)\(files) · \(item.detail)"
        case .done:
            let size = item.bytesTotal.map(Format.bytes) ?? ""
            return item.kind == .download ? "Downloaded \(size) \(item.detail)" : "Uploaded \(size) \(item.detail)"
        case .cancelled: return "Cancelled · \(item.detail)"
        case .failed(let message): return message
        }
    }
}

// MARK: - Sheets

/// Opens a vault the list doesn't show (an account may reach a vault through a role without managing it).
struct OpenVaultSheet: View {
    var open: (Int64) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    private var id: Int64? { Int64(text.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Vault by ID")
                .font(.title3.weight(.semibold))
            Text("Some accounts reach vaults through a role without seeing them in the vault list. Enter the vault's number from the web console or `vh vault list`.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Vault ID", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(id == nil)
            }
        }
        .padding(22)
        .frame(width: 400)
    }

    private func submit() {
        guard let id else { return }
        open(id)
        dismiss()
    }
}

/// Rename from the icon grid (the list renames in place).
struct RenameSheet: View {
    var item: FileItem
    var commit: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(item: FileItem, commit: @escaping (String) -> Void) {
        self.item = item
        self.commit = commit
        _name = State(initialValue: item.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename “\(item.name)”")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let problem = VaultPath.problem(withName: name), name != item.name {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(StatusTone.danger.color)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name == item.name || VaultPath.problem(withName: name) != nil)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func submit() {
        guard name != item.name, VaultPath.problem(withName: name) == nil else { return }
        commit(name)
        dismiss()
    }
}
