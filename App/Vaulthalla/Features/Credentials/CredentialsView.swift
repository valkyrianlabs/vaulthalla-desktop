import SwiftUI
import VHCore

struct CredentialsView: View {
    var node: Node

    var body: some View {
        PlaceholderSection(node: node, section: .credentials)
    }
}
