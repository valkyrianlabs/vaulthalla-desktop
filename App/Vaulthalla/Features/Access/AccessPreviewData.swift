#if DEBUG
import Foundation
import Synchronization
import VHContract
import VHTransport

/// PREVIEW DATA, DEBUG only: canned answers for the Access commands (users, groups, roles, permissions, vault role
/// assignments and overrides), served by `PreviewTransport`. Groups and custom roles say "(preview)"; the accounts
/// use example.com addresses. In the full scenario the Mac acts for "cooper", whose `admin` role lacks a few admin
/// permissions, so the escalation ceiling shows; in the restricted one for an unprivileged account.
nonisolated enum AccessPreviewData: PreviewFeature {
    static func answer(_ command: WsCommand, _ payload: some Sendable, from transport: PreviewTransport)
        throws(WsError) -> Any? {
        let full = transport.scenario == .full
        let denied = WsError.denied("Permission denied: your role lacks the permission this needs.")
        switch command {
        case .authIsAuthenticated:
            let user: WsModel.User? = full ? store.withLock { s in try? s.detail(actorID) } : guest
            return Ws.Auth.IsAuthenticated.Response(isAuthenticated: true, user: user.map(session))

        case .permissionsList:
            return Ws.Permissions.List.Response(permissions: (adminCatalog + vaultCatalog).enumerated().map { index, p in
                var p = p
                p.id = Int64(index + 1)
                return p
            })

        // MARK: Users
        case .authUsersList:
            guard full else { throw denied }
            return Ws.Auth.Users.List.Response(users: store.withLock { s in s.users.map { s.summary($0) } })
        case .authUserGet:
            guard full else { throw denied }
            let id = (payload as? Ws.Auth.User.Get.Payload)?.id
            return Ws.Auth.User.Get.Response(user: try store.withLock { s throws(WsError) in try s.detail(id) })
        case .authRegister:
            guard full, let p = payload as? Ws.Auth.Register.Payload else { throw denied }
            return Ws.Auth.Register.Response(user: try store.withLock { s throws(WsError) in
                guard !s.users.contains(where: { $0.name == p.name }) else { throw .conflict("A user named \(p.name) already exists.") }
                guard let role = s.adminRoles.first(where: { $0.name == p.role || String($0.id) == p.role }) else {
                    throw .invalid("There is no admin role named \(p.role).")
                }
                if role.name == "super_admin" { throw .denied("You cannot assign the super_admin role.") }
                let id = (s.users.map(\.id).max() ?? 0) + 1
                s.users.append(PreviewUser(id: id, name: p.name, email: p.email, roleID: role.id, active: p.isActive ?? true))
                return try s.detail(id)
            })
        case .authUserUpdate:
            guard full, let p = payload as? Ws.Auth.User.Update.Payload else { throw denied }
            return Ws.Auth.User.Update.Response(user: try store.withLock { s throws(WsError) in
                guard let id = p.id?.wrapped, let index = s.users.firstIndex(where: { $0.id == id }) else {
                    throw .notFound("No such user.")
                }
                if s.users[index].protected { throw .denied("This is a protected account; change it with the vh CLI.") }
                if let name = p.name?.wrapped { s.users[index].name = name }
                if let email = p.email { s.users[index].email = email.wrapped }
                if let active = p.isActive?.wrapped { s.users[index].active = active }
                if let role = p.role {
                    guard let found = s.adminRoles.first(where: { $0.name == role }) else { throw .invalid("No such role.") }
                    if found.name == "super_admin" { throw .denied("You cannot assign the super_admin role.") }
                    s.users[index].roleID = found.id
                }
                return try s.detail(id)
            })
        case .authUserChangePassword:
            guard full, let p = payload as? Ws.Auth.User.ChangePassword.Payload else { throw denied }
            if p.newPassword.lowercased().contains("password") {
                throw .invalid("This password appears in breach corpora. Choose another.")
            }
            return Ws.Auth.User.ChangePassword.Response(user: try store.withLock { s throws(WsError) in try s.detail(p.id) })
        case .authUserDelete:
            guard full, let p = payload as? Ws.Auth.User.Delete.Payload else { throw denied }
            return Ws.Auth.User.Delete.Response(userID: try store.withLock { s throws(WsError) in
                guard let user = s.users.first(where: { $0.id == p.id }) else { throw .notFound("No such user.") }
                if p.confirm != true {
                    let heir = p.transferTo?.wrapped.flatMap { id in s.users.first { $0.id == id }?.name }
                    let vaults = user.ownedVaults
                    let lead = heir.map { "Delete \(user.name)? Their vaults move to \($0) first:" }
                        ?? (vaults.isEmpty ? "Delete \(user.name)? They own no vaults." : "Delete \(user.name)? These vaults are destroyed with the account:")
                    throw .needsConfirmation(code: "user_delete",
                                             message: vaults.isEmpty ? lead : "\(lead)\n\(vaults.joined(separator: "\n"))")
                }
                s.users.removeAll { $0.id == p.id }
                for index in s.groups.indices { s.groups[index].members.removeAll { $0 == p.id } }
                return p.id
            })

        // MARK: Groups
        case .groupsList:
            return Ws.Groups.List.Response(groups: store.withLock { s in
                full ? s.groups.map { s.group($0) } : []
            })
        case .groupsListByUser:
            guard full else { throw denied }
            let id = (payload as? Ws.Groups.List.ByUser.Payload)?.userID
            return Ws.Groups.List.ByUser.Response(groups: store.withLock { s in
                s.groups.filter { $0.members.contains { $0 == id } }.map { s.group($0) }
            })
        case .groupAdd:
            guard full, let p = payload as? Ws.Group.Add.Payload else { throw denied }
            let group = store.withLock { s in
                let id = (s.groups.map(\.id).max() ?? 0) + 1
                s.groups.append(PreviewGroup(id: id, name: p.name, description: p.description, gid: p.linuxGid?.wrapped, members: []))
                return s.group(s.groups[s.groups.count - 1])
            }
            return Ws.Group.Add.Response(name: group.name, group: group)
        case .groupUpdate:
            guard full, let p = payload as? Ws.Group.Update.Payload else { throw denied }
            let group = try store.withLock { s throws(WsError) in
                guard let index = s.groups.firstIndex(where: { $0.id == p.id }) else { throw .notFound("No such group.") }
                if let name = p.name?.wrapped { s.groups[index].name = name }
                if let description = p.description { s.groups[index].description = description.wrapped }
                if let gid = p.linuxGid?.wrapped { s.groups[index].gid = gid }
                return s.group(s.groups[index])
            }
            return Ws.Group.Update.Response(id: group.id, name: group.name, group: group)
        case .groupRemove:
            guard full, let p = payload as? Ws.Group.Remove.Payload else { throw denied }
            store.withLock { $0.groups.removeAll { $0.id == p.id } }
            return Ws.Group.Remove.Response(id: p.id)
        case .groupMemberAdd, .groupMemberRemove:
            guard full else { throw denied }
            let (groupID, userID, adding): (Int64, Int64, Bool) =
                if let p = payload as? Ws.Group.Member.Add.Payload { (p.groupID, p.userID, true) }
                else if let p = payload as? Ws.Group.Member.Remove.Payload { (p.groupID, p.userID, false) }
                else { throw WsError.invalid("Bad payload.") }
            let group = try store.withLock { s throws(WsError) in
                guard let index = s.groups.firstIndex(where: { $0.id == groupID }) else { throw .notFound("No such group.") }
                if adding {
                    if s.groups[index].members.contains(userID) { throw .conflict("Already a member.") }
                    s.groups[index].members.append(userID)
                } else {
                    s.groups[index].members.removeAll { $0 == userID }
                }
                return s.group(s.groups[index])
            }
            return adding ? Ws.Group.Member.Add.Response(group: group, groupID: groupID, userID: userID) as Any
                : Ws.Group.Member.Remove.Response(group: group, groupID: groupID, userID: userID)

        // MARK: Roles
        case .rolesAdminList:
            guard full else { throw denied }
            return Ws.Roles.Admin.List.Response(roles: store.withLock { $0.adminRoles })
        case .rolesVaultList:
            guard full else { throw denied }
            return Ws.Roles.Vault.List.Response(roles: store.withLock { $0.vaultRoles })
        case .roleAdminGet:
            guard full else { throw denied }
            let id = (payload as? Ws.Role.Admin.Get.Payload)?.id
            guard let role = store.withLock({ $0.adminRoles.first { $0.id == id } }) else { throw .notFound("No such role.") }
            return Ws.Role.Admin.Get.Response(role: role)
        case .roleVaultGet:
            guard full else { throw denied }
            let id = (payload as? Ws.Role.Vault.Get.Payload)?.id
            guard let role = store.withLock({ $0.vaultRoles.first { $0.id == id } }) else { throw .notFound("No such role.") }
            return Ws.Role.Vault.Get.Response(role: role)
        case .roleAdminAdd:
            guard full, let p = payload as? Ws.Role.Admin.Add.Payload else { throw denied }
            try ceiling(p.permissions?.map { ($0.qualified, $0.value) } ?? [], baseline: [:])
            return Ws.Role.Admin.Add.Response(role: store.withLock { s in
                let role = adminRole((s.adminRoles.map(\.id).max() ?? 0) + 1, p.name, p.description ?? "",
                                     Set(p.permissions?.filter(\.value).map(\.qualified) ?? []))
                s.adminRoles.append(role)
                return role
            })
        case .roleVaultAdd:
            guard full, let p = payload as? Ws.Role.Vault.Add.Payload else { throw denied }
            return Ws.Role.Vault.Add.Response(role: store.withLock { s in
                let role = vaultRole((s.vaultRoles.map(\.id).max() ?? 0) + 1, p.name, p.description ?? "",
                                     Set(p.permissions?.filter(\.value).map(\.qualified) ?? []))
                s.vaultRoles.append(role)
                return role
            })
        case .roleAdminUpdate:
            guard full, let p = payload as? Ws.Role.Admin.Update.Payload else { throw denied }
            return Ws.Role.Admin.Update.Response(role: try store.withLock { s throws(WsError) in
                guard let index = s.adminRoles.firstIndex(where: { $0.id == p.id }) else { throw .notFound("No such role.") }
                let old = s.adminRoles[index]
                if old.name == "super_admin" { throw .denied("The super_admin role can't be changed.") }
                if old.name == "admin" { throw .denied("You cannot edit your own role.") }
                if let permissions = p.permissions {
                    try ceiling(permissions.map { ($0.qualified, $0.value) },
                                baseline: PermissionCatalogSnapshot.of(old.permissions))
                    s.adminRoles[index] = adminRole(old.id, old.name, old.description,
                                                    Set(permissions.filter(\.value).map(\.qualified)))
                }
                if let name = p.name?.wrapped { s.adminRoles[index].name = name }
                if let description = p.description?.wrapped { s.adminRoles[index].description = description }
                s.adminRoles[index].updatedAt = Int64(Date.now.timeIntervalSince1970)
                return s.adminRoles[index]
            })
        case .roleVaultUpdate:
            guard full, let p = payload as? Ws.Role.Vault.Update.Payload else { throw denied }
            return Ws.Role.Vault.Update.Response(role: try store.withLock { s throws(WsError) in
                guard let index = s.vaultRoles.firstIndex(where: { $0.id == p.id }) else { throw .notFound("No such role.") }
                let old = s.vaultRoles[index]
                if let permissions = p.permissions {
                    s.vaultRoles[index] = vaultRole(old.id, old.name, old.description,
                                                    Set(permissions.filter(\.value).map(\.qualified)))
                }
                if let name = p.name?.wrapped { s.vaultRoles[index].name = name }
                if let description = p.description?.wrapped { s.vaultRoles[index].description = description }
                s.vaultRoles[index].updatedAt = Int64(Date.now.timeIntervalSince1970)
                return s.vaultRoles[index]
            })
        case .roleAdminDelete:
            guard full, let p = payload as? Ws.Role.Admin.Delete.Payload else { throw denied }
            try store.withLock { s throws(WsError) in
                if s.users.contains(where: { $0.roleID == p.id }) { throw .conflict("The role is still assigned to accounts.") }
                s.adminRoles.removeAll { $0.id == p.id }
            }
            return Ws.Role.Admin.Delete.Response(role: p.id)
        case .roleVaultDelete:
            guard full, let p = payload as? Ws.Role.Vault.Delete.Payload else { throw denied }
            try store.withLock { s throws(WsError) in
                if s.assignments.contains(where: { $0.roleID == p.id }) { throw .conflict("The role is assigned on a vault.") }
                s.vaultRoles.removeAll { $0.id == p.id }
            }
            return Ws.Role.Vault.Delete.Response(roleID: p.id)

        // MARK: Vault assignments
        case .rolesVaultListAssigned:
            guard full else { throw denied }
            let vault = (payload as? Ws.Roles.Vault.List.Assigned.Payload)?.id
            return Ws.Roles.Vault.List.Assigned.Response(assignedRoles: store.withLock { s in
                s.assignments.filter { $0.vaultID == vault }.compactMap { s.assigned($0) }
            })
        case .roleVaultAssign:
            guard full, let p = payload as? Ws.Role.Vault.Assign.Payload else { throw denied }
            return Ws.Role.Vault.Assign.Response(assignment: try store.withLock { s throws(WsError) in
                let assignment = PreviewAssignment(vaultID: p.vaultID, subject: p.subjectType.rawValue,
                                                   subjectID: p.subjectID, roleID: p.id)
                s.assignments.removeAll { $0.key == assignment.key }
                s.assignments.append(assignment)
                guard let role = s.assigned(assignment) else { throw .notFound("No such role.") }
                return role
            })
        case .roleVaultUnassign:
            guard full, let p = payload as? Ws.Role.Vault.Unassign.Payload else { throw denied }
            store.withLock { s in
                s.assignments.removeAll { $0.vaultID == p.vaultID && $0.subject == p.subjectType.rawValue && $0.subjectID == p.subjectID }
            }
            return Ws.Role.Vault.Unassign.Response(unassigned: true)
        case .roleVaultOverridesList:
            guard full, let p = payload as? Ws.Role.Vault.Overrides.List.Payload else { throw denied }
            let key = "\(p.vaultID)-\(p.subjectType.rawValue)-\(p.subjectID)"
            return Ws.Role.Vault.Overrides.List.Response(overrides: store.withLock { $0.overrides[key] ?? [] })
        case .roleVaultOverridesAdd:
            guard full, let p = payload as? Ws.Role.Vault.Overrides.Add.Payload else { throw denied }
            let key = "\(p.vaultID)-\(p.subjectType.rawValue)-\(p.subjectID)"
            let made = store.withLock { s in
                let made = (p.permissions ?? []).map { permission in
                    s.nextOverride += 1
                    return override(s.nextOverride, permission.qualified, permission.value ? "allow" : "deny",
                                    p.pattern, enabled: p.enabled ?? true)
                }
                s.overrides[key, default: []].append(contentsOf: made)
                return made
            }
            return Ws.Role.Vault.Overrides.Add.Response(overrides: made)
        case .roleVaultOverridesUpdate:
            guard full, let p = payload as? Ws.Role.Vault.Overrides.Update.Payload else { throw denied }
            let key = "\(p.vaultID)-\(p.subjectType.rawValue)-\(p.subjectID)"
            return Ws.Role.Vault.Overrides.Update.Response(override: try store.withLock { s throws(WsError) in
                guard let index = s.overrides[key]?.firstIndex(where: { $0.id == p.overrideID }) else {
                    throw .notFound("No such override.")
                }
                if let effect = p.effect?.wrapped { s.overrides[key]?[index].effect = effect.rawValue }
                if let pattern = p.pattern?.wrapped { s.overrides[key]?[index].globPath = pattern }
                if let enabled = p.enabled?.wrapped { s.overrides[key]?[index].enabled = enabled }
                return s.overrides[key]![index]
            })
        case .roleVaultOverridesRemove:
            guard full, let p = payload as? Ws.Role.Vault.Overrides.Remove.Payload else { throw denied }
            let key = "\(p.vaultID)-\(p.subjectType.rawValue)-\(p.subjectID)"
            store.withLock { $0.overrides[key]?.removeAll { $0.id == p.overrideID } }
            return Ws.Role.Vault.Overrides.Remove.Response(removed: true)

        default:
            return nil
        }
    }

    /// core `requireWithinCeiling`: an admin role can't newly grant what the acting account lacks.
    private static func ceiling(_ permissions: [(String, Bool)], baseline: [String: Bool]) throws(WsError) {
        let mine = Set(actorRole.filter { $0.value == true }.map(\.qualified))
        let beyond = permissions.filter { $0.1 && !mine.contains($0.0) && baseline[$0.0] != true }.map(\.0)
        if !beyond.isEmpty {
            throw .denied("you cannot grant admin permissions you do not hold: \(beyond.joined(separator: ", "))")
        }
    }

    private static var actorRole: [WsModel.Permission] {
        store.withLock { s in s.adminRoles.first { $0.name == "admin" }?.permissions ?? [] }
    }

    // MARK: Store

    struct PreviewUser {
        var id: Int64
        var name: String
        var email: String?
        var roleID: Int64
        var active: Bool
        var protected = false
        var system = false
        var linuxUid: Int64?
        var lastLogin: String?
        var ownedVaults: [String] = []
    }

    struct PreviewGroup {
        var id: Int64
        var name: String
        var description: String?
        var gid: Int64?
        var members: [Int64]
    }

    struct PreviewAssignment {
        var vaultID: Int64
        var subject: String
        var subjectID: Int64
        var roleID: Int64
        var key: String { "\(vaultID)-\(subject)-\(subjectID)" }
    }

    struct Store {
        var users: [PreviewUser]
        var groups: [PreviewGroup]
        var adminRoles: [WsModel.AdminRole]
        var vaultRoles: [WsModel.VaultRole]
        var assignments: [PreviewAssignment]
        var overrides: [String: [WsModel.PermissionOverride]]
        var nextOverride: Int64 = 10

        func summary(_ user: PreviewUser) -> WsModel.UserSummary {
            let role = adminRoles.first { $0.id == user.roleID }
            return WsModel.UserSummary(
                id: user.id, name: user.name, email: user.email, isProtected: user.protected, systemOnly: user.system,
                isActive: user.active, createdAt: "2026-0\(user.id % 9 + 1)-1\(user.id % 9)T10:00:00Z",
                updatedAt: "2026-10-01T10:00:00Z", lastLogin: user.lastLogin,
                deactivatedAt: user.active ? nil : "2026-09-30T18:00:00Z", linuxUid: user.linuxUid,
                createdBy: user.id == 13 ? nil : 13,
                adminRole: role.map { WsModel.RoleSummary(id: $0.id, name: $0.name, description: $0.description, type: "admin") },
                vaultRoles: [])
        }

        func detail(_ id: Int64?) throws(WsError) -> WsModel.User {
            guard let user = users.first(where: { $0.id == id }) else { throw .notFound("No such user.") }
            let s = summary(user)
            let groupIDs = Set(groups.filter { $0.members.contains(user.id) }.map(\.id))
            let roles = assignments.filter {
                ($0.subject == "user" && $0.subjectID == user.id) || ($0.subject == "group" && groupIDs.contains($0.subjectID))
            }.compactMap(assigned)
            return WsModel.User(
                id: s.id, name: s.name, email: s.email, isProtected: s.isProtected, systemOnly: s.systemOnly,
                isActive: s.isActive, createdAt: s.createdAt, updatedAt: s.updatedAt, lastLogin: s.lastLogin,
                deactivatedAt: s.deactivatedAt, linuxUid: s.linuxUid, createdBy: s.createdBy,
                adminRole: adminRoles.first { $0.id == user.roleID } ?? adminRoles[0], vaultRoles: .array(roles))
        }

        func group(_ group: PreviewGroup) -> WsModel.Group {
            WsModel.Group(
                id: group.id, name: group.name, description: group.description, createdAt: "2026-04-0\(group.id)T12:00:00Z",
                members: group.members.compactMap { id in
                    users.first { $0.id == id }.map {
                        WsModel.GroupMember(user: WsModel.PublicUser(id: $0.id, name: $0.name, email: $0.email, isActive: $0.active),
                                            joinedAt: "2026-05-1\(id % 10)T09:00:00Z")
                    }
                },
                gid: group.gid)
        }

        func assigned(_ assignment: PreviewAssignment) -> WsModel.VaultRole? {
            guard var role = vaultRoles.first(where: { $0.id == assignment.roleID }) else { return nil }
            role.assignedAt = 1_786_000_000 + assignment.subjectID * 86_400
            role.assignment = WsModel.VaultRoleAssignment(subjectID: String(assignment.subjectID),
                                                          vaultID: String(assignment.vaultID),
                                                          subjectType: assignment.subject)
            return role
        }
    }

    private static let actorID: Int64 = 11

    private static let guest = WsModel.User(
        id: 40, name: "studio-guest", email: "guest@studio.example.com", isProtected: false, systemOnly: false,
        isActive: true, createdAt: "2026-06-01T10:00:00Z", updatedAt: "2026-06-01T10:00:00Z",
        adminRole: adminRole(1, "unprivileged", "Own vaults and API keys only.", unprivilegedGrants), vaultRoles: .array([]))

    private static func session(_ user: WsModel.User) -> WsModel.SessionUser {
        WsModel.SessionUser(
            id: user.id, name: user.name, email: user.email, isProtected: user.isProtected, systemOnly: user.systemOnly,
            isActive: user.isActive, createdAt: user.createdAt, updatedAt: user.updatedAt,
            adminRole: WsModel.SessionAdminRole(
                id: user.adminRole.id, name: user.adminRole.name, description: user.adminRole.description,
                createdAt: user.adminRole.createdAt, updatedAt: user.adminRole.updatedAt,
                permissions: user.adminRole.permissions.map { .init(qualified: $0.qualified, value: $0.value ?? false) },
                s3Gateway: .init(view: true, manageService: false, manageCredentials: false, assignPrincipal: false,
                                 manageBuckets: false, manageBudgets: false)),
            vaultRoles: .array([]))
    }

    private static let store = Mutex(Store(
        users: [
            PreviewUser(id: 13, name: "admin", email: "admin@example.com", roleID: 9, active: true, protected: true,
                        linuxUid: 0, lastLogin: "2026-10-18T07:12:00Z"),
            PreviewUser(id: 11, name: "cooper", email: "cooper@example.com", roleID: 8, active: true, linuxUid: 1000,
                        lastLogin: "2026-10-20T08:02:00Z", ownedVaults: ["Family Photos (preview)", "Documents (preview)"]),
            PreviewUser(id: 3, name: "maya", email: "maya@example.com", roleID: 4, active: true,
                        lastLogin: "2026-10-19T21:40:00Z"),
            PreviewUser(id: 4, name: "jonah", email: "jonah@example.com", roleID: 1, active: true,
                        lastLogin: "2026-10-12T16:05:00Z"),
            PreviewUser(id: 5, name: "priya", email: nil, roleID: 1, active: false, lastLogin: "2026-08-02T11:30:00Z",
                        ownedVaults: ["Media Archive (preview)"]),
            PreviewUser(id: 14, name: "studio", email: "studio@example.com", roleID: 1, active: true),
            PreviewUser(id: 7, name: "sam", email: "sam@example.com", roleID: 2, active: true,
                        lastLogin: "2026-10-20T06:55:00Z"),
            PreviewUser(id: 8, name: "vaulthalla", email: nil, roleID: 9, active: true, protected: true, system: true),
        ],
        groups: [
            PreviewGroup(id: 1, name: "Family (preview)", description: "Everyone at home.", members: [11, 3, 4]),
            PreviewGroup(id: 2, name: "Studio crew (preview)", description: "Editors and the studio account.", gid: 2001, members: [5, 14]),
            PreviewGroup(id: 3, name: "Auditors (preview)", description: nil, members: [7]),
        ],
        adminRoles: [
            adminRole(1, "unprivileged", "Own vaults and API keys only.", unprivilegedGrants),
            adminRole(2, "auditor", "Reads everything, changes nothing.",
                      Set(adminCatalog.map(\.qualified).filter { $0.hasSuffix(".view") || $0.hasSuffix("view_stats") })),
            adminRole(3, "support", "Helps users: resets passwords, views accounts.",
                      ["admin.identities.users.view", "admin.identities.users.reset-password", "admin.identities.groups.view"]),
            adminRole(4, "identity_admin", "Manages user accounts and groups.",
                      Set(adminCatalog.map(\.qualified).filter { $0.hasPrefix("admin.identities.users") || $0.hasPrefix("admin.identities.groups") }).union(unprivilegedGrants)),
            adminRole(8, "admin", "Everything except key export and system settings.",
                      Set(adminCatalog.map(\.qualified)).subtracting(adminWithheld)),
            adminRole(9, "super_admin", "The node's owner: every permission.", Set(adminCatalog.map(\.qualified))),
            adminRole(12, "photo_curator", "Preview: curates shared albums.",
                      unprivilegedGrants.union(["admin.vaults.user.view", "admin.identities.groups.view"])),
        ],
        vaultRoles: [
            vaultRole(1, "implicit_deny", "Nothing: an explicit no.", []),
            vaultRole(2, "reader", "Browse, preview and download.",
                      ["vault.fs.files.preview", "vault.fs.files.download", "vault.fs.directories.list"]),
            vaultRole(3, "contributor", "Read and add files; no deletes.",
                      ["vault.fs.files.preview", "vault.fs.files.download", "vault.fs.files.upload",
                       "vault.fs.directories.list", "vault.fs.directories.touch", "vault.fs.files.share.internal"]),
            vaultRole(4, "editor", "Everything with files and folders.",
                      Set(vaultCatalog.map(\.qualified).filter { $0.hasPrefix("vault.fs.") && !$0.contains("share.public") })),
            vaultRole(5, "manager", "Editor plus sharing and sync settings.",
                      Set(vaultCatalog.map(\.qualified).filter { !$0.hasPrefix("vault.roles.") })),
            vaultRole(6, "full", "Every vault permission.", Set(vaultCatalog.map(\.qualified))),
            vaultRole(7, "share_download_only", "Share preset: download only.", ["vault.fs.files.download"]),
            vaultRole(8, "share_browse_download", "Share preset: browse and download.",
                      ["vault.fs.files.preview", "vault.fs.files.download", "vault.fs.directories.list"]),
            vaultRole(9, "share_upload_dropbox", "Share preset: upload only.", ["vault.fs.files.upload"]),
            vaultRole(11, "album_viewer", "Preview: browse the shared albums.",
                      ["vault.fs.files.preview", "vault.fs.directories.list"]),
        ],
        assignments: [
            PreviewAssignment(vaultID: 1, subject: "group", subjectID: 1, roleID: 3),
            PreviewAssignment(vaultID: 1, subject: "user", subjectID: 3, roleID: 5),
            PreviewAssignment(vaultID: 1, subject: "user", subjectID: 4, roleID: 2),
            PreviewAssignment(vaultID: 3, subject: "user", subjectID: 11, roleID: 6),
            PreviewAssignment(vaultID: 4, subject: "group", subjectID: 2, roleID: 4),
        ],
        overrides: [
            "1-user-4": [
                override(1, "vault.fs.files.download", "deny", "/private/**"),
                override(2, "vault.fs.files.upload", "allow", "/inbox/**", enabled: false),
            ],
        ]))

    // MARK: Catalog

    private static let unprivilegedGrants: Set<String> = Set(adminCatalog.map(\.qualified).filter {
        $0.hasPrefix("admin.vaults.self.") || $0.hasPrefix("admin.keys.api.self.")
    })

    /// What the actor's `admin` role doesn't hold: the ceiling locks these.
    private static let adminWithheld: Set<String> = [
        "admin.keys.encryption.export", "admin.keys.encryption.rotate", "admin.settings.auth.edit",
        "admin.settings.database.edit", "admin.identities.admins.delete",
    ]

    private static func perms(_ prefix: String, _ leaves: [(String, String)]) -> [(String, String)] {
        leaves.map { ("\(prefix).\($0.0)", $0.1) }
    }

    private static let adminCatalog: [WsModel.Permission] = {
        let rows: [(String, String)] =
            perms("admin.identities.users", [("view", "See user accounts."), ("add", "Create user accounts."),
                                             ("edit", "Change user accounts."), ("delete", "Delete user accounts."),
                                             ("reset-password", "Set a new password for a user account.")])
            + perms("admin.identities.admins", [("view", "See admin accounts."), ("add", "Create admin accounts."),
                                                ("edit", "Change admin accounts."), ("delete", "Delete admin accounts."),
                                                ("reset-password", "Set a new password for an admin account.")])
            + perms("admin.identities.groups", [("view", "See every group."), ("add", "Create groups."),
                                                ("edit", "Rename groups."), ("delete", "Delete groups."),
                                                ("add-member", "Add accounts to groups."),
                                                ("remove-member", "Remove accounts from groups.")])
            + perms("admin.vaults.self", [("view", "See vaults the account owns."), ("add", "Create vaults."),
                                          ("edit", "Change own vaults."), ("delete", "Delete own vaults.")])
            + perms("admin.vaults.user", [("view", "See vaults owned by users."), ("edit", "Change users' vaults."),
                                          ("delete", "Delete users' vaults.")])
            + perms("admin.vaults.admin", [("view", "See vaults owned by admins."), ("edit", "Change admins' vaults."),
                                           ("delete", "Delete admins' vaults.")])
            + perms("admin.roles.admin", [("view", "See admin roles."), ("add", "Create admin roles."),
                                          ("edit", "Change admin roles."), ("delete", "Delete admin roles.")])
            + perms("admin.roles.vault", [("view", "See vault roles."), ("add", "Create vault roles."),
                                          ("edit", "Change vault roles."), ("delete", "Delete vault roles.")])
            + perms("admin.keys.api.self", [("view", "See own provider credentials."), ("add", "Add provider credentials."),
                                            ("edit", "Change own provider credentials."), ("delete", "Delete own provider credentials."),
                                            ("consume", "Use own credentials in vaults.")])
            + perms("admin.keys.encryption", [("view", "See vault key versions."), ("export", "Export vault keys."),
                                              ("rotate", "Rotate vault keys.")])
            + perms("admin.settings.auth", [("view", "See authentication settings."), ("edit", "Change authentication settings.")])
            + perms("admin.settings.database", [("view", "See database settings."), ("edit", "Change database settings.")])
            + perms("admin.stats", [("view", "See server health and telemetry.")])
            + perms("admin.audits", [("view", "Read audit logs.")])
        return rows.enumerated().map { index, row in
            WsModel.Permission(bitPosition: Int64(index), qualified: row.0, description: row.1,
                               slug: String(row.0.split(separator: ".").last ?? ""))
        }
    }()

    private static let vaultCatalog: [WsModel.Permission] = {
        let rows: [(String, String)] =
            perms("vault.fs.files", [("preview", "Preview files."), ("download", "Download files."),
                                     ("upload", "Upload new files."), ("overwrite", "Replace existing files."),
                                     ("rename", "Rename files."), ("move", "Move files."), ("delete", "Delete files."),
                                     ("share.internal", "Share with vault members."),
                                     ("share.public", "Share by public link.")])
            + perms("vault.fs.directories", [("list", "List folder contents."), ("touch", "Create folders."),
                                             ("rename", "Rename folders."), ("delete", "Delete folders.")])
            + perms("vault.sync", [("config.view", "See sync settings."), ("config.edit", "Change sync settings."),
                                   ("action.trigger", "Run a sync now."),
                                   ("action.resolve_conflicts", "Resolve sync conflicts.")])
            + perms("vault.roles", [("view", "See who has access."), ("assign", "Grant vault roles."),
                                    ("revoke", "Revoke vault roles."), ("assign_override", "Add path overrides.")])
        return rows.enumerated().map { index, row in
            WsModel.Permission(bitPosition: Int64(index), qualified: row.0, description: row.1,
                               slug: String(row.0.split(separator: ".").last ?? ""))
        }
    }()

    private static func exported(_ catalog: [WsModel.Permission], _ granted: Set<String>) -> [WsModel.Permission] {
        catalog.map { p in
            var p = p
            p.value = granted.contains(p.qualified)
            return p
        }
    }

    private static func adminRole(_ id: Int64, _ name: String, _ description: String,
                                  _ granted: Set<String>) -> WsModel.AdminRole {
        WsModel.AdminRole(id: id, name: name, description: description, createdAt: 1_772_000_000 + id * 86_400,
                          updatedAt: 1_789_000_000 + id * 86_400, permissions: exported(adminCatalog, granted),
                          s3Gateway: .init(view: false, manageService: false, manageCredentials: false,
                                           assignPrincipal: false, manageBuckets: false, manageBudgets: false))
    }

    private static func vaultRole(_ id: Int64, _ name: String, _ description: String,
                                  _ granted: Set<String>) -> WsModel.VaultRole {
        WsModel.VaultRole(id: id, name: name, description: description, createdAt: 1_772_000_000 + id * 86_400,
                          updatedAt: 1_789_000_000 + id * 86_400, permissions: exported(vaultCatalog, granted))
    }

    private static func override(_ id: Int64, _ qualified: String, _ effect: String, _ glob: String,
                                 enabled: Bool = true) -> WsModel.PermissionOverride {
        let permission = vaultCatalog.first { $0.qualified == qualified }
            ?? WsModel.Permission(bitPosition: 0, qualified: qualified, description: "", slug: qualified)
        return WsModel.PermissionOverride(id: id, permission: permission, effect: effect, assignmentID: 1,
                                          enabled: enabled, globPath: glob)
    }
}

private nonisolated enum PermissionCatalogSnapshot {
    static func of(_ permissions: [WsModel.Permission]) -> [String: Bool] {
        Dictionary(permissions.map { ($0.qualified, $0.value ?? false) }, uniquingKeysWith: { a, _ in a })
    }
}
#endif
