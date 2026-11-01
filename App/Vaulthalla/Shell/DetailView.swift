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
            } else if model.allNodesPage == .recoveryKeys {
                SensitiveGate(title: "Recovery Keys") { AllRecoveryKeysView() }
                    .navigationTitle("Recovery Keys")
                    .navigationSubtitle("All Nodes")
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
        case .credentials: SensitiveGate(title: "Credentials") { CredentialsView(node: node) }
        case .shares: SharesView(node: node)
        case .access: SensitiveGate(title: "Access") { AccessView(node: node) }
        case .syncConflicts: SyncConflictsView(node: node)
        case .cost: CostView(node: node)
        case .s3Gateway: S3GatewayView(node: node)
        case .recoveryKeys: SensitiveGate(title: "Recovery Keys") { RecoveryKeysView(node: node) }
        case .devices: DevicesView(node: node)
        }
    }
}
