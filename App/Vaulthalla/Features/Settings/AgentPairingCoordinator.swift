import Foundation
import Observation
import VHAgents
import VHCore
import VHNodes

/// AI apps' own pairings and switches, for Settings → Agents and the node's Devices page (docs/architecture.md §3,
/// "AI apps' own pairings"). The credential owner does the work through ``AgentPairings``; this holds what the views
/// show: the switches and choices (`agent-access.json`), which identity each app presents to each node, and the
/// outcome of the last attempt per node and app.
@MainActor @Observable final class AgentPairingCoordinator {
    struct Key: Hashable {
        var node: NodeID
        var client: AgentClient
    }

    struct Outcome: Equatable {
        var text: String
        var tone: StatusTone
        /// A failure the person can act on: try again, or use this Mac's pairing for that node.
        var offersChoice: Bool
    }

    /// Which identity an app presents to a node, for the views.
    enum Use: Equatable {
        case off
        case own(AgentIdentity)
        case mac
        case unavailable(String)
    }

    private(set) var access = AgentAccess()
    private(set) var accessProblem: String?
    private(set) var working: Set<Key> = []
    private(set) var outcomes: [Key: Outcome] = [:]
    /// Something the person must do outside Vaulthalla (devices to revoke in a node's web console).
    var notice: String?

    @ObservationIgnored weak var app: AppModel?

    private var accessURL: URL? { app.map { AgentAccess.fileURL(besideRegistry: $0.registryURL) } }
    private var macName: String { Host.current().localizedName ?? "this Mac" }
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    func load() {
        guard let accessURL else { return }
        do {
            access = try AgentAccess.load(from: accessURL)
            accessProblem = nil
        } catch {
            accessProblem = "\(error.description). Until it's fixed, AI apps can't use any node."
        }
    }

    @discardableResult
    private func save(_ change: (inout AgentAccess) -> Void) -> Bool {
        guard let accessURL, let app else { return false }
        var changed = access
        change(&changed)
        changed.prune(keeping: app.nodes.map(\.id))
        do {
            try changed.save(to: accessURL)
            access = changed
            return true
        } catch {
            accessProblem = "The change couldn't be saved: \(error.localizedDescription)"
            return false
        }
    }

    private var pairings: AgentPairings? {
        guard let app, app.isCredentialOwner, let keys = app.deviceKeys else { return nil }
        return AgentPairings(store: app.store, keys: keys)
    }

    var pairedNodes: [Node] {
        app?.nodes.filter { if case .paired = $0.pairing { true } else { false } } ?? []
    }

    func use(_ node: Node, by client: AgentClient) -> Use {
        guard access.isAvailable(node.id, to: client) else { return .off }
        switch AgentIdentityChoice.choose(for: node, client: client, access: access) {
        case .own(let identity): return .own(identity)
        case .mac: return .mac
        case .unavailable(let reason): return .unavailable(reason)
        }
    }

    // MARK: - Choices

    func prefersOwnPairing(_ client: AgentClient) -> Bool { access.prefersOwnPairing(client) }

    func setPrefersOwnPairing(_ on: Bool, for client: AgentClient) {
        save { $0.setOwnPairing(on, for: client) }
    }

    /// "Use this Mac's pairing" for one node an app couldn't get its own pairing on.
    func useMacPairing(on id: NodeID, for client: AgentClient) {
        save { $0.setMacPairing(true, on: id, for: client) }
        outcomes[Key(node: id, client: client)] = nil
    }

    /// The node's switch for an app. Off revokes the app's own device there.
    func setAvailable(_ available: Bool, node id: NodeID, for client: AgentClient) async {
        guard save({ $0.set(id, available: available, to: client) }) else { return }
        if !available { await removeOwn(on: id, for: client) }
    }

    // MARK: - Pairing

    /// Gives the app its own pairing on every paired node that has none, one by one (one approval each), and
    /// reports per node.
    func pairAll(_ client: AgentClient) async {
        for node in pairedNodes where access.isAvailable(node.id, to: client) {
            if case .own = use(node, by: client) { continue }
            await pair(node.id, for: client)
        }
    }

    func pair(_ id: NodeID, for client: AgentClient) async {
        let key = Key(node: id, client: client)
        guard !working.contains(key), let app, let pairings, let keys = app.deviceKeys else {
            if pairings == nil {
                outcomes[key] = Outcome(text: AgentPairing.Failure.notOwner.description, tone: .warn, offersChoice: false)
            }
            return
        }
        guard let session = app.cloudTransport(for: id) else {
            outcomes[key] = Outcome(text: "\(name(id)) isn't connected right now.", tone: .warn, offersChoice: true)
            return
        }
        working.insert(key)
        defer { working.remove(key) }
        outcomes[key] = nil
        let signer = try? app.cloud?.approvals.signer(for: id)
        let pairing = AgentPairing(keys: keys, session: session, signer: signer)
        let result = await pairings.pair(id, client: client, using: pairing, macName: macName, appVersion: appVersion)
        app.loadNodes()
        switch result {
        case .success:
            outcomes[key] = Outcome(text: "Paired: it's its own device on \(name(id)) now.", tone: .ok,
                                    offersChoice: false)
        case .failure(let failure):
            outcomes[key] = Outcome(text: failure.description, tone: .warn, offersChoice: true)
        }
    }

    // MARK: - Removing

    /// Revokes the app's own device on the node and deletes its key; queued while the node can't be reached.
    func removeOwn(on id: NodeID, for client: AgentClient) async {
        guard let app, let pairings else { return }
        let key = Key(node: id, client: client)
        working.insert(key)
        defer { working.remove(key) }
        let removal = await pairings.remove(client, from: id, macSession: app.cloudTransport(for: id))
        app.loadNodes()
        if case .queued(let why) = removal {
            outcomes[key] = Outcome(text: "Its key is deleted on this Mac. Revoking it on \(name(id)) is pending "
                + "(\(why)); Vaulthalla retries when the node is back.", tone: .warn, offersChoice: false)
        } else {
            outcomes[key] = nil
        }
    }

    /// An app removed from this Mac: its own devices revoked on every node, its choice forgotten.
    func removeClient(_ client: AgentClient) async {
        for node in app?.nodes ?? [] where node.agentIdentities[client.rawValue] != nil {
            await removeOwn(on: node.id, for: client)
        }
        save { $0.setOwnPairing(false, for: client) }
    }

    /// Asks each node whether it still accepts the apps' own keys (records a refusal, so it shows and the bridge
    /// never falls back), and retries queued revocations on nodes that are connected.
    func check() async {
        guard let app, let pairings else { return }
        for node in pairedNodes {
            if !node.agentIdentities.isEmpty { await pairings.checkAccepted(on: node.id) }
            if !node.pendingAgentRevocations.isEmpty, let session = app.cloudTransport(for: node.id) {
                await pairings.retryPending(on: node.id, macSession: session)
            }
        }
        app.loadNodes()
    }

    /// Called by the app when a node is removed: revokes its apps' devices; names any the node must be told about.
    func nodeRemoved(_ node: Node, macSession: (any NodeTransport)?) async {
        guard let pairings else { return }
        let left = await pairings.revokeAll(of: node, macSession: macSession)
        guard !left.isEmpty else { return }
        notice = "\(node.displayName) couldn't be reached to revoke \(left.joined(separator: ", ")). Revoke "
            + (left.count == 1 ? "it" : "them") + " in \(node.displayName)'s web console (Devices)."
    }

    private func name(_ id: NodeID) -> String {
        app?.node(withID: id)?.displayName ?? "the node"
    }
}
