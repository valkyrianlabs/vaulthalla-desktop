import SwiftUI
import VHContract
import VHCore
import VHNodes

/// A file or folder to share, picked from `fs.dir.list`.
struct ShareTarget: Hashable {
    var entryID: Int64
    var path: String
    var name: String
    var isDirectory: Bool
}

/// Create a link the way the web console's share dialog does (features/shares/ShareDialog.tsx): pick a file or
/// folder, a preset (link type, operations and the matching seeded role template), who may open it (only the kinds
/// `settings.policy.get` allows), a label and an expiry. The daemon checks every delegated permission and refuses
/// with its own words; the address comes back once.
struct CreateShareSheet: View {
    var node: Node
    var queries: NodeQueries
    var policy: SharingPolicy
    var onCreated: (WsModel.ShareLink, IssuedLink) -> Void

    @State private var vaultID: Int64?
    @State private var folder = "/"
    @State private var target: ShareTarget?
    @State private var preset = SharePreset.access
    @State private var access = Ws.Share.Link.Create.Payload.AccessMode.public
    @State private var label = ""
    @State private var expires = false
    @State private var expiry = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var limitDownloads = false
    @State private var maxDownloads = 10
    @State private var recipients: [String] = []
    @State private var recipientEmail = ""
    @State private var roleID: Int64?
    @State private var created: (share: WsModel.ShareLink, link: IssuedLink)?
    @State private var create: NodeMutation<Ws.Share.Link.Create>
    @Environment(\.dismiss) private var dismiss

