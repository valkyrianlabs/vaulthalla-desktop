import SwiftUI
import VHKeyBackup
import VHOnePassword

/// The selected vault: its state in words, how sure a restore would be, each key version compared between the node
/// and 1Password (metadata only), and the actions.
struct RecoveryKeyInspector: View {
    var row: VaultKeyRow
    var onRestore: () -> Void

    @Environment(AppModel.self) private var app

    private var keys: RecoveryKeysModel { app.recoveryKeys }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.vaultName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                        .lineLimit(2)
                    Text(row.deleted ? "\(row.nodeName) · deleted vault, key retained" : row.nodeName)
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                    StatusBadge(label: row.stateLabel, tone: row.stateTone)
                    Text(row.stateDetail)
                        .font(.callout)
                        .foregroundStyle(.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actions

                if let assurance = row.recoveryAssurance {
                    KeySection("Recovery") {
                        StatusBadge(label: assurance.label, tone: assurance.tone)
                        Text(assurance.detail)
                            .font(.callout)
                            .foregroundStyle(.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                KeySection("Key versions") {
                    VerificationList(verification: KeyRestore.verify(daemon: row.daemon, item: row.item),
                                     checked: row.onePasswordChecked)
                }

                KeySection("Details") {
                    DefinitionList(items: details, monospacedValues: ["Key check"], termWidth: 112)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var actions: some View {
        let busy = keys.run?.isRunning == true
        HStack(spacing: 8) {
            if row.status.wantsSync {
                Button("Back Up Now") { keys.sync([row], title: "Back up \(row.vaultName)") }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            } else if case .backedUp = row.status, row.recoveryAssurance != .guaranteed {
                Button("Back Up Again") { keys.sync([row], force: true, title: "Back up \(row.vaultName) again") }
                    .disabled(busy)
                    .help("Store the node's current attestations with the keys")
            }
            if row.isKeyUnavailable {
                Button("Restore from 1Password…", action: onRestore)
                    .buttonStyle(.borderedProminent)
            } else if row.item != nil {
                Button("Restore…", action: onRestore)
            }
        }
        .controlSize(.regular)
    }

    private var details: [(term: String, value: String)] {
        var items: [(String, String)] = [
            ("Current version", "v\(row.daemon.version)"),
            ("Key check", row.daemon.keyCheck ?? "not readable on the node"),
        ]
        if row.daemon.rotationInProgress { items.append(("Rotation", "under way")) }
        if let exported = row.daemon.exportedVersion {
            let when = row.daemon.exportedAt.map { " · \(Format.relative($0))" } ?? ""
            items.append(("Node's record", "v\(exported) backed up\(when)"))
        } else {
            items.append(("Node's record", "never backed up"))
        }
        if let item = row.item {
            items.append(("1Password item", item.title.isEmpty ? item.itemID : item.title))
            if let at = item.backedUpAt { items.append(("Stored", at.formatted(date: .abbreviated, time: .shortened))) }
        } else if row.onePasswordChecked {
            items.append(("1Password item", "none"))
        }
        return items.map { (term: $0.0, value: $0.1) }
    }
}

/// Each key version: the node's key check, 1Password's, and what that means.
struct VerificationList: View {
    var verification: KeyRestore.Verification
    var checked: Bool

    var body: some View {
        if !checked {
            Text("Check 1Password to compare the stored versions with the node's.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Version")
                    Text("Node")
                    Text("1Password")
                    Text("")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.fgSubtle)
                ForEach(verification.lines) { line in
                    GridRow {
                        Text("v\(line.version)")
                            .monospacedDigit()
                            .foregroundStyle(.fg)
                        check(line.nodeCheck, missing: line.verdict == .retired ? "not needed" : "unreadable")
                        check(line.backupCheck, missing: "missing")
                        Label(verdict(line.verdict).text, systemImage: verdict(line.verdict).symbol)
                            .foregroundStyle(verdict(line.verdict).tone.color)
                            .labelStyle(.titleAndIcon)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func check(_ value: String?, missing: String) -> some View {
        Text(value.map { String($0.prefix(8)) } ?? missing)
            .font(.callout.monospaced())
            .foregroundStyle(value == nil ? Color.fgFaint : Color.fgMuted)
            .help(value ?? "")
    }

    private func verdict(_ verdict: KeyRestore.Verification.Verdict) -> (text: String, symbol: String, tone: StatusTone) {
        switch verdict {
        case .matches: ("Matches", "checkmark.circle.fill", .ok)
        case .differs: ("Differs", "xmark.octagon.fill", .danger)
        case .restorable: ("Restorable", "arrow.uturn.backward.circle.fill", .info)
        case .missingFromBackup: ("Not backed up", "exclamationmark.circle.fill", .warn)
        case .lost: ("Lost", "xmark.octagon.fill", .danger)
        case .retired: ("Retired", "archivebox", .unknown)
        }
    }
}

struct KeySection<Content: View>: View {
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

/// The progress of one sync, vault by vault, with plain-word outcomes. Partial failure is normal and reported.
struct KeySyncSheet: View {
    var run: KeySyncRun

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.accentText)
                    .frame(width: 36, height: 36)
                    .background(.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                }
            }

            switch run.phase {
            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to 1Password… (approve with Touch ID if it asks)")
                        .foregroundStyle(.fgMuted)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            case .failed(let message):
                Callout(tone: .warn, systemImage: "exclamationmark.lock") { Text(message) }
            case .running, .finished:
                if run.entries.isEmpty {
                    Text("Every vault is already backed up.")
                        .foregroundStyle(.fgMuted)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(run.entries) { entry in
                                SyncEntryRow(entry: entry)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 340)
                }
            }

            HStack {
                Text("Keys go from the node to 1Password over this Mac's paired connection; nothing is kept here.")
                    .font(.caption)
                    .foregroundStyle(.fgFaint)
                Spacer()
                Button(run.isRunning ? "Hide" : "Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var summary: String {
        let done = run.entries.filter { $0.outcome != nil }
        let ok = done.filter { $0.outcome?.succeeded == true }.count
        switch run.phase {
        case .preparing: return "Preparing…"
        case .failed: return "Nothing was backed up."
        case .running: return "\(done.count) of \(run.entries.count) vaults done"
        case .finished:
            let failed = done.count - ok
            return failed == 0 ? "\(ok) of \(run.entries.count) vaults backed up"
                : "\(ok) backed up, \(failed) not: see below"
        }
    }
}

private struct SyncEntryRow: View {
    var entry: KeySyncRun.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.vaultName)")
                    .foregroundStyle(.fg)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch entry.outcome {
        case nil:
            if entry.running { ProgressView().controlSize(.mini) } else { Image(systemName: "circle").foregroundStyle(.fgFaint) }
        case .backedUp: Image(systemName: "checkmark.circle.fill").foregroundStyle(StatusTone.ok.color)
        case .storedNotConfirmed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(StatusTone.warn.color)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(StatusTone.unknown.color)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(StatusTone.danger.color)
        }
    }

    private var detail: String {
        let node = entry.nodeName
        switch entry.outcome {
        case nil: return entry.running ? "\(node) · backing up…" : "\(node) · waiting"
        case .backedUp(let version, let written):
            return written ? "\(node) · key version \(version) stored in 1Password and recorded on the node"
                : "\(node) · 1Password already held version \(version); recorded on the node"
        case .storedNotConfirmed(let version, let reason):
            return "\(node) · version \(version) is in 1Password, but the node didn't record it: \(reason). Back up again for the new key."
        case .skipped(let reason): return "\(node) · \(reason)"
        case .failed(let step, let message):
            let stage = switch step {
            case .export: "reading the key"
            case .store: "storing it in 1Password"
            case .confirm: "recording the backup"
            }
            return "\(node) · failed while \(stage): \(message)"
        }
    }
}
