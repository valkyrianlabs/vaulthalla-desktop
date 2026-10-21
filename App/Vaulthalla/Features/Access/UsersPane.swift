import SwiftUI
import VHContract
import VHCore
import VHNodes

/// `auth.users.list` as a sortable, multi-select table. Double-click or Return opens the inspector; ⌫ asks to delete.
struct UsersPane: View {
    var node: Node
    var queries: NodeQueries
    var actor: AccessActor?
    var filter: String
    var showsSystem: Bool
    @Binding var selection: Set<Int64>
    var present: (AccessSheet) -> Void

    @State private var sortOrder = [KeyPathComparator(\UserRow.sortName)]
    @State private var deactivating: WsModel.UserSummary?
    @State private var update: NodeMutation<Ws.Auth.User.Update>

    init(node: Node, queries: NodeQueries, actor: AccessActor?, filter: String, showsSystem: Bool,
         selection: Binding<Set<Int64>>, present: @escaping (AccessSheet) -> Void) {
        self.node = node
        self.queries = queries
        self.actor = actor
        self.filter = filter
        self.showsSystem = showsSystem
        _selection = selection
        self.present = present
        _update = State(initialValue: NodeMutation(Ws.Auth.User.Update.self, on: queries, invalidating: UserCommands.all))
    }

    var body: some View {
        let list = queries.query(Ws.Auth.Users.List.self)
        let roles = queries.query(Ws.Roles.Admin.List.self)
        let rows = rows(list.value?.users ?? [], roles: roles.value?.roles)

        VStack(alignment: .leading, spacing: 0) {
            switch list.state {
            case .idle, .loading:
                LoadingPanel(subject: "users")
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .failed(let error):
                ProblemPanel(problem: QueryProblem(error), node: node, subject: "users") {
                    Task { await list.refresh() }
                }
                .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .loaded(let value, let at):
                StaleBanner(node: node, updatedAt: at, refreshError: list.refreshError, connected: queries.isConnected)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 12)
                if value.users.isEmpty {
                    Panel {
                        EmptyState("No users to show", systemImage: "person.2",
                                   message: "The node lists the accounts this Mac's account may view.")
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    Spacer(minLength: 0)
                } else {
                    table(rows)
                    MutationError(error: update.error)
                        .padding(Theme.pagePadding / 2)
                }
            }
        }
        .observing(list)
        .observing(roles)
        .confirmationDialog(deactivating.map { "Deactivate \($0.name)?" } ?? "", isPresented: isDeactivating,
                            titleVisibility: .visible, presenting: deactivating) { user in
            Button("Deactivate", role: .destructive) { Task { await setActive(user, false) } }
            Button("Cancel", role: .cancel) {}
        } message: { user in
            Text("\(user.name) is signed out everywhere and can't sign in until reactivated. Their vaults, groups and shares stay as they are.")
        }
    }

    // MARK: Table

