import AppKit
import SwiftUI
import VHContract
import VHCore
import VHFinder
import VHNodes

/// Settings ▸ Finder: every vault of every paired node, each with a Show in Finder switch (one File Provider domain per
/// vault, docs/architecture.md §7). Finder shows what the paired account may see, as the server decides; files download
/// when opened. This also walks the operator through the consent gate in System Settings.
struct FinderSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var finder = FinderVaults()
    @State private var confirmingHide: HideRequest?

    private var pairedNodes: [Node] {
        model.nodes.filter { if case .paired = $0.pairing { true } else { false } }
    }

    /// Domains no paired node accounts for: a node removed from this Mac, or an identifier Desktop didn't make.
    private var otherDomains: [DomainSnapshot] {
        let nodes = Set(pairedNodes.map(\.id))
        return finder.domains.filter { domain in domain.vault.map { !nodes.contains($0.nodeID) } ?? true }
    }

    var body: some View {
        Form {
            Section {
                Text("Vaults you show here appear in Finder under Locations, like iCloud Drive. Files download when you "
                    + "open them, and macOS removes downloaded copies when it needs the space. Finder shows exactly what "
                    + "your Vaulthalla account can see.")
                    .foregroundStyle(.fgMuted)
            }

            if finder.awaitingApproval {
                Section {
                    Callout(tone: .warn, systemImage: "hand.raised") {
                        Text("Turn on Vaulthalla in System Settings")
                            .fontWeight(.semibold)
                            .foregroundStyle(.fg)
                        Text("macOS shows no vault in Finder until you allow Vaulthalla under General ▸ Login Items & "
                            + "Extensions ▸ File Providers. Your other vaults are added once it's on.")
                            .foregroundStyle(.fgMuted)
                    }
                    Button("Open File Providers Settings", systemImage: "gearshape") {
                        if !NSWorkspace.shared.open(FileProviderSettings.fileProvidersURL) {
                            NSWorkspace.shared.open(FileProviderSettings.loginItemsURL)
                        }
                    }
                }
            }

            if pairedNodes.isEmpty {
                Section {
                    Text("Pair a node to show its vaults in Finder.")
                        .foregroundStyle(.fgSubtle)
                }
            }
            ForEach(pairedNodes) { node in
                NodeVaultsSection(node: node, queries: model.liveQueries(for: node), finder: finder) { id, name in
                    confirmingHide = HideRequest(id: id, name: name)
                }
            }

            if !otherDomains.isEmpty {
                Section("Other vaults in Finder") {
                    ForEach(otherDomains) { domain in
                        HStack {
                            Text(domain.displayName)
                                .foregroundStyle(.fg)
                            Spacer()
                            Button("Remove") { Task { await finder.remove(identifier: domain.identifier) } }
                        }
                    }
                }
            }

            if let problem = finder.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(StatusTone.warn.color)
                }
            }

            #if DEBUG
            FinderDeveloperSection(finder: finder)
            #endif
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
        // The system reports no change in a domain's approval, so read it again while the tab is open.
        .task {
            while !Task.isCancelled {
                await finder.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog(
            "Remove “\(confirmingHide?.name ?? "")” from Finder?",
            isPresented: Binding(get: { confirmingHide != nil }, set: { if !$0 { confirmingHide = nil } }),
            presenting: confirmingHide
        ) { request in
            Button("Remove from Finder", role: .destructive) { Task { await finder.hide(request.id) } }
        } message: { _ in
            Text("Its files stay on the server. Copies downloaded to this Mac are removed, so let changes finish "
                + "uploading first.")
        }
    }
}

private struct HideRequest: Identifiable {
    var id: VaultDomainID
    var name: String
}

/// One node's vaults: what its accessible list offers, plus domains of the node the list no longer has.
private struct NodeVaultsSection: View {
    var node: Node
    var queries: NodeQueries?
    var finder: FinderVaults
    var confirmHide: (VaultDomainID, String) -> Void

    private var nodeDomains: [DomainSnapshot] {
        finder.domains.filter { $0.vault?.nodeID == node.id }
    }

    var body: some View {
        Section(node.displayName) {
            if let queries {
                VaultList(node: node, vaults: VaultChoices(queries: queries), domains: nodeDomains, finder: finder,
                          confirmHide: confirmHide)
            } else {
                Text("\(node.displayName) isn't connected. Vaults already in Finder keep working when it's back.")
                    .foregroundStyle(.fgSubtle)
                ForEach(nodeDomains) { domain in
                    if let id = domain.vault {
                        FinderVaultRow(name: domain.displayName, id: id, domain: nil, canShow: false, finder: finder,
                                       confirmHide: confirmHide)
                    }
                }
            }
        }
    }
}

private struct VaultList: View {
    var node: Node
    var vaults: VaultChoices
    var domains: [DomainSnapshot]
    var finder: FinderVaults
    var confirmHide: (VaultDomainID, String) -> Void

