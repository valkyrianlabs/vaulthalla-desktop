import SwiftUI
import VHCore

/// Every node this Mac knows about. Counts come from the registry and live connection statuses only.
struct AllNodesView: View {
    @Environment(AppModel.self) private var model
    @State private var tableSelection: NodeID?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.stackSpacing + 8) {
            SectionHeader(eyebrow: "Vaulthalla", title: "All Nodes", subtitle: "Every Vaulthalla server this Mac knows about.")

            if model.nodes.isEmpty {
                Panel {
                    EmptyState(
                        "No nodes yet",
                        systemImage: "server.rack",
                        message: "Add a Vaulthalla server from your network or by its address. This Mac pairs with each server once, then manages it from here."
                    ) {
                        Button("Add Node…") { model.presentAddNode() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Spacer(minLength: 0)
            } else {
                StatGrid {
                    StatTile(label: "Nodes", value: "\(model.nodes.count)", systemImage: "server.rack")
                    StatTile(label: "Paired", value: "\(count { $0.pairing.isPaired })", systemImage: "lock.laptopcomputer")
                    StatTile(label: "Online", value: "\(count { model.status(for: $0) == .online })", systemImage: "dot.radiowaves.left.and.right")
                    keyBackupsTile
                }

                Panel(padded: false) {
                    nodeTable
                }
            }
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }

    /// Recovery Keys at a glance; opens the cross-node Recovery Keys page. "not available" until a node answered.
    private var keyBackupsTile: some View {
        let rows = model.recoveryKeys.rows()
        let backedUp = rows.filter { if case .backedUp = $0.status { true } else { false } }.count
        let attention = rows.filter(\.needsAttention).count
        return Button {
            model.showAllRecoveryKeys()
        } label: {
            StatTile(label: "Key backups",
                     value: rows.isEmpty ? nil : attention > 0 ? "\(attention) need attention" : "\(backedUp) of \(rows.count) backed up",
                     systemImage: "key.horizontal", tone: attention > 0 ? .warn : nil)
        }
        .buttonStyle(.plain)
        .help("Recovery Keys across every node")
    }

    private var nodeTable: some View {
        Table(model.nodes, selection: $tableSelection) {
            TableColumn("Name") { node in
                HStack(spacing: 8) {
                    StatusDot(tone: model.status(for: node).tone)
                    Text(node.displayName)
                        .foregroundStyle(.fg)
                }
            }
            TableColumn("Address") { node in
                Text(node.endpoint.description)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.fgMuted)
            }
            TableColumn("Pairing") { node in
                Text(node.pairing.summary)
                    .foregroundStyle(.fgMuted)
            }
            TableColumn("Connection") { node in
                let status = model.status(for: node)
                StatusBadge(label: status.label, tone: status.tone, pulse: status.isTransitional)
            }
            .width(min: 110, ideal: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: NodeID.self) { ids in
            if let id = ids.first, ids.count == 1 {
                Button("Open") { model.selectNode(id) }
                if model.node(withID: id)?.pairing.isPaired == false {
                    Button("Pair This Mac…") { model.presentPairing(for: id) }
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { model.selectNode(id) }
        }
        .frame(minHeight: 180)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
    }

    private func count(where predicate: (Node) -> Bool) -> Int {
        model.nodes.filter(predicate).count
    }
}

#if DEBUG
#Preview("All nodes") {
    AllNodesView()
        .environment(PreviewSamples.model())
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 900, height: 600)
}

#Preview("All nodes · empty") {
    AllNodesView()
        .environment(PreviewSamples.model(nodes: []))
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 900, height: 600)
}
#endif
