import Foundation
import Observation
import SwiftUI
import VHCore
import VHIdentity
import VHNodes
import VHTransport

/// App-wide state for the shell: the node registry, what's selected, and each node's connection status.
@Observable
final class AppModel {
    enum Sheet: Identifiable, Hashable {
        case addNode
        /// Add Node prefilled from a `vaulthalla://pair` link.
        case addNodeFromLink(PairLink)
        case pairing(NodeID)

        var id: Self { self }
    }

    private(set) var nodes: [Node] = []
    /// Set when `nodes.json` can't be read. Edits are refused until it's fixed, so the file is never clobbered.
    private(set) var registryProblem: String?

    var showsAllNodes = true
    /// What "All Nodes" shows: the overview, or Recovery Keys across every node.
    var allNodesPage: AllNodesPage = .overview
    var selectedNodeID: NodeID?
    var selectedSection: NodeSection = .overview
    /// Which page of the Overview shows, and the panel and metric a followed warning points at.
    var healthPage: HealthPage = .summary
    var healthFocus: HealthFocus?

    var sheet: Sheet?
    var columnVisibility: NavigationSplitViewVisibility = .all
    var nodePendingRename: Node?
    var nodePendingRemoval: Node?
    /// A failed edit, shown as an alert.
    var errorMessage: String?
    /// Why a `vaulthalla://pair` link couldn't be used, shown as an alert.
    var pairLinkProblem: String?
    /// What a pairing link said about a node added from it: the server key to insist on while pairing (the code
    /// still decides) and the server id it named. Kept in memory only, until that node pairs or is removed.
    @ObservationIgnored private var pairingHints: [NodeID: PairingHint] = [:]

    struct PairingHint: Hashable {
        var serverSPKISHA256: Data?
        var serverNodeID: String?
    }

    /// Statuses reported by live connections. Absent means nothing is connected (see `status(for:)`).
    private var liveStatus: [NodeID: NodeConnectionStatus] = [:]
    /// Why a node with a session is offline, in the session's words.
    private var offlineReasons: [NodeID: String] = [:]
    /// Where each node's device key lives, as its session (or pairing) reported it.
    private(set) var keyBackends: [NodeID: KeyBackend] = [:]
    /// Paired nodes whose session gave up for good (key missing, unannounced server key): only pairing again helps.
    private(set) var nodesNeedingPairing: Set<NodeID> = []
    /// What each node's session negotiated with `meta.hello` (docs/architecture.md §3, "Protocol negotiation").
    /// Absent: not settled yet, support unknown.
    private(set) var nodeProtocols: [NodeID: NodeProtocol] = [:]
    /// The route each node's session takes (endpoint, class, RTT, the selection behind it), as it last reported.
    private(set) var routes: [NodeID: NodeRoute] = [:]
    /// What each node's transfers report (throughput, part size and concurrency, tuning); absent: nothing reported.
    private(set) var transferStats: [NodeID: TransferStats] = [:]
    /// "Test connection" per node: running, or what it found last.
    private(set) var connectionTests: [NodeID: ConnectionTestState] = [:]

    enum ConnectionTestState: Hashable {
        case running
        case finished(ConnectionTestResult)
    }

