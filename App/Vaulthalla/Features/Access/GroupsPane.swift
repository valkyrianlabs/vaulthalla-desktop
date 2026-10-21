import SwiftUI
import VHContract
import VHCore
import VHNodes

/// The commands whose answers a change to a group makes stale.
enum GroupCommands {
    static let all = ["groups.list", "group.get", "auth.user", "roles.vault.list.assigned"]
}

/// `groups.list` as a sortable table: every group for group viewers, otherwise the account's own groups.
struct GroupsPane: View {
    var node: Node
    var queries: NodeQueries
    var actor: AccessActor?
    var filter: String
    @Binding var selection: Int64?
    var present: (AccessSheet) -> Void

    @State private var sortOrder = [KeyPathComparator(\GroupRow.sortName)]
    @State private var deleting: WsModel.Group?
    @State private var remove: NodeMutation<Ws.Group.Remove>

    init(node: Node, queries: NodeQueries, actor: AccessActor?, filter: String, selection: Binding<Int64?>,
         present: @escaping (AccessSheet) -> Void) {
        self.node = node
        self.queries = queries
        self.actor = actor
        self.filter = filter
        _selection = selection
        self.present = present
        _remove = State(initialValue: NodeMutation(Ws.Group.Remove.self, on: queries, invalidating: GroupCommands.all))
    }

    var body: some View {
        let list = queries.query(Ws.Groups.List.self)
        let rows = rows(list.value?.groups ?? [])

        VStack(alignment: .leading, spacing: 0) {
            switch list.state {
            case .idle, .loading:
                LoadingPanel(subject: "groups")
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .failed(let error):
                ProblemPanel(problem: QueryProblem(error), node: node, subject: "groups") {
                    Task { await list.refresh() }
                }
                .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            case .loaded(let value, let at):
                StaleBanner(node: node, updatedAt: at, refreshError: list.refreshError, connected: queries.isConnected)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 12)
                if value.groups.isEmpty {
                    Panel {
                        EmptyState("No groups yet", systemImage: "person.3",
                                   message: "Create a group to grant vault access to several accounts at once.") {
                            if can("admin.identities.groups.add") {
                                Button("New Group") { present(.newGroup) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    Spacer(minLength: 0)
                } else {
                    if !can("admin.identities.groups.view") {
                        Callout(tone: .info, systemImage: "info.circle") {
                            Text("Your role can't view every group, so only the groups this account belongs to are listed.")
                        }
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.bottom, 12)
                    }
                    table(rows)
                    MutationError(error: remove.error)
                        .padding(Theme.pagePadding / 2)
                }
            }
        }
        .observing(list)
        .confirmationDialog(deleting.map { "Delete group \($0.name)?" } ?? "", isPresented: isDeleting,
                            titleVisibility: .visible, presenting: deleting) { group in
            Button("Delete Group", role: .destructive) {
                Task {
                    if await remove.run(.init(id: group.id)) != nil, selection == group.id { selection = nil }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text(group.members.isEmpty
                 ? "Members lose every vault role granted through this group. The accounts themselves stay."
                 : "Its \(AccessFormat.count(group.members.count, "member")) lose every vault role granted through this group. The accounts themselves stay.")
        }
    }

    private func can(_ permission: String) -> Bool {
        actor.map { $0.has(permission) } ?? true
    }

    private func table(_ rows: [GroupRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.sortName) { row in
                HStack(spacing: 10) {
                    Image(systemName: "person.3")
                        .foregroundStyle(.accentText)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.group.name)
                            .foregroundStyle(.fg)
                        if let description = row.group.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.fgSubtle)
                        }
                    }
                    .lineLimit(1)
                }
                .padding(.vertical, 3)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Members", value: \.memberCount) { row in
                MemberStack(group: row.group)
            }
            .width(min: 100, ideal: 140)

            TableColumn("Linux GID", value: \.gidSort) { row in
                Text(row.group.gid.map(String.init) ?? "—")
                    .foregroundStyle(row.group.gid == nil ? Color.fgFaint : Color.fgMuted)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Created", value: \.group.createdAt) { row in
                Text(Format.day(iso: row.group.createdAt) ?? row.group.createdAt)
                    .foregroundStyle(.fgSubtle)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Add Members…") { present(.addMembers(row.group)) }
                    .disabled(!can("admin.identities.groups.add-member"))
                Button("Edit…") { present(.editGroup(row.group)) }
                    .disabled(!can("admin.identities.groups.edit"))
                Divider()
                Button("Delete…", role: .destructive) { deleting = row.group }
                    .disabled(!can("admin.identities.groups.delete"))
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }), can("admin.identities.groups.edit") {
                present(.editGroup(row.group))
            }
        }
        .onDeleteCommand {
            if let selection, let row = rows.first(where: { $0.id == selection }), can("admin.identities.groups.delete") {
                deleting = row.group
            }
        }
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func rows(_ groups: [WsModel.Group]) -> [GroupRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return groups
            .filter { needle.isEmpty || "\($0.name) \($0.description ?? "")".lowercased().contains(needle) }
            .map(GroupRow.init)
            .sorted(using: sortOrder)
    }
}

