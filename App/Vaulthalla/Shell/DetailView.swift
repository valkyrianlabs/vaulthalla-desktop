import SwiftUI
import VHCore

/// Routes the selection to one view per section.
struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.showsAllNodes, let node = model.selectedNode {
                sectionView(model.selectedSection, node: node)
                    .navigationTitle(model.selectedSection.title)
                    .navigationSubtitle(node.displayName)
                    .id(node.id)
            } else {
                AllNodesView()
                    .navigationTitle("All Nodes")
                    .navigationSubtitle("")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .vaulthallaCanvas()
    }

    @ViewBuilder
    private func sectionView(_ section: NodeSection, node: Node) -> some View {
        switch section {
        case .overview: NodeOverviewView(node: node)
        case .files: FilesView(node: node)
        case .vaults: VaultsView(node: node)
        case .shares: SharesView(node: node)
        case .access: AccessView(node: node)
        case .syncConflicts: SyncConflictsView(node: node)
        case .cost: CostView(node: node)
        case .s3Gateway: S3GatewayView(node: node)
        case .recoveryKeys: RecoveryKeysView(node: node)
        case .devices: DevicesView(node: node)
        }
    }
}