    private func table(_ rows: [UserRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.sortName) { row in
                HStack(spacing: 10) {
                    AccountAvatar(name: row.user.name)
                    Text(row.user.name)
                        .foregroundStyle(row.user.isActive ? Color.fg : Color.fgMuted)
                        .lineLimit(1)
                    AccountBadges(user: row.user, selfID: actor?.id)
                }
                .padding(.vertical, 3)
            }
            .width(min: 180, ideal: 240)

            TableColumn("Email", value: \.sortEmail) { row in
                Text(row.user.email ?? "—")
                    .foregroundStyle(row.user.email == nil ? Color.fgFaint : Color.fgMuted)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 200)

            TableColumn("Admin Role", value: \.sortRole) { row in
                Text(AccessFormat.roleLabel(row.user.adminRole?.name))
                    .foregroundStyle(.fgMuted)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 130)

            TableColumn("Status", value: \.statusRank) { row in
                ActiveLabel(active: row.user.isActive)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Last Login", value: \.lastLogin) { row in
                Text(row.lastLoginText)
                    .foregroundStyle(row.user.lastLogin == nil ? Color.fgFaint : Color.fgMuted)
                    .monospacedDigit()
                    .help(Format.moment(iso: row.user.lastLogin) ?? "")
            }
            .width(min: 80, ideal: 100)

            TableColumn("Created", value: \.user.createdAt) { row in
                Text(Format.day(iso: row.user.createdAt) ?? row.user.createdAt)
                    .foregroundStyle(.fgSubtle)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int64.self) { ids in
            menu(rows.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let row = rows.first(where: { ids.contains($0.id) }), ids.count == 1, row.rules.profile.allowed {
                present(.editUser(row.user))
            }
        }
        .onDeleteCommand {
            if selection.count == 1, let row = rows.first(where: { selection.contains($0.id) }), row.rules.remove.allowed {
                present(.deleteUser(row.user))
            }
        }
    }

    @ViewBuilder
    private func menu(_ chosen: [UserRow]) -> some View {
        if chosen.count == 1, let row = chosen.first {
            Button("Edit…") { present(.editUser(row.user)) }
                .disabled(!row.rules.profile.allowed)
            Button("Reset Password…") { present(.resetPassword(row.user)) }
                .disabled(!row.rules.password.allowed)
            if row.user.isActive {
                Button("Deactivate…") { deactivating = row.user }
                    .disabled(!row.rules.active.allowed)
            } else {
                Button("Activate") { Task { await setActive(row.user, true) } }
                    .disabled(!row.rules.active.allowed)
            }
            Divider()
            Button("Add to Group…") { present(.addToGroup([row.user])) }
                .disabled(!canAddMembers)
            Divider()
            Button("Delete…", role: .destructive) { present(.deleteUser(row.user)) }
                .disabled(!row.rules.remove.allowed)
        } else if chosen.count > 1 {
            Button("Add \(chosen.count) Users to Group…") { present(.addToGroup(chosen.map(\.user))) }
                .disabled(!canAddMembers)
        }
    }

    private var canAddMembers: Bool {
        actor.map { $0.has("admin.identities.groups.add-member") } ?? true
    }

    private var isDeactivating: Binding<Bool> {
        Binding(get: { deactivating != nil }, set: { if !$0 { deactivating = nil } })
    }

    private func setActive(_ user: WsModel.UserSummary, _ active: Bool) async {
        await update.run(.init(id: .value(user.id), isActive: .value(active)))
    }

    // MARK: Rows

    private func rows(_ users: [WsModel.UserSummary], roles: [WsModel.AdminRole]?) -> [UserRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return users
            .filter { showsSystem || !$0.systemOnly }
            .filter { needle.isEmpty || $0.searchText.contains(needle) }
            .map { user in
                let permissions = roles?.first { $0.id == user.adminRole?.id }?.permissions
                return UserRow(user: user, rules: AccessRules.account(actor, AccountFacts(user), rolePermissions: permissions))
            }
            .sorted(using: sortOrder)
    }
}

/// The commands whose answers a change to an account makes stale.
enum UserCommands {
    static let all = ["auth.users", "auth.user", "groups.list", "group.get", "roles.admin"]
}

nonisolated struct UserRow: Identifiable {
    var user: WsModel.UserSummary
    var rules: AccountRules

    var id: Int64 { user.id }
    var sortName: String { user.name.lowercased() }
    /// Accounts without email sort last.
    var sortEmail: String { user.email?.lowercased() ?? "\u{10FFFF}" }
    var sortRole: String { user.adminRole?.name ?? "" }
    var statusRank: Int { user.isActive ? 0 : 1 }
    var lastLogin: String { user.lastLogin ?? "" }

    var lastLoginText: String {
        guard let date = Format.date(iso: user.lastLogin) else { return "Never" }
        return Format.relative(date)
    }
}

extension WsModel.UserSummary {
    var searchText: String {
        [name, email ?? "", adminRole?.name ?? "", AccessFormat.roleLabel(adminRole?.name)].joined(separator: " ").lowercased()
    }
}

/// "You", "System", "Protected" and the CLI binding, as the web shows them next to a name.
struct AccountBadges: View {
    var isSelf: Bool
    var systemOnly: Bool
    var isProtected: Bool
    var linuxUid: Int64?

    init(user: WsModel.UserSummary, selfID: Int64?) {
        isSelf = user.id == selfID
        systemOnly = user.systemOnly
        isProtected = user.isProtected
        linuxUid = user.linuxUid
    }

    init(user: WsModel.User, selfID: Int64?) {
        isSelf = user.id == selfID
        systemOnly = user.systemOnly
        isProtected = user.isProtected
        linuxUid = user.linuxUid
    }

    var body: some View {
        HStack(spacing: 4) {
            if isSelf { Pill(text: "You", accent: true) }
            if systemOnly {
                Pill(text: "System", help: "A service identity the daemon uses internally; it can't sign in")
            } else if isProtected {
                Pill(text: "Protected", help: "Changed only from the server with the vh CLI")
            }
            if let linuxUid, !systemOnly {
                Pill(text: "CLI · \(linuxUid)", help: "Bound to Linux UID \(linuxUid) for the vh CLI")
            }
        }
    }
}

struct ActiveLabel: View {
    var active: Bool

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(tone: active ? .ok : .unknown, size: 7)
            Text(active ? "Active" : "Inactive")
                .foregroundStyle(.fgMuted)
        }
    }
}

