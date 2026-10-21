import SwiftUI
import VHContract
import VHCore
import VHNodes

/// The admin role picker for creating and editing accounts: every role from `roles.admin.list`, with the ones this
/// account can't assign disabled and labelled with the reason. Without `admin.roles.admin.view` it is a name field.
private struct AdminRolePicker: View {
    @Binding var role: String
    var queries: NodeQueries
    var actor: AccessActor?
    var verb: AccessRules.Verb
    /// The account's current role: always selectable (keeping it is no change).
    var current: String?
    var disabled = false

    var body: some View {
        let roles = queries.query(Ws.Roles.Admin.List.self)
        Group {
            switch roles.state {
            case .idle, .loading:
                LabeledContent("Admin role") { ProgressView().controlSize(.small) }
            case .failed:
                TextField("Admin role", text: $role, prompt: Text("Role name, e.g. unprivileged"))
                    .disabled(disabled)
            case .loaded(let response, _):
                Picker("Admin role", selection: $role) {
                    if role.isEmpty { Text("Choose a role…").tag("") }
                    if !role.isEmpty, !response.roles.contains(where: { $0.name == role }) {
                        Text(AccessFormat.roleLabel(role)).tag(role)
                    }
                    ForEach(response.roles.sorted { $0.name < $1.name }, id: \.id) { option in
                        let verdict = option.name == current ? Verdict.ok : AccessRules.assign(actor, option, verb)
                        Text(AccessFormat.roleLabel(option.name) + (verdict.allowed ? "" : " — \(verdict.reason ?? "not allowed")"))
                            .tag(option.name)
                            .selectionDisabled(!verdict.allowed)
                    }
                }
                .disabled(disabled)
            }
        }
        .observing(roles)
    }
}

/// The selected admin role's description and size, under the picker.
private struct AdminRoleSummary: View {
    var name: String
    var queries: NodeQueries

    var body: some View {
        if let role = queries.query(Ws.Roles.Admin.List.self).value?.roles.first(where: { $0.name == name }) {
            let granted = role.permissions.filter { $0.value == true }.count
            Text("\(role.description.isEmpty ? "" : role.description + " ")(\(granted) of \(role.permissions.count) admin permissions)")
                .foregroundStyle(.fgSubtle)
        }
    }
}

/// A field's client-side problem, under it.
struct FieldProblem: View {
    var text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.caption)
                .foregroundStyle(StatusTone.danger.color)
        }
    }
}

/// Cancel and the primary action, at the bottom of a sheet.
struct SheetButtons: View {
    var primary: String
    var role: ButtonRole?
    var running: Bool
    var enabled: Bool
    var action: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            if running { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(primary, role: role, action: action)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(role == .destructive ? StatusTone.danger.color : nil)
                .disabled(!enabled || running)
        }
    }
}

// MARK: - New user

/// `auth.register`: name, optional email, password, admin role and whether it may sign in yet.
struct NewUserSheet: View {
    var queries: NodeQueries
    var actor: AccessActor?
    var onCreated: (WsModel.User) -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var role = ""
    @State private var active = true
    @State private var submitted = false
    @State private var create: NodeMutation<Ws.Auth.Register>
    @Environment(\.dismiss) private var dismiss

    init(queries: NodeQueries, actor: AccessActor?, onCreated: @escaping (WsModel.User) -> Void) {
        self.queries = queries
        self.actor = actor
        self.onCreated = onCreated
        _create = State(initialValue: NodeMutation(Ws.Auth.Register.self, on: queries, invalidating: UserCommands.all))
    }

    private var problems: (name: String?, email: String?, password: String?, confirm: String?, role: String?) {
        (AccessRules.nameProblem(name), AccessRules.emailProblem(email), AccessRules.passwordProblem(password),
         confirm == password ? nil : "Passwords don't match",
         role.trimmingCharacters(in: .whitespaces).isEmpty ? "Choose an admin role" : nil)
    }

    private var valid: Bool {
        let p = problems
        return p.name == nil && p.email == nil && p.password == nil && p.confirm == nil && p.role == nil
    }

