import AppKit
import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Upstream provider credentials (`storage.apiKey.*`): access keys for S3-compatible storage (AWS, Cloudflare R2, …)
/// that S3 vaults use to reach their bucket. Not the keys clients use with Vaulthalla's own S3 gateway. The daemon
/// never sends a secret back.
struct CredentialsView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        if let queries = model.liveQueries(for: node) {
            CredentialsScreen(node: node, queries: queries)
                .environment(queries)
        } else {
            PlaceholderSection(node: node, section: .credentials)
        }
    }
}

private struct CredentialsScreen: View {
    var node: Node
    var queries: NodeQueries

    @Environment(AppModel.self) private var model
    @State private var selection: Int64?
    @State private var sortOrder = [KeyPathComparator(\CredentialRow.sortName)]
    @State private var filter = ""
    @State private var sheet: CredentialSheet.Mode?
    @State private var deleting: CredentialRow?

    var body: some View {
        let list = queries.query(Ws.Storage.ApiKey.List.self)
        let vaults = queries.query(Ws.Storage.Vault.List.self)
        let rows = rows(list: list, vaults: vaults)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(eyebrow: node.displayName, title: "Credentials", subtitle: NodeSection.credentials.summary) {
                let status = model.status(for: node)
                StatusBadge(label: status.label, tone: status.tone, pulse: status.isTransitional)
            }
            .padding([.horizontal, .top], Theme.pagePadding)
            .padding(.bottom, 16)

            switch list.state {
            case .idle, .loading:
                LoadingPanel(subject: "credentials")
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .failed(let error):
                ProblemPanel(problem: QueryProblem(error), node: node, subject: "provider credentials") {
                    Task { await list.refresh() }
                }
                .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .loaded(let value, let at):
                StaleBanner(node: node, updatedAt: at, refreshError: list.refreshError, connected: queries.isConnected)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 12)
                if value.keys.isEmpty {
                    Panel {
                        EmptyState("No provider credentials yet", systemImage: "key.2.on.ring",
                                   message: "Add an access key for your S3 or R2 account, then create an S3 vault that uses it.") {
                            Button("Add Credential…") { sheet = .create }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    Spacer(minLength: 0)
                } else {
                    table(rows, usageKnown: vaults.value != nil)
                }
            }
        }
        .observing(list)
        .observing(vaults)
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter Credentials")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Credential", systemImage: "plus") { sheet = .create }
                    .help("Add a provider credential (⇧⌘N)")
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        .sheet(item: $sheet) { mode in
            CredentialSheet(mode: mode, queries: queries)
        }
        .sheet(item: $deleting) { row in
            DeleteCredentialSheet(row: row, queries: queries) {
                if selection == row.id { selection = nil }
            }
        }
        #if DEBUG
        .task { await debugOpenSheet() }
        #endif
    }

    private func table(_ rows: [CredentialRow], usageKnown: Bool) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.sortName) { row in
                HStack(spacing: 10) {
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.accentText)
                        .frame(width: 26, height: 26)
                        .background(.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.accentLine, lineWidth: 1) }
                    Text(row.key.name.isEmpty ? "Credential \(row.id)" : row.key.name)
                        .foregroundStyle(.fg)
                        .lineLimit(1)
                }
                .padding(.vertical, 3)
            }
            .width(min: 160, ideal: 220)

            TableColumn("Provider", value: \.key.provider) { row in
                HStack(spacing: 6) {
                    Text(row.key.provider.isEmpty ? "—" : row.key.provider)
                        .foregroundStyle(.fgMuted)
                    if row.key.adminEnabled {
                        Text("Admin")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.accentText)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(.accentSoft, in: Capsule())
                            .help("Provider administration is on: Vaulthalla can create, adopt and watch buckets with this key.")
                    }
                }
            }
            .width(min: 100, ideal: 150)

            TableColumn("Endpoint", value: \.host) { row in
                Text(row.host.isEmpty ? "—" : row.host)
                    .font(.callout.monospaced())
                    .foregroundStyle(.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.key.endpoint)
            }
            .width(min: 120, ideal: 220)

            TableColumn("Region", value: \.key.region) { row in
                Text(row.key.region.isEmpty ? "—" : row.key.region)
                    .font(.callout.monospaced())
                    .foregroundStyle(.fgMuted)
            }
            .width(min: 60, ideal: 90)

            TableColumn("Access key") { row in
                Text(row.maskedAccessKey)
                    .font(.callout.monospaced())
                    .foregroundStyle(.fgSubtle)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Used by", value: \.usageSort) { row in
                if !usageKnown {
                    Text("—").foregroundStyle(.fgFaint)
                } else if row.usedBy.isEmpty {
                    Text("No vaults").foregroundStyle(.fgSubtle)
                } else {
                    Text(row.usedBy.count == 1 ? row.usedBy[0].name : "\(row.usedBy.count) vaults")
                        .foregroundStyle(.fgMuted)
                        .help(row.usedBy.map(\.name).joined(separator: ", "))
                }
            }
            .width(min: 90, ideal: 140)

            TableColumn("Added", value: \.key.createdAt) { row in
                Text(Format.day(iso: row.key.createdAt) ?? row.key.createdAt)
                    .foregroundStyle(.fgSubtle)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Edit…") { sheet = .edit(row.key) }
                Button("Copy Access Key ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.key.accessKey, forType: .string)
                }
                Divider()
                Button("Delete…", role: .destructive) { deleting = row }
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) { sheet = .edit(row.key) }
        }
        .onDeleteCommand {
            if let selection, let row = rows.first(where: { $0.id == selection }) { deleting = row }
        }
    }

    private func rows(list: NodeQuery<Ws.Storage.ApiKey.List>, vaults: NodeQuery<Ws.Storage.Vault.List>) -> [CredentialRow] {
        let all = vaults.value?.vaults ?? []
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return (list.value?.keys ?? [])
            .map { key in CredentialRow(key: key, usedBy: all.filter { $0.apiKeyID == key.apiKeyID }) }
            .filter { needle.isEmpty || $0.searchText.contains(needle) }
            .sorted(using: sortOrder)
    }

    #if DEBUG
    /// `-VHDebugCredential new|edit:<id>|delete:<id>` opens that sheet (DebugSnapshot).
    private func debugOpenSheet() async {
        guard let raw = UserDefaults.standard.string(forKey: "VHDebugCredential") else { return }
        if raw == "new" { sheet = .create; return }
        let list = queries.query(Ws.Storage.ApiKey.List.self)
        let vaults = queries.query(Ws.Storage.Vault.List.self)
        while (list.value == nil || vaults.value == nil), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let id = Int64(parts[1]), let key = list.value?.keys.first(where: { $0.apiKeyID == id }) else { return }
        selection = id
        if parts[0] == "edit" { sheet = .edit(key) }
        if parts[0] == "delete" {
            deleting = CredentialRow(key: key, usedBy: vaults.value?.vaults.filter { $0.apiKeyID == id } ?? [])
        }
    }
    #endif
}

/// One credential with the vaults (of those this account may list) that use it.
nonisolated struct CredentialRow: Identifiable {
    var key: WsModel.APIKey
    var usedBy: [WsModel.Vault]

    var id: Int64 { key.apiKeyID }
    var sortName: String { key.name.lowercased() }
    var usageSort: Int { usedBy.count }

    var host: String {
        URL(string: key.endpoint)?.host() ?? key.endpoint
    }

    /// "AKIA…WXYZ": enough to recognise a key without putting the whole identifier on screen.
    var maskedAccessKey: String {
        let access = key.accessKey
        guard access.count > 10 else { return access.isEmpty ? "—" : access }
        return "\(access.prefix(4))…\(access.suffix(4))"
    }

    var searchText: String {
        [key.name, key.provider, key.endpoint, key.region].joined(separator: " ").lowercased()
    }
}

#if DEBUG
#Preview("Credentials (preview data)") {
    let model = PreviewSamples.liveModel()
    CredentialsView(node: PreviewSamples.nodes[1])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1100, height: 560)
}
#endif
