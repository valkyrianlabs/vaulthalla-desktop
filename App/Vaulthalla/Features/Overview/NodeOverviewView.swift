import SwiftUI
import VHContract
import VHCore
import VHIdentity
import VHNodes

/// The node's health once it's connected (`HealthOverview`), and what Desktop itself knows about it. Without
/// access to stats, the health part shows a calm denied state; the node's identity still shows.
struct NodeOverviewView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        NodePage(node: node, section: .overview) {
            let queries = model.liveQueries(for: node)
            if let queries {
                HealthOverview(node: node, queries: queries)
                    .environment(queries)
            } else {
                NodeUnavailablePanel(node: node, section: .overview)
            }
            NodeIdentityPanel(node: node, queries: queries)
        }
    }
}

/// Name, address, contract and this Mac's side of the pairing.
private struct NodeIdentityPanel: View {
    var node: Node
    var queries: NodeQueries?

    @Environment(AppModel.self) private var model

    var body: some View {
        let contract = queries?.query(Ws.Meta.Contract.Get.self)
        Panel(title: "Node", subtitle: "Its identity, and the record Desktop keeps for it. Nothing here is secret.") {
            DefinitionList(items: details(contract: contract), monospacedValues: ["Address", "Device ID", "Server key"])
        } actions: {
            Button("Rename…") { model.nodePendingRename = node }
                .controlSize(.small)
        }
        .task(id: contract.map(ObjectIdentifier.init)) {
            await contract?.observe()
        }
    }

    /// The node record, the contract it runs once connected, and this Mac's side of the pairing.
    private func details(contract: NodeQuery<Ws.Meta.Contract.Get>?) -> [(term: String, value: String)] {
        var items: [(term: String, value: String)] = [
            ("Name", node.displayName),
            ("Address", node.endpoint.description),
        ]
        if let contract {
            items.append(("Contract", Self.describe(contract)))
        }
        items.append(("Pairing", node.pairing.summary))
        items.append(("Connection", connection))
        if case .paired(let serverSPKI, let deviceID, let since) = node.pairing {
            items.append(("Device ID", Self.short(deviceID)))
            items.append(("Key", model.keyBackends[node.id]?.displayName
                ?? (model.needsPairingAgain(node.id) ? "Missing" : "Not found yet")))
            items.append(("Paired since", since.formatted(date: .long, time: .shortened)))
            items.append(("Server key", serverSPKI.shortFingerprint))
        }
        return items
    }

    /// "Version 2, same as this app" from `meta.contract.get`; the daemon reports no release version.
    private static func describe(_ query: NodeQuery<Ws.Meta.Contract.Get>) -> String {
        if let value = query.value {
            let same = value.wsHash == WsContract.wsHash
            return "Version \(value.contractVersion), "
                + (same ? "same as this app" : "differs from this app's (\(value.wsHash.prefix(8))…)")
        }
        if let error = query.error {
            return QueryProblem(error) == .noAnswerYet ? "No answer yet" : "Not available"
        }
        return "Asking…"
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
#Preview("Online (preview data)") {
    let model = PreviewSamples.liveModel()
    NodeOverviewView(node: PreviewSamples.nodes[1])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 980, height: 900)
}

#Preview("No stats access (preview data)") {
    let model = PreviewSamples.liveModel()
    NodeOverviewView(node: PreviewSamples.nodes[3])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 980, height: 700)
}

#Preview("Unpaired") {
    NodeOverviewView(node: PreviewSamples.nodes[0])
        .environment(PreviewSamples.model(selecting: PreviewSamples.nodes[0].id))
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 860, height: 640)
}
#endif
