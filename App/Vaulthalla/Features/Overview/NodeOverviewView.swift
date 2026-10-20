import SwiftUI
import VHCore

/// What Desktop itself knows about the node (its registry record), plus the health view once it's connected.
struct NodeOverviewView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        NodePage(node: node, section: .overview) {
            NodeUnavailablePanel(node: node, section: .overview)

            Panel(title: "On This Mac", subtitle: "The record Desktop keeps for this node. Nothing in it is secret.") {
                DefinitionList(
                    items: [
                        ("Name", node.displayName),
                        ("Address", node.endpoint.description),
                        ("Pairing", node.pairing.summary),
                        ("Connection", model.status(for: node).label),
                    ],
                    monospacedValues: ["Address"]
                )
            } actions: {
                Button("Rename…") { model.nodePendingRename = node }
                    .controlSize(.small)
            }
        }
    }
}

#if DEBUG
#Preview("Unpaired") {
    NodeOverviewView(node: PreviewSamples.nodes[0])
        .environment(PreviewSamples.model(selecting: PreviewSamples.nodes[0].id))
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 860, height: 640)
}

#Preview("Paired, offline") {
    NodeOverviewView(node: PreviewSamples.nodes[1])
        .environment(PreviewSamples.model(selecting: PreviewSamples.nodes[1].id))
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 860, height: 640)
}
#endif
