import SwiftUI
import VHContract
import VHCore
import VHNodes

/// What admin and vault role definitions have in common.
nonisolated protocol RoleRecord: Sendable {
    var id: Int64 { get }
    var name: String { get }
    var description: String { get }
    var permissions: [WsModel.Permission] { get }
    var updatedAt: Int64 { get }
}

extension WsModel.AdminRole: RoleRecord {}
extension WsModel.VaultRole: RoleRecord {}

/// The commands whose answers a change to a role makes stale.
enum RoleCommands {
    static let all = ["roles.admin", "roles.vault", "role.admin", "role.vault", "auth.users", "auth.user"]
}

nonisolated struct RoleRow: Identifiable {
    var role: any RoleRecord
    var kind: RoleKind
    /// Accounts holding an admin role; nil when unknown (vault roles, or users not readable).
    var holders: Int?

    var id: Int64 { role.id }
    var sortName: String { role.name }
    var granted: Int { role.permissions.filter { $0.value == true }.count }
    var holderSort: Int { holders ?? -1 }
    var updated: Int64 { role.updatedAt }
    var isBuiltin: Bool { AccessRules.isBuiltin(kind, role.name) }
}

/// `roles.admin.list` or `roles.vault.list` as a sortable table.
struct RolesPane: View {
    var node: Node
    var queries: NodeQueries
    var actor: AccessActor?
    var kind: RoleKind
    var filter: String
    @Binding var selection: Int64?
    var present: (AccessSheet) -> Void

    @State private var sortOrder = [KeyPathComparator(\RoleRow.sortName)]

    var body: some View {
        switch kind {
        case .admin: pane(queries.query(Ws.Roles.Admin.List.self)) { $0.roles }
        case .vault: pane(queries.query(Ws.Roles.Vault.List.self)) { $0.roles }
        }
    }

