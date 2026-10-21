import SwiftUI
import VHContract
import VHCore
import VHNodes

extension View {
    /// The New Vault sheet, presented from the Vaults toolbar. `onCreated` gets the vault the node made.
    func newVaultSheet(isPresented: Binding<Bool>, node: Node, queries: NodeQueries,
                       onCreated: @escaping (WsModel.Vault) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            NewVaultSheet(node: node, queries: queries, onCreated: onCreated)
        }
        #if DEBUG
        // `-VHDebugNewVault local|s3|adopt` opens the sheet in that state (DebugSnapshot).
        .task {
            if UserDefaults.standard.string(forKey: "VHDebugNewVault") != nil { isPresented.wrappedValue = true }
        }
        #endif
    }
}

/// Creates a vault (`storage.vault.add`): local disk, or an S3/R2 bucket through a provider credential, with the
/// bucket bound by name, created or adopted (credentials with provider administration), upstream encryption, quota
/// and the sync policy, seeded from the node's `vaults.s3.*` defaults (`settings.policy.get`). The daemon's own
/// questions (`encryption_waiver`, `upstream_adoption`) are asked in its words before anything is accepted.
struct NewVaultSheet: View {
    var node: Node
    var queries: NodeQueries
    var onCreated: (WsModel.Vault) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = NewVaultDraft()
    @State private var add: NodeMutation<Ws.Storage.Vault.Add>

    private let credentials: NodeQuery<Ws.Storage.ApiKey.List>
    private let policy: NodeQuery<Ws.Settings.Policy.Get>
    private let users: NodeQuery<Ws.Auth.Users.List>

    init(node: Node, queries: NodeQueries, onCreated: @escaping (WsModel.Vault) -> Void) {
        self.node = node
        self.queries = queries
        self.onCreated = onCreated
        credentials = queries.query(Ws.Storage.ApiKey.List.self)
        policy = queries.query(Ws.Settings.Policy.Get.self)
        users = queries.query(Ws.Auth.Users.List.self)
        _add = State(initialValue: NodeMutation(
            Ws.Storage.Vault.Add.self, on: queries,
            invalidating: ["storage.vault", "stats.system.storage", "storage.apiKey", "upstream"]))
    }

    private var credential: WsModel.APIKey? {
        credentials.value?.keys.first { $0.apiKeyID == draft.apiKeyID }
    }

    /// Creating or adopting a bucket needs a credential with provider administration; the daemon authorizes it.
    private var canProvision: Bool { credential?.adminEnabled == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                storage
                if draft.isS3 { bucket }
                details
                names
                if draft.isS3 {
                    sync
                    guardrails
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(add.isRunning)

            MutationError(error: add.error)
                .padding(.horizontal, 20)

            HStack {
                if add.isRunning {
                    ProgressView().controlSize(.small)
                    Text(draft.isS3 ? "Checking the bucket and creating the vault…" : "Creating the vault…")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Vault") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.isValid || add.isRunning)
            }
            .padding(20)
        }
        .frame(width: 620)
        .frame(minHeight: 520, idealHeight: 760)
        .observing(credentials)
        .observing(policy)
        .observing(users)
        .onChange(of: policy.value, initial: true) { _, value in seedDefaults(value) }
        .onChange(of: credentials.value, initial: true) { _, value in
            // A single credential is the obvious choice.
            if draft.apiKeyID == nil, let keys = value?.keys, keys.count == 1 { draft.apiKeyID = keys[0].apiKeyID }
        }
        .onChange(of: draft.apiKeyID) { _, _ in
            // An admin-enabled credential starts in "create a new bucket".
            draft.bucketMode = canProvision ? .create : .existing
            draft.storageTier = ""
        }
        .serverConfirmation(add, title: confirmationTitle, confirmLabel: confirmationLabel)
        .interactiveDismissDisabled(add.isRunning)
        #if DEBUG
        .task { debugPrepare() }
        #endif
    }

    // MARK: Sections

    private var storage: some View {
        Section {
            Picker("Storage", selection: $draft.type) {
                Label("Local disk", systemImage: "externaldrive").tag(NewVaultDraft.Payload.TypeValue.local)
                Label("S3 bucket", systemImage: "cloud").tag(NewVaultDraft.Payload.TypeValue.s3)
            }
            .pickerStyle(.segmented)
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("New vault on \(node.displayName)")
                    .font(.headline)
                Text("Pick where the files live, then name it. Everything except the storage type can be changed later.")
                    .foregroundStyle(.fgSubtle)
            }
        } footer: {
            Text(draft.isS3
                 ? "Files live in an S3 or R2 bucket, with an encrypted local cache."
                 : "Files live on the node, encrypted at rest.")
                .foregroundStyle(.fgSubtle)
        }
    }

