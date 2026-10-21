import SwiftUI
import VHContract
import VHCore
import VHNodes

/// Users, groups and roles on one node (the web console's Access area), each a sortable table with an inspector.
/// What the account this Mac acts for may do comes from its session user (`auth.isAuthenticated`); the daemon
/// authorizes every request regardless, and its denials are shown as they come.
struct AccessView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        if let queries = model.liveQueries(for: node) {
            AccessScreen(node: node, queries: queries)
                .environment(queries)
        } else {
            PlaceholderSection(node: node, section: .access)
        }
    }
}

enum AccessTab: String, CaseIterable, Identifiable {
    case users, groups, roles

    var id: Self { self }

    var title: String {
        switch self {
        case .users: "Users"
        case .groups: "Groups"
        case .roles: "Roles"
        }
    }

    func subtitle(_ kind: RoleKind) -> String {
        switch self {
        case .users:
            "Accounts that can sign in. An account's admin role decides what it can manage; vault roles decide what it can do inside each vault."
        case .groups:
            "Collections of accounts. A vault role granted to a group applies to every member."
        case .roles:
            kind == .admin
                ? "Admin roles decide what an account can manage across the node. Each account holds exactly one."
                : "Vault roles decide what a user or group can do inside a vault. Assign them from each vault's inspector."
        }
    }
}

/// The sheets the Access screen presents, from its tables, inspectors and toolbar.
enum AccessSheet: Identifiable {
    case newUser
    case editUser(WsModel.UserSummary)
    case resetPassword(WsModel.UserSummary)
    case deleteUser(WsModel.UserSummary)
    case addToGroup([WsModel.UserSummary])
    case newGroup
    case editGroup(WsModel.Group)
    case addMembers(WsModel.Group)
    case newRole(RoleKind)
    case editRole(RoleKind, Int64)

    var id: String {
        switch self {
        case .newUser: "newUser"
        case .editUser(let user): "editUser-\(user.id)"
        case .resetPassword(let user): "reset-\(user.id)"
        case .deleteUser(let user): "deleteUser-\(user.id)"
        case .addToGroup(let users): "addToGroup-\(users.map(\.id))"
        case .newGroup: "newGroup"
        case .editGroup(let group): "editGroup-\(group.id)"
        case .addMembers(let group): "addMembers-\(group.id)"
        case .newRole(let kind): "newRole-\(kind)"
        case .editRole(let kind, let id): "editRole-\(kind)-\(id)"
        }
    }
}

private struct AccessScreen: View {
    var node: Node
    var queries: NodeQueries

    @Environment(AppModel.self) private var model
    @SceneStorage("access.tab") private var tab = AccessTab.users
    @SceneStorage("access.roleKind") private var roleKind = RoleKind.admin
    @State private var filter = ""
    @State private var showsSystem = false
    @State private var showsInspector = true
    @State private var userSelection: Set<Int64> = []
    @State private var groupSelection: Int64?
    @State private var roleSelection: Int64?
    @State private var sheet: AccessSheet?

    var body: some View {
        let session = queries.query(Ws.Auth.IsAuthenticated.self)
        let actor = session.value?.user.map(AccessActor.init)

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(eyebrow: node.displayName, title: "Access", subtitle: tab.subtitle(roleKind)) {
                let status = model.status(for: node)
                StatusBadge(label: status.label, tone: status.tone, pulse: status.isTransitional)
            }
            .padding([.horizontal, .top], Theme.pagePadding)
            .padding(.bottom, 16)

            controls
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 14)

