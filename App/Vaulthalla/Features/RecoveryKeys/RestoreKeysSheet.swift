import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VHContract
import VHCore
import VHKeyBackup
import VHNodes
import VHOnePassword

/// Restoring one vault's keys from 1Password (decision D7): verify what 1Password holds against the node, export
/// it to a file in the `vh vault keys export` shape, or import it back to the node. The node restores only versions
/// its own attestation proves are the vault's, never a key of the caller's own, and asks for the vault's name before
/// writing; only its answer calls the vault recovered. Versions it can't prove (`needs_salvage`) are only usable
/// through Salvage, a separate step with its own confirmation and report.
@MainActor
@Observable
final class RestoreFlow {
    enum Step: Equatable {
        case idle
        case working(String)
        /// The node would write; `message` is what, in its words. The person types the vault's name.
        case confirm(message: String)
        case done(VaultKeyImportReport)
        case failed(String)
    }

    let row: VaultKeyRow
    private(set) var recover: Step = .idle
    private(set) var salvage: Step = .idle
    var typedName = ""
    var salvageTypedName = ""
    private(set) var exportNote: (text: String, ok: Bool)?
    private(set) var exporting = false

    @ObservationIgnored private weak var keys: RecoveryKeysModel?

    init(row: VaultKeyRow, keys: RecoveryKeysModel) {
        self.row = row
        self.keys = keys
    }

    static var exportedBy: String {
        "Vaulthalla Desktop (1Password) on \(Host.current().localizedName ?? "this Mac")"
    }

    private func prepared() async -> (KeyRestore, OnePasswordVault, KeyBackupNode?)? {
        guard let keys else { return nil }
        if keys.onePasswordVault == nil { await keys.refreshOnePassword() }
        guard let vault = keys.onePasswordVault else { return nil }
        let node = keys.app?.node(withID: row.nodeID).flatMap { node in
            keys.app?.keyTransport(for: node.id).map { KeyBackupNode(node: node, transport: $0) }
        }
        return (KeyRestore(store: keys.store), vault, node)
    }

    private var onePasswordProblem: String {
        if case .failed(let message) = keys?.onePassword { return message }
        return "1Password isn't set up (Settings → 1Password)."
    }

    // MARK: Export to a file

    func exportToFile() async {
        guard !exporting else { return }
        let panel = NSSavePanel()
        panel.title = "Export Vault Keys"
        panel.message = "The file holds \(row.vaultName)'s keys unencrypted. Keep it somewhere only you can read, or encrypt it."
        panel.nameFieldStringValue = "\(row.vaultName)-keys.json".replacingOccurrences(of: "/", with: "-")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true
        defer { exporting = false }
        guard let (restore, vault, _) = await prepared() else {
            exportNote = (onePasswordProblem, false)
            return
        }
        do {
            // Revealed, written (0600) and dropped within this call; the buffer zeroes itself.
            let document = try await restore.exportDocument(row, in: vault, exportedBy: Self.exportedBy)
            try SecretFile.write(document, to: url)
            exportNote = ("Saved to \(url.lastPathComponent), readable only by you. Import it with `vh vault keys import \(row.vaultID) --file …`.", true)
        } catch let error as KeyRestore.RestoreError {
            exportNote = (error.description, false)
        } catch let error as SecretFile.Failure {
            exportNote = (error.description, false)
        } catch {
            exportNote = (KeyBackupWords.onePassword(error), false)
        }
    }

    // MARK: Import

    /// Asks the node to plan (no name: nothing is written), or writes with the typed name.
    func run(_ mode: VaultKeyImportMode, confirmed: Bool) async {
        set(mode, .working(mode == .recover ? "Restoring…" : "Salvaging…"))
        guard let (restore, vault, node) = await prepared() else {
            set(mode, .failed(onePasswordProblem))
            return
        }
        guard let node else {
            set(mode, .failed("\(row.nodeName) isn't connected."))
            return
        }
        let name = confirmed ? (mode == .recover ? typedName : salvageTypedName) : nil
        let outcome = await restore.importToNode(row, on: node, in: vault, mode: mode, confirmName: name,
                                                 exportedBy: Self.exportedBy)
        switch outcome {
        case .imported(let report): set(mode, .done(report))
        case .needsConfirmation(let message): set(mode, .confirm(message: message))
        case .failed(let message): set(mode, .failed(message))
        }
        if case .done = outcome.step { await keys?.pollNodes() }
    }

    func cancel(_ mode: VaultKeyImportMode) {
        set(mode, .idle)
    }

    private func set(_ mode: VaultKeyImportMode, _ step: Step) {
        switch mode {
        case .recover: recover = step
        case .salvage: salvage = step
        }
    }

    var salvageDone: Bool {
        if case .done = salvage { return true }
        return false
    }

    /// Recover finished and some versions only a salvage can use.
    var needsSalvage: [VaultKeyImportReport.Version] {
        if case .done(let report) = recover { return report.needsSalvage }
        return []
    }

