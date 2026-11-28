public import VHCore

/// The one thing the menu bar item says (docs/mac-experience.md §2): the worst state across the paired nodes that are
/// not muted, and a sentence for it. Derived only from what the nodes reported and how reachable they are; a node
/// that has not answered is "not reporting", never quiet. A finding someone acknowledged or silenced (on any Mac or
/// in the console) no longer raises the item, when the node reports that (§7); the health pages still show it.
public struct FleetStatus: Sendable, Hashable {
    public enum Level: Int, Sendable, Hashable, Comparable {
        /// No node is paired, or none has answered yet.
        case notReporting
        /// Every paired node is online and none reports errors or warnings.
        case quiet
        /// Unattended warnings, no unattended errors.
        case warnings
        /// A node reports errors nobody acknowledged or silenced, is unreachable past the grace period, or revoked
        /// this Mac.
        case attention

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var level: Level
    /// One sentence for the fleet: "3 nodes, all healthy", "1 node needs attention".
    public var headline: String
    /// What is behind the headline, when it helps: "Studio is unreachable".
    public var detail: String?
    /// Nodes that need a person, most pressing first.
    public var attention: [NodeID]

    /// `members` carry each node's reachability as the caller wants it judged: a node still inside its grace period
    /// is passed as `.connecting`, so a blip never raises the item.
    public init(_ members: [FleetSummary.Member], muted: Set<NodeID> = []) {
        let paired = members.filter { $0.reachability != .notPaired && !muted.contains($0.id) }
        guard !paired.isEmpty else {
            level = .notReporting
            attention = []
            if members.isEmpty {
                headline = "No nodes yet"
            } else if members.allSatisfy({ muted.contains($0.id) }) {
                headline = members.count == 1 ? "1 node, muted" : "\(members.count) nodes, muted"
            } else {
                headline = members.count == 1 ? "1 node, not paired" : "\(members.count) nodes, none paired"
            }
            detail = nil
            return
        }

        var down: [FleetSummary.Member] = []
        var revoked: [FleetSummary.Member] = []
        var errors: [FleetSummary.Member] = []
        var warnings: [FleetSummary.Member] = []
        var connecting = 0
        var online = 0
        var reporting = 0
        var attended = 0
        for member in paired {
            switch member.reachability {
            case .offline: down.append(member)
            case .revoked: revoked.append(member)
            case .connecting: connecting += 1
            case .online: online += 1
            case .notPaired: break
            }
            // A node that isn't online says nothing current about its health: its last answer is not counted.
            guard member.reachability == .online, let health = member.digest.health.value else { continue }
            reporting += 1
            attended += health.attendedCount
            if health.needsErrorAttention {
                errors.append(member)
            } else if health.needsWarningAttention {
                warnings.append(member)
            }
        }

        let pressing = revoked + down + errors
        if !pressing.isEmpty {
            level = .attention
            attention = pressing.map(\.id)
            headline = pressing.count == 1 ? "1 node needs attention" : "\(pressing.count) nodes need attention"
            detail = Self.reasons(revoked: revoked, down: down, errors: errors)
            return
        }
        if !warnings.isEmpty {
            level = .warnings
            attention = warnings.map(\.id)
            headline = warnings.count == 1 ? "Warnings on 1 node" : "Warnings on \(warnings.count) nodes"
            detail = warnings.count == 1 ? warnings[0].name : nil
            return
        }
        attention = []
        if online == 0 {
            // Nothing has connected yet (launch, wake): say so instead of guessing.
            level = .notReporting
            headline = paired.count == 1 ? "Connecting to \(paired[0].name)…" : "Connecting to \(paired.count) nodes…"
            detail = nil
            return
        }
        if connecting > 0 {
            level = .notReporting
            headline = "\(online) of \(paired.count) nodes online"
            detail = "Connecting to the rest…"
            return
        }
        // Everything is online. A node whose health is still loading keeps the item from saying "healthy"; one whose
        // account may not read health (denied) is simply online.
        let loading = paired.contains { $0.digest.health == .loading }
        if loading {
            level = .notReporting
            headline = paired.count == 1 ? "\(paired[0].name) is online" : "\(paired.count) nodes online"
            detail = "Checking health…"
            return
        }
        level = .quiet
        detail = nil
        if attended > 0 {
            // Findings remain, but each was acknowledged or silenced: quiet, and not "healthy".
            headline = paired.count == 1 ? "\(paired[0].name): nothing needs attention"
                : "\(paired.count) nodes, nothing needs attention"
            detail = attended == 1 ? "1 finding acknowledged or silenced" : "\(attended) findings acknowledged or silenced"
        } else if reporting == paired.count {
            headline = paired.count == 1 ? "\(paired[0].name) is healthy" : "\(paired.count) nodes, all healthy"
        } else {
            headline = paired.count == 1 ? "\(paired[0].name) is online" : "\(paired.count) nodes online"
        }
    }

    private static func reasons(revoked: [FleetSummary.Member], down: [FleetSummary.Member],
                                errors: [FleetSummary.Member]) -> String? {
        var parts: [String] = []
        if let first = revoked.first {
            parts.append(revoked.count == 1 ? "\(first.name) revoked this Mac" : "\(revoked.count) nodes revoked this Mac")
        }
        if let first = down.first {
            parts.append(down.count == 1 ? "\(first.name) is unreachable" : "\(down.count) nodes are unreachable")
        }
        if let first = errors.first {
            parts.append(errors.count == 1 ? "\(first.name) reports errors" : "\(errors.count) nodes report errors")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
