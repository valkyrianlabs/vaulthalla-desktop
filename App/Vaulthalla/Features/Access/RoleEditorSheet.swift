import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Create a role (from a template) or edit one: name, description and every permission the server exports. Saves send
/// the complete `{qualified, value}` snapshot, as the web console does; an edit sends it only when a permission
/// changed. Admin roles can't newly grant what this account doesn't hold (the server's escalation ceiling): those
/// switches are locked, and the server's refusal is shown if it says no anyway.
struct RoleEditorSheet: View {
    var kind: RoleKind
    var roleID: Int64?
    var queries: NodeQueries
    var actor: AccessActor?
    var onSaved: (Int64) -> Void

    var body: some View {
        Group {
            if let roleID {
                switch kind {
                case .admin: Loader(query: queries.query(Ws.Role.Admin.Get.self, .init(id: roleID))) { form(role: $0.role) }
                case .vault: Loader(query: queries.query(Ws.Role.Vault.Get.self, .init(id: roleID))) { form(role: $0.role) }
                }
            } else {
                NewRoleLoader(kind: kind, queries: queries) { templates, permissions in
                    RoleForm(kind: kind, role: nil, permissions: permissions, templates: templates, queries: queries,
                             actor: actor, onSaved: onSaved)
                }
            }
        }
        .frame(width: 820, height: 720)
    }

    private func form(role: any RoleRecord) -> some View {
        RoleForm(kind: kind, role: role, permissions: role.permissions, templates: [], queries: queries, actor: actor,
                 onSaved: onSaved)
    }
}

/// A read for a sheet: spinner, value, or the reason with a Close button.
private struct Loader<R: WsRequest, Content: View>: View {
    var query: NodeQuery<R>
    @ViewBuilder var content: (R.Response) -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch query.state {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let value, _):
                content(value)
            case .failed(let error):
                VStack(spacing: 16) {
                    InlineProblem(error: error, subject: "this role")
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await query.refresh() }
    }
}

/// A new role starts from the role list (any role carries the full permission set the server expects in a snapshot,
/// and each is a template). Without `admin.roles.<kind>.view`, the catalog (`permissions.list`) gives the set.
private struct NewRoleLoader<Content: View>: View {
    var kind: RoleKind
    var queries: NodeQueries
    @ViewBuilder var content: (_ templates: [any RoleRecord], _ permissions: [WsModel.Permission]) -> Content

    var body: some View {
        switch kind {
        case .admin:
            ListLoader(query: queries.query(Ws.Roles.Admin.List.self), roles: { $0.roles }, kind: kind, queries: queries,
                       content: content)
        case .vault:
            ListLoader(query: queries.query(Ws.Roles.Vault.List.self), roles: { $0.roles }, kind: kind, queries: queries,
                       content: content)
        }
    }
}

private struct ListLoader<R: WsRequest, Content: View>: View {
    var query: NodeQuery<R>
    var roles: (R.Response) -> [any RoleRecord]
    var kind: RoleKind
    var queries: NodeQueries
    @ViewBuilder var content: (_ templates: [any RoleRecord], _ permissions: [WsModel.Permission]) -> Content

    var body: some View {
        switch query.state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await query.refreshIfStale() }
        case .loaded(let value, _):
            let templates = roles(value)
            let base = templates.first?.permissions ?? []
            content(templates, base.map { blank($0) })
        case .failed:
            Loader(query: queries.query(Ws.Permissions.List.self)) { catalog in
                content([], catalog.permissions.filter { $0.qualified.hasPrefix("\(kind.rawValue).") }.map { blank($0) })
            }
        }
    }

    private func blank(_ permission: WsModel.Permission) -> WsModel.Permission {
        var copy = permission
        copy.value = false
        return copy
    }
}

// MARK: - Form

private struct RoleForm: View {
    var kind: RoleKind
    var role: (any RoleRecord)?
    /// The full permission list for this kind, with the saved values (all off for a new role).
    var permissions: [WsModel.Permission]
    var templates: [any RoleRecord]
    var actor: AccessActor?
    var onSaved: (Int64) -> Void