    var body: some View {
        let p = problems
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(title: "New User", systemImage: "person.badge.plus",
                       subtitle: "The account signs in with this name and password. Add it to groups and vaults afterwards.")
                .padding([.horizontal, .top], 22)

            Form {
                Section("Profile") {
                    TextField("Username", text: $name, prompt: Text("3 to 50 characters"))
                    if submitted { FieldProblem(text: p.name) }
                    TextField("Email", text: $email, prompt: Text("Optional"))
                    if submitted { FieldProblem(text: p.email) }
                }
                Section {
                    SecureField("Password", text: $password)
                    if submitted { FieldProblem(text: p.password) }
                    SecureField("Confirm", text: $confirm)
                    if submitted { FieldProblem(text: p.confirm) }
                } header: {
                    Text("Password")
                } footer: {
                    Text("Share it over a trusted channel. Weak or breached passwords are refused by the node.")
                        .foregroundStyle(.fgSubtle)
                }
                Section {
                    AdminRolePicker(role: $role, queries: queries, actor: actor, verb: .add)
                    if submitted { FieldProblem(text: p.role) }
                    Toggle("Active", isOn: $active)
                } header: {
                    Text("Access")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        AdminRoleSummary(name: role, queries: queries)
                        Text(active ? "The account can sign in as soon as it's created."
                                    : "The account exists but can't sign in until you activate it.")
                            .foregroundStyle(.fgSubtle)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            MutationError(error: create.error)
                .padding(.horizontal, 20)

            SheetButtons(primary: active ? "Create User" : "Create Inactive User", running: create.isRunning,
                         enabled: true) {
                submitted = true
                guard valid else { return }
                Task { await submit() }
            }
            .padding(20)
        }
        .frame(width: 500)
        .task {
            // Default to the unprivileged role once the list arrives.
            let roles = queries.query(Ws.Roles.Admin.List.self)
            await roles.refreshIfStale()
            if role.isEmpty, roles.value?.roles.contains(where: { $0.name == "unprivileged" }) == true {
                role = "unprivileged"
            }
        }
        .serverConfirmation(create, title: "Create the account?", confirmLabel: "Create")
    }

    private func submit() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        let payload = Ws.Auth.Register.Payload(
            name: name.trimmingCharacters(in: .whitespaces), email: trimmedEmail.isEmpty ? nil : trimmedEmail,
            password: password, isActive: active, role: role.trimmingCharacters(in: .whitespaces))
        if let response = await create.run(payload) {
            onCreated(response.user)
            dismiss()
        }
    }
}

// MARK: - Edit user

/// `auth.user.update` with only what changed: name and email, the admin role, whether the account may sign in.
/// A role change or deactivation signs the account out everywhere, so it is confirmed first.
struct EditUserSheet: View {
    var user: WsModel.UserSummary
    var queries: NodeQueries
    var actor: AccessActor?

    @State private var name: String
    @State private var email: String
    @State private var role: String
    @State private var active: Bool
    @State private var submitted = false
    @State private var confirmingSignOut = false
    @State private var update: NodeMutation<Ws.Auth.User.Update>
    @Environment(\.dismiss) private var dismiss

    init(user: WsModel.UserSummary, queries: NodeQueries, actor: AccessActor?) {
        self.user = user
        self.queries = queries
        self.actor = actor
        _name = State(initialValue: user.name)
        _email = State(initialValue: user.email ?? "")
        _role = State(initialValue: user.adminRole?.name ?? "")
        _active = State(initialValue: user.isActive)
        _update = State(initialValue: NodeMutation(Ws.Auth.User.Update.self, on: queries, invalidating: UserCommands.all))
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }
    private var roleChanged: Bool { !role.isEmpty && role != (user.adminRole?.name ?? "") }
    private var changed: Bool {
        trimmedName != user.name || trimmedEmail != (user.email ?? "") || roleChanged || active != user.isActive
    }
    private var problem: String? {
        (trimmedName != user.name ? AccessRules.nameProblem(name) : nil) ?? AccessRules.emailProblem(email)
    }

