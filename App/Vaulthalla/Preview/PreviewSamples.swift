#if DEBUG
import Foundation
import VHCore

/// PREVIEW-ONLY sample data for `#Preview`s. Never referenced by the running app: the shell only shows nodes the
/// operator added. Each model gets its own throwaway registry in the temporary directory.
enum PreviewSamples {
    static let nodes: [Node] = [
        Node(
            id: NodeID(rawValue: "preview-storage"),
            displayName: "vh-storage (preview)",
            endpoint: NodeEndpoint(host: "vh-storage.local")
        ),
        Node(
            id: NodeID(rawValue: "preview-homelab"),
            displayName: "Home lab (preview)",
            endpoint: NodeEndpoint(host: "10.0.0.33", port: 4443),
            pairing: .paired(serverSPKISHA256: Data(repeating: 0xAB, count: 32), deviceID: "preview-device", since: Date(timeIntervalSince1970: 1_790_000_000))
        ),
        Node(
            id: NodeID(rawValue: "preview-offsite"),
            displayName: "Offsite (preview)",
            endpoint: NodeEndpoint(host: "vault.example.com"),
            pairing: .revoked(at: Date(timeIntervalSince1970: 1_792_000_000))
        ),
    ]

    static func model(nodes: [Node] = PreviewSamples.nodes, selecting id: NodeID? = nil) -> AppModel {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "VaulthallaPreview-\(UUID().uuidString)/nodes.json")
        let store = NodeStore(fileURL: url)
        for node in nodes { _ = try? store.add(node) }
        let model = AppModel(store: store)
        if let id { model.selectNode(id) }
        return model
    }
}
#endif