    /// What "Test connection" runs: the endpoint selection again (previews), and with live sessions also a calibration
    /// over the node's `/transfer/*` lanes where it announces `device.lanes.transfer` (`ConnectionTests.calibrating`).
    @ObservationIgnored var connectionTest: ConnectionTest = ConnectionTests.route
    /// Where transfer code reports `TransferStats`.
    @ObservationIgnored let transferStatsBoard: TransferStatsBoard
    @ObservationIgnored private var statsWatch: Task<Void, Never>?
    /// Each node's HTTP lanes (the Files section, Test Connection), made on first use and kept while the node is
    /// listed, with the feed that reports their transfer monitor to `transferStatsBoard`.
    @ObservationIgnored private var laneServices: [NodeID: NodeFileLanes] = [:]
    @ObservationIgnored private var statsFeeds: [NodeID: TransferStatsFeed] = [:]
    /// Nodes whose transfers run with automatic tuning off (the Connection panel's switch): fixed part size and
    /// concurrency. Saved in UserDefaults under `transferTuningKey` (node ids only, nothing secret).
    private(set) var tuningDisabled: Set<NodeID> = AppModel.savedTuningDisabled()
    static let transferTuningKey = "transfers.automaticTuningOff"
    /// Whether this app manages the device keys and the node list (it holds the credential lease) or only reads
    /// what another process manages (docs/architecture.md §3, "Credential ownership").
    private(set) var credentialRole: CredentialRole
    /// The process managing them while this app is a consumer, as it recorded itself.
    private(set) var credentialOwner: CredentialLease.Holder?

    @ObservationIgnored let store: NodeStore
    /// Where the registry lives and what launch did to it (the App Group migration). It also keeps the leases
    /// alive: the registry's, and after a migration the old location's. nil when run against a given store.
    @ObservationIgnored let registry: RegistryOwnership?
    /// One live session per paired node. nil in previews, which never connect.
    @ObservationIgnored private(set) var sessions: NodeSessions?
    /// Each connected node's server data (`queries(for:)`), kept while its session lives.
    @ObservationIgnored private var queryStores: [NodeID: NodeQueries] = [:]
    /// Whether the app is active with a visible window: polling runs only then (`AppActivity`).
    @ObservationIgnored private var isAppActive = true
    /// Vault key backups to 1Password across every node (Recovery Keys).
    @ObservationIgnored let recoveryKeys: RecoveryKeysModel
    /// The optional Touch ID gate for Recovery Keys, Credentials and Access (desktop#7).
    @ObservationIgnored let sensitiveAccess = SensitiveAccess()
    /// While a consumer: follows the owner's changes to the registry and takes the lease over once the owner exits.
    @ObservationIgnored private var ownerWatch: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored private var previewTransports: [NodeID: any NodeTransport] = [:]
    #endif

    /// `store` and `keys` carry the credential lease when this app owns the credentials; without it (or while
    /// another process holds it) the model is a consumer: it shows the registry read-only and edits are refused.
    init(store: NodeStore, keys: DeviceKeys? = nil, recoveryKeys: RecoveryKeysModel = RecoveryKeysModel(),
         registry: RegistryOwnership? = nil, transferStats: TransferStatsBoard = .shared) {
        self.store = store
        self.registry = registry
        self.recoveryKeys = recoveryKeys
        self.transferStatsBoard = transferStats
        credentialRole = store.role
        loadNodes()
        recoveryKeys.app = self
        if let keys {
            sessions = NodeSessions(keys: keys, registry: store) { [weak self] id, event in self?.handle(event, from: id) }
            syncSessions()
            recoveryKeys.start()
            if credentialRole == .consumer { watchOwner() }
            watchTransferStats()
            connectionTest = ConnectionTests.calibrating { [weak self] session throws(TransferError) in
                guard let lanes = await self?.fileLanes(for: session.nodeID) else { throw .cancelled }
                return try await lanes.testConnection()
            }
        }
    }

    /// Follows what transfer code reports, for the status view.
    private func watchTransferStats() {
        guard statsWatch == nil else { return }
        let updates = transferStatsBoard.updates()
        statsWatch = Task { [weak self] in
            for await (id, stats) in updates {
                guard let self else { return }
                self.transferStats[id] = stats
            }
        }
    }

    /// Runs "Test connection" on the node's session (no-op without one).
    func testConnection(for id: NodeID) {
        guard connectionTests[id] != .running, let session = sessions?.session(for: id) else { return }
        connectionTests[id] = .running
        let test = connectionTest
        Task { [weak self] in
            let result = await test(session)
            self?.connectionTests[id] = .finished(result)
        }
    }

    // MARK: - Transfers

