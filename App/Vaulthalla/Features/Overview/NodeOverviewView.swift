import SwiftUI
import VHCore
import VHIdentity
import VHNodes

/// What Desktop itself knows about the node (its registry record), plus the health view once it's connected.
struct NodeOverviewView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        NodePage(node: node, section: .overview) {
            NodeUnavailablePanel(node: node, section: .overview)

            Panel(title: "On This Mac", subtitle: "The record Desktop keeps for this node. Nothing in it is secret.") {
                DefinitionList(items: details, monospacedValues: ["Address", "Device ID", "Server key"])
            } actions: {
                Button("Rename…") { model.nodePendingRename = node }
                    .controlSize(.small)
            }
        }
    }
}

extension NodeOverviewView {
    /// The node record, plus this Mac's side of the pairing once there is one.
    private var details: [(term: String, value: String)] {
        var items: [(term: String, value: String)] = [
            ("Name", node.displayName),
            ("Address", node.endpoint.description),
            ("Pairing", node.pairing.summary),
            ("Connection", connection),
        ]
        if case .paired(let serverSPKI, let deviceID, let since) = node.pairing {
            items.append(("Device ID", Self.short(deviceID)))
            items.append(("Key", model.keyBackends[node.id]?.displayName
                ?? (model.needsPairingAgain(node.id) ? "Missing" : "Not found yet")))
            items.append(("Paired since", since.formatted(date: .long, time: .shortened)))
            items.append(("Server key", serverSPKI.shortFingerprint))
        }
        return items
    }

    private var connection: String {
        let label = model.status(for: node).label
        guard let reason = model.offlineReason(for: node.id) else { return label }
        return "\(label): \(reason)"
    }

    /// `3ac2baf6…8fc1`: enough to tell devices apart in the web console's list, which shows the same prefix.
    private static func short(_ id: String) -> String {
        id.count > 12 ? "\(id.prefix(8))…\(id.suffix(4))" : id
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