            switch tab {
            case .users:
                UsersPane(node: node, queries: queries, actor: actor, filter: filter, showsSystem: showsSystem,
                          selection: $userSelection, present: present)
            case .groups:
                GroupsPane(node: node, queries: queries, actor: actor, filter: filter, selection: $groupSelection,
                           present: present)
            case .roles:
                RolesPane(node: node, queries: queries, actor: actor, kind: roleKind, filter: filter,
                          selection: $roleSelection, present: present)
                    .id(roleKind)
            }
        }
        .observing(session)
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter \(tab.title)")
        // The content's own minimum width must not reach the inspector's split view: a Table's column
        // minimums plus the inspector can exceed the window, and SwiftUI then loops AppKit's constraint pass.
        .frame(minWidth: 0, maxWidth: .infinity)
        .inspector(isPresented: $showsInspector) {
            inspector(actor: actor)
                .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let label = newLabel, canCreate(actor) {
                    Button(label, systemImage: "plus") { createNew() }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                        .help("\(label) (⇧⌘N)")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(showsInspector ? "Hide the inspector" : "Show the inspector")
            }
        }
        .sheet(item: $sheet) { sheet in
            sheetContent(sheet, actor: actor)
        }
        .onChange(of: roleKind) { roleSelection = nil }
        #if DEBUG
        .task { await debugSetup() }
        #endif
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Show", selection: $tab) {
                ForEach(AccessTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if tab == .roles {
                Picker("Role type", selection: $roleKind) {
                    ForEach(RoleKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Spacer(minLength: 0)

            if tab == .users, queries.query(Ws.Auth.Users.List.self).value?.users.contains(where: \.systemOnly) == true {
                Toggle("Show system accounts", isOn: $showsSystem)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.fgSubtle)
                    .help("Service identities the daemon uses internally. They can't sign in.")
            }
        }
        // Invisible buttons: ⌥⌘1–3 switch tabs (⌘1–9 pick nodes).
        .background {
            ForEach(Array(AccessTab.allCases.enumerated()), id: \.element) { index, value in
                Button(value.title) { tab = value }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: Creating

    private var newLabel: String? {
        switch tab {
        case .users: "New User"
        case .groups: "New Group"
        case .roles: roleKind == .admin ? "New Admin Role" : "New Vault Role"
        }
    }

    /// The web hides create actions the account can't use; an unknown account sees them, and the daemon decides.
    private func canCreate(_ actor: AccessActor?) -> Bool {
        guard let actor else { return true }
        return switch tab {
        case .users: actor.hasAny(AccessRules.addUsers)
        case .groups: actor.has("admin.identities.groups.add")
        case .roles: actor.has("admin.roles.\(roleKind.rawValue).add")
        }
    }

    private func createNew() {
        switch tab {
        case .users: sheet = .newUser
        case .groups: sheet = .newGroup
        case .roles: sheet = .newRole(roleKind)
        }
    }

    private func present(_ next: AccessSheet) {
        sheet = next
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(actor: AccessActor?) -> some View {
        switch tab {
        case .users:
            UsersInspector(node: node, queries: queries, actor: actor, selection: userSelection, present: present)
        case .groups:
            GroupInspectorHost(queries: queries, actor: actor, selection: groupSelection, present: present) {
                groupSelection = nil
            }
        case .roles:
            RoleInspectorHost(queries: queries, actor: actor, kind: roleKind, selection: roleSelection, present: present)
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: AccessSheet, actor: AccessActor?) -> some View {
        switch sheet {
        case .newUser:
            NewUserSheet(queries: queries, actor: actor) { created in
                tab = .users
                userSelection = [created.id]
            }
        case .editUser(let user):
            EditUserSheet(user: user, queries: queries, actor: actor)
        case .resetPassword(let user):
            ResetPasswordSheet(user: user, queries: queries)
        case .deleteUser(let user):
            DeleteUserSheet(user: user, node: node, queries: queries) {
                userSelection.remove(user.id)
            }
        case .addToGroup(let users):
            AddToGroupSheet(users: users, queries: queries)
        case .newGroup:
            GroupFormSheet(group: nil, queries: queries) { created in
                groupSelection = created.id
            }
        case .editGroup(let group):
            GroupFormSheet(group: group, queries: queries) { _ in }
        case .addMembers(let group):
            AddMembersSheet(group: group, queries: queries)
        case .newRole(let kind):
            RoleEditorSheet(kind: kind, roleID: nil, queries: queries, actor: actor) { created in
                roleKind = kind
                roleSelection = created
            }
        case .editRole(let kind, let id):
            RoleEditorSheet(kind: kind, roleID: id, queries: queries, actor: actor) { _ in }
        }
    }

    #if DEBUG
    /// `-VHDebugAccessTab groups|roles`, `-VHDebugAccessRoleKind vault`, `-VHDebugAccessSelect <id>` and
    /// `-VHDebugAccessSheet newUser|editUser|resetPassword|deleteUser|newGroup|addMembers|newRole|editRole` (on the
    /// selected row) for DebugSnapshot.
    private func debugSetup() async {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "VHDebugAccessTab"), let value = AccessTab(rawValue: raw) { tab = value }
        if let raw = defaults.string(forKey: "VHDebugAccessRoleKind"), let value = RoleKind(rawValue: raw) {
            roleKind = value
        }
        let id = Int64(defaults.integer(forKey: "VHDebugAccessSelect"))
        if id > 0 {
            switch tab {
            case .users: userSelection = [id]
            case .groups: groupSelection = id
            case .roles: roleSelection = id
            }
        }
        guard let which = defaults.string(forKey: "VHDebugAccessSheet") else { return }
        try? await Task.sleep(for: .milliseconds(400))
        let users = queries.query(Ws.Auth.Users.List.self)
        let groups = queries.query(Ws.Groups.List.self)
        await users.refreshIfStale()
        await groups.refreshIfStale()
        let user = users.value?.users.first { $0.id == id }
        let group = groups.value?.groups.first { $0.id == id }
        switch which {
        case "newUser": sheet = .newUser
        case "editUser": sheet = user.map(AccessSheet.editUser)
        case "resetPassword": sheet = user.map(AccessSheet.resetPassword)
        case "deleteUser": sheet = user.map(AccessSheet.deleteUser)
        case "newGroup": sheet = .newGroup
        case "addMembers": sheet = group.map(AccessSheet.addMembers)
        case "newRole": sheet = .newRole(roleKind)
        case "editRole": sheet = .editRole(roleKind, id)
        default: break
        }
    }
    #endif
}

// MARK: - Shared pieces

/// A round monogram for an account.
struct AccountAvatar: View {
    var name: String
    var size: CGFloat = 26

    var body: some View {
        Text(AccessFormat.initials(name))
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.accentText)
            .frame(width: size, height: size)
            .background(.accentSoft, in: Circle())
            .overlay { Circle().strokeBorder(.accentLine, lineWidth: 1) }
            .accessibilityHidden(true)
    }
}

/// A small neutral or accent pill ("You", "Built-in", "System").
struct Pill: View {
    var text: String
    var accent = false
    var help: String?

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(accent ? Color.accentText : Color.fgMuted)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(accent ? Color.accentSoft : Color.surface2, in: Capsule())
            .overlay { Capsule().strokeBorder(accent ? Color.accentLine : Color.line, lineWidth: 1) }
            .help(help ?? "")
            .fixedSize()
    }
}

/// Why a control isn't live, next to it.
struct ReasonLabel: View {
    var reason: String?

    var body: some View {
        if let reason {
            Label(reason, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A titled group in an Access inspector.
struct AccessInspectorSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.fgSubtle)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row in an inspector list (a group, a member, a vault role).
struct InspectorRow<Trailing: View>: View {
    var systemImage: String?
    var avatar: String?
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            if let avatar {
                AccountAvatar(name: avatar, size: 24)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.fgSubtle)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(.fg)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

extension InspectorRow where Trailing == EmptyView {
    init(systemImage: String? = nil, avatar: String? = nil, title: String, subtitle: String? = nil) {
        self.init(systemImage: systemImage, avatar: avatar, title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

/// A hairline-bordered stack of inspector rows.
struct InspectorList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous).strokeBorder(.line, lineWidth: 1)
        }
    }
}

/// The empty inspector.
struct InspectorPlaceholder: View {
    var title: String
    var message: String

    var body: some View {
        EmptyState(title, systemImage: "sidebar.trailing", message: message)
            .frame(maxHeight: .infinity)
    }
}

/// A sheet's title row.
struct SheetTitle: View {
    var title: String
    var systemImage: String
    var tone: StatusTone?
    var subtitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tone?.color ?? .accentText)
                .frame(width: 34, height: 34)
                .background(tone?.soft ?? .accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.fg)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                        // No vertical fixedSize: in a header above a Table it loops AppKit's constraint pass (see Callout).
                }
            }
        }
    }
}

#if DEBUG
#Preview("Access: users (preview data)") {
    let model = PreviewSamples.liveModel()
    AccessView(node: PreviewSamples.nodes[1])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1180, height: 680)
}

#Preview("Access: no access (preview data)") {
    let model = PreviewSamples.liveModel()
    AccessView(node: PreviewSamples.nodes[3])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1000, height: 560)
}
#endif