    private func pane<R: WsRequest>(_ list: NodeQuery<R>, roles: @escaping (R.Response) -> [any RoleRecord]) -> some View {
        let users = queries.query(Ws.Auth.Users.List.self)
        let rows = rows(list.value.map(roles) ?? [], users: kind == .admin ? users.value?.users : nil)
        return VStack(alignment: .leading, spacing: 0) {
            switch list.state {
            case .idle, .loading:
                LoadingPanel(subject: "\(kind.rawValue) roles")
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .failed(let error):
                ProblemPanel(problem: QueryProblem(error), node: node, subject: "\(kind.rawValue) roles") {
                    Task { await list.refresh() }
                }
                .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .loaded(_, let at):
                StaleBanner(node: node, updatedAt: at, refreshError: list.refreshError, connected: queries.isConnected)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 12)
                table(rows)
            }
        }
        .observing(list)
        .observing(users)
    }

    private func table(_ rows: [RoleRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Role", value: \.sortName) { row in
                HStack(spacing: 8) {
                    Image(systemName: kind == .admin ? "person.badge.key" : "lock.shield")
                        .foregroundStyle(.accentText)
                        .frame(width: 22)
                    Text(AccessFormat.roleLabel(row.role.name))
                        .foregroundStyle(.fg)
                        .lineLimit(1)
                    if row.isBuiltin { Pill(text: "Built-in") }
                }
                .padding(.vertical, 3)
            }
            .width(min: 160, ideal: 220)

            TableColumn("Description") { row in
                Text(row.role.description.isEmpty ? "—" : row.role.description)
                    .foregroundStyle(row.role.description.isEmpty ? Color.fgFaint : Color.fgSubtle)
                    .lineLimit(1)
                    .help(row.role.description)
            }
            .width(min: 160, ideal: 300)

            TableColumn("Permissions", value: \.granted) { row in
                PermissionMeter(granted: row.granted, total: row.role.permissions.count)
            }
            .width(min: 110, ideal: 130)

            TableColumn("Accounts", value: \.holderSort) { row in
                Text(row.holders.map(String.init) ?? "—")
                    .foregroundStyle(row.holders == nil ? Color.fgFaint : Color.fgMuted)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            .defaultVisibility(kind == .admin ? .visible : .hidden)

            TableColumn("Updated", value: \.updated) { row in
                Text(AccessFormat.day(epoch: row.role.updatedAt) ?? "—")
                    .foregroundStyle(.fgSubtle)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                let rules = AccessRules.roleEdit(actor, kind, roleName: row.role.name)
                Button(rules.edit.allowed ? "Edit Permissions…" : "View Permissions…") {
                    present(.editRole(kind, row.id))
                }
                if actor.map({ $0.has("admin.roles.\(kind.rawValue).add") }) ?? true {
                    Button("New Role…") { present(.newRole(kind)) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { present(.editRole(kind, id)) }
        }
    }

    private func rows(_ roles: [any RoleRecord], users: [WsModel.UserSummary]?) -> [RoleRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var holders: [Int64: Int] = [:]
        for user in users ?? [] {
            if let id = user.adminRole?.id { holders[id, default: 0] += 1 }
        }
        return roles
            .filter { role in
                needle.isEmpty || "\(role.name) \(AccessFormat.roleLabel(role.name)) \(role.description)".lowercased().contains(needle)
            }
            .map { RoleRow(role: $0, kind: kind, holders: users == nil ? nil : holders[$0.id] ?? 0) }
            .sorted(using: sortOrder)
    }
}

/// "12 / 40" with a small bar.
struct PermissionMeter: View {
    var granted: Int
    var total: Int

    var body: some View {
        if total == 0 {
            Text("—").foregroundStyle(.fgFaint)
        } else {
            HStack(spacing: 8) {
                Capsule()
                    .fill(.surface3)
                    .frame(width: 44, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.accentFill)
                            .frame(width: 44 * Double(granted) / Double(total), height: 4)
                    }
                HStack(spacing: 0) {
                    Text("\(granted)")
                        .foregroundStyle(.fgMuted)
                    Text(" / \(total)")
                        .foregroundStyle(.fgFaint)
                }
            }
            .monospacedDigit()
            .help("\(granted) of \(total) permissions granted")
        }
    }
}

// MARK: - Inspector

struct RoleInspectorHost: View {
    var queries: NodeQueries
    var actor: AccessActor?
    var kind: RoleKind
    var selection: Int64?
    var present: (AccessSheet) -> Void

    var body: some View {
        let role: (any RoleRecord)? = switch kind {
        case .admin: queries.query(Ws.Roles.Admin.List.self).value?.roles.first { $0.id == selection }
        case .vault: queries.query(Ws.Roles.Vault.List.self).value?.roles.first { $0.id == selection }
        }
        if let role {
            RoleInspector(role: role, kind: kind, queries: queries, actor: actor, present: present)
                .id(role.id)
        } else {
            InspectorPlaceholder(title: "No role selected",
                                 message: "Select a role to see what it grants and who holds it.")
        }
    }
}

private struct RoleInspector: View {
    var role: any RoleRecord
    var kind: RoleKind
    var queries: NodeQueries
    var actor: AccessActor?
    var present: (AccessSheet) -> Void

    @State private var deleting = false

    var body: some View {
        let rules = AccessRules.roleEdit(actor, kind, roleName: role.name)
        let users = queries.query(Ws.Auth.Users.List.self).value?.users
        let holders = (users ?? []).filter { $0.adminRole?.id == role.id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let blocked = kind == .admin && !holders.isEmpty
            ? "Assigned to \(AccessFormat.count(holders.count, "account")). Move them to another role first." : nil

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: kind == .admin ? "person.badge.key" : "lock.shield")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.accentText)
                            .frame(width: 34, height: 34)
                            .background(.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(AccessFormat.roleLabel(role.name))
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.fg)
                                if AccessRules.isBuiltin(kind, role.name) { Pill(text: "Built-in") }
                            }
                            Text(role.name)
                                .font(.caption.monospaced())
                                .foregroundStyle(.fgSubtle)
                                .textSelection(.enabled)
                        }
                    }
                    if !role.description.isEmpty {
                        Text(role.description)
                            .font(.callout)
                            .foregroundStyle(.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button(rules.edit.allowed ? "Edit Permissions…" : "View Permissions…") {
                            present(.editRole(kind, role.id))
                        }
                        Button("Delete…", role: .destructive) { deleting = true }
                            .disabled(!rules.remove.allowed || blocked != nil)
                    }
                    .controlSize(.small)
                    ReasonLabel(reason: rules.edit.allowed ? (rules.remove.allowed ? blocked : rules.remove.reason)
                                                           : rules.edit.reason)
                }

                if AccessRules.isBuiltin(kind, role.name), rules.edit.allowed {
                    Callout(tone: .info, systemImage: "info.circle") {
                        Text("Built-in role").fontWeight(.semibold)
                        Text("Changes apply to every \(kind == .admin ? "account" : "vault assignment") that uses it\(kind == .vault && role.name.hasPrefix("share_") ? ", including share links created with this preset" : "").")
                            .foregroundStyle(.fgMuted)
                    }
                }

                AccessInspectorSection("Grants") {
                    GrantSummary(kind: kind, permissions: role.permissions)
                }

                if kind == .admin, let users {
                    AccessInspectorSection("Accounts") {
                        if holders.isEmpty {
                            Text("No account holds this role.")
                                .font(.callout)
                                .foregroundStyle(.fgSubtle)
                        } else {
                            InspectorList {
                                ForEach(holders, id: \.id) { user in
                                    InspectorRow(avatar: user.name, title: user.name, subtitle: user.email)
                                    if user.id != holders.last?.id { Divider().opacity(0.4) }
                                }
                            }
                        }
                    }
                    .id(users.count)
                }

                AccessInspectorSection("Details") {
                    DefinitionList(items: [
                        ("Created", AccessFormat.day(epoch: createdAt) ?? "—"),
                        ("Updated", AccessFormat.day(epoch: role.updatedAt) ?? "—"),
                        ("Role ID", String(role.id)),
                    ], termWidth: 96)
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $deleting) {
            DeleteRoleSheet(role: role, kind: kind, queries: queries)
        }
    }

    private var createdAt: Int64 {
        (role as? WsModel.AdminRole)?.createdAt ?? (role as? WsModel.VaultRole)?.createdAt ?? 0
    }
}