    #if DEBUG
    /// PREVIEW DATA: the result of a recover that left a version for salvage.
    func debugShowRecoverResult() async {
        await run(.recover, confirmed: false)
        typedName = row.vaultName
        await run(.recover, confirmed: true)
    }

    /// PREVIEW DATA: then the salvage of what recover left, with its report.
    func debugShowSalvageResult() async {
        await debugShowRecoverResult()
        await run(.salvage, confirmed: false)
        salvageTypedName = row.vaultName
        await run(.salvage, confirmed: true)
    }
    #endif
}

private extension KeyRestore.ImportOutcome {
    var step: RestoreFlow.Step {
        switch self {
        case .imported(let report): .done(report)
        case .needsConfirmation(let message): .confirm(message: message)
        case .failed(let message): .failed(message)
        }
    }
}

struct RestoreKeysSheet: View {
    @State private var flow: RestoreFlow
    @Environment(\.dismiss) private var dismiss

    init(row: VaultKeyRow, keys: RecoveryKeysModel) {
        _flow = State(initialValue: RestoreFlow(row: row, keys: keys))
    }

    private var row: VaultKeyRow { flow.row }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        if let assurance = row.recoveryAssurance {
                            Callout(tone: assurance.tone, systemImage: assurance == .guaranteed ? "checkmark.seal" : "seal") {
                                Text(assurance.label).fontWeight(.semibold)
                                Text(row.assuranceDetail)
                            }
                        }
                        KeySection("1. Verify") {
                            Text("What 1Password stores, compared with what \(row.nodeName) reports, by key check. No key leaves 1Password.")
                                .font(.callout)
                                .foregroundStyle(.fgSubtle)
                            VerificationList(verification: KeyRestore.verify(daemon: row.daemon, item: row.item),
                                             checked: row.onePasswordChecked)
                        }
                        KeySection("2. Export to a file") {
                            Text("Writes the keys in `vh vault keys export` format to a file you choose (only you can read it).")
                                .font(.callout)
                                .foregroundStyle(.fgSubtle)
                            HStack(spacing: 10) {
                                Button("Export to File…") { Task { await flow.exportToFile() } }
                                    .disabled(row.item == nil || flow.exporting)
                                if flow.exporting { ProgressView().controlSize(.small) }
                            }
                            if let note = flow.exportNote {
                                Label(note.text, systemImage: note.ok ? "checkmark.circle" : "exclamationmark.triangle")
                                    .font(.callout)
                                    .foregroundStyle(note.ok ? StatusTone.ok.color : StatusTone.warn.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        KeySection("3. Restore to \(row.nodeName)") {
                            importStep(.recover, step: flow.recover)
                        }
                        if !flow.needsSalvage.isEmpty || flow.salvage != .idle {
                            KeySection("Salvage") {
                                if !flow.salvageDone { salvageIntro }
                                importStep(.salvage, step: flow.salvage)
                            }
                            .id(Self.salvageAnchor)
                        }
                    }
                    .padding(20)
                }
                #if DEBUG
                .task {
                    switch UserDefaults.standard.string(forKey: "VHDebugRecoveryKeys") {
                    case "restore-result":
                        await flow.debugShowRecoverResult()
                    case "restore-salvage":
                        await flow.debugShowSalvageResult()
                        scroll.scrollTo(Self.salvageAnchor, anchor: .top)
                    default:
                        break
                    }
                }
                #endif
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 640)
    }

    private static let salvageAnchor = "salvage"

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.accentText)
                .frame(width: 36, height: 36)
                .background(.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore “\(row.vaultName)”")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.fg)
                Text("\(row.nodeName) · from 1Password")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
            }
        }
    }

    private var salvageIntro: some View {
        let versions = flow.needsSalvage.map { Int($0.version) }
        return Callout(tone: .warn, systemImage: "bandage") {
            Text(versions.isEmpty ? "Salvage" : "\(row.nodeName) can't prove \(VaultKeyRow.versionWords(versions)) \(versions.count == 1 ? "is" : "are") this vault's key. Nothing changed.")
                .fontWeight(.semibold)
            Text("Salvage is a separate step. \(row.nodeName) re-encrypts the files the backed-up \(versions.count == 1 ? "key opens" : "keys open") under a new key it creates, and lists the files it couldn't open: they may be unrecoverable. It never stores the backed-up \(versions.count == 1 ? "key" : "keys"). Back up the new key afterwards.")
        }
    }

    @ViewBuilder
    private func importStep(_ mode: VaultKeyImportMode, step: RestoreFlow.Step) -> some View {
        let canStart = row.item != nil
        switch step {
        case .idle:
            if mode == .recover {
                Text("Sends the versions \(row.nodeName) needs, with their attestations, over this Mac's paired connection. \(row.nodeName) restores only keys the vault had, never a key of your own, and shows what it would write before anything changes.")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(mode == .recover ? "Restore to \(row.nodeName)…" : "Salvage…") {
                Task { await flow.run(mode, confirmed: false) }
            }
            .disabled(!canStart)
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(.fgMuted)
            }
        case .confirm(let message):
            confirmation(mode, message: message)
        case .done(let report):
            ImportReportView(report: report, mode: mode, nodeName: row.nodeName)
        case .failed(let message):
            Callout(tone: .danger, systemImage: "exclamationmark.circle") { Text(message) }
            Button("Try Again") { flow.cancel(mode) }
        }
    }

    private func confirmation(_ mode: VaultKeyImportMode, message: String) -> some View {
        let typed = Binding(get: { mode == .recover ? flow.typedName : flow.salvageTypedName },
                            set: { if mode == .recover { flow.typedName = $0 } else { flow.salvageTypedName = $0 } })
        return VStack(alignment: .leading, spacing: 10) {
            Callout(tone: mode == .recover ? .info : .warn, systemImage: "questionmark.circle") {
                Text(message)
            }
            Text("Type “\(row.vaultName)” to \(mode == .recover ? "restore" : "salvage") its keys.")
                .font(.callout)
                .foregroundStyle(.fgMuted)
            TextField("Vault name", text: typed)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            HStack {
                Button("Cancel") { flow.cancel(mode) }
                Button(mode == .recover ? "Restore" : "Salvage", role: mode == .salvage ? .destructive : nil) {
                    Task { await flow.run(mode, confirmed: true) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(typed.wrappedValue != row.vaultName)
            }
        }
    }
}

/// The node's answer: the one sentence that matters (recovered or not), per version what happened, and a salvage's
/// report.
struct ImportReportView: View {
    var report: VaultKeyImportReport
    var mode: VaultKeyImportMode
    var nodeName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if report.keyAvailable {
                Callout(tone: .ok, systemImage: "checkmark.seal.fill") {
                    Text(mode == .salvage ? "“\(report.vaultName)” runs again under a new key." : "“\(report.vaultName)” is recovered.")
                        .fontWeight(.semibold)
                    Text(mode == .salvage ? "Back its new key up to 1Password now."
                         : "Its keys work on \(nodeName) again.")
                }
            } else if mode == .recover, !report.needsSalvage.isEmpty {
                let versions = report.needsSalvage.map { Int($0.version) }
                Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                    Text("Not recovered yet.").fontWeight(.semibold)
                    Text("\(nodeName) can't prove \(VaultKeyRow.versionWords(versions)) \(versions.count == 1 ? "is" : "are") this vault's key, so nothing changed for \(versions.count == 1 ? "it" : "them"). See Salvage below.")
                }
            } else {
                Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                    Text("“\(report.vaultName)” still can't use its keys.").fontWeight(.semibold)
                    Text(report.note ?? "\(nodeName) restored what it could prove; the vault needs more.")
                }
            }
            if !report.refused.isEmpty {
                let versions = report.refused.map { Int($0.version) }
                Text("\(nodeName) never had \(VaultKeyRow.versionWords(versions)), so the backup's \(versions.count == 1 ? "copy was" : "copies were") refused: an import never adds a key version.")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let salvage = report.salvage, salvage.isRunning {
                Callout(tone: .warn, systemImage: "pause.circle") {
                    Text("The salvage was interrupted. Run it again to resume; it continues with the same new key.")
                }
            }
            ForEach(report.versions, id: \.version) { version in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("v\(version.version)")
                        .monospacedDigit()
                        .foregroundStyle(.fg)
                        .frame(width: 36, alignment: .leading)
                    StatusBadge(label: Format.words(version.outcome), tone: tone(version.outcome))
                    Text(version.detail)
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let salvage = report.salvage {
                SalvageReportView(report: salvage)
            }
        }
    }

    private func tone(_ outcome: String) -> StatusTone {
        typealias Outcome = VaultKeyImportReport.Version.Outcome
        return switch outcome {
        case Outcome.restored, Outcome.salvaged: .ok
        case Outcome.unchanged: .info
        case Outcome.needsSalvage: .warn
        case Outcome.refused: .warn
        default: .unknown
        }
    }
}

