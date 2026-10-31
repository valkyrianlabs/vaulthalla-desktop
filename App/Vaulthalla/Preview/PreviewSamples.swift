#if DEBUG
import Foundation
import VHContract
import VHCore
import VHNodes

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
        Node(
            id: NodeID(rawValue: "preview-restricted"),
            displayName: "Studio (preview)",
            endpoint: NodeEndpoint(host: "studio.local"),
            pairing: .paired(serverSPKISHA256: Data(repeating: 0xCD, count: 32), deviceID: "preview-device-2", since: Date(timeIntervalSince1970: 1_791_000_000))
        ),
    ]

    /// PREVIEW DATA: "Home lab" reached over the VPN while its LAN address doesn't answer from here.
    static let homeLabRoute: NodeRoute = {
        let configured = EndpointCandidate(endpoint: NodeEndpoint(host: "10.0.0.33", port: 4443), sources: [.configured],
                                           order: 1)
        let vpn = EndpointCandidate(endpoint: NodeEndpoint(host: "100.101.1.2", port: 4443), sources: [.advertised],
                                    advertisedKind: .vpn, interface: "tailscale0", order: 3)
        let loopback = EndpointCandidate(endpoint: NodeEndpoint(host: "127.0.0.1", port: 4443), sources: [.loopback])
        let chosen = EndpointSelection.Report(candidate: vpn, outcome: .ok, transportClass: .vpn,
                                              rtt: .milliseconds(23), remoteAddress: "100.101.1.2",
                                              interfaceName: "utun4", matchedPin: Data(repeating: 0xAB, count: 32))
        let selection = EndpointSelection(reports: [
            EndpointSelection.Report(candidate: loopback, outcome: .refused, transportClass: .loopback),
            EndpointSelection.Report(candidate: configured, outcome: .timeout, transportClass: .lan),
            chosen,
        ], chosen: chosen, startedAt: .now.addingTimeInterval(-90))
        return NodeRoute(endpoint: vpn.endpoint, transportClass: .vpn, rtt: .milliseconds(23),
                         remoteAddress: "100.101.1.2", interfaceName: "utun4", verifiedKey: .current, isConnected: true,
                         selection: selection)
    }()

    /// PREVIEW DATA: "Studio" on the LAN, where another Vaulthalla answers on this Mac's loopback; nothing reports
    /// transfer stats.
    static let studioRoute: NodeRoute = {
        let lan = EndpointCandidate(endpoint: NodeEndpoint(host: "studio.local"), sources: [.configured], order: 2)
        let loopback = EndpointCandidate(endpoint: NodeEndpoint(host: "127.0.0.1"), sources: [.loopback, .advertised],
                                         advertisedKind: .loopback)
        let chosen = EndpointSelection.Report(candidate: lan, outcome: .ok, transportClass: .lan, rtt: .microseconds(1800),
                                              remoteAddress: "192.168.1.40", interfaceName: "en0")
        let selection = EndpointSelection(reports: [
            EndpointSelection.Report(candidate: loopback, outcome: .identityMismatch, transportClass: .loopback),
            chosen,
        ], chosen: chosen, startedAt: .now.addingTimeInterval(-20))
        return NodeRoute(endpoint: lan.endpoint, transportClass: .lan, rtt: .microseconds(1800),
                         remoteAddress: "192.168.1.40", interfaceName: "en0", verifiedKey: .next, isConnected: true,
                         selection: selection)
    }()

    static func model(nodes: [Node] = PreviewSamples.nodes, selecting id: NodeID? = nil) -> AppModel {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "VaulthallaPreview-\(UUID().uuidString)/nodes.json")
        // Each preview gets its own registry, so its lease is always free: the model owns it.
        let lease = CredentialLease(forRegistry: url, holder: "preview")
        try? lease.acquire()
        let store = NodeStore(fileURL: url, lease: lease)
        for node in nodes { _ = try? store.add(node) }
        let model = AppModel(store: store)
        if let id { model.selectNode(id) }
        return model
    }

    /// A model whose paired nodes answer from PREVIEW DATA (`PreviewTransport`): "Home lab" as an admin sees it,
    /// "Studio" as an account without stats access and no manageable vaults.
    /// PREVIEW DATA: what "Home lab" answers to `meta.hello` (every command and capability this build knows).
    static let negotiated = NodeProtocol(
        state: .negotiated, version: 1, serverName: "vaulthalla", serverVersion: "1.19.0", serverRange: 1...1,
        capabilities: Set(WsContract.capabilities.keys), commands: Set(WsCommand.allCases.map(\.rawValue)),
        contract: .init(contractVersion: WsContract.contractVersion, contractHash: "preview", wsHash: WsContract.wsHash,
                        modelsHash: WsContract.modelsHash))

    static func liveModel(selecting id: NodeID? = nil) -> AppModel {
        let model = model(selecting: id)
        model.usePreviewData(for: nodes[1].id, transport: PreviewTransport(.full), negotiated: negotiated)
        model.usePreviewData(for: nodes[3].id, transport: PreviewTransport(.restricted), negotiated: .legacy)
        model.usePreviewRoute(homeLabRoute, stats: TransferStats(
            throughputUp: 41_200_000, throughputDown: 87_500_000, partBytes: 64 << 20, partsInFlight: 3, tuning: true,
            concurrency: 4, serverBound: false, source: .measured),
            for: nodes[1].id)
        model.usePreviewRoute(studioRoute, stats: nil, for: nodes[3].id)
        RecoveryKeysPreviewData.install(on: model)
        return model
    }
}
#endif
