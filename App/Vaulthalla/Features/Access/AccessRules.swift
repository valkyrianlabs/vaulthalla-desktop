import Foundation
import VHContract

/// The two kinds of role the daemon defines: admin roles (one per account, what it can manage across the node) and
/// vault roles (assigned to a user or group on a vault, what it can do inside).
nonisolated enum RoleKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case admin, vault

    var id: Self { self }
    var title: String { self == .admin ? "Admin Roles" : "Vault Roles" }
    var noun: String { self == .admin ? "admin role" : "vault role" }
}

/// Whether a control is live, and why not. The daemon authorizes every request; a verdict only decides what the UI
/// offers and explains, so a person isn't refused after the fact.
nonisolated struct Verdict: Hashable, Sendable {
    var allowed: Bool
    var reason: String?

    static let ok = Verdict(allowed: true)
    static func no(_ reason: String) -> Verdict { Verdict(allowed: false, reason: reason) }
}

/// The account this Mac acts for on the node, from `auth.isAuthenticated` (a paired device's session user).
nonisolated struct AccessActor: Hashable, Sendable {
    var id: Int64
    var name: String
    var roleName: String
    var granted: Set<String>

    init(id: Int64, name: String, roleName: String, granted: Set<String>) {
        self.id = id
        self.name = name
        self.roleName = roleName
        self.granted = granted
    }

    init(_ user: WsModel.SessionUser) {
        self.init(id: user.id, name: user.name, roleName: user.adminRole.name,
                  granted: Set(user.adminRole.permissions.filter(\.value).map(\.qualified)))
    }

    /// The web's `isSuperAdminUser`.
    var isSuperAdmin: Bool {
        roleName == AccessRules.superAdminRole && granted.contains("admin.keys.encryption.rotate")
    }

    func has(_ qualified: String) -> Bool { granted.contains(qualified) }
    func hasAny(_ qualified: [String]) -> Bool { qualified.contains(where: granted.contains) }
}

/// What the client can know about an account before deciding which of its controls are live.
nonisolated struct AccountFacts: Hashable, Sendable {
    var id: Int64
    var name: String
    var isProtected: Bool
    var systemOnly: Bool
    var roleName: String?
    var roleID: Int64?

    init(_ user: WsModel.UserSummary) {
        self.init(id: user.id, name: user.name, isProtected: user.isProtected, systemOnly: user.systemOnly,
                  roleName: user.adminRole?.name, roleID: user.adminRole?.id)
    }

    init(_ user: WsModel.User) {
        self.init(id: user.id, name: user.name, isProtected: user.isProtected, systemOnly: user.systemOnly,
                  roleName: user.adminRole.name, roleID: user.adminRole.id)
    }

    init(id: Int64, name: String, isProtected: Bool, systemOnly: Bool, roleName: String?, roleID: Int64?) {
        self.id = id
        self.name = name
        self.isProtected = isProtected
        self.systemOnly = systemOnly
        self.roleName = roleName
        self.roleID = roleID
    }
}

/// Everything an account's controls need.
nonisolated struct AccountRules: Hashable, Sendable {
    var isSelf: Bool
    var profile: Verdict
    var rename: Verdict
    var role: Verdict
    var active: Verdict
    var password: Verdict
    var remove: Verdict
}

