import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Bucket bindings (`s3.gateway.buckets.*`): each bucket name maps to one vault. Bindings don't grant access; a key
/// still needs its principal's permissions or a gateway vault role.
struct GatewayBucketsTab: View {
    var node: Node
    var queries: NodeQueries

    private enum Sheet: String, Identifiable {
        case bind, local, remote
        var id: Self { self }
    }

    @State private var sheet: Sheet?
    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator(\GatewayBucketRow.name)]
    @State private var unbinding: GatewayBucketRow?
    @State private var unbind: NodeMutation<Ws.S3.Gateway.Buckets.Unbind>

    init(node: Node, queries: NodeQueries) {
        self.node = node
        self.queries = queries
        _unbind = State(initialValue: NodeMutation(Ws.S3.Gateway.Buckets.Unbind.self, on: queries,
                                                   invalidating: ["s3.gateway.buckets"]))
    }

    var body: some View {
        let list = queries.query(Ws.S3.Gateway.Buckets.List.self)
        let vaults = queries.query(Ws.Storage.Vault.List.self)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Bind Vault…", systemImage: "link") { sheet = .bind }
                Button("Remote-Cache Bucket…", systemImage: "cloud") { sheet = .remote }
                Button("Local Bucket…", systemImage: "plus") { sheet = .local }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.pagePadding)
            Text("Each bucket name maps to one vault. Bindings don't grant access: a key still needs its principal's permissions or a gateway vault role.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("Each bucket name maps to one vault. Bindings don't grant access: a key still needs its principal's permissions or a gateway vault role.")
                .padding(.horizontal, Theme.pagePadding)

            MutationError(error: unbind.error)
                .padding(.horizontal, Theme.pagePadding)

            switch list.state {
            case .idle, .loading:
                LoadingPanel(subject: "buckets")
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .failed(let error):
                ProblemPanel(problem: QueryProblem(error), node: node, subject: "buckets") {
                    Task { await list.refresh() }
                }
                .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .loaded(let value, _):
                if value.buckets.isEmpty {
                    Panel {
                        EmptyState("No buckets yet", systemImage: "shippingbox",
                                   message: "Create a local bucket, or bind an existing vault, so S3 clients have somewhere to read and write.")
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    Spacer(minLength: 0)
                } else {
                    table(value.buckets.map { GatewayBucketRow(bucket: $0, vaults: vaults.value?.vaults ?? []) }
                        .sorted(using: sortOrder))
                }
            }
        }
        .observing(list)
        .observing(vaults)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .bind: BindBucketSheet(queries: queries)
            case .local: LocalBucketSheet(queries: queries)
            case .remote: RemoteCacheBucketSheet(queries: queries)
            }
        }
        .confirmationDialog(unbinding.map { "Unbind bucket “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { unbinding != nil }, set: { if !$0 { unbinding = nil } }),
                            titleVisibility: .visible, presenting: unbinding) { row in
            Button("Unbind", role: .destructive) { Task { await unbind.run(.init(bucketName: row.name)) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Clients can no longer reach the vault under this bucket name. The vault and its files stay.")
        }
    }

    private func table(_ rows: [GatewayBucketRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Bucket", value: \.name) { row in
                Text(row.name)
                    .font(.body.monospaced())
                    .foregroundStyle(.fg)
                    .padding(.vertical, 3)
            }
            .width(min: 160, ideal: 220)
            TableColumn("Vault", value: \.vaultName) { row in
                Text(row.vaultName)
                    .foregroundStyle(.fgMuted)
            }
            .width(min: 120, ideal: 180)
            TableColumn("Mode", value: \.mode) { row in
                Text(GatewayFormat.bucketModeLabel(row.mode))
                    .foregroundStyle(.fgMuted)
                    .help(GatewayFormat.bucketModes[row.mode]?.hint ?? "")
            }
            .width(min: 90, ideal: 110)
            TableColumn("Gateway Only") { row in
                Text(row.bucket.apiExclusive ? "Yes" : "No")
                    .foregroundStyle(.fgSubtle)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Bound", value: \.created) { row in
                Text(Format.relative(epoch: row.bucket.createdAt))
                    .foregroundStyle(.fgSubtle)
                    .help(GatewayFormat.moment(row.bucket.createdAt) ?? "")
            }
            .width(min: 80, ideal: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { names in
            if let name = names.first, let row = rows.first(where: { $0.id == name }) {
                Button("Copy Bucket Name") { GatewayFormat.copy(row.name) }
                Divider()
                Button("Unbind…", role: .destructive) { unbinding = row }
            }
        }
    }
}

nonisolated struct GatewayBucketRow: Identifiable {
    var bucket: WsModel.S3GatewayBucket
    var vaultName: String

    init(bucket: WsModel.S3GatewayBucket, vaults: [WsModel.Vault]) {
        self.bucket = bucket
        vaultName = vaults.first { $0.id == bucket.vaultID }?.name ?? "Vault #\(bucket.vaultID)"
    }

    var id: String { name }
    var name: String { bucket.bucketName.isEmpty ? bucket.bucket : bucket.bucketName }
    var mode: String { bucket.mode }
    var created: Int64 { bucket.createdAt }
}

// MARK: - Sheets

/// The common frame of the bucket sheets.
private struct BucketSheet<Fields: View>: View {
    var title: String
    var footer: String
    var action: String
    var ready: Bool
    var running: Bool
    var error: WsError?
    var submit: () async -> Void
    @ViewBuilder var fields: Fields

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    fields
                } header: {
                    Text(title)
                } footer: {
                    Text(footer)
                        .foregroundStyle(.fgSubtle)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            MutationError(error: error)
                .padding(.horizontal, 20)

            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action) { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready || running)
            }
            .padding(20)
        }
        .frame(width: 500)
    }
}

