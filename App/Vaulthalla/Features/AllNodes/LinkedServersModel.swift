import Foundation
import Observation
import VHCore
import VHNodes
import VHTransport

/// Linked servers across every paired node, for All Nodes (docs/architecture.md §3, "Linked servers"): which nodes
/// link servers (Vaulthalla 1.27 and newer) and which are older, each one's links with their health, links only one
/// side records, and the Link Servers sheet's attempt. Link Servers is always offered; linking needs two nodes that
/// link servers. Everything goes over this Mac's own Device sessions; agents never reach any of it.
@MainActor @Observable final class LinkedServersModel {
    /// What each paired node said last (`peer.list`).
    private(set) var availability: [NodeID: ServerLinkAvailability] = [:]
    /// The Link Servers sheet's attempt.
    private(set) var attempt: Attempt?
    /// Unlink or rename in flight, per node and row.
    private(set) var working: Set<String> = []
    /// The last unlink or rename that failed, to show beside the list.
    var problem: String?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var running: Task<Void, Never>?

    struct Attempt: Equatable {
        var first: NodeID
        var second: NodeID
        var step: ServerLinking.Step = .checking
        var outcome: Result<ServerLinking.Linked, ServerLinking.Failure>?

        var isRunning: Bool { outcome == nil }
    }

    /// Paired nodes whose Vaulthalla links servers, in sidebar order.
    var linkableNodes: [Node] {
        (app?.nodes ?? []).filter { availability[$0.id]?.supportsLinking == true }
    }

    /// Paired nodes whose Vaulthalla is too old to link servers, in sidebar order.
    var olderNodes: [Node] {
        (app?.nodes ?? []).filter { availability[$0.id] == .unsupported }
    }

    /// Whether All Nodes shows the Linked servers panel: once any node has said whether it links servers.
    var isVisible: Bool { !linkableNodes.isEmpty || !olderNodes.isEmpty }

    /// Whether two servers can be picked: two nodes that link servers.
    var canLink: Bool { linkableNodes.count >= 2 }

    func links(for id: NodeID) -> [LinkedServer] { availability[id]?.links ?? [] }

    /// Links only one side records, among this Mac's nodes.
    var oneSided: [ServerLinking.HalfLink] {
        LinkedServers.oneSided(nodes: linkableNodes,
                               links: availability.compactMapValues { if case .on(let l) = $0 { l } else { nil } })
    }

    /// The node this Mac knows by `row`'s key, if any.
    func node(for row: LinkedServer) -> Node? {
        (app?.nodes ?? []).first { $0.serverPin != nil && $0.serverPin == row.serverSPKISHA256 }
    }

    // MARK: - Reading

    /// Asks every paired, connected node. A node that can't be asked keeps what it said last.
    func refresh() async {
        guard let app else { return }
        let targets = app.nodes.filter { $0.pairing.isPaired && app.status(for: $0) == .online }
            .compactMap { node in app.transport(for: node.id).map { (node, $0) } }
        let known = Set(app.nodes.map(\.id))
        await withTaskGroup(of: (NodeID, ServerLinkAvailability).self) { group in
            for (node, transport) in targets {
                group.addTask { (node.id, await LinkedServers.availability(on: transport, name: node.displayName)) }
            }
            for await (id, answer) in group {
                if case .unknown = answer, availability[id] != nil { continue }
                availability[id] = answer
            }
        }
        for id in availability.keys where !known.contains(id) { availability[id] = nil }
    }

    /// While All Nodes shows: now, then every 15 s (health changes on its own).
    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(15))
        }
    }

    // MARK: - Linking

    func startLinking(_ first: NodeID, _ second: NodeID) {
        guard let app, let a = app.node(withID: first), let b = app.node(withID: second),
              let ta = app.transport(for: first), let tb = app.transport(for: second)
        else {
            attempt = Attempt(first: first, second: second, outcome: .failure(.offline("A node")))
            return
        }
        running?.cancel()
        attempt = Attempt(first: first, second: second)
        let sides = (ServerLinking.Side(node: a, transport: ta), ServerLinking.Side(node: b, transport: tb))
        let (steps, reporter) = AsyncStream<ServerLinking.Step>.makeStream()
        running = Task { [weak self] in
            let follow = Task { @MainActor [weak self] in
                for await step in steps where self?.attempt?.isRunning == true { self?.attempt?.step = step }
            }
            let result = await ServerLinking().link(sides.0, sides.1) { reporter.yield($0) }
            reporter.finish()
            await follow.value
            guard let self else { return }
            self.attempt?.outcome = result
            await self.refresh()
        }
    }

    /// Stops the attempt; ``ServerLinking`` undoes what it got to before it reports.
    func cancelLinking() {
        running?.cancel()
    }

    func clearAttempt() {
        guard attempt?.isRunning != true else { return }
        attempt = nil
    }

    // MARK: - Changing

    func unlink(_ row: LinkedServer, on id: NodeID) async {
        await change(row, on: id) { transport in try await LinkedServers.unlink(row.id, on: transport) }
    }

    func unlink(_ half: ServerLinking.HalfLink) async {
        guard let app, let transport = app.transport(for: half.node) else {
            problem = "\(half.nodeName) isn't connected."
            return
        }
        let key = "\(half.node.rawValue)#\(half.peerID)"
        working.insert(key)
        defer { working.remove(key) }
        do {
            try await LinkedServers.unlink(half.peerID, on: transport)
            problem = nil
        } catch {
            problem = "\(half.nodeName): \(error.message)"
        }
        await refresh()
        if case .failure(.halfLinked(let leftover))? = attempt?.outcome, leftover == half { attempt = nil }
    }

    func rename(_ row: LinkedServer, on id: NodeID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != row.name else { return }
        await change(row, on: id) { transport in try await LinkedServers.rename(row.id, to: trimmed, on: transport) }
    }

    func isWorking(_ row: LinkedServer, on id: NodeID) -> Bool { working.contains("\(id.rawValue)#\(row.id)") }

    private func change(_ row: LinkedServer, on id: NodeID,
                        _ body: @escaping @Sendable (any NodeTransport) async throws -> Void) async {
        guard let app, let transport = app.transport(for: id) else {
            problem = "\(app?.node(withID: id)?.displayName ?? "The node") isn't connected."
            return
        }
        let key = "\(id.rawValue)#\(row.id)"
        working.insert(key)
        defer { working.remove(key) }
        do {
            try await body(transport)
            problem = nil
        } catch {
            let text = (error as? WsError)?.message ?? error.localizedDescription
            problem = "\(app.node(withID: id)?.displayName ?? "The node"): \(text)"
        }
        await refresh()
    }
}
