import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Who holds a role on one vault (`roles.vault.list.assigned`), for the Vaults inspector: assign, change and remove
/// vault roles, and each assignment's path overrides. The entry point the Vaults feature embeds.
struct VaultAccessSection: View {
    var vaultID: Int64
    var vaultName: String
    var queries: NodeQueries

    @State private var assigning = false
    @State private var changing: VaultAssignment?
    @State private var overridesFor: VaultAssignment?
    @State private var unassigning: VaultAssignment?
    @State private var unassign: NodeMutation<Ws.Role.Vault.Unassign>

    init(vaultID: Int64, vaultName: String, queries: NodeQueries) {
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.queries = queries
        _unassign = State(initialValue: NodeMutation(Ws.Role.Vault.Unassign.self, on: queries,
                                                     invalidating: VaultAccessCommands.all))
    }

    var body: some View {
        let assigned = queries.query(Ws.Roles.Vault.List.Assigned.self, .init(id: vaultID))
        let names = SubjectNames(queries: queries)

        VStack(alignment: .leading, spacing: 10) {
            InlineQuery(query: assigned, subject: "this vault's access") { response in
                let rows = VaultAssignment.rows(response.assignedRoles, names: names)
                if rows.isEmpty {
                    Text("Nobody has a role on this vault yet. The owner and administrators can always reach it.")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    InspectorList {
                        ForEach(rows) { row in
                            InspectorRow(systemImage: row.subject.systemImage, title: row.label,
                                         subtitle: row.subject == .group ? "Group" : nil) {
                                Pill(text: AccessFormat.roleLabel(row.role.name), accent: true, help: row.role.description)
                                Menu {
                                    menu(row)
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuStyle(.button)
                                .buttonStyle(.borderless)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Actions for \(row.label)")
                            }
                            .contextMenu { menu(row) }
                            if row.id != rows.last?.id { Divider().opacity(0.4) }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Assign Role…") { assigning = true }
                if let value = assigned.value?.assignedRoles, !value.isEmpty {
                    Text(summary(VaultAssignment.rows(value, names: names)))
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                }
            }
            .controlSize(.small)
            MutationError(error: unassign.error)
        }
        .observing(assigned)
        .observing(names.users)
        .observing(names.groups)
        .sheet(isPresented: $assigning) {
            AssignVaultRoleSheet(vaultID: vaultID, vaultName: vaultName, changing: nil,
                                 existing: VaultAssignment.rows(assigned.value?.assignedRoles ?? [], names: names),
                                 queries: queries)
        }
        .sheet(item: $changing) { row in
            AssignVaultRoleSheet(vaultID: vaultID, vaultName: vaultName, changing: row, existing: [], queries: queries)
        }
        .sheet(item: $overridesFor) { row in
            OverridesSheet(vaultID: vaultID, vaultName: vaultName, row: row, queries: queries)
        }
        .confirmationDialog(unassigning.map { "Remove \($0.label)'s access?" } ?? "", isPresented: isUnassigning,
                            titleVisibility: .visible, presenting: unassigning) { row in
            Button("Remove Access", role: .destructive) {
                Task {
                    await unassign.run(.init(vaultID: vaultID, subjectType: row.subject.unassign,
                                             subjectID: row.subjectID))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { row in
            Text("\(row.label) loses the “\(AccessFormat.roleLabel(row.role.name))” role on \(vaultName), and any permission overrides on it. Access through other roles or groups is unaffected.")
        }
        #if DEBUG
        .task { await debugOpen(assigned) }
        #endif
    }

    @ViewBuilder
    private func menu(_ row: VaultAssignment) -> some View {
        Button("Permission Overrides…") { overridesFor = row }
        Button("Change Role…") { changing = row }
        Divider()
        Button("Remove Access…", role: .destructive) { unassigning = row }
    }

    private func summary(_ rows: [VaultAssignment]) -> String {
        let users = rows.filter { $0.subject == .user }.count
        let groups = rows.count - users
        return "\(AccessFormat.count(users, "user")) · \(AccessFormat.count(groups, "group"))"
    }

    private var isUnassigning: Binding<Bool> {
        Binding(get: { unassigning != nil }, set: { if !$0 { unassigning = nil } })
    }

    #if DEBUG
    /// `-VHDebugVaultAccess assign|overrides` opens a sheet for the selected vault (DebugSnapshot).
    private func debugOpen(_ assigned: NodeQuery<Ws.Roles.Vault.List.Assigned>) async {
        guard let which = UserDefaults.standard.string(forKey: "VHDebugVaultAccess") else { return }
        await assigned.refreshIfStale()
        try? await Task.sleep(for: .milliseconds(300))
        let rows = VaultAssignment.rows(assigned.value?.assignedRoles ?? [], names: SubjectNames(queries: queries))
        switch which {
        case "assign": assigning = true
        case "overrides": overridesFor = rows.first
        default: break
        }
    }
    #endif
}

enum VaultAccessCommands {
    static let all = ["roles.vault.list.assigned", "role.vault.overrides", "auth.user"]
}

/// User and group names for assignment rows; empty when this account can't list them.
@MainActor
struct SubjectNames {
    let users: NodeQuery<Ws.Auth.Users.List>
    let groups: NodeQuery<Ws.Groups.List>

    init(queries: NodeQueries) {
        users = queries.query(Ws.Auth.Users.List.self)
        groups = queries.query(Ws.Groups.List.self)
    }

    func name(_ subject: VaultAssignment.Subject, _ id: Int64) -> String? {
        switch subject {
        case .user: users.value?.users.first { $0.id == id }?.name
        case .group: groups.value?.groups.first { $0.id == id }?.name
        }
    }
}

/// One subject's role on a vault.
struct VaultAssignment: Identifiable {
    enum Subject: String, CaseIterable, Identifiable {
        case user, group

        var id: Self { self }
        var systemImage: String { self == .user ? "person" : "person.3" }
        var assign: Ws.Role.Vault.Assign.Payload.SubjectType { self == .user ? .user : .group }
        var unassign: Ws.Role.Vault.Unassign.Payload.SubjectType { self == .user ? .user : .group }
        var overridesList: Ws.Role.Vault.Overrides.List.Payload.SubjectType { self == .user ? .user : .group }
        var overridesAdd: Ws.Role.Vault.Overrides.Add.Payload.SubjectType { self == .user ? .user : .group }
        var overridesUpdate: Ws.Role.Vault.Overrides.Update.Payload.SubjectType { self == .user ? .user : .group }
        var overridesRemove: Ws.Role.Vault.Overrides.Remove.Payload.SubjectType { self == .user ? .user : .group }
    }

    var subject: Subject
    var subjectID: Int64
    var name: String?
    var role: WsModel.VaultRole

    var id: String { "\(subject.rawValue)-\(subjectID)" }
    var label: String { name ?? "\(subject == .user ? "User" : "Group") #\(subjectID)" }

    static func rows(_ roles: [WsModel.VaultRole], names: SubjectNames) -> [VaultAssignment] {
        roles.compactMap { role in
            guard let assignment = role.assignment, let subject = Subject(rawValue: assignment.subjectType),
                  let id = Int64(assignment.subjectID) else { return nil }
            return VaultAssignment(subject: subject, subjectID: id, name: names.name(subject, id), role: role)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}

// MARK: - Assign

/// Assign a vault role to a user or group on this vault, or change an assignment's role (the daemon upserts).
private struct AssignVaultRoleSheet: View {
    var vaultID: Int64
    var vaultName: String
    var changing: VaultAssignment?
    var existing: [VaultAssignment]

    @State private var subject: VaultAssignment.Subject
    @State private var subjectID: Int64?
    @State private var typedID = ""
    @State private var roleID: Int64?
    @State private var assign: NodeMutation<Ws.Role.Vault.Assign>
    private let roles: NodeQuery<Ws.Roles.Vault.List>
    private let names: SubjectNames
    @Environment(\.dismiss) private var dismiss

    init(vaultID: Int64, vaultName: String, changing: VaultAssignment?, existing: [VaultAssignment],
         queries: NodeQueries) {
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.changing = changing
        self.existing = existing
        roles = queries.query(Ws.Roles.Vault.List.self)
        names = SubjectNames(queries: queries)
        _subject = State(initialValue: changing?.subject ?? .user)
        _subjectID = State(initialValue: changing?.subjectID)
        _roleID = State(initialValue: changing?.role.id)
        _assign = State(initialValue: NodeMutation(Ws.Role.Vault.Assign.self, on: queries,
                                                   invalidating: VaultAccessCommands.all))
    }

    private struct Candidate: Identifiable {
        var id: Int64
        var name: String
        var detail: String?
    }

    /// nil when this account can't list subjects of the kind: the id is typed instead.
    private var candidates: [Candidate]? {
        let taken = Set(existing.filter { $0.subject == subject }.map(\.subjectID))
        switch subject {
        case .user:
            guard let users = names.users.value?.users else { return nil }
            return users.filter { !$0.systemOnly && !taken.contains($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { Candidate(id: $0.id, name: $0.name, detail: $0.email) }
        case .group:
            guard let groups = names.groups.value?.groups else { return nil }
            return groups.filter { !taken.contains($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { Candidate(id: $0.id, name: $0.name, detail: AccessFormat.count($0.members.count, "member")) }
        }
    }

    private var chosenSubject: Int64? { candidates == nil ? Int64(typedID) : subjectID }

    var body: some View {
        let role = roles.value?.roles.first { $0.id == roleID }
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(title: changing.map { "Change \($0.label)'s Role" } ?? "Assign a Vault Role",
                       systemImage: "person.badge.key",
                       subtitle: changing.map { "The new role replaces “\(AccessFormat.roleLabel($0.role.name))” on \(vaultName). Overrides stay." }
                           ?? "Give a user or group a role on \(vaultName).")
                .padding([.horizontal, .top], 22)

            Form {
                if changing == nil {
                    Section {
                        Picker("Assign to", selection: $subject) {
                            Text("User").tag(VaultAssignment.Subject.user)
                            Text("Group").tag(VaultAssignment.Subject.group)
                        }
                        .pickerStyle(.segmented)
                        if let candidates {
                            Picker(subject == .user ? "User" : "Group", selection: $subjectID) {
                                Text(candidates.isEmpty ? "Every \(subject.rawValue) already has a role here" : "Choose…")
                                    .tag(Int64?.none)
                                ForEach(candidates) { candidate in
                                    Text(candidate.detail.map { "\(candidate.name) · \($0)" } ?? candidate.name)
                                        .tag(Int64?.some(candidate.id))
                                }
                            }
                        } else {
                            TextField(subject == .user ? "User ID" : "Group ID", text: $typedID)
                                .monospacedDigit()
                            Text("Your role can't list \(subject.rawValue)s, so enter the id.")
                                .font(.caption)
                                .foregroundStyle(.fgSubtle)
                        }
                    }
                }
                Section {
                    switch roles.state {
                    case .idle, .loading:
                        LabeledContent("Vault role") { ProgressView().controlSize(.small) }
                    case .failed(let error):
                        InlineProblem(error: error, subject: "vault roles")
                    case .loaded(let response, _):
                        Picker("Vault role", selection: $roleID) {
                            Text("Choose…").tag(Int64?.none)
                            ForEach(response.roles.sorted { $0.name < $1.name }, id: \.id) { role in
                                Text("\(AccessFormat.roleLabel(role.name)) (\(role.permissions.filter { $0.value == true }.count) permissions)")
                                    .tag(Int64?.some(role.id))
                            }
                        }
                    }
                } footer: {
                    if let role {
                        VStack(alignment: .leading, spacing: 6) {
                            if !role.description.isEmpty {
                                Text(role.description).foregroundStyle(.fgSubtle)
                            }
                            RoleGrants(role: role)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onChange(of: subject) {
                subjectID = nil
                typedID = ""
            }

            MutationError(error: assign.error)
                .padding(.horizontal, 20)

            SheetButtons(primary: changing == nil ? "Assign" : "Change Role", running: assign.isRunning,
                         enabled: chosenSubject != nil && roleID != nil) {
                guard let id = chosenSubject, let roleID else { return }
                Task {
                    if await assign.run(.init(vaultID: vaultID, subjectType: subject.assign, subjectID: id,
                                              id: roleID)) != nil {
                        dismiss()
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 500)
        .observing(roles)
        .observing(names.users)
        .observing(names.groups)
    }
}

/// What a vault role allows, by area, so nobody assigns blind.
private struct RoleGrants: View {
    var role: WsModel.VaultRole

    var body: some View {
        let values = PermissionCatalog.snapshot(role.permissions)
        let groups = PermissionCatalog.groups(.vault, role.permissions)
            .map { group in (group.label, group.items.filter { values[$0.qualified] == true }.map(\.label)) }
            .filter { !$0.1.isEmpty }
        if groups.isEmpty {
            Text("This role grants no permissions.").foregroundStyle(.fgSubtle)
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(groups, id: \.0) { label, leaves in
                    GridRow {
                        Text(label).foregroundStyle(.fgSubtle)
                        Text(leaves.joined(separator: ", ")).foregroundStyle(.fgMuted)
                    }
                }
            }
            .font(.caption)
        }
    }
}

// MARK: - Overrides

/// Path-scoped allow/deny overrides on one assignment: "deny downloads under /finance/**" on top of the role.
private struct OverridesSheet: View {
    var vaultID: Int64
    var vaultName: String
    var row: VaultAssignment

    @State private var removing: WsModel.PermissionOverride?
    @State private var permission = ""
    @State private var effect = Ws.Role.Vault.Overrides.Update.Payload.Effect.deny
    @State private var pattern = "/"
    @State private var update: NodeMutation<Ws.Role.Vault.Overrides.Update>
    @State private var remove: NodeMutation<Ws.Role.Vault.Overrides.Remove>
    @State private var add: NodeMutation<Ws.Role.Vault.Overrides.Add>
    private let overrides: NodeQuery<Ws.Role.Vault.Overrides.List>
    private let catalog: NodeQuery<Ws.Permissions.List>
    @Environment(\.dismiss) private var dismiss

    init(vaultID: Int64, vaultName: String, row: VaultAssignment, queries: NodeQueries) {
        self.vaultID = vaultID
        self.vaultName = vaultName
        self.row = row
        overrides = queries.query(Ws.Role.Vault.Overrides.List.self,
                                  .init(vaultID: vaultID, subjectType: row.subject.overridesList, subjectID: row.subjectID))
        catalog = queries.query(Ws.Permissions.List.self)
        let invalidating = ["role.vault.overrides"]
        _update = State(initialValue: NodeMutation(Ws.Role.Vault.Overrides.Update.self, on: queries, invalidating: invalidating))
        _remove = State(initialValue: NodeMutation(Ws.Role.Vault.Overrides.Remove.self, on: queries, invalidating: invalidating))
        _add = State(initialValue: NodeMutation(Ws.Role.Vault.Overrides.Add.self, on: queries, invalidating: invalidating))
    }

    private var trimmedPattern: String { pattern.trimmingCharacters(in: .whitespaces) }
    private var patternProblem: String? {
        !trimmedPattern.isEmpty && !trimmedPattern.hasPrefix("/") ? "Start with / (vault-relative), e.g. /docs/**" : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: "Overrides for \(row.label)", systemImage: "slider.horizontal.3",
                       subtitle: "On top of the “\(AccessFormat.roleLabel(row.role.name))” role in \(vaultName). A matching override wins over the role.")

            switch overrides.state {
            case .idle, .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
            case .failed(let error):
                if error.message.localizedCaseInsensitiveContains("unknown command") {
                    Callout(tone: .info, systemImage: "terminal") {
                        Text("This node can't manage overrides remotely yet. Use `vh vault role override` on the host, or upgrade Vaulthalla.")
                    }
                } else {
                    InlineProblem(error: error, subject: "this assignment's overrides")
                }
            case .loaded(let response, _):
                list(response.overrides)
                addForm
            }

            MutationError(error: update.error ?? remove.error)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 600)
        .observing(overrides)
        .observing(catalog)
        .confirmationDialog("Remove this override?", isPresented: isRemoving, titleVisibility: .visible,
                            presenting: removing) { item in
            Button("Remove Override", role: .destructive) {
                Task {
                    await remove.run(.init(vaultID: vaultID, subjectType: row.subject.overridesRemove,
                                           subjectID: row.subjectID, overrideID: item.id))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(PermissionCatalog.longLabel(.vault, item.permission.qualified)) on \(item.globPath) goes back to what the role allows.")
        }
    }

    @ViewBuilder
    private func list(_ items: [WsModel.PermissionOverride]) -> some View {
        if items.isEmpty {
            Text("No overrides: the role alone decides.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
        } else {
            InspectorList {
                ForEach(items, id: \.id) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PermissionCatalog.longLabel(.vault, item.permission.qualified))
                                .foregroundStyle(item.enabled ? Color.fg : Color.fgSubtle)
                                .help(item.permission.description)
                            Text(item.globPath.isEmpty ? "/" : item.globPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.fgSubtle)
                        }
                        Spacer(minLength: 0)
                        Picker("Effect", selection: effectBinding(item)) {
                            Text("Allow").tag(WsModel.PermissionOverride.Effect.allow)
                            Text("Deny").tag(WsModel.PermissionOverride.Effect.deny)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Toggle("Enabled", isOn: enabledBinding(item))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .help(item.enabled ? "Turn this override off" : "Turn this override on")
                        Button("Remove", systemImage: "trash") { removing = item }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.fgSubtle)
                            .help("Remove this override")
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if item.id != items.last?.id { Divider().opacity(0.4) }
                }
            }
            .disabled(update.isRunning || remove.isRunning)
        }
    }

    private var addForm: some View {
        let fsPermissions = (catalog.value?.permissions ?? []).filter { $0.qualified.hasPrefix("vault.fs.") }
        let chosen = fsPermissions.first { $0.qualified == permission }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Add an override")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.fg)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Permission").foregroundStyle(.fgSubtle)
                    Picker("Permission", selection: $permission) {
                        Text(catalog.value == nil ? "Loading…" : "Choose a file or folder permission…").tag("")
                        ForEach(fsPermissions, id: \.qualified) { item in
                            Text(PermissionCatalog.longLabel(.vault, item.qualified)).tag(item.qualified)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Effect").foregroundStyle(.fgSubtle)
                    Picker("Effect", selection: $effect) {
                        Text("Deny").tag(Ws.Role.Vault.Overrides.Update.Payload.Effect.deny)
                        Text("Allow").tag(Ws.Role.Vault.Overrides.Update.Payload.Effect.allow)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Path pattern").foregroundStyle(.fgSubtle)
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Path pattern", text: $pattern, prompt: Text("/docs/**"))
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                            .labelsHidden()
                        Text(patternProblem ?? chosen?.description ?? "Vault-relative glob: /docs/**, /finance/*.csv")
                            .font(.caption)
                            .foregroundStyle(patternProblem == nil ? Color.fgSubtle : StatusTone.danger.color)
                    }
                }
            }
            .font(.callout)
            MutationError(error: add.error)
            HStack {
                Spacer()
                Button("Add Override") { Task { await addOverride() } }
                    .disabled(permission.isEmpty || trimmedPattern.isEmpty || patternProblem != nil || add.isRunning)
            }
        }
        .padding(14)
        .panelSurface(radius: Theme.radiusCard)
    }

    private func addOverride() async {
        let payload = Ws.Role.Vault.Overrides.Add.Payload(
            vaultID: vaultID, subjectType: row.subject.overridesAdd, subjectID: row.subjectID,
            permissions: [.init(qualified: permission, value: effect == .allow)], pattern: trimmedPattern, enabled: true)
        if await add.run(payload) != nil {
            permission = ""
            pattern = "/"
        }
    }

    private func patch(_ item: WsModel.PermissionOverride, effect: String? = nil, enabled: Bool? = nil) {
        var payload = Ws.Role.Vault.Overrides.Update.Payload(
            vaultID: vaultID, subjectType: row.subject.overridesUpdate, subjectID: row.subjectID, overrideID: item.id)
        if let effect, let value = Ws.Role.Vault.Overrides.Update.Payload.Effect(rawValue: effect) {
            payload.effect = .value(value)
        }
        if let enabled { payload.enabled = .value(enabled) }
        Task { await update.run(payload) }
    }

    private func effectBinding(_ item: WsModel.PermissionOverride) -> Binding<String> {
        Binding(get: { item.effect }, set: { patch(item, effect: $0) })
    }

    private func enabledBinding(_ item: WsModel.PermissionOverride) -> Binding<Bool> {
        Binding(get: { item.enabled }, set: { patch(item, enabled: $0) })
    }

    private var isRemoving: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }
}
