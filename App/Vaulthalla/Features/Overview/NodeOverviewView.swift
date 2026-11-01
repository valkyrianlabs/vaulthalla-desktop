import SwiftUI
import VHContract
import VHCore
import VHIdentity
import VHNodes

/// The node's health once it's connected (`HealthPages`: the summary and the Runtime, Filesystem, Storage and
/// Activity drill-downs, switched in the toolbar), how this Mac reaches it (`ConnectionPanel`), and what Desktop itself
/// knows about it. Without access to stats, the health part shows a calm denied state; the node's identity still shows.
struct NodeOverviewView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        let page = model.healthPage
        let queries = model.liveQueries(for: node)
        NodePage(node: node, section: .overview, title: page == .summary ? nil : page.title,
                 subtitle: page == .summary ? nil : page.subtitle) {
            if let queries {
                HealthPages(node: node, queries: queries, page: page)
                    .environment(queries)
            } else {
                NodeUnavailablePanel(node: node, section: .overview)
            }
            if page == .summary {
                AdaptiveColumns(minColumnWidth: 460, spacing: Theme.stackSpacing) {
                    if node.pairing.isPaired {
                        ConnectionPanel(node: node)
                    }
                    NodeIdentityPanel(node: node, queries: queries)
                }
            }
        }
        // An All Nodes alert names the card it's about (`healthFocus`): open its panel and mark what's behind it.
        .task(id: model.healthFocus) {
            guard let cardID = model.healthFocus else { return }
            model.healthFocus = nil
            model.openHealth(href: nil, cardID: cardID)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HealthPagePicker(overview: queries.flatMap { $0.query(Ws.Stats.Dashboard.Overview.self, .init()).value?.stats })
            }
        }
    }
}

/// Switches the Overview between its summary and drill-downs (Activity Monitor's tabs). A page whose sections report
/// warnings or errors says so in its label. ⌥⌘1…5 from the View menu.
private struct HealthPagePicker: View {
    var overview: WsModel.DashboardOverview?

    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Health", selection: page) {
            ForEach(HealthPage.allCases) { page in
                Label(label(page), systemImage: page.systemImage)
                    .tag(page)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.titleOnly)
        .help("Overview pages")
        .fixedSize()
    }

    private var page: Binding<HealthPage> {
        Binding(get: { model.healthPage }, set: { model.openHealth($0) })
    }

    /// "Filesystem ⚠︎" when that page's sections report a problem.
    private func label(_ page: HealthPage) -> String {
        guard let overview else { return page.title }
        let sections = overview.sections.filter { page.sectionIDs.contains($0.id) }
        return sections.contains { $0.errorCount + $0.warningCount > 0 } ? "\(page.title) ⚠︎" : page.title
    }
}

/// Name, address, the Vaulthalla it runs (release and protocol, from `meta.hello`), its contract and this Mac's side
/// of the pairing.
private struct NodeIdentityPanel: View {
    var node: Node
    var queries: NodeQueries?

    @Environment(AppModel.self) private var model

    var body: some View {
        let settled = model.nodeProtocol(for: node.id)
        // A negotiated node reported its contract in the hello; others are asked (`meta.contract.get`).
        let contract = settled?.contract == nil ? queries?.query(Ws.Meta.Contract.Get.self) : nil
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

    /// The node record, what it runs once connected, and this Mac's side of the pairing.
    private func details(contract: NodeQuery<Ws.Meta.Contract.Get>?) -> [(term: String, value: String)] {
        let settled = model.nodeProtocol(for: node.id)
        var items: [(term: String, value: String)] = [
            ("Name", node.displayName),
            ("Address", node.endpoint.description),
        ]
        if node.pairing.isPaired {
            items.append(("Vaulthalla", Self.describe(settled, status: model.status(for: node))))
        }
        if let identity = settled?.contract {
            items.append(("Contract", Self.describe(identity)))
        } else if let contract {
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

    /// "Vaulthalla 1.19.0 · protocol 1", "Vaulthalla 1.18 or earlier" (a legacy node, no `meta.hello`), the
    /// incompatible release and range with which side to update, or "—" until a connection settled it.
    private static func describe(_ settled: NodeProtocol?, status: NodeConnectionStatus) -> String {
        guard let settled else { return status == .online || status == .connecting ? "Asking…" : "—" }
        if let mismatch = settled.mismatch {
            return switch mismatch.side {
            case .desktopTooOld: "\(settled.productLabel), needs a newer Vaulthalla Desktop"
            case .serverTooOld: "\(settled.productLabel), needs a newer Vaulthalla on the node"
            case .unclear: "\(settled.productLabel), incompatible with this app"
            }
        }
        return settled.productLabel
    }

    /// "Version 3, same as this app" from the hello's contract identity.
    private static func describe(_ identity: NodeProtocol.ContractIdentity) -> String {
        let same = identity.matchesThisBuild
        return "Version \(identity.contractVersion), "
            + (same ? "same as this app" : "differs from this app's (\(identity.wsHash.prefix(8))…)")
    }

    /// "Version 2, same as this app" from `meta.contract.get` (a legacy node reports no release version).
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