    private let saved: [String: Bool]
    @State private var name: String
    @State private var summary: String
    @State private var values: [String: Bool]
    @State private var template: Int64?
    @State private var problem: String?
    @State private var addAdmin: NodeMutation<Ws.Role.Admin.Add>
    @State private var addVault: NodeMutation<Ws.Role.Vault.Add>
    @State private var updateAdmin: NodeMutation<Ws.Role.Admin.Update>
    @State private var updateVault: NodeMutation<Ws.Role.Vault.Update>
    @Environment(\.dismiss) private var dismiss

    init(kind: RoleKind, role: (any RoleRecord)?, permissions: [WsModel.Permission], templates: [any RoleRecord],
         queries: NodeQueries, actor: AccessActor?, onSaved: @escaping (Int64) -> Void) {
        self.kind = kind
        self.role = role
        self.permissions = permissions
        self.templates = templates
        self.actor = actor
        self.onSaved = onSaved
        let saved = PermissionCatalog.snapshot(permissions)
        self.saved = saved
        _name = State(initialValue: role?.name ?? "")
        _summary = State(initialValue: role?.description ?? "")
        _values = State(initialValue: saved)
        let invalidating = RoleCommands.all
        _addAdmin = State(initialValue: NodeMutation(Ws.Role.Admin.Add.self, on: queries, invalidating: invalidating))
        _addVault = State(initialValue: NodeMutation(Ws.Role.Vault.Add.self, on: queries, invalidating: invalidating))
        _updateAdmin = State(initialValue: NodeMutation(Ws.Role.Admin.Update.self, on: queries, invalidating: invalidating))
        _updateVault = State(initialValue: NodeMutation(Ws.Role.Vault.Update.self, on: queries, invalidating: invalidating))
    }

    private var creating: Bool { role == nil }
    private var rules: (edit: Verdict, remove: Verdict) { AccessRules.roleEdit(actor, kind, roleName: role?.name) }
    private var editable: Bool { creating || rules.edit.allowed }
    private var locked: ((String) -> String?)? { AccessRules.ceiling(actor, kind, saved: saved) }