    @ViewBuilder
    private var bucket: some View {
        Section {
            switch credentials.state {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .failed(let error):
                InlineProblem(error: error, subject: "provider credentials")
            case .loaded(let value, _):
                if value.keys.isEmpty {
                    HStack {
                        Label("An S3 vault needs a provider credential (endpoint and access key) first.",
                              systemImage: "key.2.on.ring")
                            .foregroundStyle(.fgMuted)
                        Spacer()
                        Button("Add a Credential…") {
                            dismiss()
                            model.select(.credentials)
                        }
                    }
                } else {
                    Picker("Credential", selection: $draft.apiKeyID) {
                        if draft.apiKeyID == nil { Text("Choose…").tag(Int64?.none) }
                        ForEach(value.keys, id: \.apiKeyID) { key in
                            Text(key.provider.isEmpty ? key.name : "\(key.name) · \(key.provider)").tag(Int64?.some(key.apiKeyID))
                        }
                    }
                }
            }

            if credential != nil {
                if canProvision {
                    Picker("Bucket", selection: $draft.bucketMode) {
                        Text("Create new").tag(NewVaultDraft.BucketMode.create)
                        Text("Adopt existing").tag(NewVaultDraft.BucketMode.adopt)
                        Text("Use a name").tag(NewVaultDraft.BucketMode.existing)
                    }
                    .pickerStyle(.segmented)
                }
                switch canProvision ? draft.bucketMode : .existing {
                case .existing:
                    TextField("Bucket", text: $draft.bucket, prompt: Text("bucket-name"))
                        .autocorrectionDisabled()
                case .create:
                    TextField("New bucket name", text: $draft.bucket,
                              prompt: Text(draft.generateName ? "Generated from the vault name" : "my-vault-bucket"))
                        .autocorrectionDisabled()
                        .disabled(draft.generateName)
                    Toggle("Generate a bucket name", isOn: $draft.generateName)
                    TextField("Region", text: $draft.region,
                              prompt: Text(credential?.region.isEmpty == false ? credential!.region : "Credential default"))
                        .autocorrectionDisabled()
                    TextField("Abort incomplete uploads after (days)", text: $draft.abortMultipartDays, prompt: Text("None"))
                        .multilineTextAlignment(.trailing)
                case .adopt:
                    AdoptBucketFields(queries: queries, apiKeyID: draft.apiKeyID ?? 0, draft: $draft)
                }
                if canProvision, draft.bucketMode != .existing {
                    Toggle("Event-driven sync", isOn: $draft.events)
                    if draft.events {
                        TextField("Only keys under this prefix", text: $draft.eventsPrefix, prompt: Text("Whole bucket"))
                            .autocorrectionDisabled()
                    }
                }
                if let tiers = NewVaultDraft.storageTiers(provider: credential?.provider) {
                    Picker("Storage tier", selection: $draft.storageTier) {
                        ForEach(tiers, id: \.id) { Text($0.title).tag($0.id) }
                    }
                }
            }
            Toggle("Encrypt objects before upload", isOn: $draft.encryptUpstream)
        } header: {
            Text("Bucket")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if credential != nil, !draft.trimmedBucket.isEmpty || draft.bucketMode == .create,
                   let problem = draft.bucketProblem {
                    Text(problem).foregroundStyle(StatusTone.danger.color)
                }
                if draft.bucketMode == .create, canProvision, draft.abortDays == nil {
                    Text("Abort after whole days, up to 36500, or leave it empty.").foregroundStyle(StatusTone.danger.color)
                }
                Text(bucketFooter).foregroundStyle(.fgSubtle)
            }
        }
    }

    private var bucketFooter: String {
        var lines: [String] = []
        if canProvision {
            switch draft.bucketMode {
            case .create: lines.append("Vaulthalla creates the bucket and owns its lifecycle rule. An existing bucket is never taken over: adopt it instead.")
            case .adopt: lines.append("The node asks before adopting a bucket; nothing in it changes.")
            case .existing: lines.append("Binds a bucket by name without any provider administration.")
            }
            if draft.events, draft.bucketMode != .existing {
                lines.append("The bucket notifies Vaulthalla of uploads and deletes (AWS through SQS; R2 needs a Cloudflare API token on the credential).")
            }
        }
        lines.append(draft.encryptUpstream ? "The bucket only ever sees ciphertext. Recommended."
                                           : "Objects are stored in the bucket as plain files.")
        return lines.joined(separator: " ")
    }

    private var details: some View {
        Section {
            TextField("Name", text: $draft.name)
            TextField("Description", text: $draft.summary, axis: .vertical)
                .lineLimit(2...4)
            LabeledContent("Quota") {
                HStack(spacing: 6) {
                    TextField("Quota", text: $draft.quotaAmount, prompt: Text("Unlimited"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 140)
                    Picker("Unit", selection: $draft.quotaUnit) {
                        ForEach(NewVaultDraft.QuotaUnit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if let others = users.value?.users.filter({ $0.isActive && !$0.systemOnly }), others.count > 1 {
                Picker("Owner", selection: $draft.ownerID) {
                    Text("This Mac's account").tag(Int64?.none)
                    ForEach(others, id: \.id) { Text($0.name).tag(Int64?.some($0.id)) }
                }
            }
        } header: {
            Text("Details")
        } footer: {
            Text(draft.quotaBytes == nil ? "Enter a size, or leave the quota empty for none." : "An empty quota means no quota.")
                .foregroundStyle(draft.quotaBytes == nil ? StatusTone.danger.color : Color.fgSubtle)
        }
    }

    private var names: some View {
        Section {
            TextField("Slug", text: $draft.slug, prompt: Text("Derived from the name"))
                .autocorrectionDisabled()
            TextField("FUSE folder name", text: $draft.fuseName, prompt: Text("The slug"))
                .autocorrectionDisabled()
        } header: {
            Text("Names on disk and over S3")
        } footer: {
            if let problem = draft.slugProblem ?? draft.fuseProblem {
                Text(problem).foregroundStyle(StatusTone.danger.color)
            } else {
                Text("The slug is 3–63 lowercase letters, digits or hyphens; the FUSE folder is the vault's folder under the node's mount.")
                    .foregroundStyle(.fgSubtle)
            }
        }
    }

    private var sync: some View {
        Section {
            Toggle("Scheduled sync", isOn: $draft.syncEnabled)
            Picker("Strategy", selection: strategyBinding) {
                ForEach(NewVaultDraft.Strategy.allCases, id: \.self) { Text(NewVaultDraft.strategyTitle($0)).tag($0) }
            }
            Picker("On conflict", selection: conflictBinding) {
                ForEach(NewVaultDraft.s3Conflicts, id: \.self) { Text(NewVaultDraft.conflictTitle($0)).tag($0) }
            }
            Picker("Interval", selection: $draft.intervalSeconds) {
                ForEach(NewVaultDraft.intervals, id: \.seconds) { Text($0.title).tag($0.seconds) }
            }
            TextField("Max remote index age (seconds)", text: $draft.maxIndexAge, prompt: Text("No limit"))
                .multilineTextAlignment(.trailing)
        } header: {
            Text("Sync")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if draft.indexAge == nil {
                    Text("The index age is whole seconds, or empty for no limit.").foregroundStyle(StatusTone.danger.color)
                }
                Text("\(NewVaultDraft.strategyHint(draft.strategy)) \(NewVaultDraft.conflictHint(draft.conflict))\(seededNote)")
                    .foregroundStyle(.fgSubtle)
            }
        }
    }

    private var seededNote: String {
        policy.value == nil ? "" : " Strategy and conflict policy start from this node's defaults for new S3 vaults."
    }

    private var guardrails: some View {
        Section {
            Picker("Per-run limits", selection: $draft.guardrails) {
                ForEach(NewVaultDraft.GuardrailPreset.allCases) { Text(NewVaultDraft.presetTitle($0)).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Request guardrails")
        } footer: {
            Text("\(NewVaultDraft.presetHint(draft.guardrails)) A run that would exceed one stops and reports it instead of running up the bill.")
                .foregroundStyle(.fgSubtle)
        }
    }

    // MARK: Behaviour

    private var strategyBinding: Binding<NewVaultDraft.Strategy> {
        Binding(get: { draft.strategy }, set: { draft.strategy = $0; draft.strategyChosen = true })
    }

    private var conflictBinding: Binding<NewVaultDraft.Conflict> {
        Binding(get: { draft.conflict }, set: { draft.conflict = $0; draft.conflictChosen = true })
    }

    /// New S3 vaults start from the operator's defaults, unless the person already chose.
    private func seedDefaults(_ value: Ws.Settings.Policy.Get.Response?) {
        guard let defaults = value?.policy.vaults.s3 else { return }
        if !draft.strategyChosen, let strategy = NewVaultDraft.Strategy(rawValue: defaults.defaultRemoteSyncStrategy) {
            draft.strategy = strategy
        }
        if !draft.conflictChosen, let conflict = NewVaultDraft.Conflict(rawValue: defaults.defaultRemoteConflictPolicy) {
            draft.conflict = conflict
        }
    }

    private var confirmationTitle: String {
        switch add.confirmation?.code {
        case "encryption_waiver": "Accept the encryption waiver?"
        case "upstream_adoption": "Adopt this bucket?"
        default: "Create the vault?"
        }
    }

    private var confirmationLabel: String {
        switch add.confirmation?.code {
        case "encryption_waiver": "Accept and Continue"
        case "upstream_adoption": "Adopt and Create"
        default: "Continue"
        }
    }

    private func create() async {
        if let response = await add.run(draft.payload(canProvision: canProvision)) {
            onCreated(response.vault)
            dismiss()
        }
    }

    #if DEBUG
    private func debugPrepare() {
        guard let raw = UserDefaults.standard.string(forKey: "VHDebugNewVault"), raw != "local" else { return }
        draft.type = .s3
        draft.name = "Project Archive"
        if raw == "adopt" {
            draft.apiKeyID = 1
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                draft.bucketMode = .adopt
            }
        }
    }
    #endif
}