/// A salvage pass (`VaultKeySalvageReport`): its counts, then the files it didn't re-encrypt (the first 50).
struct SalvageReportView: View {
    var report: WsModel.VaultKeySalvageReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(report.failures.isEmpty
                 ? "Every file the backed-up key opened is re-encrypted under the new key."
                 : "Unrecoverable files didn't open with the backed-up key and may be lost. The others can be retried by running the salvage again.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
            DefinitionList(items: [
                ("Salvaged", report.salvaged.formatted()),
                ("Unrecoverable", report.unrecoverable.formatted()),
                ("Skipped (remote)", report.skippedRemote.formatted()),
                ("Deferred", report.deferred.formatted()),
                ("Failed", report.failed.formatted()),
                ("New key version", report.newVersion.map { "v\($0)" } ?? "—"),
            ].map { (term: $0.0, value: $0.1) }, termWidth: 120)
            if !report.failures.isEmpty {
                Text("Files not salvaged")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.fgSubtle)
                ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.fgMuted)
                            .textSelection(.enabled)
                        Text("v\(failure.version) · \(Format.words(failure.kind)) · \(failure.reason)")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if report.unlistedFailures > 0 {
                    Text("and \(report.unlistedFailures.formatted()) more")
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                }
            }
        }
    }
}
