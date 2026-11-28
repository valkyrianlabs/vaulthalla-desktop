import Foundation
import Observation
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Linked servers across every paired node, for All Nodes (docs/architecture.md §3, "Linked servers"): which nodes
/// link servers (Vaulthalla 1.27 and newer) and which are older, each one's links with their health, links only one
/// side records, pairs that aren't linked (a suggestion only), and the Link Servers sheet's attempts: the one-screen
/// handshake where this Mac is a super admin on both, a request where it is one on only one side, and accepting a
/// request on a node. Trust never spreads by itself: the servers still shake hands, and each refuses every linking
/// command unless the caller is a super admin there. Everything goes over this Mac's own Device sessions; agents never
/// reach any of it.
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

    /// Each node's vault roles, for the default-role pickers (`roles.vault.list`), or why they couldn't be read.
    private(set) var roleOptions: [NodeID: Result<[LinkRoles.Option], WsError>] = [:]
    /// The Link Servers sheet's request (this Mac a super admin on one side only).
    private(set) var request: RequestAttempt?
    /// The Accept a Link Request sheet's window.
    private(set) var acceptance: Acceptance?
    @ObservationIgnored private var requesting: Task<Void, Never>?
    @ObservationIgnored private var accepting: Task<Void, Never>?

    struct Attempt: Equatable {
        var first: NodeID
        var second: NodeID
        var step: ServerLinking.Step = .checking
        var outcome: Result<ServerLinking.Linked, ServerLinking.Failure>?
        /// The default roles chosen per node (what that node gives the other).
        var chosenRoles: [NodeID: LinkRoles.Option] = [:]
        /// Linked, and the chosen roles are being set.
        var settingRoles = false
        /// What became of each chosen role, once linked.
        var roles: [LinkRoles.Applied] = []

        var isRunning: Bool { outcome == nil || settingRoles }
    }

    /// One request from `from` to another server, whose admin approves it there.
    struct RequestAttempt: Equatable {
        var from: NodeID
        var otherName: String
        var endpoint: NodeEndpoint
        var linkID: String?
        var phase: LinkRequest.Phase = .connecting
        /// The server refused to start it, in its words.
        var failure: String?

        var isRunning: Bool { failure == nil && !phase.isFinished }
    }

    /// The window on `node` for another server's request.
    struct Acceptance: Equatable {
        enum State: Equatable {
            case opening
            case open(LinkAcceptance.Window)
            /// Another pairing window is open there.
            case busy
            /// Expired, or closed by an approval.
            case closed
            case failed(String)
        }

        var node: NodeID
        var state: State = .opening
        var requests: [LinkAcceptance.Request] = []
        /// The request being approved or denied.
        var working: String?
        /// The last decision, said beside the list.
        var decision: LinkAcceptance.Decision?
        var problem: String?
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

    /// Whether the sheet has anything to start: a node where this Mac may link servers.
    var canLink: Bool { linkableNodes.contains { isPermitted($0.id) } }

    /// Whether this Mac's account may link servers on the node (a super admin there, on a direct, full-access session).
    func isPermitted(_ id: NodeID) -> Bool {
        if case .on = availability[id] { true } else { false }
    }

    /// Pairs of nodes that aren't linked with each other: All Nodes' quiet suggestion rows.
    var suggestions: [LinkSuggestion] {
        LinkedServers.suggestions(nodes: app?.nodes ?? [], availability: availability)
    }

    /// What the sheet offers for two picks (nil: a server by its address).
    func plan(_ first: NodeID, _ second: NodeID?) -> LinkPlan {
        LinkedServers.plan(first, second, availability: availability)
    }

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

    private func side(_ id: NodeID) -> ServerLinking.Side? {
        guard let app, let node = app.node(withID: id), let transport = app.transport(for: id) else { return nil }
        return ServerLinking.Side(node: node, transport: transport)
    }

    /// Reads the node's vault roles for its default-role picker, once per sheet.
    func loadRoleOptions(_ id: NodeID) async {
        guard roleOptions[id] == nil, let side = side(id) else { return }
        roleOptions[id] = await LinkRoles.options(on: side.transport)
    }

    /// Links `first` and `second`, then gives each the role chosen for the other there (`roles`, per node; "No role"
    /// sends nothing). A refused role leaves the link as it is.
    func startLinking(_ first: NodeID, _ second: NodeID, roles: [NodeID: LinkRoles.Option] = [:]) {
        guard let a = side(first), let b = side(second) else {
            attempt = Attempt(first: first, second: second, outcome: .failure(.offline("A node")))
            return
        }
        running?.cancel()
        attempt = Attempt(first: first, second: second, chosenRoles: roles)
        let sides = (a, b)
        let (steps, reporter) = AsyncStream<ServerLinking.Step>.makeStream()
        running = Task { [weak self] in
            let follow = Task { @MainActor [weak self] in
                for await step in steps where self?.attempt?.isRunning == true { self?.attempt?.step = step }
            }
            let result = await ServerLinking().link(sides.0, sides.1) { reporter.yield($0) }
            reporter.finish()
            await follow.value
            guard let self else { return }
            let chosen = roles.filter { $0.value.roleID != nil }
            self.attempt?.settingRoles = result.isSuccess && !chosen.isEmpty
            self.attempt?.outcome = result
            if result.isSuccess, !chosen.isEmpty {
                var applied: [LinkRoles.Applied] = []
                for (side, other) in [(sides.0, sides.1), (sides.1, sides.0)] {
                    guard let option = chosen[side.node.id] else { continue }
                    applied.append(await LinkRoles.apply(option, on: side, for: other.node))
                }
                self.attempt?.roles = applied
                self.attempt?.settingRoles = false
            }
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

    // MARK: - Requesting a link (one side)

    /// `from` dials `endpoint` and asks; the other server's admin approves it there. `expect`: this Mac's pin for the
    /// other server when it is paired here, so only that key completes the handshake.
    func startRequest(from: NodeID, otherName: String, endpoint: NodeEndpoint, expect: Data?) {
        guard let side = side(from) else {
            request = RequestAttempt(from: from, otherName: otherName, endpoint: endpoint,
                                     failure: ServerLinking.Failure.offline(app?.node(withID: from)?.displayName ?? "The node").description)
            return
        }
        requesting?.cancel()
        request = RequestAttempt(from: from, otherName: otherName, endpoint: endpoint)
        requesting = Task { [weak self] in
            let started = await LinkRequest.start(on: side, to: endpoint, expect: expect)
            // Cancelled while it was being started: stop what the server started, and say nothing more.
            if Task.isCancelled {
                if case .success(let id) = started { await LinkRequest.cancel(id, on: side) }
                return
            }
            guard let self else { return }
            let id: String
            switch started {
            case .success(let linkID): id = linkID
            case .failure(.refused(_, let text)) where LinkRequest.isNoWindow(text):
                self.request?.phase = .noWindow
                return
            case .failure(let failure):
                self.request?.failure = failure.description
                return
            }
            self.request?.linkID = id
            while !Task.isCancelled {
                switch await LinkRequest.status(id, on: side) {
                case .success(let status):
                    self.request?.phase = status.phase
                    if status.phase.isFinished {
                        if status.phase == .linked { await self.refresh() }
                        return
                    }
                case .failure(let failure):
                    self.request?.failure = failure.description
                    return
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    /// Stops the request (`peer.link.cancel`) and shows that it was.
    func cancelRequest() {
        requesting?.cancel()
        guard let request, request.isRunning, let id = request.linkID, let side = side(request.from) else {
            if self.request?.isRunning == true { self.request?.phase = .cancelled }
            return
        }
        Task {
            await LinkRequest.cancel(id, on: side)
            if case .success(let status) = await LinkRequest.status(id, on: side) { self.request?.phase = status.phase }
            if self.request?.isRunning == true { self.request?.phase = .cancelled }
        }
    }

    func clearRequest() {
        if request?.isRunning == true { cancelRequest() }
        requesting = nil
        request = nil
    }

    // MARK: - Accepting a request

    /// Opens the node's window for another server's request and watches its requests until it closes.
    func openAcceptance(on id: NodeID) {
        accepting?.cancel()
        acceptance = Acceptance(node: id)
        guard let side = side(id) else {
            acceptance?.state = .failed(ServerLinking.Failure.offline(app?.node(withID: id)?.displayName ?? "The node").description)
            return
        }
        accepting = Task { [weak self] in
            let opened = await LinkAcceptance.open(on: side)
            guard let self else { return }
            switch opened {
            case .success(.open(let window)): self.acceptance?.state = .open(window)
            case .success(.busy):
                self.acceptance?.state = .busy
                return
            case .failure(let failure):
                self.acceptance?.state = .failed(failure.description)
                return
            }
            while !Task.isCancelled {
                switch await LinkAcceptance.pending(on: side) {
                case .success(let requests?): self.acceptance?.requests = requests
                case .success(nil):
                    self.acceptance?.requests = []
                    if case .open = self.acceptance?.state { self.acceptance?.state = .closed }
                    return
                case .failure(let failure): self.acceptance?.problem = failure.description
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func approve(_ request: LinkAcceptance.Request, code: String) {
        decide(request) { side in await LinkAcceptance.approve(request, code: code, on: side) }
    }

    func deny(_ request: LinkAcceptance.Request) {
        decide(request) { side in await LinkAcceptance.deny(request, on: side) }
    }

    private func decide(_ request: LinkAcceptance.Request,
                        _ body: @escaping (ServerLinking.Side) async -> Result<LinkAcceptance.Decision, ServerLinking.Failure>) {
        guard let acceptance, acceptance.working == nil, let side = side(acceptance.node) else { return }
        self.acceptance?.working = request.id
        Task {
            let result = await body(side)
            self.acceptance?.working = nil
            switch result {
            case .success(let decision):
                self.acceptance?.decision = decision
                self.acceptance?.problem = nil
                self.acceptance?.requests.removeAll { $0.id == request.id }
                // The server closes the window when it approves.
                if case .linked = decision {
                    accepting?.cancel()
                    self.acceptance?.state = .closed
                    await refresh()
                }
            case .failure(let failure):
                self.acceptance?.problem = failure.description
            }
        }
    }

    /// Closes the window (when the sheet closes) and forgets it.
    func closeAcceptance() {
        accepting?.cancel()
        accepting = nil
        if let acceptance, let side = side(acceptance.node) {
            Task { await LinkAcceptance.close(on: side) }
        }
        acceptance = nil
    }

    /// Forgets the role choices read for the sheet, so the next one reads them again.
    func clearRoleOptions() { roleOptions = [:] }

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

fileprivate extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