/// Granted permissions per group, compactly: "Files  6 of 12".
private struct GrantSummary: View {
    var kind: RoleKind
    var permissions: [WsModel.Permission]

    var body: some View {
        let groups = PermissionCatalog.groups(kind, permissions)
        let values = PermissionCatalog.snapshot(permissions)
        if groups.isEmpty {
            Text("The node sent no permissions for this role.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(groups) { group in
                    let on = group.items.filter { values[$0.qualified] == true }.count
                    GridRow {
                        Text(group.label)
                            .foregroundStyle(on == 0 ? Color.fgSubtle : Color.fg)
                            .help(group.items.filter { values[$0.qualified] == true }.map(\.label).joined(separator: ", "))
                        PermissionMeter(granted: on, total: group.items.count)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            .font(.callout)
        }
    }
}

/// Deleting a role: permanent, so its name is typed first (as the web console asks).
private struct DeleteRoleSheet: View {
    var role: any RoleRecord
    var kind: RoleKind

    @State private var typed = ""
    @State private var removeAdmin: NodeMutation<Ws.Role.Admin.Delete>
    @State private var removeVault: NodeMutation<Ws.Role.Vault.Delete>
    @Environment(\.dismiss) private var dismiss

    init(role: any RoleRecord, kind: RoleKind, queries: NodeQueries) {
        self.role = role
        self.kind = kind
        _removeAdmin = State(initialValue: NodeMutation(Ws.Role.Admin.Delete.self, on: queries, invalidating: RoleCommands.all))
        _removeVault = State(initialValue: NodeMutation(Ws.Role.Vault.Delete.self, on: queries, invalidating: RoleCommands.all + ["roles.vault.list.assigned"]))
    }

    var body: some View {
        let running = removeAdmin.isRunning || removeVault.isRunning
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: "Delete \(AccessFormat.roleLabel(role.name))?", systemImage: "trash", tone: .danger,
                       subtitle: kind == .admin
                           ? "The role is removed permanently. Accounts must be moved to another role first."
                           : "The role is removed permanently. It must not be assigned on any vault.")
            TextField("Type “\(role.name)” to confirm", text: $typed)
                .textFieldStyle(.roundedBorder)
            MutationError(error: removeAdmin.error ?? removeVault.error)
            SheetButtons(primary: "Delete Role", role: .destructive, running: running, enabled: typed == role.name) {
                Task {
                    let done = switch kind {
                    case .admin: await removeAdmin.run(.init(id: role.id)) != nil
                    case .vault: await removeVault.run(.init(id: role.id)) != nil
                    }
                    if done { dismiss() }
                }
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