    /// The node's HTTP lanes, made on first use: its transfer monitor starts with the node's tuning switch and its
    /// route's class, and reports to `transferStatsBoard` from then on.
    func fileLanes(for id: NodeID) -> NodeFileLanes {
        if let existing = laneServices[id] { return existing }
        let made = NodeFileLanes(nodeID: id) { [weak self] in self?.sessions?.session(for: id) }
        laneServices[id] = made
        if let monitor = made.transferMonitor {
            monitor.setTuningEnabled(!tuningDisabled.contains(id))
            if let route = routes[id] { monitor.setEndpointClass(TransferEndpointClass(route.transportClass)) }
            statsFeeds[id] = TransferStatsFeed(monitor: monitor, node: id, board: transferStatsBoard)
        }
        return made
    }

    private func dropFileLanes(for id: NodeID) {
        statsFeeds.removeValue(forKey: id)?.stop()
        laneServices[id] = nil
    }

    /// Whether the node's transfers adapt part size and concurrency to the measured link.
    func automaticTuning(for id: NodeID) -> Bool {
        !tuningDisabled.contains(id)
    }

    /// The Connection panel's switch: applies to the node's transfers now (parts already sent are unaffected) and
    /// is remembered for the next launch.
    func setAutomaticTuning(_ enabled: Bool, for id: NodeID) {
        guard enabled != automaticTuning(for: id) else { return }
        if enabled { tuningDisabled.remove(id) } else { tuningDisabled.insert(id) }
        saveTuningDisabled()
        laneServices[id]?.transferMonitor?.setTuningEnabled(enabled)
    }

    private static func savedTuningDisabled() -> Set<NodeID> {
        let saved = UserDefaults.standard.stringArray(forKey: transferTuningKey) ?? []
        return Set(saved.map { NodeID(rawValue: $0) })
    }

