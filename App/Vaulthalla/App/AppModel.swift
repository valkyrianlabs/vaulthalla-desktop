import Foundation
import Observation
import SwiftUI
import VHCore

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

    @ObservationIgnored let store: NodeStore

    init(store: NodeStore) {
        self.store = store
        loadNodes()
    }

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
    }

    /// Saves a new, unpaired node and selects it.
    @discardableResult
    func addNode(displayName: String, endpoint: NodeEndpoint) -> Node? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = Node(id: .local(), displayName: name.isEmpty ? endpoint.host : name, endpoint: endpoint)
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
        edit { try store.update(node) }
    }

    func remove(_ id: NodeID) {
        let index = nodes.firstIndex { $0.id == id }
        guard edit({ try store.remove(id) }) else { return }
        liveStatus[id] = nil
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

    @discardableResult
    private func edit(_ change: () throws -> [Node]) -> Bool {
        do {
            nodes = try change()
            return true
        } catch {
            errorMessage = Self.message(for: error)
            return false
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? NodeStore.Failure)?.description ?? error.localizedDescription
    }

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
