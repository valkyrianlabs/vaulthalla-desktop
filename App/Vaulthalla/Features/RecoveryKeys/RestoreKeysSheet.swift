import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VHCore
import VHKeyBackup
import VHNodes
import VHOnePassword

/// Restoring one vault's keys from 1Password (decision D7): verify what 1Password holds against the node, export
/// it to a file in the `vh vault keys export` shape, or import it back to the node. The node verifies every key
/// against the vault's files and asks for the vault's name before writing; only its answer calls the vault
/// recovered. Versions it can't verify as its own (no valid attestation) are only usable through Salvage, a
/// separate step with its own confirmation and report.
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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let assurance = row.recoveryAssurance {
                        Callout(tone: assurance.tone, systemImage: assurance == .guaranteed ? "checkmark.seal" : "seal") {
                            Text(assurance.label).fontWeight(.semibold)
                            Text(assurance.detail)
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
                            salvageIntro
                            importStep(.salvage, step: flow.salvage)
                        }
                    }
                }
                .padding(20)
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
        #if DEBUG
        .task {
            if UserDefaults.standard.string(forKey: "VHDebugRecoveryKeys") == "restore-result" {
                await flow.debugShowRecoverResult()
            }
        }
        #endif
    }

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
        let versions = flow.needsSalvage.map(\.version)
        return Callout(tone: .warn, systemImage: "bandage") {
            Text(versions.isEmpty ? "Salvage" : "\(VaultKeyRow.versionWords(versions, capitalized: true)) couldn't be restored as the vault's own key.")
                .fontWeight(.semibold)
            Text("The node couldn't verify \(versions.count == 1 ? "it" : "them") with an attestation, so it won't put \(versions.count == 1 ? "it" : "them") back as the vault's key. Salvage is the fallback: the node decrypts whatever those keys still can, re-encrypts it under a fresh key, and lists the files it couldn't recover. It changes the vault's key; back up again afterwards.")
        }
    }

    @ViewBuilder
    private func importStep(_ mode: VaultKeyImportMode, step: RestoreFlow.Step) -> some View {
        let canStart = row.item != nil
        switch step {
        case .idle:
            if mode == .recover {
                Text("Sends the versions \(row.nodeName) needs over this Mac's paired connection. \(row.nodeName) verifies each against the vault's files and shows what it would write before anything changes.")
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

/// The node's answer: per version what happened, then the one sentence that matters (recovered or not).
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
                Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                    Text("Not recovered yet.").fontWeight(.semibold)
                    Text("Some versions couldn't be verified as this vault's own; see Salvage below.")
                }
            } else {
                Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                    Text("“\(report.vaultName)” still can't use its keys.").fontWeight(.semibold)
                    Text(report.note ?? "\(nodeName) took what it could verify; the vault needs more.")
                }
            }
            ForEach(report.versions) { version in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("v\(version.version)")
                        .monospacedDigit()
                        .foregroundStyle(.fg)
                        .frame(width: 36, alignment: .leading)
                    StatusBadge(label: Format.words(version.outcome), tone: tone(version.outcome))
                    Text(versionDetail(version))
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let salvage = report.salvage {
                DefinitionList(items: [
                    ("Recovered files", salvage.recoveredFiles.formatted()),
                    ("Unrecoverable", salvage.unrecoverableCount.formatted()),
                    ("New key version", salvage.newKeyVersion.map { "v\($0)" } ?? "—"),
                ].map { (term: $0.0, value: $0.1) }, termWidth: 120)
                if !salvage.unrecoverableFiles.isEmpty {
                    Text("Files that couldn't be recovered")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.fgSubtle)
                    ForEach(salvage.unrecoverableFiles.prefix(50), id: \.self) { path in
                        Text(path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.fgMuted)
                            .textSelection(.enabled)
                    }
                    if salvage.unrecoverableFiles.count > 50 {
                        Text("and \(salvage.unrecoverableFiles.count - 50) more")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }
            }
        }
    }

    private func versionDetail(_ version: VaultKeyImportReport.Version) -> String {
        var parts = [version.detail]
        if version.verifiedFiles > 0 { parts.append("\(version.verifiedFiles) files verified") }
        if version.failedFiles > 0 { parts.append("\(version.failedFiles) damaged") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func tone(_ outcome: String) -> StatusTone {
        switch outcome {
        case "restored", "salvaged": .ok
        case "unchanged": .info
        case VaultKeyImportReport.Version.needsSalvage: .warn
        default: .unknown
        }
    }
}