    private var changed: Set<String> {
        Set(permissions.map(\.qualified).filter { (values[$0] ?? false) != (saved[$0] ?? false) })
    }
    private var nameChanged: Bool { name.trimmingCharacters(in: .whitespaces) != (role?.name ?? "") }
    private var summaryChanged: Bool { summary.trimmingCharacters(in: .whitespaces) != (role?.description ?? "") }
    private var changeCount: Int { changed.count + (nameChanged ? 1 : 0) + (summaryChanged ? 1 : 0) }
    private var running: Bool {
        addAdmin.isRunning || addVault.isRunning || updateAdmin.isRunning || updateVault.isRunning
    }
    private var mutationError: WsError? { addAdmin.error ?? addVault.error ?? updateAdmin.error ?? updateVault.error }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], 22)
                .padding(.bottom, 14)

            details
                .padding(.horizontal, 22)
                .padding(.bottom, 14)

            Divider().opacity(0.5)

            PermissionMatrix(kind: kind, permissions: permissions, values: $values, readOnly: !editable,
                             locked: locked, changed: changed)

            Divider().opacity(0.5)

            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let role {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SheetTitle(title: AccessFormat.roleLabel(role.name),
                               systemImage: kind == .admin ? "person.badge.key" : "lock.shield",
                               subtitle: "\(kind == .admin ? "Admin" : "Vault") role · \(role.name)")
                    if AccessRules.isBuiltin(kind, role.name) { Pill(text: "Built-in") }
                }
            } else {
                SheetTitle(title: "New \(kind == .admin ? "Admin" : "Vault") Role",
                           systemImage: kind == .admin ? "person.badge.key" : "lock.shield",
                           subtitle: kind == .admin
                               ? "What an account with this role can manage across the node."
                               : "What a user or group with this role can do inside a vault.")
            }
            if !editable {
                Callout(tone: .info, systemImage: "lock") {
                    Text("Read only").fontWeight(.semibold)
                    Text(rules.edit.reason ?? "").foregroundStyle(.fgMuted)
                }
            } else if locked != nil {
                Callout(tone: .info, systemImage: "lock") {
                    Text("Permissions your own role doesn't hold are locked: you can revoke them but not grant them.")
                        .foregroundStyle(.fgMuted)
                }
            }
        }
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Name").foregroundStyle(.fgSubtle)
                TextField("Name", text: $name, prompt: Text("e.g. support_lead"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!editable)
                    .labelsHidden()
            }
            GridRow {
                Text("Description").foregroundStyle(.fgSubtle)
                TextField("Description", text: $summary, prompt: Text("What it's for"))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!editable)
                    .labelsHidden()
            }
            if creating, !templates.isEmpty {
                GridRow {
                    Text("Start from").foregroundStyle(.fgSubtle)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Start from", selection: $template) {
                            Text(kind == .admin ? "Unprivileged (nothing granted)" : "Nothing granted").tag(Int64?.none)
                            Divider()
                            ForEach(templates.sorted { $0.name < $1.name }, id: \.id) { template in
                                Text(AccessFormat.roleLabel(template.name)).tag(Int64?.some(template.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("Copies that role's permissions as a starting point. The new role keeps its own copy.")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }
            }
        }
        .font(.callout)
        .onChange(of: template) { _, id in apply(template: id) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let problem {
                Callout(tone: .danger, systemImage: "exclamationmark.circle") { Text(problem) }
            }
            MutationError(error: mutationError)
            HStack(spacing: 10) {
                Group {
                    if creating {
                        Text("\(values.values.filter { $0 }.count) permissions granted")
                    } else if editable {
                        Text(changeCount == 0 ? "No unsaved changes" : "\(AccessFormat.count(changeCount, "unsaved change"))")
                    }
                }
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .monospacedDigit()
                if running { ProgressView().controlSize(.small) }
                Spacer()
                if editable, !creating, changeCount > 0 {
                    Button("Discard") { discard() }
                        .disabled(running)
                }
                Button(editable ? "Cancel" : "Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if editable {
                    Button(creating ? "Create Role" : "Save") { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(running || (!creating && changeCount == 0))
                }
            }
        }
    }

    // MARK: Actions

    private func apply(template id: Int64?) {
        let source = templates.first { $0.id == id }
        var next = source.map { PermissionCatalog.snapshot($0.permissions) }
            ?? Dictionary(permissions.map { ($0.qualified, false) }, uniquingKeysWith: { a, _ in a })
        // A template can't smuggle in permissions this account couldn't grant by hand.
        if let locked {
            for (qualified, on) in next where on && locked(qualified) != nil { next[qualified] = false }
        }
        values = next
    }

    private func discard() {
        name = role?.name ?? ""
        summary = role?.description ?? ""
        values = saved
        template = nil
        problem = nil
    }

    private func save() async {
        problem = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            problem = "A role needs a name."
            return
        }
        // The complete snapshot, in the server's order.
        let snapshot = permissions.map { ($0.qualified, values[$0.qualified] ?? false) }
        if let role {
            let id: Int64?
            switch kind {
            case .admin:
                var payload = Ws.Role.Admin.Update.Payload(id: role.id)
                if nameChanged { payload.name = .value(trimmedName) }
                if summaryChanged { payload.description = .value(trimmedSummary) }
                if !changed.isEmpty { payload.permissions = snapshot.map { .init(qualified: $0.0, value: $0.1) } }
                id = await updateAdmin.run(payload)?.role.id
            case .vault:
                var payload = Ws.Role.Vault.Update.Payload(id: role.id)
                if nameChanged { payload.name = .value(trimmedName) }
                if summaryChanged { payload.description = .value(trimmedSummary) }
                if !changed.isEmpty { payload.permissions = snapshot.map { .init(qualified: $0.0, value: $0.1) } }
                id = await updateVault.run(payload)?.role.id
            }
            if let id {
                onSaved(id)
                dismiss()
            }
        } else {
            let id: Int64? = switch kind {
            case .admin:
                await addAdmin.run(.init(name: trimmedName, description: trimmedSummary,
                                         permissions: snapshot.map { .init(qualified: $0.0, value: $0.1) }))?.role.id
            case .vault:
                await addVault.run(.init(name: trimmedName, description: trimmedSummary,
                                         permissions: snapshot.map { .init(qualified: $0.0, value: $0.1) }))?.role.id
            }
            if let id {
                onSaved(id)
                dismiss()
            }
        }
    }
}

// MARK: - Permission matrix

/// A grouped checklist (the web's PermissionMatrix): every permission with a readable label and the server's
/// description, a switch each, a bulk grant/revoke per group, search, and granted/not-granted filters.
struct PermissionMatrix: View {
    enum Show: String, CaseIterable, Identifiable {
        case all = "All", granted = "Granted", denied = "Not Granted"
        var id: Self { self }
    }

