public import Foundation
public import VHCore

/// The All Nodes dashboard's totals across every node: added up only where adding means something (bytes, vaults,
/// spend in one currency), and counted only from what the nodes said. A node that didn't answer adds nothing and is
/// counted as not reporting, never as healthy.
public struct FleetSummary: Sendable {
    /// One node as the dashboard sees it: whether it's reachable and what it reported.
    public struct Member: Sendable, Hashable {
        public var id: NodeID
        public var name: String
        public var reachability: Reachability
        public var digest: NodeDigest

        public init(id: NodeID, name: String, reachability: Reachability, digest: NodeDigest) {
            self.id = id
            self.name = name
            self.reachability = reachability
            self.digest = digest
        }
    }

    public enum Reachability: Sendable, Hashable {
        case online, connecting, offline, notPaired, revoked
    }

    /// An alert with the node it came from.
    public struct FleetAlert: Sendable, Hashable, Identifiable {
        public var node: NodeID
        public var nodeName: String
        public var alert: NodeDigest.Alert

        public var id: String { "\(node.rawValue)|\(alert.id)" }
    }

    public var nodeCount = 0
    public var onlineCount = 0
    /// Paired nodes that aren't online (offline, revoked or still connecting).
    public var unreachableCount = 0
    public var unpairedCount = 0
    /// Nodes whose health reports errors, and those with warnings only.
    public var nodesWithErrors: [NodeID] = []
    public var nodesWithWarnings: [NodeID] = []
    /// Online nodes whose health isn't known: no answer yet, or no stats access.
    public var healthUnknownCount = 0

    public var usedBytes: Int64 = 0
    /// The sum of the quotas over the nodes whose every vault has one; ``quotaCoverage`` says how many.
    public var quotaBytes: Int64 = 0
    public var quotaCoverage = 0
    /// Nodes that reported storage.
    public var storageReporting = 0
    public var vaultCount = 0
    public var openConflicts: Int64 = 0

    /// Spend this month per currency (decimal strings summed exactly), over the nodes that track it.
    public var monthToDate: [String: Decimal] = [:]
    public var projectedMonth: [String: Decimal] = [:]
    public var costReporting = 0

    public var changes24h: Int64 = 0
    public var bytesAdded24h: Int64 = 0
    public var lastActivity: (node: NodeID, at: Date)?

    /// Every node's alerts, most severe first; within a severity, in node order.
    public var alerts: [FleetAlert] = []

    public init(_ members: [Member]) {
        nodeCount = members.count
        var ranked: [(rank: Int, order: Int, alert: FleetAlert)] = []
        for member in members {
            switch member.reachability {
            case .online: onlineCount += 1
            case .notPaired: unpairedCount += 1
            case .offline, .revoked, .connecting: unreachableCount += 1
            }
            let digest = member.digest
            if let health = digest.health.value {
                if health.hasErrors {
                    nodesWithErrors.append(member.id)
                } else if health.hasWarnings {
                    nodesWithWarnings.append(member.id)
                }
                for alert in health.alerts {
                    ranked.append((SeverityRank.of(alert.severity), ranked.count,
                                   FleetAlert(node: member.id, nodeName: member.name, alert: alert)))
                }
            } else if member.reachability == .online {
                healthUnknownCount += 1
            }
            if let storage = digest.storage.value {
                storageReporting += 1
                usedBytes += storage.usedBytes
                vaultCount += storage.vaultCount
                if let quota = storage.quotaBytes {
                    quotaBytes += quota
                    quotaCoverage += 1
                }
            }
            if let open = digest.conflicts.value { openConflicts += open }
            if let cost = digest.cost.value, cost.isTracked {
                costReporting += 1
                let currency = cost.currency.isEmpty ? "USD" : cost.currency.uppercased()
                if let amount = Self.decimal(cost.monthToDate) { monthToDate[currency, default: 0] += amount }
                if let amount = Self.decimal(cost.projectedMonth) { projectedMonth[currency, default: 0] += amount }
            }
            if let activity = digest.activity.value {
                changes24h += activity.changes24h
                bytesAdded24h += activity.bytesAdded24h
                if let at = activity.lastActivityAt, at > (lastActivity?.at ?? .distantPast) {
                    lastActivity = (member.id, at)
                }
            }
        }
        alerts = ranked.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.order < $1.order }.map(\.alert)
    }

    /// Nodes that need someone to look: errors, or not reachable while paired.
    public var needsAttention: Bool { !nodesWithErrors.isEmpty || unreachableCount > 0 }

    private static func decimal(_ text: String?) -> Decimal? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
}