nonisolated struct GroupRow: Identifiable {
    var group: WsModel.Group

    var id: Int64 { group.id }
    var sortName: String { group.name.lowercased() }
    var memberCount: Int { group.members.count }
    var gidSort: Int64 { group.gid ?? -1 }
}

/// Up to four member monograms and the count.
private struct MemberStack: View {
    var group: WsModel.Group

    var body: some View {
        if group.members.isEmpty {
            Text("No members")
                .foregroundStyle(.fgFaint)
        } else {
            HStack(spacing: 8) {
                HStack(spacing: -7) {
                    ForEach(Array(group.members.prefix(4).enumerated()), id: \.offset) { _, member in
                        AccountAvatar(name: member.user?.name ?? "?", size: 22)
                            .background(Circle().fill(Color.canvas))
                            .help(member.user?.name ?? "Unknown account")
                    }
                }
                Text("\(group.members.count)")
                    .foregroundStyle(.fgMuted)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Inspector

struct GroupInspectorHost: View {
    var queries: NodeQueries
    var actor: AccessActor?
    var selection: Int64?
    var present: (AccessSheet) -> Void
    var onDeleted: () -> Void

    var body: some View {
        if let selection, let group = queries.query(Ws.Groups.List.self).value?.groups.first(where: { $0.id == selection }) {
            GroupInspector(group: group, queries: queries, actor: actor, present: present)
                .id(group.id)
        } else {
            InspectorPlaceholder(title: "No group selected", message: "Select a group to see and change its members.")
        }
    }
}

/// A group's details and members; members can be removed one at a time or several at once.
private struct GroupInspector: View {
    var group: WsModel.Group
    var queries: NodeQueries
    var actor: AccessActor?
    var present: (AccessSheet) -> Void

    @State private var memberSelection: Set<Int64> = []
    @State private var removing: [WsModel.PublicUser] = []
    @State private var remove: NodeMutation<Ws.Group.Member.Remove>

    init(group: WsModel.Group, queries: NodeQueries, actor: AccessActor?, present: @escaping (AccessSheet) -> Void) {
        self.group = group
        self.queries = queries
        self.actor = actor
        self.present = present
        _remove = State(initialValue: NodeMutation(Ws.Group.Member.Remove.self, on: queries,
                                                   invalidating: GroupCommands.all))
    }

    private func can(_ permission: String) -> Bool { actor.map { $0.has(permission) } ?? true }

    private var members: [WsModel.GroupMember] {
        group.members.sorted { ($0.user?.name ?? "").localizedStandardCompare($1.user?.name ?? "") == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "person.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.accentText)
                        .frame(width: 34, height: 34)
                        .background(.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.fg)
                        Text(AccessFormat.count(group.members.count, "member"))
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }
                if let description = group.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Add Members…") { present(.addMembers(group)) }
                        .disabled(!can("admin.identities.groups.add-member"))
                    Button("Edit…") { present(.editGroup(group)) }
                        .disabled(!can("admin.identities.groups.edit"))
                }
                .controlSize(.small)
            }

            AccessInspectorSection("Details") {
                DefinitionList(items: [
                    ("Linux GID", group.gid.map(String.init) ?? "Not mapped"),
                    ("Created", Format.moment(iso: group.createdAt) ?? group.createdAt),
                    ("Group ID", String(group.id)),
                ], termWidth: 96)
            }

            AccessInspectorSection("Members") {
                if members.isEmpty {
                    Text("No members yet.")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                } else {
                    List(selection: $memberSelection) {
                        ForEach(members, id: \.user?.id) { member in
                            InspectorRow(avatar: member.user?.name ?? "?", title: member.user?.name ?? "Unknown account",
                                         subtitle: joined(member)) {
                                if can("admin.identities.groups.remove-member"), let user = member.user {
                                    Button("Remove \(user.name)", systemImage: "xmark") { removing = [user] }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.fgSubtle)
                                        .help("Remove \(user.name) from \(group.name)")
                                }
                            }
                            .listRowInsets(EdgeInsets())
                            .tag(member.user?.id ?? -1)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: .infinity)
                    .contextMenu(forSelectionType: Int64.self) { ids in
                        let users = members.compactMap(\.user).filter { ids.contains($0.id) }
                        if !users.isEmpty {
                            Button(users.count == 1 ? "Remove from Group…" : "Remove \(users.count) Members…",
                                   role: .destructive) { removing = users }
                                .disabled(!can("admin.identities.groups.remove-member"))
                        }
                    }
                    .onDeleteCommand {
                        let users = members.compactMap(\.user).filter { memberSelection.contains($0.id) }
                        if !users.isEmpty, can("admin.identities.groups.remove-member") { removing = users }
                    }
                }
                MutationError(error: remove.error)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .confirmationDialog(removalTitle, isPresented: isRemoving, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await removeMembers() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removing.count == 1
                 ? "\(removing[0].name) loses every vault role granted through \(group.name)."
                 : "They lose every vault role granted through \(group.name).")
        }
    }

    private func joined(_ member: WsModel.GroupMember) -> String {
        let joined = Format.day(iso: member.joinedAt).map { "Joined \($0)" } ?? ""
        return member.user?.isActive == false ? "Inactive · \(joined)" : joined
    }

    private var removalTitle: String {
        removing.count == 1 ? "Remove \(removing[0].name) from \(group.name)?"
            : "Remove \(removing.count) members from \(group.name)?"
    }

    private var isRemoving: Binding<Bool> {
        Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } })
    }

    private func removeMembers() async {
        let users = removing
        removing = []
        for user in users {
            guard await remove.run(.init(groupID: group.id, userID: user.id)) != nil else { break }
            memberSelection.remove(user.id)
        }
    }
}