// MARK: - Inspector

struct UsersInspector: View {
    var node: Node
    var queries: NodeQueries
    var actor: AccessActor?
    var selection: Set<Int64>
    var present: (AccessSheet) -> Void

    var body: some View {
        if selection.count == 1, let id = selection.first {
            UserInspector(id: id, node: node, queries: queries, actor: actor, present: present)
                .id(id)
        } else if selection.count > 1 {
            let users = queries.query(Ws.Auth.Users.List.self).value?.users.filter { selection.contains($0.id) } ?? []
            EmptyState("\(selection.count) users selected", systemImage: "person.2",
                       message: "Add them to a group together, or select one to see its roles, groups and vault access.") {
                Button("Add to Group…") { present(.addToGroup(users)) }
                    .disabled(users.isEmpty || !(actor.map { $0.has("admin.identities.groups.add-member") } ?? true))
            }
            .frame(maxHeight: .infinity)
        } else {
            InspectorPlaceholder(title: "No user selected",
                                 message: "Select an account to see its admin role, groups and vault access.")
        }
    }
}

/// One account in full (`auth.user.get`): status, admin role, groups (`groups.list.byUser`) and vault roles.
private struct UserInspector: View {
    var id: Int64
    var node: Node
    var queries: NodeQueries
    var actor: AccessActor?
    var present: (AccessSheet) -> Void

    private static let termWidth: CGFloat = 112

