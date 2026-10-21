import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// A file's or folder's recovery history (`recovery.list` for its path): snapshots, local versions and provider
/// versions this account may read. Restoring one plans first (`recovery.plan`: what would be created, overwritten or
/// removed), then runs that plan with its token (`recovery.restore`); overwrites and removals need RESTORE typed, as on
/// the web (web/src/features/recovery/RestorePreviewDialog.tsx).
struct RecoveryHistorySheet: View {
    var item: FileItem
    var vaultID: Int64
    var node: Node
    var queries: NodeQueries

    @State private var restoring: PointChoice?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let list = queries.query(Ws.Recovery.List.self, .init(vaultID: vaultID, path: item.path.rawValue))
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recovery History")
                    .font(.title3.weight(.semibold))
                Text(item.isDirectory ? "Recovery points for “\(item.name)” and what is inside it."
                     : "Earlier versions of “\(item.name)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            Group {
                switch list.state {
                case .idle, .loading:
                    ProgressView("Loading recovery points…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let error):
                    VStack(spacing: 12) {
                        InlineProblem(error: error, subject: "this item's recovery history")
                        Button("Try Again") { Task { await list.refresh() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let value, _):
                    if value.points.isEmpty {
                        EmptyState("No recovery points", systemImage: "clock.arrow.circlepath",
                                   message: "The node keeps none for this path that this account may read. Local versioning or provider versioning in the vault's recovery settings creates them.")
                    } else {
                        points(value.points)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 480)
        .task { await list.refresh() }
        .sheet(item: $restoring) { choice in
            RestorePlanSheet(point: choice.point, queries: queries) { Task { await list.refresh() } }
        }
    }

    private func points(_ points: [WsModel.RecoveryPoint]) -> some View {
        let sorted = points.sorted { Self.time($0) ?? .distantPast > Self.time($1) ?? .distantPast }
        return List(sorted, id: \.id) { point in
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(point.backend))
                    .foregroundStyle(.accentText)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.time(point).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown time")
                        .font(.callout.weight(.medium))
                    Text(Self.detail(point))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if let size = point.sizeBytes {
                    Text(Format.bytes(size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if point.restorable {
                    Button("Restore…") { restoring = PointChoice(point: point) }
                        .controlSize(.small)
                } else {
                    Text(point.unavailableReason ?? "Not restorable")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(point.unavailableReason ?? "")
                }
            }
            .padding(.vertical, 3)
        }
        .scrollContentBackground(.hidden)
    }

    static func time(_ point: WsModel.RecoveryPoint) -> Date? {
        Format.date(iso: point.validFrom) ?? Format.date(iso: point.createdAt)
    }

    static func symbol(_ backend: String) -> String {
        switch backend {
        case WsModel.RecoveryPoint.Backend.localSnapshot: "camera"
        case WsModel.RecoveryPoint.Backend.providerVersion: "cloud"
        default: "clock.arrow.circlepath"
        }
    }

    static func detail(_ point: WsModel.RecoveryPoint) -> String {
        var parts: [String] = []
        switch point.backend {
        case WsModel.RecoveryPoint.Backend.localSnapshot: parts.append("Snapshot\(point.name.map { " “\($0)”" } ?? "")")
        case WsModel.RecoveryPoint.Backend.localVersion: parts.append("Local version")
        case WsModel.RecoveryPoint.Backend.providerVersion: parts.append(point.isCurrent ? "Provider version (current)" : "Provider version")
        default: parts.append(Format.words(point.backend))
        }
        if let reason = point.reason {
            switch reason {
            case "overwrite": parts.append("before it was overwritten")
            case "truncate": parts.append("before it was truncated")
            case "delete": parts.append("before it was deleted")
            case "restore": parts.append("before a restore")
            default: parts.append(Format.words(reason).lowercased())
            }
        }
        if point.isDeleteMarker { parts.append("delete marker") }
        if let count = point.fileCount, count > 0 { parts.append("\(count) files") }
        return parts.joined(separator: " · ")
    }
}

/// A recovery point picked for a restore (sheet identity).
private struct PointChoice: Identifiable {
    var point: WsModel.RecoveryPoint
    var id: String { point.id }
}

/// Plans a restore of one point, shows what it would change, and runs it.
private struct RestorePlanSheet: View {
    var point: WsModel.RecoveryPoint
    var queries: NodeQueries
    var onRestored: () -> Void

    @State private var plan: WsModel.RecoveryPlan?
    @State private var planError: WsError?
    @State private var typed = ""
    @State private var restore: NodeMutation<Ws.Recovery.Restore>
    @State private var result: WsModel.RecoveryRestoreResult?
    @Environment(\.dismiss) private var dismiss

    init(point: WsModel.RecoveryPoint, queries: NodeQueries, onRestored: @escaping () -> Void) {
        self.point = point
        self.queries = queries
        self.onRestored = onRestored
        _restore = State(initialValue: NodeMutation(Ws.Recovery.Restore.self, on: queries,
                                                    invalidating: ["fs.dir", "fs.list", "recovery", "vault.recovery"]))
    }

    private var destructive: Bool { (plan?.overwrites ?? 0) + (plan?.removals ?? 0) > 0 }
    private var changes: Int64 { (plan?.creates ?? 0) + (plan?.overwrites ?? 0) + (plan?.removals ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(result == nil ? "Restore Preview" : "Restore Result")
                .font(.title3.weight(.semibold))
            if let result {
                resultView(result)
            } else if let plan {
                planView(plan)
            } else if let planError {
                InlineProblem(error: planError, subject: "planning this restore")
                Button("Plan Again") { Task { await makePlan() } }
            } else {
                ProgressView("Working out what a restore would change. Nothing is changed yet.")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            MutationError(error: restore.error)
            buttons
        }
        .padding(22)
        .frame(width: 520)
        .task { await makePlan() }
        .serverConfirmation(restore, title: "Restore anyway?", confirmLabel: "Restore", role: .destructive)
        .interactiveDismissDisabled(restore.isRunning)
    }

    private func planView(_ plan: WsModel.RecoveryPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.sourceLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                count("Created", plan.creates)
                count("Overwritten", plan.overwrites, tone: plan.overwrites > 0 ? .warn : nil)
                count("Removed", plan.removals, tone: plan.removals > 0 ? .danger : nil)
                count("Skipped", plan.skips)
                if plan.conflicts > 0 { count("Conflicts", plan.conflicts, tone: .warn) }
            }
            if !plan.atomic, !plan.consistencyNote.isEmpty {
                Callout(tone: .info, systemImage: "info.circle") { Text(plan.consistencyNote) }
            }
            ForEach(plan.warnings, id: \.self) { warning in
                Callout(tone: .warn, systemImage: "exclamationmark.triangle") { Text(warning) }
            }
            ForEach(plan.blockers, id: \.self) { blocker in
                Callout(tone: .danger, systemImage: "xmark.octagon") { Text(blocker) }
            }
            if destructive, plan.blockers.isEmpty {
                Text("Existing content is replaced. The current contents become a recovery point only if versioning keeps them. Type RESTORE to confirm.")
                    .font(.callout)
                    .foregroundStyle(StatusTone.warn.color)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("RESTORE", text: $typed)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func count(_ label: String, _ value: Int64, tone: StatusTone? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tone?.color ?? .primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resultView(_ result: WsModel.RecoveryRestoreResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Callout(tone: result.state == "done" ? .ok : .warn,
                    systemImage: result.state == "done" ? "checkmark.circle" : "exclamationmark.triangle") {
                Text(result.state == "done" ? "Restore finished: \(result.restored) restored."
                     : "Restore \(result.state): \(result.restored) restored, \(result.failed) failed, \(result.conflicts) conflicts, \(result.skipped) skipped.")
            }
            ForEach(result.items.filter { $0.error != nil }.prefix(5), id: \.destinationPath) { outcome in
                Text("\(outcome.destinationPath): \(outcome.error ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if restore.isRunning { ProgressView().controlSize(.small) }
            Spacer()
            if result != nil {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(changes == 1 ? "Restore 1 Item" : "Restore \(changes) Items") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(destructive ? StatusTone.danger.color : .accentFill)
                    .disabled(!canRestore)
            }
        }
    }

    private var canRestore: Bool {
        guard let plan, plan.blockers.isEmpty, changes > 0, !restore.isRunning else { return false }
        return !destructive || typed == "RESTORE"
    }

    private func makePlan() async {
        planError = nil
        let query = queries.query(Ws.Recovery.Plan.self, .init(recoveryID: point.id))
        await query.refresh()
        if let answer = query.value, query.refreshError == nil {
            plan = answer.plan
            typed = ""
        } else {
            planError = query.error
        }
    }

    private func run() async {
        guard let plan else { return }
        if let done = await restore.run(.init(planID: plan.id, token: plan.token)) {
            result = done.result
            onRestored()
        } else if case .failed(.needsConfirmation(let code, _)) = restore.phase,
                  code == "recovery_plan_expired" || code == "recovery_restore" {
            // The plan (or its token) is no longer valid: plan again and show it before anything runs.
            await makePlan()
        }
    }
}
