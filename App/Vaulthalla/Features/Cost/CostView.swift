import SwiftUI
import VHCore

struct CostView: View {
    var node: Node

    var body: some View {
        PlaceholderSection(node: node, section: .cost)
    }
}

#if DEBUG
#Preview {
    CostView(node: PreviewSamples.nodes[0])
        .environment(PreviewSamples.model(selecting: PreviewSamples.nodes[0].id))
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 820, height: 560)
}
#endif
