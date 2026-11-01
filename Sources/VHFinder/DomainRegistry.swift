public import Foundation

/// A File Provider domain as the system reports it (`NSFileProviderDomain`), without the framework: what the app
/// lists and the tests fake.
public struct DomainSnapshot: Hashable, Sendable, Identifiable {
    /// The raw identifier: ``VaultDomainID/identifier`` for Desktop's domains.
    public let identifier: String
    public let displayName: String
    /// Whether the operator allowed the domain in System Settings ▸ General ▸ Login Items & Extensions ▸ File
    /// Providers. A new domain starts disallowed until the provider is turned on there once; no API can do it.
    public let userEnabled: Bool
    public let isDisconnected: Bool
    public let isHidden: Bool

    public init(identifier: String, displayName: String, userEnabled: Bool, isDisconnected: Bool = false,
                isHidden: Bool = false) {
        self.identifier = identifier
        self.displayName = displayName
        self.userEnabled = userEnabled
        self.isDisconnected = isDisconnected
        self.isHidden = isHidden
    }

    public var id: String { identifier }

    /// The vault it shows; nil for an identifier Desktop didn't make.
    public var vault: VaultDomainID? { VaultDomainID(identifier: identifier) }

    public var state: DomainState {
        if !userEnabled { return .needsUserApproval }
        if isDisconnected { return .disconnected }
        if isHidden { return .hidden }
        return .active
    }
}

/// What a domain is doing, in the order the UI cares about.
public enum DomainState: String, Hashable, Sendable {
    /// Waiting for the operator to turn Vaulthalla on under File Providers in System Settings: the system shows
    /// nothing and the extension isn't started until then (FP -2011, "Sync is not enabled").
    case needsUserApproval
    case disconnected
    case hidden
    case active

    public var label: String {
        switch self {
        case .needsUserApproval: "Needs approval in System Settings"
        case .disconnected: "Disconnected"
        case .hidden: "Hidden"
        case .active: "Active"
        }
    }
}

/// Where the operator allows File Provider extensions: System Settings ▸ General ▸ Login Items & Extensions ▸ File
/// Providers.
public enum FileProviderSettings {
    /// The File Providers list itself (the extension point's anchor in Login Items & Extensions).
    public static let fileProvidersURL = URL(
        string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fileprovider-nonui")!
    /// Login Items & Extensions, for when the anchor isn't recognized.
    public static let loginItemsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    /// Whether any of `domains` waits for the operator in System Settings.
    public static func needsApproval(_ domains: [DomainSnapshot]) -> Bool {
        domains.contains { $0.state == .needsUserApproval }
    }
}

/// The File Provider consent gate as Desktop handles it (docs/architecture.md §7, "Order matters"). The switch in System
/// Settings is per provider and lists no domains, and a domain added before it is turned on can stay disallowed after
/// it is. So Desktop adds one domain while the operator hasn't turned Vaulthalla on, keeps further selections pending,
/// adds them once a domain is allowed, and offers to add a domain stuck behind the gate again.
public enum ConsentGate {
    /// Whether Vaulthalla is on under File Providers, as far as the system shows it: one of its domains is allowed.
    public static func providerEnabled(_ domains: [DomainSnapshot]) -> Bool {
        domains.contains(where: \.userEnabled)
    }

    /// Domains exist and none is allowed: the operator still has to turn Vaulthalla on.
    public static func awaitingApproval(_ domains: [DomainSnapshot]) -> Bool {
        !domains.isEmpty && !providerEnabled(domains)
    }

    /// Which of `pending` to add now, in order: all of them once a domain is allowed (they start allowed too), the
    /// first while there is no domain at all (it either starts allowed or asks for the switch), and none while a domain
    /// waits for approval. Vaults that already have a domain are left out.
    public static func admit(_ pending: [VaultDomain], existing: [DomainSnapshot]) -> [VaultDomain] {
        let identifiers = Set(existing.map(\.identifier))
        var seen: Set<VaultDomainID> = []
        let fresh = pending.filter { !identifiers.contains($0.id.identifier) && seen.insert($0.id).inserted }
        if providerEnabled(existing) { return fresh }
        if existing.isEmpty { return Array(fresh.prefix(1)) }
        return []
    }

    /// Domains to remove and add again: disallowed while another domain of the provider is allowed, which the switch
    /// in System Settings can't fix. Adding one again after approval brings it up allowed.
    public static func stuck(_ domains: [DomainSnapshot]) -> [DomainSnapshot] {
        guard providerEnabled(domains) else { return [] }
        return domains.filter { !$0.userEnabled && $0.vault != nil }
    }
}

/// Adds, removes and lists this app's File Provider domains: `NSFileProviderManager` in the app, a fake in tests.
public protocol DomainRegistrar: Sendable {
    func domains() async throws -> [DomainSnapshot]
    func add(_ domain: VaultDomain) async throws
    func remove(identifier: String) async throws
}

/// The changes that turn the domains that exist into the ones wanted.
public struct DomainPlan: Hashable, Sendable {
    public var add: [VaultDomain] = []
    /// Domains to drop: wanted no more, or not Desktop's shape at all (a leftover). Identifiers.
    public var remove: [String] = []
    /// Wanted domains whose display name changed (the vault or node was renamed): removed and added again, since
    /// the system keeps a domain's name for its life.
    public var rename: [VaultDomain] = []

    public init(add: [VaultDomain] = [], remove: [String] = [], rename: [VaultDomain] = []) {
        self.add = add
        self.remove = remove
        self.rename = rename
    }

    public var isEmpty: Bool { add.isEmpty && remove.isEmpty && rename.isEmpty }

    /// The plan from `existing` to `wanted`. The order of `wanted` is kept; duplicates in it count once.
    public static func reconcile(wanted: [VaultDomain], existing: [DomainSnapshot]) -> DomainPlan {
        var plan = DomainPlan()
        var seen: Set<VaultDomainID> = []
        let existingByID = Dictionary(existing.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        for domain in wanted where seen.insert(domain.id).inserted {
            if let current = existingByID[domain.id.identifier] {
                if current.displayName != domain.displayName { plan.rename.append(domain) }
            } else {
                plan.add.append(domain)
            }
        }
        plan.remove = existing.map(\.identifier).filter { identifier in
            guard let id = VaultDomainID(identifier: identifier) else { return true }
            return !seen.contains(id)
        }
        return plan
    }
}

extension DomainRegistrar {
    /// Applies `plan`: removals first, then renames (remove, add), then additions. Stops at the first failure.
    public func apply(_ plan: DomainPlan) async throws {
        for identifier in plan.remove { try await remove(identifier: identifier) }
        for domain in plan.rename {
            try await remove(identifier: domain.id.identifier)
            try await add(domain)
        }
        for domain in plan.add { try await add(domain) }
    }

    /// Removes `domain` and adds it again under the same identifier and name: the recovery for a domain stuck behind
    /// the consent gate (``ConsentGate/stuck(_:)``). Nothing but Desktop's own domains can be added again.
    public func addAgain(_ domain: DomainSnapshot) async throws {
        guard let id = domain.vault else { return }
        try await remove(identifier: domain.identifier)
        try await add(VaultDomain(id: id, displayName: domain.displayName))
    }

    /// Adds `domain` unless a domain for that vault exists already. Returns what the system reports afterwards.
    @discardableResult
    public func ensure(_ domain: VaultDomain) async throws -> DomainSnapshot? {
        if try await domains().contains(where: { $0.identifier == domain.id.identifier }) == false {
            try await add(domain)
        }
        return try await domains().first { $0.identifier == domain.id.identifier }
    }
}
