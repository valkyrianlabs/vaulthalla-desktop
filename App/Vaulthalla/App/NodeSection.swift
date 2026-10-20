import Foundation

/// The per-node areas of the sidebar, in sidebar order (docs/architecture.md §3).
enum NodeSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case overview
    case files
    case vaults
    case shares
    case access
    case syncConflicts
    case cost
    case s3Gateway
    case recoveryKeys
    case devices

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .files: "Files"
        case .vaults: "Vaults"
        case .shares: "Shares"
        case .access: "Access"
        case .syncConflicts: "Sync Conflicts"
        case .cost: "Cost"
        case .s3Gateway: "S3 Gateway"
        case .recoveryKeys: "Recovery Keys"
        case .devices: "Devices"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .files: "folder"
        case .vaults: "lock.rectangle.stack"
        case .shares: "link"
        case .access: "person.2.badge.key"
        case .syncConflicts: "exclamationmark.arrow.triangle.2.circlepath"
        case .cost: "chart.bar.xaxis"
        case .s3Gateway: "server.rack"
        case .recoveryKeys: "key.horizontal"
        case .devices: "laptopcomputer.and.iphone"
        }
    }

    /// What the section shows once the node is connected. Used in the empty states, so it reads as a sentence.
    var summary: String {
        switch self {
        case .overview: "Health, storage and activity for this node."
        case .files: "Browse vault files, preview them with Quick Look and drag them to and from Finder."
        case .vaults: "The node's vaults: storage backends, quotas, encryption and key versions."
        case .shares: "Links and shares people use to reach vault content."
        case .access: "Users, groups and roles, and what each of them can do."
        case .syncConflicts: "Files whose local and remote copies diverged, and how to resolve them."
        case .cost: "Storage and transfer cost by vault and backend."
        case .s3Gateway: "The node's S3-compatible endpoint and the credentials that use it."
        case .recoveryKeys: "Vault key backups to 1Password and their status."
        case .devices: "Devices paired with this node, including this Mac."
        }
    }
}
