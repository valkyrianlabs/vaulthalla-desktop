public import Foundation
public import VHCore

/// What the background agent learned about one node on a tick (valkyrianlabs/vaulthalla-desktop#5).
public enum NodeCheck: Hashable, Sendable {
    /// The node answered `storage.vault.accessible.list`: the vaults the account may browse there.
    case browsable(Set<Int64>)
    /// No definite answer (offline, slow, or a node without the accessible list): its domains stay as they are and
    /// are still signalled, since the extension reports what it can't reach itself.
    case unknown
    /// The node can't be acted for any more: it revoked this Mac, or the record isn't paired. The reason is shown.
    case closed(String)
}

/// One tick of the agent: which domains to signal for changes, and which to take out of Finder, failing closed.
/// Only a definite answer removes a domain: a revocation, an unpaired or deleted node, or a list without the vault.
/// A domain Desktop didn't make, and one still waiting for approval, is left alone.
public struct FreshnessPlan: Hashable, Sendable {
    public struct Removal: Hashable, Sendable {
        public let identifier: String
        public let displayName: String
        public let reason: String
    }

    public var signal: [String] = []
    public var remove: [Removal] = []

    public init(signal: [String] = [], remove: [Removal] = []) {
        self.signal = signal
        self.remove = remove
    }

    /// The plan for `domains` from what each node said. A node missing from `checks` was removed from this Mac's
    /// registry.
    public static func make(domains: [DomainSnapshot], checks: [NodeID: NodeCheck]) -> FreshnessPlan {
        var plan = FreshnessPlan()
        for domain in domains {
            guard let vault = domain.vault else { continue }
            let reason: String? = switch checks[vault.nodeID] {
            case nil: "Its node was removed from Vaulthalla on this Mac."
            case .closed(let why): why
            case .browsable(let ids): ids.contains(vault.vaultID) ? nil
                : "Your Vaulthalla account can no longer browse this vault, or it was deleted."
            case .unknown: nil
            }
            if let reason {
                plan.remove.append(Removal(identifier: domain.identifier, displayName: domain.displayName,
                                           reason: reason))
            } else if domain.userEnabled {
                plan.signal.append(domain.identifier)
            }
        }
        return plan
    }
}

/// Vaults the agent took out of Finder, and why, for the Finder tab to show (it runs while Desktop may be closed).
/// Kept in the App Group's defaults, newest last, the last 20.
public struct RemovedDomain: Codable, Hashable, Sendable, Identifiable {
    public let identifier: String
    public let displayName: String
    public let reason: String
    public let at: Date

    public init(identifier: String, displayName: String, reason: String, at: Date) {
        self.identifier = identifier
        self.displayName = displayName
        self.reason = reason
        self.at = at
    }

    public var id: String { "\(identifier)@\(at.timeIntervalSince1970)" }
}

public enum RemovalLog {
    static let key = "finder.agentRemovals"
    static let limit = 20

    public static func read(_ defaults: UserDefaults) -> [RemovedDomain] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([RemovedDomain].self, from: $0) } ?? []
    }

    public static func append(_ removals: [RemovedDomain], to defaults: UserDefaults) {
        guard !removals.isEmpty else { return }
        write(Array((read(defaults) + removals).suffix(limit)), to: defaults)
    }

    public static func clear(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
    }

    private static func write(_ removals: [RemovedDomain], to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(removals), forKey: key)
    }
}
