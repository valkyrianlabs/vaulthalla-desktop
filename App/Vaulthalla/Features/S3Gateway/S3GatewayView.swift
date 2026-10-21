import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// The node's S3-compatible endpoint (`s3.gateway.*`): whether it runs, the keys S3 clients use (scoped, with
/// budgets), the buckets they see, the spend against key budgets, and how to configure a client. Mirrors the web
/// console's gateway page; every part is authorized by the daemon, and a refusal shows as a calm "no access".
struct S3GatewayView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        if let queries = model.liveQueries(for: node) {
            GatewayScreen(node: node, queries: queries)
                .environment(queries)
        } else {
            PlaceholderSection(node: node, section: .s3Gateway)
        }
    }
}

private struct GatewayScreen: View {
    var node: Node
    var queries: NodeQueries

    enum Tab: String, CaseIterable, Identifiable {
        case keys, buckets, budgets, clients

        var id: Self { self }

        var title: String {
            switch self {
            case .keys: "Keys"
            case .buckets: "Buckets"
            case .budgets: "Budgets"
            case .clients: "Client Setup"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var tab = Tab.keys
    @State private var creating = false
    @State private var selectedKey: Int64?
    @State private var showsInspector = true

    var body: some View {
        let status = queries.query(Ws.S3.Gateway.Status.self)
        let credentials = queries.query(Ws.S3.Gateway.Credentials.List.self, .init(includeDisabled: true))

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(eyebrow: node.displayName, title: "S3 Gateway",
                          subtitle: "Let S3 clients (aws, rclone, mc, backup tools) use vaults as buckets, with scoped keys and per-key budgets.") {
                HStack(spacing: 10) {
                    let connection = model.status(for: node)
                    StatusBadge(label: connection.label, tone: connection.tone, pulse: connection.isTransitional)
                    Button("Create Key…", systemImage: "key") { creating = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(isDenied(credentials.error))
                }
            }
            .padding([.horizontal, .top], Theme.pagePadding)
            .padding(.bottom, 16)

            if isDenied(credentials.error) && isDenied(status.error) {
                // No admin.s3_gateway permission at all: one calm state instead of four refusals.
                ProblemPanel(problem: QueryProblem(credentials.error ?? .denied("")), node: node,
                             subject: "the S3 gateway") {}
                    .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            } else {
                ServicePanel(query: status)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 16)

                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 14)

                switch tab {
                case .keys:
                    GatewayKeysTab(node: node, queries: queries, list: credentials, selection: $selectedKey) {
                        creating = true
                    }
                case .buckets:
                    GatewayBucketsTab(node: node, queries: queries)
                case .budgets:
                    GatewayBudgetsTab(node: node, queries: queries, credentials: credentials)
                case .clients:
                    GatewayClientSetup(node: node, status: status.value?.status, credentials: credentials,
                                       buckets: queries.query(Ws.S3.Gateway.Buckets.List.self))
                }
            }
        }
        .observing(status, polling: .seconds(30))
        .observing(credentials)
        .inspector(isPresented: Binding(get: { showsInspector && tab == .keys && !(credentials.value?.credentials.isEmpty ?? true) },
                                        set: { showsInspector = $0 })) {
            Group {
                if let id = selectedKey, let credential = credentials.value?.credentials.first(where: { $0.id == id }) {
                    GatewayKeyInspector(credential: credential, queries: queries)
                        .id(credential)
                } else {
                    EmptyState("No key selected", systemImage: "sidebar.trailing",
                               message: "Select a key to see what it reaches, its budget and what can be done with it.")
                        .frame(maxHeight: .infinity)
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar {
            if tab == .keys {
                ToolbarItem(placement: .primaryAction) {
                    Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                        .help(showsInspector ? "Hide the inspector" : "Show the inspector")
                }
            }
        }
        .sheet(isPresented: $creating) {
            CreateGatewayKeySheet(queries: queries) { tab = .keys }
        }
        #if DEBUG
        .task { debugSetup() }
        #endif
    }

    private func isDenied(_ error: WsError?) -> Bool {
        if case .denied = error { return true }
        return false
    }

    #if DEBUG
    /// `-VHDebugGatewayTab keys|buckets|budgets|clients` picks a tab, `-VHDebugGatewayKey <id>` selects a key and
    /// `-VHDebugGatewayCreate YES` opens the create sheet (DebugSnapshot).
    private func debugSetup() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "VHDebugGatewayTab"), let picked = Tab(rawValue: raw) { tab = picked }
        if defaults.bool(forKey: "VHDebugGatewayCreate") { creating = true }
        let key = defaults.integer(forKey: "VHDebugGatewayKey")
        if key > 0 { selectedKey = Int64(key) }
    }
    #endif
}

/// Running/stopped are facts from the daemon; an unknown status stays unknown.
private struct ServicePanel: View {
    var query: NodeQuery<Ws.S3.Gateway.Status>

    var body: some View {
        Panel(title: "Service", subtitle: subtitle) {
            switch query.state {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .failed(let error):
                InlineProblem(error: error, subject: "the gateway's status")
            case .loaded(let response, _):
                let status = response.status
                StatGrid {
                    StatTile(label: "Bind address", value: bindAddress(status), systemImage: "network",
                             hint: wildcard(status.host) ? "Listens on every interface" : (status.configured ? nil : "Not configured"))
                    StatTile(label: "Active sessions", value: GatewayFormat.number(status.activeSessions),
                             systemImage: "person.2")
                    StatTile(label: "Requests", value: GatewayFormat.number(status.totalRequests),
                             systemImage: "arrow.left.arrow.right", hint: "Since the gateway started")
                    StatTile(label: "Failed requests", value: GatewayFormat.number(status.failedRequests),
                             systemImage: "exclamationmark.triangle",
                             tone: status.failedRequests > 0 ? .warn : nil)
                }
            }
        } actions: {
            stateBadge
        }
    }

    private var subtitle: String? {
        guard let status = query.value?.status, !status.running else { return nil }
        return "The gateway is off. Turn it on with s3_gateway.enabled in the node's settings."
    }

    @ViewBuilder
    private var stateBadge: some View {
        if let status = query.value?.status {
            if !status.running {
                StatusBadge(label: "Stopped", tone: .unknown)
            } else if !status.ready {
                StatusBadge(label: "Starting", tone: .info, pulse: true)
            } else {
                StatusBadge(label: "Running", tone: .ok)
            }
        } else if query.error != nil {
            StatusBadge(label: "Status unknown", tone: .unknown)
        }
    }

    /// The listener's bind address as the daemon reports it, not a URL clients can use (Client Setup proposes one).
    private func bindAddress(_ status: Ws.S3.Gateway.Status.Response.Status) -> String? {
        status.host.isEmpty ? nil : "\(status.host):\(status.port)"
    }

    private func wildcard(_ host: String) -> Bool {
        ["0.0.0.0", "::", "[::]", "*", ""].contains(host)
    }
}

/// A titled group on a gateway page, with its own surface below the heading.
struct GatewaySection<Content: View, Actions: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.fg)
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.fgSubtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                actions
            }
            content
        }
    }
}

extension GatewaySection where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, content: content, actions: { EmptyView() })
    }
}

#if DEBUG
#Preview("S3 Gateway (preview data)") {
    let model = PreviewSamples.liveModel()
    S3GatewayView(node: PreviewSamples.nodes[1])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1180, height: 760)
}

#Preview("No gateway access (preview data)") {
    let model = PreviewSamples.liveModel()
    S3GatewayView(node: PreviewSamples.nodes[3])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1000, height: 560)
}
#endif