    var body: some View {
        let permissions = queries.query(Ws.Roles.Admin.List.self).value?.roles.first { $0.id == user.adminRole?.id }?.permissions
        let rules = AccessRules.account(actor, AccountFacts(user), rolePermissions: permissions)

        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(title: "Edit \(user.name)", systemImage: "person.crop.circle")
                .padding([.horizontal, .top], 22)

            Form {
                Section {
                    TextField("Username", text: $name)
                        .disabled(!rules.rename.allowed)
                    TextField("Email", text: $email, prompt: Text("No email"))
                        .disabled(!rules.profile.allowed)
                    if submitted { FieldProblem(text: problem) }
                } header: {
                    Text("Profile")
                } footer: {
                    ReasonLabel(reason: rules.profile.allowed ? rules.rename.reason : rules.profile.reason)
                }
                Section {
                    AdminRolePicker(role: $role, queries: queries, actor: actor, verb: .edit, current: user.adminRole?.name,
                                    disabled: !rules.role.allowed)
                    Toggle("Active", isOn: $active)
                        .disabled(!rules.active.allowed)
                } header: {
                    Text("Admin role and status")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        AdminRoleSummary(name: role, queries: queries)
                        if !rules.role.allowed {
                            ReasonLabel(reason: rules.role.reason)
                        } else {
                            Text("Changing the role or deactivating the account signs it out everywhere.")
                                .foregroundStyle(.fgSubtle)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            MutationError(error: update.error)
                .padding(.horizontal, 20)

            SheetButtons(primary: "Save", running: update.isRunning, enabled: changed) {
                submitted = true
                guard problem == nil else { return }
                if roleChanged || (user.isActive && !active) {
                    confirmingSignOut = true
                } else {
                    Task { await save() }
                }
            }
            .padding(20)
        }
        .frame(width: 500)
        .confirmationDialog(signOutTitle, isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button(roleChanged ? "Change Role" : "Deactivate", role: roleChanged ? nil : .destructive) {
                Task { await save() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(roleChanged
                 ? "\(user.name) is signed out everywhere and gets the new role's permissions at the next sign-in."
                 : "\(user.name) is signed out everywhere and can't sign in until reactivated. Their vaults, groups and shares stay as they are.")
        }
        .serverConfirmation(update, title: "Save the change?", confirmLabel: "Save")
    }

    private var signOutTitle: String {
        roleChanged ? "Make \(user.name) \(AccessFormat.roleLabel(role))?" : "Deactivate \(user.name)?"
    }

    private func save() async {
        var payload = Ws.Auth.User.Update.Payload(id: .value(user.id))
        if trimmedName != user.name { payload.name = .value(trimmedName) }
        if trimmedEmail != (user.email ?? "") { payload.email = trimmedEmail.isEmpty ? .null : .value(trimmedEmail) }
        if roleChanged { payload.role = role }
        if active != user.isActive { payload.isActive = .value(active) }
        if await update.run(payload) != nil { dismiss() }
    }
}

// MARK: - Reset password

/// `auth.user.change_password` for another account: a new password, no old one. Its sessions end.
struct ResetPasswordSheet: View {
    var user: WsModel.UserSummary

    @State private var password = ""
    @State private var confirm = ""
    @State private var submitted = false
    @State private var reset: NodeMutation<Ws.Auth.User.ChangePassword>
    @Environment(\.dismiss) private var dismiss

    init(user: WsModel.UserSummary, queries: NodeQueries) {
        self.user = user
        _reset = State(initialValue: NodeMutation(Ws.Auth.User.ChangePassword.self, on: queries,
                                                  invalidating: ["auth.users", "auth.user"]))
    }

    private var problem: String? {
        AccessRules.passwordProblem(password) ?? (confirm == password ? nil : "Passwords don't match")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(title: "Reset \(user.name)'s Password", systemImage: "key",
                       subtitle: "Set a new password and give it to them over a trusted channel. Every session they have open ends.")
                .padding([.horizontal, .top], 22)

            Form {
                Section {
                    SecureField("New password", text: $password)
                    SecureField("Confirm", text: $confirm)
                    if submitted { FieldProblem(text: problem) }
                } footer: {
                    Text("Weak or breached passwords are refused by the node.")
                        .foregroundStyle(.fgSubtle)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            MutationError(error: reset.error)
                .padding(.horizontal, 20)

            SheetButtons(primary: "Reset Password", running: reset.isRunning, enabled: !password.isEmpty) {
                submitted = true
                guard problem == nil else { return }
                Task {
                    if await reset.run(.init(id: user.id, newPassword: password)) != nil { dismiss() }
                }
            }
            .padding(20)
        }
        .frame(width: 460)
        .serverConfirmation(reset, title: "Reset the password?", confirmLabel: "Reset")
    }
}

// MARK: - Delete user

/// Server-driven delete (the web's DeleteUserDialog): an unconfirmed `auth.user.delete` is refused with
/// `user_delete` and the exact question to ask, naming the vaults that go with the account. The question is asked
/// again whenever the heir changes; deleting resends the refused payload with the acceptance.
struct DeleteUserSheet: View {
    var user: WsModel.UserSummary
    var node: Node
    var onDeleted: () -> Void

    @State private var transferTo: Int64?
    @State private var remove: NodeMutation<Ws.Auth.User.Delete>
    private let users: NodeQuery<Ws.Auth.Users.List>
    @Environment(\.dismiss) private var dismiss

    init(user: WsModel.UserSummary, node: Node, queries: NodeQueries, onDeleted: @escaping () -> Void) {
        self.user = user
        self.node = node
        self.onDeleted = onDeleted
        users = queries.query(Ws.Auth.Users.List.self)
        _remove = State(initialValue: NodeMutation(
            Ws.Auth.User.Delete.self, on: queries,
            invalidating: UserCommands.all + ["storage.vault", "stats.system.storage", "roles.vault"]))
    }

    private var heirs: [WsModel.UserSummary] {
        (users.value?.users ?? [])
            .filter { $0.id != user.id && $0.isActive && !$0.systemOnly }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let question = remove.confirmation
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: "Delete \(user.name)?", systemImage: "trash", tone: .danger)

            Group {
                if let question {
                    let lines = question.message.split(separator: "\n", maxSplits: 1).map(String.init)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lines.first ?? question.message)
                            .foregroundStyle(.fgMuted)
                        if lines.count > 1 {
                            Text(lines[1])
                                .foregroundStyle(.fg)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.surface2, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                        }
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                } else if remove.error == nil {
                    ProgressView("Asking \(node.displayName) what deleting the account would do…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Their vaults", selection: $transferTo) {
                    Text("Destroy them").tag(Int64?.none)
                    ForEach(heirs, id: \.id) { heir in
                        Text("Transfer to \(heir.name)").tag(Int64?.some(heir.id))
                    }
                }
                .disabled(remove.isRunning)
                Text(transferTo == nil ? "Every vault this account owns is destroyed with it."
                                       : "Ownership moves to this account before the user is deleted.")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }

            MutationError(error: remove.error)

            SheetButtons(primary: "Delete User", role: .destructive, running: remove.isRunning, enabled: question != nil) {
                guard let question else { return }
                Task {
                    if await remove.confirm(question) != nil {
                        onDeleted()
                        dismiss()
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 500)
        .observing(users)
        // Ask the daemon (again) whenever the heir changes: its question names who gets the vaults.
        .task(id: transferTo) { await ask() }
        .interactiveDismissDisabled(remove.isRunning)
    }

    private func ask() async {
        remove.reset()
        let payload = Ws.Auth.User.Delete.Payload(id: user.id, transferTo: transferTo.map { .value($0) })
        // A daemon without the confirmation step deletes outright.
        if await remove.run(payload) != nil {
            onDeleted()
            dismiss()
        }
    }
}

// MARK: - Add to group

/// Adds one or more accounts to a group (`group.member.add` for each one not yet in it).
struct AddToGroupSheet: View {
    var users: [WsModel.UserSummary]

    @State private var groupID: Int64?
    @State private var running = false
    @State private var failures: [String] = []
    @State private var add: NodeMutation<Ws.Group.Member.Add>
    private let groups: NodeQuery<Ws.Groups.List>
    @Environment(\.dismiss) private var dismiss

    init(users: [WsModel.UserSummary], queries: NodeQueries) {
        self.users = users
        groups = queries.query(Ws.Groups.List.self)
        _add = State(initialValue: NodeMutation(Ws.Group.Member.Add.self, on: queries, invalidating: GroupCommands.all))
    }

    private var title: String {
        users.count == 1 ? "Add \(users[0].name) to a Group" : "Add \(users.count) Users to a Group"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: title, systemImage: "person.3",
                       subtitle: "Vault roles granted to the group apply to every member.")

            switch groups.state {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .failed(let error):
                InlineProblem(error: error, subject: "groups")
            case .loaded(let response, _):
                if response.groups.isEmpty {
                    Text("There are no groups yet. Create one on the Groups tab.")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                } else {
                    Picker("Group", selection: $groupID) {
                        Text("Choose a group…").tag(Int64?.none)
                        ForEach(response.groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                                id: \.id) { group in
                            Text("\(group.name) (\(AccessFormat.count(group.members.count, "member")))").tag(Int64?.some(group.id))
                        }
                    }
                    if let group = response.groups.first(where: { $0.id == groupID }) {
                        let already = users.filter { user in group.members.contains { $0.user?.id == user.id } }
                        if !already.isEmpty {
                            Text("Already members: \(already.map(\.name).joined(separator: ", ")).")
                                .font(.caption)
                                .foregroundStyle(.fgSubtle)
                        }
                    }
                }
            }

            if !failures.isEmpty {
                Callout(tone: .warn, systemImage: "exclamationmark.circle") {
                    ForEach(failures, id: \.self) { Text($0) }
                }
            }

            SheetButtons(primary: "Add", running: running, enabled: groupID != nil) {
                Task { await submit() }
            }
        }
        .padding(22)
        .frame(width: 460)
        .observing(groups)
    }

    private func submit() async {
        guard let groupID, let group = groups.value?.groups.first(where: { $0.id == groupID }) else { return }
        running = true
        failures = []
        for user in users where !group.members.contains(where: { $0.user?.id == user.id }) {
            if await add.run(.init(groupID: groupID, userID: user.id)) == nil, let error = add.error {
                failures.append("\(user.name): \(error.message)")
            }
        }
        running = false
        if failures.isEmpty { dismiss() }
    }
}
