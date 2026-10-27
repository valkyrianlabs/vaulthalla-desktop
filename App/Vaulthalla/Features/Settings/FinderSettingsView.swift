#if DEBUG
import AppKit
import SwiftUI
import VHContract
import VHCore
import VHFinder
import VHNodes

/// Debug builds only, until the File Provider extension serves files (valkyrianlabs/vaulthalla-desktop#4): where the registry
/// lives, and this app's File Provider domains, one per vault, to add, remove and check for the operator's approval.
struct FinderSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var domains: [DomainSnapshot] = []
    @State private var problem: String?
    @State private var nodeID: NodeID?
    @State private var vault: WsModel.Vault?
    @State private var busy = false

    private let registrar = FileProviderDomains()

    private var pairedNodes: [Node] {
        model.nodes.filter { if case .paired = $0.pairing { true } else { false } }
    }

    var body: some View {
        Form {
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
            } header: {
                Text("Shared container")
            } footer: {
                Text("Signed builds keep the node list in the App Group container, where the File Provider extension "
                    + "reads it. Builds without a team keep it in Application Support.")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }

            Section {
                if domains.isEmpty {
                    Text("No domains.")
                        .foregroundStyle(.fgSubtle)
                }
                ForEach(domains) { domain in
                    DomainRow(domain: domain) { await perform { try await registrar.remove(identifier: domain.identifier) } }
                }
                if !domains.isEmpty {
                    Button("Remove All Domains", role: .destructive) {
                        Task { await perform { try await registrar.removeAll() } }
                    }
                    .disabled(busy)
                }
            } header: {
                Text("File Provider domains")
            } footer: {
                Text("Developer preview: the domains show an empty folder in Finder until file operations arrive.")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }

            if FileProviderSettings.needsApproval(domains) {
                Section {
                    Callout(tone: .warn, systemImage: "hand.raised") {
                        Text("Turn on Vaulthalla in System Settings")
                            .fontWeight(.semibold)
                            .foregroundStyle(.fg)
                        Text("macOS shows no vault in Finder until Vaulthalla is allowed under General ▸ Login Items & "
                            + "Extensions ▸ File Providers. Only you can turn it on.")
                            .foregroundStyle(.fgMuted)
                    }
                    Button("Open File Providers Settings", systemImage: "gearshape") {
                        if !NSWorkspace.shared.open(FileProviderSettings.fileProvidersURL) {
                            NSWorkspace.shared.open(FileProviderSettings.loginItemsURL)
                        }
                    }
                }
            }

            Section("Add a vault") {
                Picker("Node", selection: $nodeID) {
                    Text("Choose a node").tag(NodeID?.none)
                    ForEach(pairedNodes) { node in
                        Text(node.displayName).tag(Optional(node.id))
                    }
                }
                if let node = pairedNodes.first(where: { $0.id == nodeID }) {
                    if let queries = model.liveQueries(for: node) {
                        VaultPicker(queries: queries, selection: $vault)
                    } else {
                        Text("\(node.displayName) isn't connected.")
                            .foregroundStyle(.fgSubtle)
                    }
                    Button("Add Domain", systemImage: "plus") {
                        guard let vault, let domain = VaultDomain(node: node, vaultID: vault.id, vaultName: vault.name)
                        else { return }
                        Task { await perform { try await registrar.ensure(domain) } }
                    }
                    .disabled(vault == nil || busy)
                }
            }

            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(StatusTone.warn.color)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 460)
        .task { await refresh() }
        .onChange(of: nodeID) { vault = nil }
    }

    private func refresh() async {
        do {
            domains = try await registrar.domains()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func perform(_ change: @escaping () async throws -> some Any) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await change()
            await refresh()
        } catch {
            problem = error.localizedDescription
        }
    }
}

private struct DomainRow: View {
    var domain: DomainSnapshot
    var remove: () async -> Void

    private var tone: StatusTone {
        switch domain.state {
        case .active: .ok
        case .needsUserApproval, .disconnected: .warn
        case .hidden: .unknown
        }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(domain.displayName)
                    .foregroundStyle(.fg)
                Text(domain.identifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.fgSubtle)
                    .textSelection(.enabled)
            }
            Spacer()
            StatusBadge(label: domain.state.label, tone: tone)
            Button("Remove", systemImage: "minus.circle") { Task { await remove() } }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}

private struct VaultPicker: View {
    var queries: NodeQueries
    @Binding var selection: WsModel.Vault?

    var body: some View {
        let list = queries.query(Ws.Storage.Vault.List.self)
        Picker("Vault", selection: $selection) {
            Text(list.value == nil ? "Loading…" : "Choose a vault").tag(WsModel.Vault?.none)
            ForEach(list.value?.vaults ?? [], id: \.id) { vault in
                Text(vault.name).tag(Optional(vault))
            }
        }
        .observing(list)
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
