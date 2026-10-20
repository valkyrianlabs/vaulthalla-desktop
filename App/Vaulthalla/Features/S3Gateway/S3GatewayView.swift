import SwiftUI
import VHCore

struct S3GatewayView: View {
    var node: Node

    var body: some View {
        PlaceholderSection(node: node, section: .s3Gateway)
    }
}

#if DEBUG
#Preview {
    S3GatewayView(node: PreviewSamples.nodes[0])
        .environment(PreviewSamples.model(selecting: PreviewSamples.nodes[0].id))
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 820, height: 560)
}
#endif