private struct BucketNameField: View {
    @Binding var name: String
    var hint: String?

    var body: some View {
        TextField("Bucket name", text: Binding(get: { name }, set: { name = $0.lowercased() }))
            .font(.body.monospaced())
        if let problem = GatewayFormat.bucketNameProblem(name.trimmingCharacters(in: .whitespaces)) {
            Text(problem)
                .font(.caption)
                .foregroundStyle(StatusTone.danger.color)
        } else if let hint {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.fgSubtle)
        }
    }
}

/// Expose an existing vault under a bucket name (`s3.gateway.buckets.bind`).
private struct BindBucketSheet: View {
    var queries: NodeQueries

    @State private var vaultID: Int64?
    @State private var name = ""
    @State private var mode: String?
    @State private var exclusive = false
    @State private var bind: NodeMutation<Ws.S3.Gateway.Buckets.Bind>
    @Environment(\.dismiss) private var dismiss

    init(queries: NodeQueries) {
        self.queries = queries
        _bind = State(initialValue: NodeMutation(Ws.S3.Gateway.Buckets.Bind.self, on: queries,
                                                 invalidating: ["s3.gateway.buckets", "storage.vault"]))
    }

    var body: some View {
        let vaults = queries.query(Ws.Storage.Vault.List.self)
        let vault = vaults.value?.vaults.first { $0.id == vaultID }
        let modes = vault?.type == WsModel.Vault.TypeValue.s3 ? ["remote_cache", "remote_proxy"] : ["local"]
        let chosen = mode.flatMap { modes.contains($0) ? $0 : nil } ?? modes[0]
        let trimmed = name.trimmingCharacters(in: .whitespaces)

        BucketSheet(title: "Bind a Vault as a Bucket",
                    footer: "Expose an existing vault under an S3 bucket name. Binding doesn't grant access; keys still need it.",
                    action: "Bind", ready: vaultID != nil && GatewayFormat.bucketNameProblem(trimmed) == nil,
                    running: bind.isRunning, error: bind.error) {
            let payload = Ws.S3.Gateway.Buckets.Bind.Payload(
                vaultID: vaultID, bucketName: trimmed.isEmpty ? nil : trimmed, mode: .init(rawValue: chosen),
                apiExclusive: exclusive)
            if await bind.run(payload) != nil { dismiss() }
        } fields: {
            Picker("Vault", selection: $vaultID) {
                Text("Choose a vault…").tag(Int64?.none)
                ForEach(vaults.value?.vaults ?? [], id: \.id) { Text($0.name).tag(Int64?.some($0.id)) }
            }
            BucketNameField(name: $name, hint: "Empty: the vault's slug.")
            Picker("Mode", selection: Binding(get: { chosen }, set: { mode = $0 })) {
                ForEach(modes, id: \.self) { Text(GatewayFormat.bucketModeLabel($0)).tag($0) }
            }
            .disabled(modes.count == 1)
            Toggle(isOn: $exclusive) {
                Text("Gateway only")
                Text("Reserve the vault for S3 access (API-exclusive).")
            }
        }
        .observing(vaults)
        .serverConfirmation(bind, title: "Bind the bucket?", confirmLabel: "Bind")
    }
}

