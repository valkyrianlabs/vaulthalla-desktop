import Foundation
import Observation
import SwiftUI
import VHCore
import VHIdentity
import VHNodes

/// App-wide state for the shell: the node registry, what's selected, and each node's connection status.
@Observable
final class AppModel {
    enum Sheet: Identifiable, Hashable {
        case addNode
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

    var sheet: Sheet?
    var columnVisibility: NavigationSplitViewVisibility = .all
    var nodePendingRename: Node?
    var nodePendingRemoval: Node?
    /// A failed edit, shown as an alert.
    var errorMessage: String?

    /// Statuses reported by live connections. Absent means nothing is connected (see `status(for:)`).
    private var liveStatus: [NodeID: NodeConnectionStatus] = [:]
    /// Why a node with a session is offline, in the session's words.
    private var offlineReasons: [NodeID: String] = [:]
    /// Where each node's device key lives, as its session (or pairing) reported it.
    private(set) var keyBackends: [NodeID: KeyBackend] = [:]
    /// Paired nodes whose session gave up for good (key missing, unannounced server key): only pairing again helps.
    private(set) var nodesNeedingPairing: Set<NodeID> = []
    /// Whether this app manages the device keys and the node list (it holds the credential lease) or only reads
    /// what another process manages (docs/architecture.md §3, "Credential ownership").
    private(set) var credentialRole: CredentialRole
    /// The process managing them while this app is a consumer, as it recorded itself.
    private(set) var credentialOwner: CredentialLease.Holder?

    @ObservationIgnored let store: NodeStore
    /// One live session per paired node. nil in previews, which never connect.
    @ObservationIgnored private(set) var sessions: NodeSessions?
    /// Each connected node's server data (`queries(for:)`), kept while its session lives.
    @ObservationIgnored private var queryStores: [NodeID: NodeQueries] = [:]
    /// Whether the app is active with a visible window: polling runs only then (`AppActivity`).
    @ObservationIgnored private var isAppActive = true
    /// Vault key backups to 1Password across every node (Recovery Keys).
    @ObservationIgnored let recoveryKeys: RecoveryKeysModel
    /// While a consumer: follows the owner's changes to the registry and takes the lease over once the owner exits.
    @ObservationIgnored private var ownerWatch: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored private var previewTransports: [NodeID: any NodeTransport] = [:]
    #endif

    /// `store` and `keys` carry the credential lease when this app owns the credentials; without it (or while
    /// another process holds it) the model is a consumer: it shows the registry read-only and edits are refused.
    init(store: NodeStore, keys: DeviceKeys? = nil, recoveryKeys: RecoveryKeysModel = RecoveryKeysModel()) {
        self.store = store
        self.recoveryKeys = recoveryKeys
        credentialRole = store.role
        loadNodes()
        recoveryKeys.app = self
        if let keys {
            sessions = NodeSessions(keys: keys, registry: store) { [weak self] id, event in self?.handle(event, from: id) }
            syncSessions()
            recoveryKeys.start()
            if credentialRole == .consumer { watchOwner() }
        }
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
    func addNode(displayName: String, endpoint: NodeEndpoint, namedByUser: Bool = false) -> Node? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = Node(id: .local(), displayName: name.isEmpty ? endpoint.host : name, endpoint: endpoint,
                        isNamedByUser: namedByUser && !name.isEmpty)
        guard edit({ try store.add(node) }) else { return nil }
        selectNode(node.id, section: .overview)
        return node
    }

    /// The saved node already reachable at `endpoint`, if any; used to stop the same server being added twice.
    func existingNode(at endpoint: NodeEndpoint) -> Node? {
        nodes.first { $0.endpoint.host.caseInsensitiveCompare(endpoint.host) == .orderedSame && $0.endpoint.port == endpoint.port }
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
        }
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
        queryStores[id] = made
        return made
    }

    /// The store a section shows server data from: while the node is online, and through a reconnect once it has
    /// answered (the views keep the last data with a "reconnecting" banner). nil means the section shows why the
    /// node isn't available instead.
    func liveQueries(for node: Node) -> NodeQueries? {
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
    /// PREVIEW DATA: serves `node` from canned answers and reports it online, without a session.
    func usePreviewData(for id: NodeID, transport: any NodeTransport) {
        let made = NodeQueries(transport: transport)
        made.isActive = isAppActive
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