    private func saveTuningDisabled() {
        let ids = tuningDisabled.map(\.rawValue).sorted()
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.transferTuningKey)
        } else {
            UserDefaults.standard.set(ids, forKey: Self.transferTuningKey)
        }
    }

    /// Whether the node has a session "Test connection" can run on.
    func canTestConnection(for id: NodeID) -> Bool {
        sessions?.session(for: id) != nil && connectionTests[id] != .running
    }

    var isCredentialOwner: Bool { credentialRole == .owner }

    /// The device keys pairing creates and sessions present.
    var deviceKeys: DeviceKeys? { sessions?.keys }

    var registryURL: URL { store.fileURL }

    var selectedNode: Node? {
        selectedNodeID.flatMap(node(withID:))
    }

    func node(withID id: NodeID) -> Node? {
        nodes.first { $0.id == id }
    }

    // MARK: - Registry

    func loadNodes() {
        do {
            nodes = try store.reload()
            registryProblem = nil
        } catch {
            nodes = []
            registryProblem = Self.message(for: error)
        }
        if let selectedNodeID, node(withID: selectedNodeID) == nil {
            self.selectedNodeID = nil
            showsAllNodes = true
        }
        syncSessions()
    }

    /// Saves a new, unpaired node and selects it. `namedByUser`: the operator typed the name, so pairing keeps it
    /// instead of taking the server's.
    @discardableResult
    func addNode(displayName: String, endpoint: NodeEndpoint, namedByUser: Bool = false,
                 endpoints: [AdvertisedEndpoint] = [], hint: PairingHint? = nil) -> Node? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = Node(id: .local(), displayName: name.isEmpty ? endpoint.host : name, endpoint: endpoint,
                        isNamedByUser: namedByUser && !name.isEmpty, endpoints: endpoints)
        guard edit({ try store.add(node) }) else { return nil }
        pairingHints[node.id] = hint
        selectNode(node.id, section: .overview)
        return node
    }

    /// The saved node that already is this server, if any; used to stop the same server being added twice. It matches
    /// the address (the configured one, or one the node advertised other than loopback, which every node has) or,
    /// where both are known, the server's install id (`serverNodeID`, from Bonjour's TXT `node_id` or a pairing link).
    func existingNode(at endpoint: NodeEndpoint?, serverNodeID: String? = nil) -> Node? {
        if let serverNodeID, let match = nodes.first(where: { $0.serverNodeID == serverNodeID }) { return match }
        guard let endpoint else { return nil }
        func same(_ other: NodeEndpoint) -> Bool {
            other.host.caseInsensitiveCompare(endpoint.host) == .orderedSame && other.port == endpoint.port
        }
        if let match = nodes.first(where: { same($0.endpoint) }) { return match }
        return nodes.first { node in
            node.endpoints.contains { $0.kind != .loopback && !TransportSecurity.isLoopback($0.host) && same($0.endpoint) }
        }
    }

    func rename(_ id: NodeID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var node = node(withID: id), node.displayName != trimmed else { return }
        node.displayName = trimmed
        node.isNamedByUser = true
        edit { try store.update(node) }
    }

    func remove(_ id: NodeID) {
        let index = nodes.firstIndex { $0.id == id }
        guard edit({ try store.remove(id) }) else { return }
        liveStatus[id] = nil
        queryStores[id] = nil
        keyBackends[id] = nil
        nodeProtocols[id] = nil
        routes[id] = nil
        pairingHints[id] = nil
        connectionTests[id] = nil
        transferStats[id] = nil
        dropFileLanes(for: id)
        if tuningDisabled.remove(id) != nil { saveTuningDisabled() }
        nodesNeedingPairing.remove(id)
        // The key was filed under this node's local id; nothing else can use it.
        if let keys = deviceKeys, isCredentialOwner {
            Task { try? await keys.deleteIdentity(for: id.rawValue) }
        }
        guard selectedNodeID == id else { return }
        if let index, !nodes.isEmpty {
            selectedNodeID = nodes[min(index, nodes.count - 1)].id
        } else {
            selectedNodeID = nil
            showsAllNodes = true
        }
    }

    /// Sidebar drag-to-reorder.
    func moveNodes(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = nodes
        reordered.move(fromOffsets: source, toOffset: destination)
        edit { try store.reorder(reordered.map(\.id)) }
    }

    /// Records a pairing outcome. The pairing client (VHIdentity/VHTransport) calls this; the shell never invents one.
    func updatePairing(_ pairing: PairingState, for id: NodeID) {
        guard var node = node(withID: id) else { return }
        node.pairing = pairing
        edit { try store.update(node) }
    }

    /// Before a pairing attempt: the node's session (if any) stops, so the old key isn't in use while it's replaced.
    func prepareForPairing(_ id: NodeID) {
        sessions?.stop(id)
        liveStatus[id] = nil
        offlineReasons[id] = nil
        queryStores[id] = nil
        nodeProtocols[id] = nil
        routes[id] = nil
        nodesNeedingPairing.remove(id)
    }

    /// Whether the node is paired on paper but needs pairing again to connect.
    func needsPairingAgain(_ id: NodeID) -> Bool {
        nodesNeedingPairing.contains(id)
    }

    /// The owner approved this Mac: pin the server's key, take the server's name unless the operator chose one, and
    /// connect as a Device session.
    func pairingApproved(_ id: NodeID, serverNodeID: String, serverName: String, deviceID: String, serverSPKI: Data,
                         backend: KeyBackend) {
        guard var node = node(withID: id) else { return }
        node.pairing = .paired(serverSPKISHA256: serverSPKI, deviceID: deviceID, since: .now)
        node.serverNodeID = serverNodeID
        node.nextServerSPKISHA256 = nil
        pairingHints[id] = nil
        let name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !node.isNamedByUser, !name.isEmpty { node.displayName = name }
        keyBackends[id] = backend
        guard edit({ try store.update(node) }) else { return }
        selectNode(id, section: .overview)
    }

    @discardableResult
    private func edit(_ change: () throws -> [Node]) -> Bool {
        do {
            nodes = try change()
            syncSessions()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    // MARK: - Credential ownership

    /// A consumer re-reads the registry the owner writes, and takes the lease as soon as the owner lets go of it
    /// (quits or crashes). The sessions then restart as owners (`NodeSessions.sync`).
    private func watchOwner() {
        guard ownerWatch == nil, let lease = store.lease else { return }
        credentialOwner = lease.currentHolder()
        ownerWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if (try? lease.acquire()) != nil {
                    self.credentialRole = self.store.role
                    self.credentialOwner = nil
                    self.ownerWatch = nil
                    self.loadNodes()
                    return
                }
                self.followOwner(holder: lease.currentHolder())
            }
        }
    }

    /// Picks up what the owner saved since the last look.
    private func followOwner(holder: CredentialLease.Holder?) {
        if holder != credentialOwner { credentialOwner = holder }
        guard let saved = try? store.reload() else { return }
        if saved != nodes || registryProblem != nil { loadNodes() }
    }

    // MARK: - Sessions

    private func syncSessions() {
        guard let sessions else { return }
        sessions.sync(nodes)
        let live = sessions.nodeIDs
        for id in liveStatus.keys where !live.contains(id) {
            liveStatus[id] = nil
            offlineReasons[id] = nil
        }
        for id in queryStores.keys where !live.contains(id) {
            queryStores[id] = nil
        }
        for id in nodeProtocols.keys where !live.contains(id) {
            nodeProtocols[id] = nil
        }
        for id in routes.keys where !live.contains(id) {
            routes[id] = nil
        }
    }

    private func handle(_ event: NodeSession.Event, from id: NodeID) {
        switch event {
        case .status(let status):
            switch status {
            case .connecting: setConnectionStatus(.connecting, for: id)
            case .online:
                let cameOnline = liveStatus[id] != .online
                setConnectionStatus(.online, for: id)
                if cameOnline { Task { await recoveryKeys.pollNodes() } }
            case .offline(let reason):
                offlineReasons[id] = reason
                setConnectionStatus(.offline, for: id)
            case .revoked: setConnectionStatus(.revoked, for: id)
            }
            if case .offline = status {} else {
                offlineReasons[id] = nil
                nodesNeedingPairing.remove(id)
            }
            queryStores[id]?.connectionChanged(online: status == .online)
        case .recordChanged(let pairing, let next):
            guard var node = node(withID: id) else { return }
            node.pairing = pairing
            node.nextServerSPKISHA256 = next
            edit { try store.update(node) }
        case .identity(_, let backend):
            keyBackends[id] = backend
        case .pairingRequired:
            nodesNeedingPairing.insert(id)
        case .protocolNegotiated(let settled):
            nodeProtocols[id] = settled
            queryStores[id]?.protocolChanged(settled)
        case .route(let route):
            routes[id] = route
            // Learning starts over when the class of route changes (a LAN estimate says nothing about a WAN route).
            laneServices[id]?.transferMonitor?.setEndpointClass(TransferEndpointClass(route.transportClass))
        case .endpointsChanged(let endpoints, let advertisedAt, let lastGood):
            // Routing hints from an owner session: saving them doesn't restart it (they aren't part of its basis).
            guard var node = node(withID: id),
                  node.endpoints != endpoints || node.lastAdvertisedAt != advertisedAt || node.lastGood != lastGood
            else { return }
            node.endpoints = endpoints
            node.lastAdvertisedAt = advertisedAt
            node.lastGood = lastGood
            edit { try store.update(node) }
        }
    }

    /// The route the node's session takes, as it last reported; nil before its first selection.
    func route(for id: NodeID) -> NodeRoute? {
        routes[id]
    }

    // MARK: - Protocol

    /// What the node's session negotiated; nil while unknown (not connected yet, or no answer).
    func nodeProtocol(for id: NodeID) -> NodeProtocol? {
        nodeProtocols[id]
    }

    /// Why this build can't work with the node, when its protocol range doesn't overlap: the node stays listed and
    /// connected, its sections say what to update, and feature calls are refused unsent.
    func incompatibility(for node: Node) -> ProtocolMismatch? {
        nodeProtocols[node.id]?.mismatch
    }

    /// Why a node's session is offline, when it said.
    func offlineReason(for id: NodeID) -> String? {
        liveStatus[id] == .offline ? offlineReasons[id] : nil
    }

    private static func message(for error: any Error) -> String {
        (error as? NodeStore.Failure)?.description ?? error.localizedDescription
    }

    // MARK: - Server data

    /// The node's query store, made on first use while it has a session. Views get it through `liveQueries(for:)`.
    func queries(for id: NodeID) -> NodeQueries? {
        if let existing = queryStores[id] { return existing }
        guard let sessions, sessions.session(for: id) != nil else { return nil }
        let made = NodeQueries(transport: SessionTransport { [weak sessions] in sessions?.session(for: id) })
        made.isActive = isAppActive
        made.connectionChanged(online: liveStatus[id] == .online)
        made.protocolChanged(nodeProtocols[id])
        queryStores[id] = made
        return made
    }

    /// The store a section shows server data from: while the node is online, and through a reconnect once it has
    /// answered (the views keep the last data with a "reconnecting" banner). nil means the section shows why the
    /// node isn't available instead, also for a node whose protocol this build doesn't speak.
    func liveQueries(for node: Node) -> NodeQueries? {
        if incompatibility(for: node) != nil { return nil }
        switch status(for: node) {
        case .online:
            return queries(for: node.id)
        case .connecting, .offline:
            guard let existing = queryStores[node.id], existing.hasAnswered else { return nil }
            return existing
        case .notPaired, .revoked:
            return nil
        }
    }

    /// The app became active or inactive, or its window was hidden or shown: polling follows.
    func setAppActive(_ active: Bool) {
        guard active != isAppActive else { return }
        isAppActive = active
        for store in queryStores.values { store.isActive = active }
        recoveryKeys.appActivityChanged(active)
    }

    /// How key backup reaches a node: its live session (or PREVIEW DATA), nil while it has none.
    func keyTransport(for id: NodeID) -> (any NodeTransport)? {
        #if DEBUG
        if let preview = previewTransports[id] { return preview }
        #endif
        guard let sessions, sessions.session(for: id) != nil else { return nil }
        return SessionTransport { [weak sessions] in sessions?.session(for: id) }
    }

    /// ⌘R: refetch what the selected node's visible section shows.
    func refreshVisible() {
        guard !showsAllNodes, let node = selectedNode else { return }
        liveQueries(for: node)?.refreshObserved()
    }

    var canRefreshVisible: Bool {
        guard !showsAllNodes, let node = selectedNode else { return false }
        return status(for: node) == .online
    }

    #if DEBUG
    /// PREVIEW DATA: shows `route` and `stats` for a node without a session.
    func usePreviewRoute(_ route: NodeRoute, stats: TransferStats?, for id: NodeID) {
        routes[id] = route
        transferStats[id] = stats
    }

    /// PREVIEW DATA: serves `node` from canned answers and reports it online, without a session, as running what
    /// `negotiated` says.
    func usePreviewData(for id: NodeID, transport: any NodeTransport, negotiated: NodeProtocol? = nil) {
        let made = NodeQueries(transport: transport)
        made.isActive = isAppActive
        nodeProtocols[id] = negotiated
        made.protocolChanged(negotiated)
        queryStores[id] = made
        liveStatus[id] = .online
        previewTransports[id] = transport
    }
    #endif

    // MARK: - Connection status

    func status(for node: Node) -> NodeConnectionStatus {
        liveStatus[node.id] ?? NodeConnectionStatus(resting: node.pairing)
    }

    /// The transport's hook: report what a node's connection is doing, or `nil` once nothing is connected.
    func setConnectionStatus(_ status: NodeConnectionStatus?, for id: NodeID) {
        liveStatus[id] = status
    }

    // MARK: - Selection

    func showAllNodes() {
        showsAllNodes = true
        allNodesPage = .overview
    }

    /// Recovery Keys across every node (the All Nodes variant; the notification's action).
    func showAllRecoveryKeys() {
        showsAllNodes = true
        allNodesPage = .recoveryKeys
    }

    func selectNode(_ id: NodeID, section: NodeSection? = nil) {
        guard node(withID: id) != nil else { return }
        selectedNodeID = id
        if let section { selectedSection = section }
        showsAllNodes = false
    }

    /// ⌘1…⌘9.
    func selectNode(atPosition position: Int) {
        guard nodes.indices.contains(position) else { return }
        selectNode(nodes[position].id)
    }

    func select(_ section: NodeSection) {
        guard selectedNodeID != nil else { return }
        selectedSection = section
        showsAllNodes = false
    }

    func presentAddNode() {
        sheet = .addNode
    }

    /// The server key a pairing link named for this node, to refuse any other while pairing.
    func pairingHint(for id: NodeID) -> PairingHint? {
        pairingHints[id]
    }

    /// Opens a `vaulthalla://pair` link (untrusted): Add Node prefilled from it, or the node it names when this Mac
    /// already has it. A link that doesn't parse is explained, never half-used.
    func openPairLink(_ url: URL) {
        let link: PairLink
        do {
            link = try PairLink(url: url)
        } catch {
            pairLinkProblem = error.description
            return
        }
        guard isCredentialOwner else {
            pairLinkProblem = CredentialOwnershipError.notOwner(operation: "pair this Mac").description
            return
        }
        let known = link.endpoints.lazy.compactMap { self.existingNode(at: $0, serverNodeID: link.nodeID) }.first
            ?? existingNode(at: nil, serverNodeID: link.nodeID)
        if let known {
            selectNode(known.id, section: .overview)
            if !known.pairing.isPaired {
                pairingHints[known.id] = PairingHint(serverSPKISHA256: link.serverSPKISHA256, serverNodeID: link.nodeID)
                sheet = .pairing(known.id)
            }
            return
        }
        sheet = .addNodeFromLink(link)
    }

    func presentPairing(for id: NodeID) {
        sheet = .pairing(id)
    }

    func toggleSidebar() {
        withAnimation {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    /// The part of the selection a window restores (`@SceneStorage`).
    var restorableSelection: RestorableSelection {
        get {
            RestorableSelection(allNodes: showsAllNodes, node: selectedNodeID?.rawValue, section: selectedSection)
        }
        set {
            selectedSection = newValue.section
            if let raw = newValue.node, node(withID: NodeID(rawValue: raw)) != nil {
                selectedNodeID = NodeID(rawValue: raw)
                showsAllNodes = newValue.allNodes
            } else {
                selectedNodeID = nil
                showsAllNodes = true
            }
        }
    }
}

enum AllNodesPage: String, Hashable, Sendable {
    case overview
    case recoveryKeys
}

struct RestorableSelection: Codable, Hashable, RawRepresentable {
    var allNodes = true
    var node: String?
    var section: NodeSection = .overview

    init(allNodes: Bool = true, node: String? = nil, section: NodeSection = .overview) {
        self.allNodes = allNodes
        self.node = node
        self.section = section
    }

    init?(rawValue: String) {
        guard let value = try? JSONDecoder().decode(Self.self, from: Data(rawValue.utf8)) else { return nil }
        self = value
    }

    var rawValue: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // Spelled out: RawRepresentable would otherwise route Codable through `rawValue` and recurse.
    private enum CodingKeys: String, CodingKey { case allNodes, node, section }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allNodes = try container.decodeIfPresent(Bool.self, forKey: .allNodes) ?? true
        node = try container.decodeIfPresent(String.self, forKey: .node)
        section = (try? container.decodeIfPresent(NodeSection.self, forKey: .section)) ?? .overview
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(allNodes, forKey: .allNodes)
        try container.encodeIfPresent(node, forKey: .node)
        try container.encode(section, forKey: .section)
    }
}