// MARK: - Sheets

/// Create a group (`group.add`) or change its name, description and Linux GID (`group.update` with what changed).
struct GroupFormSheet: View {
    var group: WsModel.Group?
    var onSaved: (WsModel.Group) -> Void

    @State private var name: String
    @State private var summary: String
    @State private var gid: String
    @State private var submitted = false
    @State private var create: NodeMutation<Ws.Group.Add>
    @State private var update: NodeMutation<Ws.Group.Update>
    @Environment(\.dismiss) private var dismiss

    init(group: WsModel.Group?, queries: NodeQueries, onSaved: @escaping (WsModel.Group) -> Void) {
        self.group = group
        self.onSaved = onSaved
        _name = State(initialValue: group?.name ?? "")
        _summary = State(initialValue: group?.description ?? "")
        _gid = State(initialValue: group?.gid.map(String.init) ?? "")
        _create = State(initialValue: NodeMutation(Ws.Group.Add.self, on: queries, invalidating: GroupCommands.all))
        _update = State(initialValue: NodeMutation(Ws.Group.Update.self, on: queries, invalidating: GroupCommands.all))
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedSummary: String { summary.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var gidValue: Int64? { Int64(gid.trimmingCharacters(in: .whitespaces)) }

    private var problem: String? {
        if let name = AccessRules.nameProblem(name) { return "Name: \(name)" }
        if summary.count > 500 { return "Description: at most 500 characters" }
        let text = gid.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty, (gidValue ?? 0) <= 0 || (gidValue ?? 0) >= 1 << 32 { return "Linux GID: a positive whole number" }
        return nil
    }

    private var changed: Bool {
        guard let group else { return true }
        return trimmedName != group.name || trimmedSummary != (group.description ?? "") || (gidValue != nil && gidValue != group.gid)
    }

    var body: some View {
        let running = create.isRunning || update.isRunning
        VStack(alignment: .leading, spacing: 0) {
            SheetTitle(title: group.map { "Edit \($0.name)" } ?? "New Group", systemImage: "person.3",
                       subtitle: group == nil ? "Groups collect accounts so a vault role can be granted to all of them at once." : nil)
                .padding([.horizontal, .top], 22)

            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description", text: $summary, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Linux GID", text: $gid, prompt: Text("Optional"))
                        .monospacedDigit()
                    if submitted, let problem { FieldProblem(text: problem) }
                } footer: {
                    Text(group?.gid != nil
                         ? "The Linux GID maps the group to a Linux group for FUSE access. It can be changed but not removed."
                         : "The Linux GID maps the group to a Linux group for FUSE access.")
                        .foregroundStyle(.fgSubtle)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            MutationError(error: create.error ?? update.error)
                .padding(.horizontal, 20)

            SheetButtons(primary: group == nil ? "Create Group" : "Save", running: running, enabled: changed) {
                submitted = true
                guard problem == nil else { return }
                Task { await save() }
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    private func save() async {
        if let group {
            var payload = Ws.Group.Update.Payload(id: group.id)
            if trimmedName != group.name { payload.name = .value(trimmedName) }
            if trimmedSummary != (group.description ?? "") { payload.description = .value(trimmedSummary) }
            if let gidValue, gidValue != group.gid { payload.linuxGid = .value(gidValue) }
            if let response = await update.run(payload) {
                onSaved(response.group)
                dismiss()
            }
        } else {
            let payload = Ws.Group.Add.Payload(name: trimmedName, description: trimmedSummary.isEmpty ? nil : trimmedSummary,
                                               linuxGid: gidValue.map { .value($0) })
            if let response = await create.run(payload) {
                onSaved(response.group)
                dismiss()
            }
        }
    }
}

/// A searchable, multi-select list of the accounts not yet in a group (`group.member.add` for each chosen one).
struct AddMembersSheet: View {
    var group: WsModel.Group

    @State private var chosen: Set<Int64> = []
    @State private var search = ""
    @State private var running = false
    @State private var failures: [String] = []
    @State private var add: NodeMutation<Ws.Group.Member.Add>
    private let users: NodeQuery<Ws.Auth.Users.List>
    @Environment(\.dismiss) private var dismiss

    init(group: WsModel.Group, queries: NodeQueries) {
        self.group = group
        users = queries.query(Ws.Auth.Users.List.self)
        _add = State(initialValue: NodeMutation(Ws.Group.Member.Add.self, on: queries, invalidating: GroupCommands.all))
    }

    private var candidates: [WsModel.UserSummary] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return (users.value?.users ?? [])
            .filter { user in !user.systemOnly && !group.members.contains { $0.user?.id == user.id } }
            .filter { needle.isEmpty || $0.searchText.contains(needle) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetTitle(title: "Add Members to \(group.name)", systemImage: "person.badge.plus",
                       subtitle: "Select one or more accounts (⌘-click or ⇧-click).")

            switch users.state {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .failed(let error):
                InlineProblem(error: error, subject: "the node's accounts")
            case .loaded:
                TextField("Search accounts", text: $search)
                    .textFieldStyle(.roundedBorder)
                List(candidates, id: \.id, selection: $chosen) { user in
                    HStack(spacing: 10) {
                        AccountAvatar(name: user.name, size: 22)
                        Text(user.name)
                        if !user.isActive {
                            Text("Inactive").font(.caption).foregroundStyle(.fgFaint)
                        }
                        Spacer()
                        Text(user.email ?? "")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }
                .frame(height: 240)
                .overlay {
                    if candidates.isEmpty {
                        Text(search.isEmpty ? "Everyone is already a member." : "No account matches.")
                            .foregroundStyle(.fgSubtle)
                    }
                }
            }

            if !failures.isEmpty {
                Callout(tone: .warn, systemImage: "exclamationmark.circle") {
                    ForEach(failures, id: \.self) { Text($0) }
                }
            }

            SheetButtons(primary: chosen.count > 1 ? "Add \(chosen.count) Members" : "Add", running: running,
                         enabled: !chosen.isEmpty) {
                Task { await submit() }
            }
        }
        .padding(22)
        .frame(width: 480)
        .observing(users)
    }

    private func submit() async {
        running = true
        failures = []
        let names = Dictionary((users.value?.users ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for id in chosen {
            if await add.run(.init(groupID: group.id, userID: id)) != nil {
                chosen.remove(id)
            } else if let error = add.error {
                failures.append("\(names[id] ?? "#\(id)"): \(error.message)")
            }
        }
        running = false
        if failures.isEmpty { dismiss() }
    }
}
