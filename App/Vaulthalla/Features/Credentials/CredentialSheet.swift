import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Adds a provider credential (`storage.apiKey.add`) or edits one in place (`storage.apiKey.update`, sending only
/// what changed). The secret is typed once into a secure field, sent, and cleared from the form right after; it is
/// never shown, logged or read back. Editing with an empty secret keeps the stored one.
struct CredentialSheet: View {
    enum Mode: Identifiable {
        case create
        case edit(WsModel.APIKey)

        var id: String {
            switch self {
            case .create: "new"
            case .edit(let key): "edit-\(key.apiKeyID)"
            }
        }
    }

    var mode: Mode

    private typealias Provider = Ws.Storage.ApiKey.Add.Payload.Provider

    @State private var name: String
    @State private var provider: String
    @State private var endpoint: String
    @State private var region: String
    @State private var accessKey: String
    @State private var secret = ""
    @State private var add: NodeMutation<Ws.Storage.ApiKey.Add>
    @State private var update: NodeMutation<Ws.Storage.ApiKey.Update>
    @Environment(\.dismiss) private var dismiss

    init(mode: Mode, queries: NodeQueries) {
        self.mode = mode
        let key: WsModel.APIKey? = if case .edit(let key) = mode { key } else { nil }
        _name = State(initialValue: key?.name ?? "")
        _provider = State(initialValue: key?.provider ?? "")
        _endpoint = State(initialValue: key?.endpoint ?? "")
        _region = State(initialValue: key?.region ?? "")
        _accessKey = State(initialValue: key?.accessKey ?? "")
        _add = State(initialValue: NodeMutation(Ws.Storage.ApiKey.Add.self, on: queries, invalidating: ["storage.apiKey"]))
        _update = State(initialValue: NodeMutation(Ws.Storage.ApiKey.Update.self, on: queries,
                                                   invalidating: ["storage.apiKey", "storage.vault"]))
    }

    private var original: WsModel.APIKey? {
        if case .edit(let key) = mode { return key }
        return nil
    }

    private var trimmed: (name: String, endpoint: String, region: String, access: String) {
        (name.trimmingCharacters(in: .whitespacesAndNewlines), endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
         region.trimmingCharacters(in: .whitespacesAndNewlines), accessKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var endpointValid: Bool { trimmed.endpoint.wholeMatch(of: /(?i)https?:\/\/\S+/) != nil }

    private var valid: Bool {
        !trimmed.name.isEmpty && !provider.isEmpty && endpointValid && !trimmed.access.isEmpty
            && (original != nil || !secret.isEmpty)
    }

    private var changed: Bool {
        guard let original else { return true }
        let t = trimmed
        return t.name != original.name || provider != original.provider || t.endpoint != original.endpoint
            || t.region != original.region || t.access != original.accessKey || !secret.isEmpty
    }

    private var running: Bool { add.isRunning || update.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Provider", selection: $provider) {
                        if provider.isEmpty { Text("Choose…").tag("") }
                        ForEach(providers, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Endpoint URL", text: $endpoint, prompt: Text(hint.endpoint))
                        .autocorrectionDisabled()
                    TextField("Region", text: $region, prompt: Text(hint.region))
                        .autocorrectionDisabled()
                } header: {
                    Text(original.map { "Edit “\($0.name)”" } ?? "Add a provider credential")
                } footer: {
                    if !trimmed.endpoint.isEmpty, !endpointValid {
                        Text("Use the provider's full S3 API URL, such as https://s3.us-east-1.amazonaws.com.")
                            .foregroundStyle(StatusTone.danger.color)
                    } else {
                        Text(original == nil
                             ? "The node checks the key against the provider before saving it. An empty region means “auto” (Cloudflare R2)."
                             : "Changes apply in place: vaults that use this credential keep working with the new values.")
                            .foregroundStyle(.fgSubtle)
                    }
                }

                Section {
                    TextField("Access key ID", text: $accessKey)
                        .autocorrectionDisabled()
                    SecureField(original == nil ? "Secret access key" : "New secret access key", text: $secret,
                                prompt: Text(original == nil ? "Required" : "Unchanged"))
                } header: {
                    Text("Access key")
                } footer: {
                    Text(original == nil
                         ? "The secret is sent to the node once and never shown again."
                         : "Leave the secret empty to keep the stored one. Type a new one only to rotate it.")
                        .foregroundStyle(.fgSubtle)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(running)

            MutationError(error: add.error ?? update.error)
                .padding(.horizontal, 20)

            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text(original == nil ? "Checking with the provider…" : "Saving…")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add Credential" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!valid || !changed || running)
            }
            .padding(20)
        }
        .frame(width: 500)
        .serverConfirmation(add, title: "Add the credential?", confirmLabel: "Add")
        .serverConfirmation(update, title: "Save the credential?", confirmLabel: "Save")
        .interactiveDismissDisabled(running)
        .onDisappear { secret = "" }
    }

    /// The providers the daemon accepts, plus the current one when a newer daemon sent another.
    private var providers: [String] {
        let known = Provider.allCases.map(\.rawValue)
        return known.contains(provider) || provider.isEmpty ? known : known + [provider]
    }

    /// Placeholders only, never saved.
    private var hint: (endpoint: String, region: String) {
        switch provider {
        case Provider.aws.rawValue: ("https://s3.us-east-1.amazonaws.com", "us-east-1")
        case Provider.cloudflareR2.rawValue: ("https://<account-id>.r2.cloudflarestorage.com", "auto")
        case Provider.wasabi.rawValue: ("https://s3.us-east-1.wasabisys.com", "us-east-1")
        case Provider.backblazeB2.rawValue: ("https://s3.us-west-004.backblazeb2.com", "us-west-004")
        case Provider.digitalOcean.rawValue: ("https://nyc3.digitaloceanspaces.com", "nyc3")
        case Provider.minIO.rawValue: ("https://minio.example.com", "us-east-1")
        default: ("https://", "auto")
        }
    }

    private func save() async {
        let t = trimmed
        // The secret leaves the form with this request; nothing keeps it afterwards.
        let typedSecret = secret
        secret = ""
        if let original {
            var payload = Ws.Storage.ApiKey.Update.Payload(id: original.apiKeyID)
            if t.name != original.name { payload.name = .value(t.name) }
            if provider != original.provider, let chosen = Ws.Storage.ApiKey.Update.Payload.Provider(rawValue: provider) {
                payload.provider = .value(chosen)
            }
            if t.endpoint != original.endpoint { payload.endpoint = .value(t.endpoint) }
            if t.region != original.region { payload.region = .value(t.region) }
            if t.access != original.accessKey { payload.accessKey = .value(t.access) }
            if !typedSecret.isEmpty { payload.secretAccessKey = .value(typedSecret) }
            add.reset()
            if await update.run(payload) != nil { dismiss() }
        } else {
            guard let chosen = Provider(rawValue: provider) else { return }
            let payload = Ws.Storage.ApiKey.Add.Payload(
                name: t.name, provider: chosen, accessKey: t.access, secretAccessKey: typedSecret, endpoint: t.endpoint,
                region: t.region.isEmpty ? nil : t.region)
            update.reset()
            if await add.run(payload) != nil { dismiss() }
        }
    }
}
