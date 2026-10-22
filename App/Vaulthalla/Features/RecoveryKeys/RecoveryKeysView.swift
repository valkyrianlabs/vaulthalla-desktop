import SwiftUI
import VHCore
import VHKeyBackup
import VHNodes
import VHOnePassword

/// One node's Recovery Keys.
struct RecoveryKeysView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        if node.pairing.isPaired {
            RecoveryKeysScreen(scope: .node(node))
        } else {
            PlaceholderSection(node: node, section: .recoveryKeys)
        }
    }
}

/// Recovery Keys across every paired node: key backup is cross-node by nature (one 1Password vault for all).
struct AllRecoveryKeysView: View {
    var body: some View {
        RecoveryKeysScreen(scope: .all)
    }
}

enum RecoveryKeysScope: Equatable {
    case node(Node)
    case all
}

/// The Recovery Keys table: every vault's key, its 1Password backup state, and the actions on it. Data comes from
/// `RecoveryKeysModel` (node statuses polled, 1Password read on open).
struct RecoveryKeysScreen: View {
    var scope: RecoveryKeysScope

    @Environment(AppModel.self) private var app
    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator(\VaultKeyRow.sortState), KeyPathComparator(\VaultKeyRow.sortVault)]
    @State private var showsInspector = true
    @State private var restoring: VaultKeyRow?
    #if DEBUG
    @State private var debugSettings = false
    #endif

    private var keys: RecoveryKeysModel { app.recoveryKeys }

    private var nodes: [Node] {
        switch scope {
        case .node(let node): [node]
        case .all: keys.pairedNodes
        }
    }

    var body: some View {
        let rows = keys.rows(for: nodes).sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], Theme.pagePadding)
                .padding(.bottom, 16)
            banners(rows)
                .padding(.horizontal, Theme.pagePadding)
            content(rows)
        }
        // A Table's column minimums plus the inspector must not push the split view past the window (layout loop).
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .inspector(isPresented: Binding(get: { showsInspector && !rows.isEmpty }, set: { showsInspector = $0 })) {
            inspector(rows)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Back Up Now", systemImage: "arrow.up.doc.on.clipboard") {
                    keys.sync(rows.filter(\.status.wantsSync), title: syncTitle)
                }
                .help("Back up every vault here that isn't backed up to 1Password")
                .disabled(keys.run?.isRunning == true || !rows.contains(where: \.status.wantsSync))
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .help("Ask the nodes and 1Password again")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                    .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
        .task(id: nodes.map(\.id)) { await openScreen() }
        .sheet(item: Binding(get: { keys.run }, set: { keys.run = $0 })) { run in
            KeySyncSheet(run: run)
        }
        .sheet(item: $restoring) { row in
            RestoreKeysSheet(row: row, keys: keys)
        }
        #if DEBUG
        .sheet(isPresented: $debugSettings) {
            OnePasswordSettingsView()
                .frame(width: 520, height: 520)
        }
        .task { await debugHooks(rows) }
        #endif
    }

    private var syncTitle: String {
        switch scope {
        case .node(let node): "Back up vault keys on \(node.displayName)"
        case .all: "Back up vault keys"
        }
    }

    private func openScreen() async {
        if keys.lastPoll == nil || (keys.lastPoll.map { Date.now.timeIntervalSince($0) > 15 } ?? true) {
            await keys.pollNodes()
        }
        if case .notChecked = keys.onePassword { await keys.refreshOnePassword() }
    }

    private func refresh() async {
        await keys.pollNodes()
        await keys.refreshOnePassword()
    }

    // MARK: Header and banners

    private var header: some View {
        SectionHeader(
            eyebrow: scopeEyebrow, title: "Recovery Keys",
            subtitle: "Every vault's encryption key, backed up to 1Password with each version files still need, and restored from there."
        ) {
            if case .node(let node) = scope {
                let status = app.status(for: node)
                StatusBadge(label: status.label, tone: status.tone, pulse: status.isTransitional)
            }
        }
    }

    private var scopeEyebrow: String {
        switch scope {
        case .node(let node): node.displayName
        case .all: "All Nodes"
        }
    }

    @ViewBuilder
    private func banners(_ rows: [VaultKeyRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let unavailable = rows.filter(\.isKeyUnavailable)
            if !unavailable.isEmpty {
                Callout(tone: .danger, systemImage: "key.slash") {
                    Text(unavailable.count == 1
                         ? "\(unavailable[0].vaultName) on \(unavailable[0].nodeName) can't use its key and doesn't run."
                         : "\(unavailable.count) vaults can't use their keys and don't run.")
                        .fontWeight(.semibold)
                    Text("Restore from 1Password: the node takes back only keys the vault had.")
                    HStack {
                        ForEach(unavailable.prefix(3)) { row in
                            Button(unavailable.count == 1 ? "Restore from 1Password…" : "Restore \(row.vaultName)…") {
                                restoring = row
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            // Backups from before the node recorded attestations. Second to an unusable key: the page doesn't scroll,
            // so a third banner would squeeze the others at the minimum window size.
            let unattested = rows.filter { !$0.attestationsToStore.isEmpty }
            if unavailable.isEmpty, !unattested.isEmpty {
                Callout(tone: .warn, systemImage: "seal") {
                    HStack(spacing: 10) {
                        Text(unattested.count == 1
                             ? "\(unattested[0].vaultName)'s backup has no attestation, which a restore needs."
                             : "\(unattested.count) backups have no attestation, which a restore needs.")
                            .help("The node's attestation is a public signature that reveals nothing about the key. Backups made before the node's update have none; backing up again adds it.")
                        Spacer(minLength: 0)
                        Button("Back Up Again") { keys.sync(unattested, force: true, title: "Back up vault keys again") }
                            .disabled(keys.run?.isRunning == true)
                    }
                }
            }
            onePasswordBanner
            ForEach(nodes) { node in
                if let problem = keys.problem(for: node) {
                    nodeProblem(problem, node: node)
                }
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var onePasswordBanner: some View {
        switch keys.onePassword {
        case .notConfigured:
            Callout(tone: .info, systemImage: "lock.shield") {
                Text("Choose your 1Password account to back up vault keys. Until then, each vault's state comes from its node's record.")
                SettingsLink { Text("Set Up 1Password…") }
                    .padding(.top, 4)
            }
        case .notChecked:
            Callout(tone: .info, systemImage: "lock.shield") {
                Text("States come from each node's record. Check 1Password to compare with what it actually holds.")
                Button("Check 1Password") { Task { await keys.refreshOnePassword() } }
                    .padding(.top, 4)
            }
        case .checking:
            Callout(tone: .info, systemImage: "lock.shield") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading 1Password… (it may ask you to approve with Touch ID)")
                }
            }
        case .failed(let message):
            Callout(tone: .warn, systemImage: "exclamationmark.lock") {
                Text("1Password couldn't be read: \(message)")
                HStack {
                    Button("Try Again") { Task { await keys.refreshOnePassword() } }
                    SettingsLink { Text("1Password Settings…") }
                }
                .padding(.top, 4)
            }
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private func nodeProblem(_ problem: RecoveryKeysModel.NodeProblem, node: Node) -> some View {
        switch problem {
        case .unsupported:
            Callout(tone: .warn, systemImage: "arrow.up.circle") {
                Text("\(node.displayName) runs a Vaulthalla without key backup (vault.keys.*). Update it to back up its vault keys from here.")
            }
        case .denied(let message):
            Callout(tone: .info, systemImage: "lock") {
                Text("This account can't see vault keys on \(node.displayName): \(message)")
            }
        case .offline:
            Callout(tone: .info, systemImage: "bolt.horizontal.circle") {
                Text("\(node.displayName) isn't connected. Its vaults appear once it is.")
            }
        case .failed(let message):
            Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                Text("\(node.displayName): \(message)")
            }
        }
    }

    // MARK: Table

    @ViewBuilder
    private func content(_ rows: [VaultKeyRow]) -> some View {
        if rows.isEmpty {
            Group {
                if nodes.contains(where: keys.isLoading) {
                    LoadingPanel(subject: "vault keys")
                } else if nodes.isEmpty {
                    Panel {
                        EmptyState("No paired nodes", systemImage: "key.horizontal",
                                   message: "Pair this Mac with a Vaulthalla node to back up its vault keys.")
                    }
                } else if nodes.allSatisfy({ keys.problem(for: $0) != nil }) {
                    EmptyView()
                } else {
                    Panel {
                        EmptyState("No vault keys to show", systemImage: "key.horizontal",
                                   message: "The nodes list the vaults whose keys this account may inspect.")
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            Spacer(minLength: 0)
        } else {
            table(rows)
        }
    }

    private func table(_ rows: [VaultKeyRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Vault", value: \.sortVault) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.vaultName)
                        .foregroundStyle(.fg)
                    if scope == .all || row.deleted {
                        Text(row.deleted ? "\(row.nodeName) · deleted" : row.nodeName)
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }
                .lineLimit(1)
                .padding(.vertical, 3)
            }
            .width(min: 150, ideal: 220)

            TableColumn("Version", value: \.daemon.version) { row in
                Text("v\(row.daemon.version)")
                    .monospacedDigit()
                    .foregroundStyle(.fgMuted)
            }
            .width(min: 54, ideal: 64)

            TableColumn("Key check") { row in
                Text(row.shortCheck)
                    .font(.callout.monospaced())
                    .foregroundStyle(row.daemon.keyCheck == nil ? Color.fgFaint : Color.fgMuted)
                    .help(row.daemon.keyCheck ?? "The node can't read this key.")
            }
            .width(min: 72, ideal: 86)

            TableColumn("1Password", value: \.sortState) { row in
                StatusBadge(label: row.stateLabel, tone: row.stateTone)
                    .help(row.stateDetail)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Recovery") { row in
                if let assurance = row.recoveryAssurance {
                    Text(assurance == .guaranteed ? "Guaranteed" : "Best effort")
                        .foregroundStyle(assurance.tone.color)
                        .help(row.assuranceDetail)
                } else {
                    Text("—").foregroundStyle(.fgFaint)
                }
            }
            .width(min: 76, ideal: 96)

            TableColumn("Last backed up", value: \.sortBackedUp) { row in
                Text(row.lastBackedUp.map { Format.relative($0) } ?? "never")
                    .foregroundStyle(row.lastBackedUp == nil ? Color.fgFaint : Color.fgSubtle)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                rowActions(row)
            }
        } primaryAction: { ids in
            selection = ids.first
            showsInspector = true
        }
    }

    @ViewBuilder
    private func rowActions(_ row: VaultKeyRow) -> some View {
        if row.status.wantsSync {
            Button("Back Up Now") { keys.sync([row], title: "Back up \(row.vaultName)") }
        }
        if case .backedUp = row.status {
            Button("Back Up Again") { keys.sync([row], force: true, title: "Back up \(row.vaultName) again") }
        }
        if row.item != nil || row.isKeyUnavailable {
            Button("Restore from 1Password…") { restoring = row }
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(_ rows: [VaultKeyRow]) -> some View {
        if let selection, let row = rows.first(where: { $0.id == selection }) {
            RecoveryKeyInspector(row: row, onRestore: { restoring = row })
                .id(row.id)
        } else {
            EmptyState("No vault selected", systemImage: "sidebar.trailing",
                       message: "Select a vault to compare its key with the 1Password backup, back it up or restore it.")
                .frame(maxHeight: .infinity)
        }
    }

    #if DEBUG
    /// `-VHDebugRecoveryKeys sync | restore | restore-result | restore-salvage | settings` (DebugSnapshot), with
    /// PREVIEW DATA.
    private func debugHooks(_ rows: [VaultKeyRow]) async {
        guard let hook = UserDefaults.standard.string(forKey: "VHDebugRecoveryKeys") else { return }
        try? await Task.sleep(for: .milliseconds(600))
        let rows = keys.rows(for: nodes)
        let vault = Int64(UserDefaults.standard.integer(forKey: "VHDebugVault"))
        let pick = rows.first { $0.vaultID == vault } ?? rows.first(where: \.isKeyUnavailable) ?? rows.first
        selection = pick?.id
        switch hook {
        case "sync": keys.run = .preview()
        case "restore", "restore-result", "restore-salvage": restoring = pick
        case "settings": debugSettings = true
        default: break
        }
    }
    #endif
}

#if DEBUG
#Preview("Recovery Keys (preview data)") {
    let model = PreviewSamples.liveModel()
    RecoveryKeysView(node: PreviewSamples.nodes[1])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1100, height: 640)
}
#endif