    var kind: RoleKind
    var permissions: [WsModel.Permission]
    @Binding var values: [String: Bool]
    var readOnly: Bool
    /// Why a permission can't be granted by this account (it stays revocable); nil when nothing is locked.
    var locked: ((String) -> String?)?
    var changed: Set<String>

    @State private var search = ""
    @State private var show = Show.all

    var body: some View {
        let groups = PermissionCatalog.groups(kind, permissions)
        let visible = filtered(groups)
        let granted = permissions.filter { values[$0.qualified] == true }.count

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Search permissions", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Picker("Show", selection: $show) {
                    ForEach(Show.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("\(granted) of \(permissions.count) granted")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .monospacedDigit()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)

            ScrollView {
                if visible.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(.fgSubtle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top),
                                        GridItem(.flexible(), spacing: 14, alignment: .top)],
                              alignment: .leading, spacing: 14) {
                        ForEach(visible) { group in
                            GroupCard(group: group, full: groups.first { $0.key == group.key } ?? group,
                                      values: $values, readOnly: readOnly, locked: locked, changed: changed)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)
                }
            }
        }
    }

    private var emptyText: String {
        if !search.isEmpty { return "No permission matches “\(search)”." }
        if permissions.isEmpty { return "The node returned no permissions for this role type." }
        return show == .granted ? "This role grants nothing yet." : "This role grants everything."
    }

    private func filtered(_ groups: [PermissionCatalog.Group]) -> [PermissionCatalog.Group] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return groups.compactMap { group in
            var group = group
            group.items = group.items.filter { item in
                let on = values[item.qualified] == true
                if show == .granted, !on { return false }
                if show == .denied, on { return false }
                guard !needle.isEmpty else { return true }
                return [item.label, item.description, item.qualified, group.label]
                    .contains { $0.lowercased().contains(needle) }
            }
            return group.items.isEmpty ? nil : group
        }
    }
}

private struct GroupCard: View {
    var group: PermissionCatalog.Group
    /// The whole group: the bulk toggle acts on all of it, not just the filtered rows.
    var full: PermissionCatalog.Group
    @Binding var values: [String: Bool]
    var readOnly: Bool
    var locked: ((String) -> String?)?
    var changed: Set<String>

    var body: some View {
        let on = full.items.filter { values[$0.qualified] == true }.count
        let all = on == full.items.count

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(group.label)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.fg)
                        Text("\(on)/\(full.items.count)")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                            .monospacedDigit()
                    }
                    if let hint = group.hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }
                Spacer()
                if !readOnly {
                    Button(all ? "Revoke All" : "Grant All") { bulk(grant: !all) }
                        .controlSize(.small)
                        .help(all ? "Revoke every \(group.label) permission"
                                  : "Grant every \(group.label) permission you can grant")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.5)

            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                row(item)
                if index < group.items.count - 1 { Divider().opacity(0.3).padding(.leading, 14) }
            }
        }
        .panelSurface(radius: Theme.radiusCard)
    }

    private func row(_ item: PermissionCatalog.Item) -> some View {
        let value = values[item.qualified] == true
        let lockReason = value ? nil : locked?(item.qualified)
        let isChanged = changed.contains(item.qualified)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .foregroundStyle(value ? Color.fg : Color.fgMuted)
                    if isChanged {
                        Circle().fill(Color.accentFill).frame(width: 6, height: 6)
                            .accessibilityLabel("changed")
                    }
                }
                Text(item.description)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(item.qualified)
            Spacer(minLength: 0)
            if let lockReason, !readOnly {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.fgFaint)
                    Toggle(item.label, isOn: .constant(false))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .disabled(true)
                }
                .help(lockReason)
            } else {
                Toggle(item.label, isOn: binding(item.qualified))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(readOnly)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isChanged ? Color.accentSoft.opacity(0.5) : .clear)
    }

    private func binding(_ qualified: String) -> Binding<Bool> {
        Binding(get: { values[qualified] == true }, set: { values[qualified] = $0 })
    }

    /// Bulk grant skips what this account can't grant; bulk revoke always applies.
    private func bulk(grant: Bool) {
        for item in full.items {
            if grant, values[item.qualified] != true, locked?(item.qualified) != nil { continue }
            values[item.qualified] = grant
        }
    }
}