/// A new local vault bound as a bucket (`s3.gateway.buckets.createLocal`).
private struct LocalBucketSheet: View {
    var queries: NodeQueries

    @State private var name = ""
    @State private var quotaGB = ""
    @State private var create: NodeMutation<Ws.S3.Gateway.Buckets.CreateLocal>
    @Environment(\.dismiss) private var dismiss

    init(queries: NodeQueries) {
        self.queries = queries
        _create = State(initialValue: NodeMutation(Ws.S3.Gateway.Buckets.CreateLocal.self, on: queries,
                                                   invalidating: ["s3.gateway.buckets", "storage.vault"]))
    }

    private var quotaBytes: Int64? {
        let text = quotaGB.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let value = Double(text), value > 0 else { return nil }
        return Int64(value * 1_000_000_000)
    }

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let quotaValid = quotaGB.trimmingCharacters(in: .whitespaces).isEmpty || quotaBytes != nil
        BucketSheet(title: "New Local Bucket", footer: "Creates a new vault on this server and binds it as a bucket.",
                    action: "Create Bucket",
                    ready: !trimmed.isEmpty && GatewayFormat.bucketNameProblem(trimmed) == nil && quotaValid,
                    running: create.isRunning, error: create.error) {
            if await create.run(.init(bucketName: trimmed, quotaBytes: quotaBytes)) != nil { dismiss() }
        } fields: {
            BucketNameField(name: $name, hint: nil)
            TextField("Quota (GB)", text: $quotaGB, prompt: Text("Empty: no quota"))
            if let quotaBytes {
                Text(Format.bytes(quotaBytes))
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }
        }
        .serverConfirmation(create, title: "Create the bucket?", confirmLabel: "Create")
    }
}

/// An S3 vault on an upstream bucket, served through the gateway with a local cache
/// (`s3.gateway.buckets.createRemoteCache`). An upstream bucket that already holds data needs the person to accept
/// the encryption waiver; the daemon asks, and `.serverConfirmation` puts its question in front of them.
private struct RemoteCacheBucketSheet: View {
    var queries: NodeQueries

    @State private var name = ""
    @State private var keyID: Int64?
    @State private var upstream = ""
    @State private var encrypt = true
    @State private var create: NodeMutation<Ws.S3.Gateway.Buckets.CreateRemoteCache>
    @Environment(\.dismiss) private var dismiss

    init(queries: NodeQueries) {
        self.queries = queries
        _create = State(initialValue: NodeMutation(Ws.S3.Gateway.Buckets.CreateRemoteCache.self, on: queries,
                                                   invalidating: ["s3.gateway.buckets", "storage.vault"]))
    }

    var body: some View {
        let keys = queries.query(Ws.Storage.ApiKey.List.self)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let bucket = upstream.trimmingCharacters(in: .whitespaces)

        BucketSheet(title: "New Remote-Cache Bucket",
                    footer: "Creates an S3 vault on an upstream bucket and serves it through the gateway with a local cache.",
                    action: "Create Bucket",
                    ready: !trimmed.isEmpty && GatewayFormat.bucketNameProblem(trimmed) == nil && keyID != nil && !bucket.isEmpty,
                    running: create.isRunning, error: create.error) {
            let payload = Ws.S3.Gateway.Buckets.CreateRemoteCache.Payload(
                bucketName: trimmed, apiKeyID: keyID.map { .value($0) }, upstreamBucket: bucket, encryptUpstream: encrypt)
            if await create.run(payload) != nil { dismiss() }
        } fields: {
            BucketNameField(name: $name, hint: nil)
            Picker("Provider credential", selection: $keyID) {
                Text(keys.value == nil ? "Loading…" : "Choose a credential…").tag(Int64?.none)
                ForEach(keys.value?.keys ?? [], id: \.apiKeyID) { key in
                    Text("\(key.name) (\(key.provider))").tag(Int64?.some(key.apiKeyID))
                }
            }
            if let error = keys.error {
                InlineProblem(error: error, subject: "provider credentials")
            }
            TextField("Upstream bucket", text: $upstream)
                .font(.body.monospaced())
            Toggle(isOn: $encrypt) {
                Text("Encrypt objects before they leave this server")
                Text("Recommended. Turning it off stores plain objects at the provider.")
            }
        }
        .observing(keys)
        .onChange(of: create.isRunning) { _, running in
            // Accepting the daemon's question resends from the dialog: close once that succeeded too.
            if !running, case .succeeded = create.phase { dismiss() }
        }
        .serverConfirmation(create, title: "Use a bucket that already holds data?", confirmLabel: "Accept and Create")
    }
}
