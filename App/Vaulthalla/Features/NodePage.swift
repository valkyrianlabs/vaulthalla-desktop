import SwiftUI
import VHContract
import VHCore
import VHTransport

/// The scaffold every per-node section uses: a header naming the node and section, then the content. It fills the
/// window: panels lay themselves out for the width they get, from the minimum window to an ultrawide.
struct NodePage<Content: View>: View {
    var node: Node
    var section: NodeSection
    /// Overrides the section's title and summary (a page within the section).
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.stackSpacing + 8) {
                SectionHeader(eyebrow: node.displayName, title: title ?? section.title,
                              subtitle: subtitle ?? section.summary) {
                    let status = model.status(for: node)
                    HStack(spacing: 6) {
                        NodeHealthPill(node: node)
                        if model.incompatibility(for: node) != nil {
                            StatusBadge(label: "Incompatible", tone: .danger)
                        }
                        StatusBadge(label: status.label, tone: status.tone, pulse: status.isTransitional)
                    }
                }
                content
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}

/// What a section shows until the node is connected: why it's empty and the one useful next step.
/// Nothing here is a stand-in number; a section stays empty until its node answers.
struct NodeUnavailablePanel: View {
    var node: Node
    var section: NodeSection

    @Environment(AppModel.self) private var model

    var body: some View {
        if let mismatch = model.incompatibility(for: node) {
            IncompatibleNodePanel(node: node, section: section, mismatch: mismatch)
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        Panel {
            switch model.status(for: node) {
            case .notPaired:
                EmptyState(
                    "Pair this Mac with \(node.displayName)",
                    systemImage: section.systemImage,
                    message: "\(section.title) appears here once this Mac is paired with the node and connected to it."
                ) {
                    Button("Pair this Mac…") { model.presentPairing(for: node.id) }
                        .buttonStyle(.borderedProminent)
                }
            case .revoked:
                EmptyState(
                    "This Mac was unpaired from \(node.displayName)",
                    systemImage: "lock.slash",
                    message: "The node no longer accepts this Mac. Pair again to manage it from here."
                ) {
                    Button("Pair Again…") { model.presentPairing(for: node.id) }
                        .buttonStyle(.borderedProminent)
                }
            case .connecting:
                EmptyState(
                    "Connecting to \(node.displayName)…",
                    systemImage: section.systemImage,
                    message: "\(section.title) loads as soon as the node answers."
                )
            case .offline:
                EmptyState(
                    "\(node.displayName) isn't connected",
                    systemImage: "bolt.horizontal.circle",
                    message: model.offlineReason(for: node.id).map { "\($0) \(section.title) appears here once it's connected." }
                        ?? "This Mac isn't connected to \(node.endpoint.description). \(section.title) appears here once it is."
                ) {
                    if model.needsPairingAgain(node.id) {
                        Button("Pair Again…") { model.presentPairing(for: node.id) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            case .online:
                EmptyState(
                    "\(section.title) isn't in this build yet",
                    systemImage: section.systemImage,
                    message: "\(node.displayName) is connected, but this version of Vaulthalla Desktop can't show \(section.title.lowercased()) yet."
                )
            }
        }
    }
}

/// Where a node's features would appear when it runs a Vaulthalla this build shares no protocol version with: what
/// it runs, and which side to update. The node stays connected (its overview shows its release); nothing is sent.
struct IncompatibleNodePanel: View {
    var node: Node
    var section: NodeSection
    var mismatch: ProtocolMismatch

    var body: some View {
        Panel {
            EmptyState(
                title,
                systemImage: "arrow.triangle.2.circlepath",
                message: "\(mismatch.message) \(section.title) appears here once both sides share a protocol version."
            )
        }
    }

    private var title: String {
        switch mismatch.side {
        case .desktopTooOld: "\(node.displayName) needs a newer Vaulthalla Desktop"
        case .serverTooOld: "\(node.displayName) needs a newer Vaulthalla"
        case .unclear: "\(node.displayName) runs an incompatible Vaulthalla"
        }
    }
}

/// A section with nothing to show but the unavailable state. Feature work replaces the body of each wrapper.
struct PlaceholderSection: View {
    var node: Node
    var section: NodeSection

    var body: some View {
        NodePage(node: node, section: section) {
            NodeUnavailablePanel(node: node, section: section)
        }
    }
}
