import Foundation
import VHContract

/// Readable names for the permissions the daemon exports (the web console's `roles/permissionCatalog.ts`). Groups come
/// from the qualified-name prefix and labels from the remaining segments; descriptions always come from the server. A
/// permission the catalog doesn't know still shows, grouped by its first segments and labelled from its name, so a new
/// core permission never disappears.
nonisolated enum PermissionCatalog {
    struct GroupDef: Sendable {
        var prefix: String
        var label: String
        var hint: String?
        var section: String
    }

    struct Item: Identifiable, Hashable, Sendable {
        var qualified: String
        var label: String
        var description: String
        var bitPosition: Int64
        var id: String { qualified }
    }

    struct Group: Identifiable, Hashable, Sendable {
        var key: String
        var label: String
        var hint: String?
        var section: String
        var items: [Item]
        var id: String { key }
    }

    private static let adminGroups: [GroupDef] = [
        .init(prefix: "admin.identities.users", label: "User accounts", hint: "Accounts without admin permissions", section: "Identities"),
        .init(prefix: "admin.identities.admins", label: "Admin accounts", hint: "Accounts whose role grants admin permissions", section: "Identities"),
        .init(prefix: "admin.identities.groups", label: "Groups", section: "Identities"),
        .init(prefix: "admin.vaults.self", label: "Own vaults", hint: "Vaults the account owns", section: "Vaults"),
        .init(prefix: "admin.vaults.user", label: "Users' vaults", hint: "Vaults owned by user accounts", section: "Vaults"),
        .init(prefix: "admin.vaults.admin", label: "Admins' vaults", hint: "Vaults owned by admin accounts", section: "Vaults"),
        .init(prefix: "admin.roles.admin", label: "Admin roles", section: "Roles"),
        .init(prefix: "admin.roles.vault", label: "Vault roles", section: "Roles"),
        .init(prefix: "admin.keys.api.self", label: "Own provider credentials", hint: "S3/R2 API keys the account owns", section: "Keys"),
        .init(prefix: "admin.keys.api.user", label: "Users' provider credentials", section: "Keys"),
        .init(prefix: "admin.keys.api.admin", label: "Admins' provider credentials", section: "Keys"),
        .init(prefix: "admin.keys.encryption", label: "Encryption keys", section: "Keys"),
        .init(prefix: "admin.s3_gateway", label: "S3 gateway", section: "Services"),
        .init(prefix: "admin.upstream", label: "Upstream buckets",
              hint: "S3/R2 bucket administration: inventory, locks, lifecycle, event sync and cleanup", section: "Services"),
        .init(prefix: "admin.settings", label: "Settings", section: "System"),
        .init(prefix: "admin.stats", label: "Health and stats", hint: "Server, daemon and system telemetry (the Health area)", section: "System"),
        .init(prefix: "admin.audits", label: "Audit logs", section: "System"),
    ]

    private static let vaultGroups: [GroupDef] = [
        .init(prefix: "vault.fs.files", label: "Files", section: "Content"),
        .init(prefix: "vault.fs.directories", label: "Folders", section: "Content"),
        .init(prefix: "vault.sync", label: "Sync", section: "Operations"),
        .init(prefix: "vault.roles", label: "Access & roles", hint: "Who can grant, change and revoke access in the vault", section: "Governance"),
    ]

    private static let leafLabels: [String: String] = [
        "view": "View", "add": "Add", "edit": "Edit", "delete": "Delete", "remove": "Delete", "create": "Create",
        "reset-password": "Reset passwords", "add-member": "Add members", "remove-member": "Remove members",
        "view-members": "View members", "view_stats": "View statistics", "configure": "Configure lifecycle and events",
        "provision": "Create and adopt buckets", "protect": "Protect buckets", "unprotect": "Remove bucket protection",
        "destroy": "Detach and delete buckets", "export": "Export", "rotate": "Rotate", "consume": "Use in vaults",
        "manage_service": "Manage the service", "manage_credentials": "Manage credentials",
        "assign_principal": "Assign credentials to others", "manage_buckets": "Manage bucket bindings",
        "manage_budgets": "Manage budgets", "preview": "Preview", "upload": "Upload", "download": "Download",
        "overwrite": "Overwrite", "rename": "Rename", "move": "Move", "copy": "Copy", "list": "List contents",
        "touch": "Create folders", "share.internal": "Share with vault members", "share.public": "Share by public link",
        "share.public_with_val": "Share by verified link", "config.view": "View sync settings",
        "config.edit": "Edit sync settings", "action.trigger": "Run a sync", "action.sign_waiver": "Sign encryption waiver",
        "action.resolve_conflicts": "Resolve sync conflicts", "assign": "Assign roles", "modify": "Change roles",
        "revoke": "Revoke roles", "assign_override": "Assign path overrides", "modify_override": "Change path overrides",
        "revoke_override": "Revoke path overrides", "view_override": "View path overrides",
    ]

    private static func humanize(_ value: String) -> String {
        let text = value.replacing(/[._-]+/, with: " ").trimmingCharacters(in: .whitespaces)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func defs(_ kind: RoleKind) -> [GroupDef] { kind == .admin ? adminGroups : vaultGroups }

    private static func def(_ kind: RoleKind, _ qualified: String) -> GroupDef {
        let best = defs(kind)
            .filter { qualified == $0.prefix || qualified.hasPrefix($0.prefix + ".") }
            .max { $0.prefix.count < $1.prefix.count }
        if let best { return best }
        let segments = qualified.split(separator: ".").map(String.init)
        let prefix = segments.prefix(max(1, segments.count - 1)).joined(separator: ".")
        let middle = segments.count > 2 ? segments[1..<(segments.count - 1)].joined(separator: " ") : ""
        return GroupDef(prefix: prefix, label: humanize(middle.isEmpty ? prefix : middle), section: "Other")
    }

    static func label(_ kind: RoleKind, _ qualified: String) -> String {
        let def = def(kind, qualified)
        let rest = qualified.count > def.prefix.count ? String(qualified.dropFirst(def.prefix.count + 1)) : qualified
        // Settings read "View websocket settings" rather than "Websocket view".
        if def.prefix == "admin.settings" {
            let parts = rest.split(separator: ".")
            let module = parts.first.map(String.init) ?? rest
            return "\(parts.last == "edit" ? "Edit" : "View") \(module) settings"
        }
        return leafLabels[rest] ?? humanize(rest)
    }

    /// "Files: Download" for a vault permission named alone (overrides).
    static func longLabel(_ kind: RoleKind, _ qualified: String) -> String {
        "\(def(kind, qualified).label): \(label(kind, qualified))"
    }

    /// Groups in catalog order (unknown groups last), items in the server's bit order.
    static func groups(_ kind: RoleKind, _ permissions: [WsModel.Permission]) -> [Group] {
        let order = defs(kind).map(\.prefix)
        var groups: [String: Group] = [:]
        for permission in permissions {
            let def = def(kind, permission.qualified)
            let item = Item(qualified: permission.qualified, label: label(kind, permission.qualified),
                            description: permission.description, bitPosition: permission.bitPosition)
            groups[def.prefix, default: Group(key: def.prefix, label: def.label, hint: def.hint, section: def.section,
                                              items: [])].items.append(item)
        }
        func rank(_ key: String) -> Int { order.firstIndex(of: key) ?? order.count }
        return groups.values
            .map { group in
                var group = group
                group.items.sort { $0.bitPosition < $1.bitPosition }
                return group
            }
            .sorted { rank($0.key) != rank($1.key) ? rank($0.key) < rank($1.key) : $0.label < $1.label }
    }

    /// The `{qualified, value}` map of a role's exported permissions.
    static func snapshot(_ permissions: [WsModel.Permission]) -> [String: Bool] {
        Dictionary(permissions.map { ($0.qualified, $0.value ?? false) }, uniquingKeysWith: { first, _ in first })
    }
}