/// Client mirror of core's account and role rules (the web console's `features/access/rbac.ts`, after core
/// `ops/Users.cpp` and `ops/Roles.cpp`). An unknown actor (the session user couldn't be read) allows everything:
/// the UI never hides what the server might allow, and the server's denial is shown when it refuses.
nonisolated enum AccessRules {
    static let superAdminRole = "super_admin"

    static let builtinAdminRoles: Set<String> = [
        "unprivileged", "auditor", "support", "identity_admin", "security_admin", "platform_operator", "vault_admin",
        "admin", "super_admin", "key_custodian",
    ]
    static let builtinVaultRoles: Set<String> = [
        "implicit_deny", "guest", "reader", "contributor", "editor", "manager", "power_user", "full", "role_manager",
        "sync_operator", "share_preview_read", "share_download_only", "share_upload_dropbox", "share_browse_download",
        "share_contributor_scoped",
    ]

    static func isBuiltin(_ kind: RoleKind, _ name: String) -> Bool {
        (kind == .admin ? builtinAdminRoles : builtinVaultRoles).contains(name)
    }

    static let viewUsers = ["admin.identities.users.view", "admin.identities.admins.view"]
    static let addUsers = ["admin.identities.users.add", "admin.identities.admins.add"]

    /// core `ops::users::isAdminIdentity`: any admin permission beyond the account's own vaults and API keys makes it
    /// an admin account, which needs `admin.identities.admins.*` to manage. nil when the permissions aren't known.
    static func isAdminIdentity(_ permissions: [WsModel.Permission]?) -> Bool? {
        guard let permissions else { return nil }
        return permissions.contains {
            $0.value == true && !$0.qualified.hasPrefix("admin.vaults.self.") && !$0.qualified.hasPrefix("admin.keys.api.self.")
        }
    }

    /// Admin permissions `permissions` grants that the actor lacks (core `roles::permissionsBeyondActor`).
    static func beyond(_ actor: AccessActor, _ permissions: [WsModel.Permission]?) -> [String]? {
        guard let permissions else { return nil }
        if actor.isSuperAdmin { return [] }
        return permissions.filter { $0.value == true && !actor.has($0.qualified) }.map(\.qualified)
    }

    enum Verb: String { case view, add, edit, delete, resetPassword = "reset-password" }

    static func canForClass(_ actor: AccessActor, _ verb: Verb, _ permissions: [WsModel.Permission]?) -> Bool {
        let users = actor.has("admin.identities.users.\(verb.rawValue)")
        let admins = actor.has("admin.identities.admins.\(verb.rawValue)")
        guard let adminClass = isAdminIdentity(permissions) else { return users || admins }
        return adminClass ? admins : users
    }

    /// core `ops::users::requireManage`, as far as the client can know it.
    static func manage(_ actor: AccessActor?, _ target: AccountFacts, _ verb: Verb,
                       rolePermissions: [WsModel.Permission]?) -> Verdict {
        if target.isProtected {
            return .no("This is a protected account. It can only be changed from the server with the vh CLI.")
        }
        if target.roleName == superAdminRole {
            return .no("Super admin accounts can't be changed from another account.")
        }
        guard let actor else { return .ok }
        if !canForClass(actor, verb, rolePermissions) {
            let kind = isAdminIdentity(rolePermissions) == true ? "admin accounts" : "user accounts"
            let action = switch verb {
            case .resetPassword: "reset passwords of"
            case .delete: "delete"
            default: "edit"
            }
            return .no("Your role doesn't allow you to \(action) \(kind).")
        }
        if let beyond = beyond(actor, rolePermissions), !beyond.isEmpty {
            return .no("This account's role grants admin permissions you don't hold, so only a more privileged administrator can change it.")
        }
        return .ok
    }

    static func account(_ actor: AccessActor?, _ target: AccountFacts,
                        rolePermissions: [WsModel.Permission]?) -> AccountRules {
        if let actor, actor.id == target.id {
            let profile: Verdict = target.isProtected
                ? .no("This is a protected account. It can only be changed from the server with the vh CLI.") : .ok
            return AccountRules(
                isSelf: true,
                profile: profile,
                rename: !profile.allowed ? profile
                    : target.roleName == superAdminRole ? .no("The super admin account can't be renamed.") : .ok,
                role: .no("You can't change your own role. Ask another administrator."),
                active: .no("You can't deactivate your own account."),
                password: .no("Change your own password from the web console's account page; it asks for the current one."),
                remove: .no("You can't delete your own account. Ask another administrator."))
        }
        let edit = manage(actor, target, .edit, rolePermissions: rolePermissions)
        return AccountRules(
            isSelf: false, profile: edit, rename: edit, role: edit, active: edit,
            password: manage(actor, target, .resetPassword, rolePermissions: rolePermissions),
            remove: manage(actor, target, .delete, rolePermissions: rolePermissions))
    }

    /// Whether the actor may give an account this admin role (core `requireAssignable` plus the class permission).
    static func assign(_ actor: AccessActor?, _ role: WsModel.AdminRole, _ verb: Verb) -> Verdict {
        if role.name == superAdminRole { return .no("The super_admin role can't be assigned.") }
        guard let actor else { return .ok }
        if !canForClass(actor, verb, role.permissions) {
            let kind = isAdminIdentity(role.permissions) == true ? "admin" : "user"
            return .no("Your role doesn't allow you to \(verb == .add ? "create" : "manage") \(kind) accounts.")
        }
        if let beyond = beyond(actor, role.permissions), !beyond.isEmpty {
            return .no("Grants admin permissions you don't hold.")
        }
        return .ok
    }

    /// Role editing (core `ops::roles::updateAdminRole` / `removeAdminRole`).
    static func roleEdit(_ actor: AccessActor?, _ kind: RoleKind, roleName: String?) -> (edit: Verdict, remove: Verdict) {
        if kind == .admin, let roleName {
            if roleName == superAdminRole {
                let reason = Verdict.no("The built-in super_admin role always holds every permission and can't be changed.")
                return (reason, reason)
            }
            if let actor, actor.roleName == roleName {
                let reason = Verdict.no("This is your own role. Ask another administrator to change it.")
                return (reason, reason)
            }
        }
        guard let actor else { return (.ok, .ok) }
        return (
            actor.has("admin.roles.\(kind.rawValue).edit") ? .ok : .no("Your role doesn't allow you to edit \(kind.rawValue) roles."),
            actor.has("admin.roles.\(kind.rawValue).delete") ? .ok : .no("Your role doesn't allow you to delete \(kind.rawValue) roles.")
        )
    }

    /// The escalation ceiling (core `ops::roles::requireWithinCeiling`): an admin role can't newly grant what the actor
    /// lacks. Vault roles have none. nil when nothing is locked.
    static func ceiling(_ actor: AccessActor?, _ kind: RoleKind, saved: [String: Bool]) -> ((String) -> String?)? {
        guard kind == .admin, let actor, !actor.isSuperAdmin else { return nil }
        return { qualified in
            actor.has(qualified) || saved[qualified] == true ? nil : "You don't hold this permission, so you can't grant it."
        }
    }

    // MARK: Client-side form checks (core's registration Validator; strength and breach checks stay on the server)

    static func nameProblem(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 3 { return "At least 3 characters" }
        if trimmed.count > 50 { return "At most 50 characters" }
        return nil
    }

    static func emailProblem(_ email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || (trimmed.contains("@") && trimmed.contains(".")) ? nil : "Enter a valid email address"
    }

    static func passwordProblem(_ password: String) -> String? {
        if password.count < 8 { return "At least 8 characters" }
        if password.count > 128 { return "At most 128 characters" }
        if password.count < 20, !(password.contains(where: \.isNumber) && password.contains(where: \.isLetter)) {
            return "Use letters and at least one digit, or 20+ characters"
        }
        return nil
    }
}

/// Role and permission names as people read them.
nonisolated enum AccessFormat {
    /// `power_user` → "Power User" (the web's `titleCase`).
    static func roleLabel(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "—" }
        return name.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// Unix seconds as a day.
    static func day(epoch seconds: Int64?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .omitted)
    }

    static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}
