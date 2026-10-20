import SwiftUI
import VHCore

/// The scaffold every per-node section uses: a header naming the node and section, then the content.
struct NodePage<Content: View>: View {
    var node: Node
    var section: NodeSection
    @ViewBuilder var content: Content

    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.stackSpacing + 8) {
                SectionHeader(eyebrow: node.displayName, title: section.title, subtitle: section.summary) {
                    let status = model.status(for: node)
                    StatusBadge(label: status.label, tone: status.tone, pulse: status.isTransitional)
                }
                content
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
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
                    message: "This Mac isn't connected to \(node.endpoint.description). \(section.title) appears here once it is."
                )
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