    var body: some View {
        Group {
            switch vaults.state {
            case .idle, .loading:
                Text("Loading vaults…")
                    .foregroundStyle(.fgSubtle)
            case .failed(let error):
                Text(Self.words(QueryProblem(error)))
                    .foregroundStyle(.fgSubtle)
            case .loaded(let choices, _):
                if choices.isEmpty {
                    Text("Your account reaches no vault here.")
                        .foregroundStyle(.fgSubtle)
                }
                ForEach(choices) { choice in
                    if let domain = VaultDomain(node: node, vaultID: choice.id, vaultName: choice.name) {
                        FinderVaultRow(name: choice.name, id: domain.id, domain: domain, canShow: choice.canOpen,
                                       finder: finder, confirmHide: confirmHide, unavailable: unavailable(choice))
                    }
                }
                // In Finder, but the list no longer has it: the vault was deleted or the account lost access.
                ForEach(domains.filter { domain in !choices.contains { $0.id == domain.vault?.vaultID } }) { domain in
                    if let id = domain.vault {
                        FinderVaultRow(name: domain.displayName, id: id, domain: nil, canShow: false, finder: finder,
                                       confirmHide: confirmHide, unavailable: "No longer listed for your account")
                    }
                }
            }
        }
        .task(id: vaults.observation) { await vaults.observe() }
    }

    private static func words(_ problem: QueryProblem) -> String {
        switch problem {
        case .denied: "Your account can't list vaults here."
        case .notFound(let message), .failed(let message): message
        case .offline: "Reconnecting…"
        case .noAnswerYet: "Waiting for the node to answer…"
        case .mismatch: CompatibilityWords.shortMismatch(legacy: false)
        }
    }

    private func unavailable(_ choice: VaultChoice) -> String? {
        if !choice.isActive { return "This vault is inactive" }
        if choice.access != .browse { return "Your account can't browse this vault" }
        return nil
    }
}

private struct FinderVaultRow: View {
    var name: String
    var id: VaultDomainID
    /// What to add when switched on; nil for a row that can only be removed.
    var domain: VaultDomain?
    var canShow: Bool
    var finder: FinderVaults
    var confirmHide: (VaultDomainID, String) -> Void
    var unavailable: String?

    private var snapshot: DomainSnapshot? { finder.snapshot(for: id) }

    private var shown: Binding<Bool> {
        Binding {
            finder.isShown(id)
        } set: { on in
            if on {
                if let domain { Task { await finder.show(domain) } }
            } else if finder.snapshot(for: id) != nil {
                confirmHide(id, name)
            } else {
                Task { await finder.hide(id) }
            }
        }
    }

    private var status: (label: String, tone: StatusTone)? {
        if let snapshot {
            switch snapshot.state {
            case .active: return ("In Finder", .ok)
            case .needsUserApproval:
                return finder.isStuck(snapshot) ? ("Stuck waiting for approval", .warn)
                    : ("Waiting for approval in System Settings", .warn)
            case .disconnected: return ("Disconnected", .warn)
            case .hidden: return ("Hidden", .unknown)
            }
        }
        if finder.isPending(id) { return ("Added once Vaulthalla is on in System Settings", .info) }
        if let unavailable { return (unavailable, .unknown) }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundStyle(.fg)
                if let status {
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(status.tone == .ok ? StatusTone.ok.color : .fgSubtle)
                }
            }
            Spacer()
            if let snapshot, finder.isStuck(snapshot) {
                Button("Add Again") { Task { await finder.addAgain(snapshot) } }
                    .help("Remove this vault from Finder and add it again, so it comes up allowed")
            }
            if snapshot?.state == .active {
                Button("Open", systemImage: "folder") { Task { await finder.open(id) } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Open in Finder")
            }
            Toggle("Show in Finder", isOn: shown)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!finder.isShown(id) && (!canShow || domain == nil))
        }
    }
}

#if DEBUG
/// Developer details: where the registry lives and the raw domains, as the system reports them.
private struct FinderDeveloperSection: View {
    @Environment(AppModel.self) private var model
    var finder: FinderVaults

    var body: some View {
        Section {
            LabeledContent("Node list") {
                Text(model.registryURL.path(percentEncoded: false))
                    .font(.callout.monospaced())
                    .foregroundStyle(.fgMuted)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            if let registry = model.registry {
                LabeledContent("Location", value: registry.location.source.label)
                LabeledContent("At launch", value: registry.migration.description)
            }
            ForEach(finder.domains) { domain in
                LabeledContent(domain.displayName) {
                    Text("\(domain.identifier) · \(domain.state.label)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.fgSubtle)
                        .textSelection(.enabled)
                }
            }
            if !finder.pending.isEmpty {
                LabeledContent("Pending", value: finder.pending.map(\.id.identifier).joined(separator: ", "))
            }
        } header: {
            Text("Developer")
        }
    }
}

extension RegistryLocation.Source {
    var label: String {
        switch self {
        case .appGroup: "App Group container"
        case .applicationSupport: "Application Support"
        case .forwarded: "App Group container (via the migration marker)"
        }
    }
}
#endif