    init(node: Node, queries: NodeQueries, policy: SharingPolicy, initialVault: Int64?,
         onCreated: @escaping (WsModel.ShareLink, IssuedLink) -> Void) {
        self.node = node
        self.queries = queries
        self.policy = policy
        self.onCreated = onCreated
        _vaultID = State(initialValue: initialVault)
        _access = State(initialValue: policy.modes.first ?? .public)
        _create = State(initialValue: NodeMutation(Ws.Share.Link.Create.self, on: queries, invalidating: ["share.link"]))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let created {
                done(created.share, created.link)
            } else if policy.loaded && policy.modes.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("New Share Link")
                        .font(.title3.weight(.semibold))
                    Callout(tone: .warn, systemImage: "link.badge.plus") {
                        Text(policy.notice ?? "Sharing is turned off on this node.")
                    }
                    HStack {
                        Spacer()
                        Button("Close") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(22)
            } else {
                form
            }
        }
        .frame(width: 600)
        .serverConfirmation(create, title: "Create the link?", confirmLabel: "Create")
        .interactiveDismissDisabled(create.isRunning)
    }

    // MARK: Form

    private var vaults: [WsModel.Vault] {
        (queries.query(Ws.Storage.Vault.List.self).value?.vaults ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var form: some View {
        let roles = queries.query(Ws.Roles.Vault.List.self)
        let vaultList = queries.query(Ws.Storage.Vault.List.self)
        return VStack(alignment: .leading, spacing: 0) {
            Text("New Share Link")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 22)
            Form {
                Section("What to share") {
                    Picker("Vault", selection: $vaultID) {
                        if vaults.isEmpty { Text("No vaults").tag(Int64?.none) }
                        ForEach(vaults, id: \.id) { vault in
                            Text(vault.name).tag(Int64?.some(vault.id))
                        }
                    }
                    .onChange(of: vaultID) {
                        folder = "/"
                        target = nil
                    }
                    if let vaultID {
                        ShareTargetBrowser(queries: queries, vaultID: vaultID, folder: $folder, target: $target)
                    }
                }

                Section("What can people do?") {
                    Picker("Preset", selection: $preset) {
                        ForEach(SharePreset.allCases) { preset in
                            VStack(alignment: .leading, spacing: 1) {
                                Label(preset.title, systemImage: preset.systemImage)
                                Text(preset.directoriesOnly && target?.isDirectory == false ? "Folders only" : preset.summary)
                                    .font(.caption)
                                    .foregroundStyle(.fgSubtle)
                            }
                            .tag(preset)
                            .selectionDisabled(preset.directoriesOnly && target?.isDirectory == false)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                Section("Link") {
                    TextField("Label recipients see", text: $label)
                    Toggle("Expires", isOn: $expires)
                    if expires {
                        DatePicker("Stops working", selection: $expiry, in: Date.now...)
                    }
                    Toggle("Limit downloads", isOn: $limitDownloads)
                    if limitDownloads {
                        Stepper(value: $maxDownloads, in: 1...100_000) {
                            TextField("Downloads", value: $maxDownloads, format: .number)
                        }
                    }
                }

                Section {
                    Picker("Who can open it", selection: $access) {
                        ForEach(policy.modes, id: \.self) { mode in
                            Text(ShareAccess.title(mode.rawValue)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    if access == .emailValidated {
                        recipientsEditor
                    }
                } header: {
                    Text("Who can open it")
                } footer: {
                    if policy.modes.count < 2 {
                        Text("Other kinds of link are turned off on this node.")
                            .foregroundStyle(.fgSubtle)
                    }
                }

                Section {
                    DisclosureGroup("Role template") {
                        switch roles.state {
                        case .loaded(let value, _):
                            Picker("Vault role for recipients", selection: $roleID) {
                                Text("Preset default (\(Format.words(preset.roleName)))").tag(Int64?.none)
                                ForEach(value.roles, id: \.id) { role in
                                    Text(Format.words(role.name)).tag(Int64?.some(role.id))
                                }
                            }
                        case .failed(let error):
                            InlineProblem(error: error, subject: "the vault roles; the preset's role is used")
                        case .idle, .loading:
                            ProgressView().controlSize(.small)
                        }
                    }
                } footer: {
                    Text("Presets apply the matching built-in role template. You need every permission the role grants.")
                        .foregroundStyle(.fgSubtle)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 520)

            MutationError(error: create.error)
                .padding(.horizontal, 20)

            HStack {
                if create.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Link") { Task { await submit(roles: roles.value?.roles) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!ready)
            }
            .padding(20)
        }
        .observing(roles)
        .observing(vaultList)
        .task(id: vaults.map(\.id)) {
            if vaultID == nil || !vaults.contains(where: { $0.id == vaultID }) { vaultID = vaults.first?.id }
        }
        .onChange(of: target) { _, target in
            guard let target else { return }
            if label.isEmpty || label == previousName { label = target.name }
            previousName = target.name
            if preset.directoriesOnly && !target.isDirectory { preset = .download }
        }
    }

    @State private var previousName = ""

    private var recipientsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recipients confirm a code sent to their inbox before the link opens.")
                .font(.caption)
                .foregroundStyle(.fgSubtle)
            HStack {
                TextField("person@example.com", text: $recipientEmail)
                    .onSubmit(addRecipient)
                Button("Add", action: addRecipient)
                    .disabled(!recipientEmail.contains("@"))
            }
            if !recipients.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(recipients, id: \.self) { email in
                        HStack(spacing: 4) {
                            Text(email)
                            Button {
                                recipients.removeAll { $0 == email }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.fgSubtle)
                            .accessibilityLabel("Remove \(email)")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.surface2, in: Capsule())
                        .overlay { Capsule().strokeBorder(.line) }
                    }
                }
            }
        }
    }

    private func addRecipient() {
        let email = recipientEmail.trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { return }
        recipients.removeAll { $0.caseInsensitiveCompare(email) == .orderedSame }
        recipients.append(email)
        recipientEmail = ""
    }

    private var ready: Bool {
        guard let target, vaultID != nil, !create.isRunning else { return false }
        if preset.directoriesOnly && !target.isDirectory { return false }
        return !label.trimmingCharacters(in: .whitespaces).isEmpty && policy.modes.contains(access)
    }

    // MARK: Done

    private func done(_ share: WsModel.ShareLink, _ link: IssuedLink) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Link created")
                .font(.title3.weight(.semibold))
            IssuedLinkPanel(title: ShareRow.title(of: share), link: link, node: node)
            HStack {
                Spacer()
                Button("Create Another") {
                    created = nil
                    create.reset()
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
    }

    // MARK: Submit

    private func submit(roles: [WsModel.VaultRole]?) async {
        guard let target, let vaultID else { return }
        typealias Payload = Ws.Share.Link.Create.Payload
        let name = label.trimmingCharacters(in: .whitespaces)
        // The preset's seeded template by id when the roles are readable, by name otherwise; the daemon resolves it.
        let role: Payload.PublicRoleAssignment
        let presetRole = roles?.first { $0.name == preset.roleName }
        if let id = roleID ?? presetRole?.id {
            role = .init(vaultRoleID: .value(id))
        } else {
            role = .init(vaultRoleName: .value(preset.roleName))
        }
        let recipientRole = Payload.RecipientRoleAssignment.RoleAssignment(
            vaultRoleID: role.vaultRoleID, vaultRoleName: role.vaultRoleName)
        let payload = Payload(
            vaultID: vaultID, rootEntryID: target.entryID, rootPath: target.path,
            targetType: target.isDirectory ? .directory : .file, linkType: preset.linkType, accessMode: access,
            allowedOps: .array(preset.operations(isDirectory: target.isDirectory).map(\.payloadItem)),
            name: .value(name), publicLabel: .value(name),
            expiresAt: expires ? .value(.string(expiry.formatted(.iso8601))) : .null,
            maxDownloads: limitDownloads ? .value(Int64(maxDownloads)) : nil,
            duplicatePolicy: .value(.reject), publicRoleAssignment: .value(role),
            recipientRoleAssignments: .value(access == .emailValidated
                ? recipients.map { .init(email: $0, roleAssignment: recipientRole) } : []))
        guard let response = await create.run(payload) else { return }
        let link = IssuedLink(path: response.publicURLPath, origin: await queries.shareLinkOrigin())
        created = (response.share, link)
        onCreated(response.share, link)
    }
}

/// Browses a vault with `fs.dir.list` to pick the file or folder to share. Double-click opens a folder.
private struct ShareTargetBrowser: View {
    var queries: NodeQueries
    var vaultID: Int64
    @Binding var folder: String
    @Binding var target: ShareTarget?

    var body: some View {
        let listing = queries.query(Ws.Fs.Dir.List.self, .init(vaultID: vaultID, path: folder))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button("Enclosing Folder", systemImage: "chevron.up") { folder = Self.parent(of: folder) }
                    .labelStyle(.iconOnly)
                    .disabled(folder == "/")
                    .help("Enclosing folder")
                Text(folder)
                    .font(.callout.monospaced())
                    .foregroundStyle(.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    switch listing.state {
                    case .idle, .loading:
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    case .failed(let error):
                        InlineProblem(error: error, subject: "this folder")
                            .padding(8)
                    case .loaded(let value, _):
                        let here = ShareTarget(entryID: value.entry.id, path: value.path,
                                               name: folder == "/" ? value.vault : value.entry.name, isDirectory: true)
                        row(here, title: folder == "/" ? "The whole vault" : "This folder", icon: "folder.fill",
                            emphasized: true)
                        ForEach(value.files.filter { !$0.isSystem }.sorted(by: Self.order), id: \.id) { entry in
                            let isDirectory = entry.type == WsModel.FsEntry.TypeValue.directory
                            row(ShareTarget(entryID: entry.id, path: entry.path, name: entry.name, isDirectory: isDirectory),
                                title: entry.name, icon: isDirectory ? "folder" : "doc")
                                .onTapGesture(count: 2) {
                                    if isDirectory { folder = entry.path }
                                }
                        }
                    }
                }
                .padding(4)
            }
            .frame(height: 170)
            .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(.line) }
            Text(target.map { "Sharing \($0.isDirectory ? "folder" : "file") \($0.path)" }
                 ?? "Select a file or folder. Double-click a folder to open it.")
                .font(.caption)
                .foregroundStyle(.fgSubtle)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .observing(listing)
    }

    private func row(_ candidate: ShareTarget, title: String, icon: String, emphasized: Bool = false) -> some View {
        let selected = target == candidate
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(candidate.isDirectory ? Color.accentText : Color.fgSubtle)
                .frame(width: 18)
            Text(title)
                .fontWeight(emphasized ? .medium : .regular)
                .foregroundStyle(.fg)
                .lineLimit(1)
            Spacer(minLength: 0)
            if candidate.isDirectory && !emphasized {
                Image(systemName: "chevron.forward")
                    .font(.caption2)
                    .foregroundStyle(.fgFaint)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { target = candidate }
    }

    private static func order(_ a: WsModel.FsEntry, _ b: WsModel.FsEntry) -> Bool {
        let aDir = a.type == WsModel.FsEntry.TypeValue.directory
        let bDir = b.type == WsModel.FsEntry.TypeValue.directory
        if aDir != bDir { return aDir }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private static func parent(of path: String) -> String {
        var parts = path.split(separator: "/")
        guard !parts.isEmpty else { return "/" }
        parts.removeLast()
        return "/" + parts.joined(separator: "/")
    }
}

/// Change a link's label, description, expiry, download limit or who may open it (`share.link.update` with only
/// the changed members). What it shares and its role stay; recipients aren't readable back, so they aren't touched.
struct EditShareSheet: View {
    var row: ShareRow
    var policy: SharingPolicy

    typealias Payload = Ws.Share.Link.Update.Payload

    @State private var label: String
    @State private var summary: String
    @State private var expires: Bool
    @State private var expiry: Date
    @State private var limitDownloads: Bool
    @State private var maxDownloads: Int
    @State private var access: Payload.AccessMode?
    @State private var update: NodeMutation<Ws.Share.Link.Update>
    @Environment(\.dismiss) private var dismiss

    private let original: (label: String, summary: String, expiry: Date?, maxDownloads: Int64?)

    init(row: ShareRow, queries: NodeQueries, policy: SharingPolicy) {
        self.row = row
        self.policy = policy
        let share = row.share
        let label = share.publicLabel ?? share.name ?? ""
        let expiry = Format.date(iso: share.expiresAt)
        original = (label, share.description ?? "", expiry, share.maxDownloads)
        _label = State(initialValue: label)
        _summary = State(initialValue: share.description ?? "")
        _expires = State(initialValue: expiry != nil)
        _expiry = State(initialValue: expiry ?? Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now)
        _limitDownloads = State(initialValue: share.maxDownloads != nil)
        _maxDownloads = State(initialValue: Int(share.maxDownloads ?? max(10, share.downloadCount + 1)))
        _access = State(initialValue: Payload.AccessMode(rawValue: share.accessMode))
        _update = State(initialValue: NodeMutation(Ws.Share.Link.Update.self, on: queries, invalidating: ["share.link"]))
    }

    /// The modes offered: the ones the policy allows, plus the link's own (an update can't move a link into a
    /// disabled kind, but it may stay where it is).
    private var modes: [Payload.AccessMode] {
        var modes = policy.modes.compactMap { Payload.AccessMode(rawValue: $0.rawValue) }
        if let current = Payload.AccessMode(rawValue: row.share.accessMode), !modes.contains(current) {
            modes.append(current)
        }
        return modes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Label recipients see", text: $label)
                    TextField("Description", text: $summary, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Edit “\(row.title)”")
                } footer: {
                    Text("\(row.kindTitle) of \(row.share.rootPath) in \(row.vaultName). What a link shares can't change; create a new link instead.")
                        .foregroundStyle(.fgSubtle)
                }

                Section("Limits") {
                    Toggle("Expires", isOn: $expires)
                    if expires {
                        DatePicker("Stops working", selection: $expiry)
                    }
                    Toggle("Limit downloads", isOn: $limitDownloads)
                    if limitDownloads {
                        Stepper(value: $maxDownloads, in: 1...100_000) {
                            TextField("Downloads", value: $maxDownloads, format: .number)
                        }
                        Text("\(row.share.downloadCount.formatted()) used so far.")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }

                if modes.count > 1 {
                    Section {
                        Picker("Who can open it", selection: $access) {
                            ForEach(modes, id: \.self) { mode in
                                Text(ShareAccess.title(mode.rawValue)).tag(Payload.AccessMode?.some(mode))
                            }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        if access == .emailValidated && row.share.accessMode != Payload.AccessMode.emailValidated.rawValue {
                            Text("Verified-email links open only for recipients. Add them from the web console's share dialog.")
                                .foregroundStyle(.fgSubtle)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            MutationError(error: update.error)
                .padding(.horizontal, 20)

            HStack {
                if update.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(patch == nil || trimmedLabel.isEmpty || update.isRunning)
            }
            .padding(20)
        }
        .frame(width: 500)
        .serverConfirmation(update, title: "Save the change?", confirmLabel: "Save")
        .interactiveDismissDisabled(update.isRunning)
    }

    private var trimmedLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Only what changed, or nil when nothing did.
    private var patch: Payload? {
        var payload = Payload(id: row.id)
        var changed = false
        if trimmedLabel != original.label {
            payload.name = .value(trimmedLabel)
            payload.publicLabel = .value(trimmedLabel)
            changed = true
        }
        if summary != original.summary {
            payload.description = summary.isEmpty ? .null : .value(summary)
            changed = true
        }
        let newExpiry = expires ? expiry : nil
        if newExpiry.map({ Int($0.timeIntervalSince1970) }) != original.expiry.map({ Int($0.timeIntervalSince1970) }) {
            payload.expiresAt = newExpiry.map { .value(.string($0.formatted(.iso8601))) } ?? .null
            changed = true
        }
        let newLimit = limitDownloads ? Int64(maxDownloads) : nil
        if newLimit != original.maxDownloads {
            payload.maxDownloads = newLimit.map { .value($0) } ?? .null
            changed = true
        }
        if let access, access.rawValue != row.share.accessMode {
            payload.accessMode = .value(access)
            changed = true
        }
        return changed ? payload : nil
    }

    private func save() async {
        guard let patch else { return }
        if await update.run(patch) != nil { dismiss() }
    }
}