    var body: some View {
        let detail = queries.query(Ws.Auth.User.Get.self, .init(id: id))
        let summary = queries.query(Ws.Auth.Users.List.self).value?.users.first { $0.id == id }
        let groups = queries.query(Ws.Groups.List.ByUser.self, .init(userID: id))

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch detail.state {
                case .idle, .loading:
                    ProgressView().controlSize(.small)
                case .failed(let error):
                    if let summary {
                        header(facts: AccountFacts(summary), name: summary.name, active: summary.isActive,
                               role: summary.adminRole?.name, summary: summary, permissions: nil)
                    }
                    InlineProblem(error: error, subject: "this account")
                case .loaded(let response, _):
                    let user = response.user
                    header(facts: AccountFacts(user), name: user.name, active: user.isActive, role: user.adminRole.name,
                           summary: summary, permissions: user.adminRole.permissions)
                    notices(user)
                    AccessInspectorSection("Details") {
                        DefinitionList(items: details(user), termWidth: Self.termWidth)
                    }
                    AccessInspectorSection("Admin role") {
                        adminRole(user.adminRole)
                    }
                    AccessInspectorSection("Groups") {
                        InlineQuery(query: groups, subject: "this account's groups") { response in
                            groupList(response.groups, summary: summary)
                        }
                    }
                    AccessInspectorSection("Vault access") {
                        VaultRolesList(user: user, queries: queries)
                    }
                }
            }
            .padding(16)
        }
        .observing(detail)
        .observing(groups)
    }

    private func header(facts: AccountFacts, name: String, active: Bool, role: String?,
                        summary: WsModel.UserSummary?, permissions: [WsModel.Permission]?) -> some View {
        let rules = AccessRules.account(actor, facts, rolePermissions: permissions)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AccountAvatar(name: name, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        StatusDot(tone: active ? .ok : .unknown, size: 6)
                        Text("\(active ? "Active" : "Inactive") · \(AccessFormat.roleLabel(role))")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }
            }
            if let summary {
                HStack(spacing: 8) {
                    Button("Edit…") { present(.editUser(summary)) }
                        .disabled(!rules.profile.allowed)
                    if !rules.isSelf {
                        Button("Reset Password…") { present(.resetPassword(summary)) }
                            .disabled(!rules.password.allowed)
                        Button("Delete…", role: .destructive) { present(.deleteUser(summary)) }
                            .disabled(!rules.remove.allowed)
                    }
                }
                .controlSize(.small)
                if !rules.isSelf, !rules.profile.allowed {
                    ReasonLabel(reason: rules.profile.reason)
                } else if !rules.isSelf, !rules.remove.allowed || !rules.password.allowed {
                    ReasonLabel(reason: rules.remove.reason ?? rules.password.reason)
                }
            }
        }
    }

    @ViewBuilder
    private func notices(_ user: WsModel.User) -> some View {
        if user.systemOnly {
            Callout(tone: .info, systemImage: "gearshape.2") {
                Text("System account").fontWeight(.semibold)
                Text("The daemon uses this identity internally. It can't sign in and is changed only from the server.")
                    .foregroundStyle(.fgMuted)
            }
        } else if user.isProtected {
            Callout(tone: .info, systemImage: "lock") {
                Text("Protected account").fontWeight(.semibold)
                Text("Bound to the server's CLI operator. Change it from the server with the vh CLI.")
                    .foregroundStyle(.fgMuted)
            }
        } else if user.id == actor?.id {
            Callout(tone: .info, systemImage: "person.crop.circle") {
                Text("The account this Mac acts for").fontWeight(.semibold)
                Text("You can edit its name and email. Its role and status can only be changed by another administrator.")
                    .foregroundStyle(.fgMuted)
            }
        }
    }

    private func details(_ user: WsModel.User) -> [(term: String, value: String)] {
        var items: [(term: String, value: String)] = [
            ("Email", user.email ?? "None"),
            ("Last login", Format.moment(iso: user.lastLogin) ?? "Never"),
            ("Created", Format.moment(iso: user.createdAt) ?? user.createdAt),
        ]
        if let createdBy = user.createdBy,
           let name = queries.query(Ws.Auth.Users.List.self).value?.users.first(where: { $0.id == createdBy })?.name {
            items.append(("Created by", name))
        }
        // Core doesn't persist password_changed_at yet; show it only when it's known.
        if let changed = Format.moment(iso: user.passwordChangedAt) { items.append(("Password set", changed)) }
        if !user.isActive, let deactivated = Format.moment(iso: user.deactivatedAt) {
            items.append(("Deactivated", deactivated))
        }
        items.append(("CLI login", user.linuxUid.map { "Linux UID \($0)" } ?? "Not bound"))
        items.append(("User ID", String(user.id)))
        return items
    }

    private func adminRole(_ role: WsModel.AdminRole) -> some View {
        let granted = role.permissions.filter { $0.value == true }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key")
                    .foregroundStyle(.accentText)
                Text(AccessFormat.roleLabel(role.name))
                    .foregroundStyle(.fg)
                if AccessRules.isBuiltin(.admin, role.name) { Pill(text: "Built-in") }
            }
            .font(.callout)
            if !role.description.isEmpty {
                Text(role.description)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !role.permissions.isEmpty {
                Text("\(granted) of \(role.permissions.count) admin permissions")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func groupList(_ groups: [WsModel.Group], summary: WsModel.UserSummary?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if groups.isEmpty {
                Text("Not a member of any group.")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
            } else {
                InspectorList {
                    ForEach(groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.id) { group in
                        InspectorRow(systemImage: "person.3", title: group.name, subtitle: group.description)
                        if group.id != groups.last?.id { Divider().opacity(0.4) }
                    }
                }
            }
            if let summary, actor.map({ $0.has("admin.identities.groups.add-member") }) ?? true {
                Button("Add to Group…") { present(.addToGroup([summary])) }
                    .controlSize(.small)
            }
        }
    }
}

/// The vault roles an account holds, directly or through a group (the web's VaultAccessPanel).
private struct VaultRolesList: View {
    var user: WsModel.User
    var queries: NodeQueries

    var body: some View {
        let vaults = queries.query(Ws.Storage.Vault.List.self)
        let groups = queries.query(Ws.Groups.List.self)
        let roles: [WsModel.VaultRole] = if case .array(let list) = user.vaultRoles { list } else { [] }

        Group {
            if roles.isEmpty {
                Text("No vault roles assigned to this account or its groups. Assign them from a vault's inspector.")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                InspectorList {
                    ForEach(Array(roles.enumerated()), id: \.offset) { index, role in
                        let vaultID = role.assignment.flatMap { Int64($0.vaultID) }
                        let vaultName = vaults.value?.vaults.first { $0.id == vaultID }?.name
                            ?? vaultID.map { "Vault #\($0)" } ?? "A vault"
                        let via: String? = if role.assignment?.subjectType == "group",
                                              let groupID = role.assignment.flatMap({ Int64($0.subjectID) }) {
                            "via " + (groups.value?.groups.first { $0.id == groupID }?.name ?? "group #\(groupID)")
                        } else { nil }
                        InspectorRow(systemImage: "lock.rectangle.stack", title: vaultName, subtitle: via) {
                            Pill(text: AccessFormat.roleLabel(role.name), accent: true, help: role.description)
                        }
                        if index < roles.count - 1 { Divider().opacity(0.4) }
                    }
                }
            }
        }
        .observing(vaults)
        .observing(groups)
    }
}
