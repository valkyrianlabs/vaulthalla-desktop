import SwiftUI
import VHCore

struct AccessView: View {
    var node: Node

    var body: some View {
        PlaceholderSection(node: node, section: .access)
    }
}

#if DEBUG
#Preview {
    AccessView(node: PreviewSamples.nodes[0])
        .environment(PreviewSamples.model(selecting: PreviewSamples.nodes[0].id))
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 820, height: 560)
}
#endif
