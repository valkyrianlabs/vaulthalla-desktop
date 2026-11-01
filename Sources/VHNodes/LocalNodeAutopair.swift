import Foundation
public import VHCore
import VHIdentity

/// Sets this Mac up with the Vaulthalla server installed on it, with no code to compare and nothing to click: what
/// `brew install --cask valkyrianlabs/tap/vaulthalla` (server and Desktop together) ends with.
///
/// The trust comes from the macOS account (an authenticated space): `vh` runs as this process's user over the daemon's
/// Unix socket, where the daemon names the caller from the kernel's peer credentials and acts as the Vaulthalla user
/// bound to that account (the person who installed the server is bound to `admin`). So the person's consent that
/// ``LocalPairing`` asks for in the pairing sheet is implied here, and nothing new is trusted: it is the same pairing,
/// number matching included, that the person could run in Terminal.
///
/// 1. `vh device pair --json` opens the window and names the listener's port, the server's install id and its key.
/// 2. A node at `127.0.0.1:<port>` is saved and this Mac pairs with it over TLS pinned to that key (a different server
///    is refused before anything is sent).
/// 3. ``LocalPairing/approve(deviceID:code:)`` approves the request once the daemon's own view shows this Mac's key
///    with this Mac's code; the window is closed.
///
/// Anything short of approval removes the node and its key again, so a failed attempt leaves no half-set-up node; the
/// caller may try again later. A node that already is this Mac's server (an address of this Mac, or the server's
/// install id) is never added twice, and once the person removed it (`declined`) it is not added back.
public struct LocalNodeAutopair: Sendable {
    public enum Outcome: Hashable, Sendable, CustomStringConvertible {
        /// Paired: the node's id in the registry and its name.
        case paired(NodeID, name: String)
        /// The registry already has this Mac's server; nothing changed.
        case alreadyKnown(NodeID)
        case skipped(Skip)
        /// Not paired, in words for the person; nothing was left behind.
        case failed(String)

        public var description: String {
            switch self {
            case .paired(_, let name): "Vaulthalla Desktop is set up with this Mac's server (\(name))."
            case .alreadyKnown: "Vaulthalla Desktop already knows this Mac's server."
            case .skipped(let skip): skip.description
            case .failed(let why): "Vaulthalla Desktop couldn't set up this Mac's server: \(why)"
            }
        }

        public var isFailure: Bool {
            if case .failed = self { true } else { false }
        }
    }

    public enum Skip: Hashable, Sendable, CustomStringConvertible {
        /// The person removed this Mac's server from Desktop; it isn't added back on its own.
        case declined
        /// Another process manages the node list (the app, while this runs headless): it sets the server up itself.
        case notOwner
        /// The node list can't be read; it is never written then.
        case unreadableRegistry

        public var description: String {
            switch self {
            case .declined: "This Mac's server was removed from Vaulthalla Desktop, so it isn't added back."
            case .notOwner: "Another Vaulthalla process manages this Mac's node list; it sets the server up itself."
            case .unreadableRegistry: "Vaulthalla Desktop's node list can't be read, so nothing was changed."
            }
        }
    }

    /// What the registry alone says, before anything runs.
    public enum Decision: Hashable, Sendable {
        case pair
        case known(NodeID)
        case skip(Skip)
    }

    /// The UserDefaults key recording that the person removed this Mac's server from Desktop.
    public static let declinedKey = "localNode.autopairDeclined"

    /// The address saved for the node: the listener is on loopback unless remote connections are on, and loopback
    /// works either way.
    public static let loopbackHost = "127.0.0.1"

    public var local: LocalPairing
    /// Where the node is saved (``loopbackHost``; live tests point it at their daemon's host).
    public var host: String
    /// The name the server lists this Mac under.
    public var deviceName: String
    public var appVersion: String
    /// Whether an address names this Mac (``LocalPairing/isThisMac(_:hostNames:addresses:)``).
    public var isThisMac: @Sendable (String) -> Bool
    /// The whole attempt, `vh` and TLS included, gives up after this.
    public var timeout: Duration
    /// The new node's local id (tests fix it to find its key).
    var newNodeID: @Sendable () -> NodeID = { .local() }

    public init(local: LocalPairing, deviceName: String, appVersion: String, host: String = Self.loopbackHost,
                isThisMac: @escaping @Sendable (String) -> Bool = { LocalPairing.isThisMac($0) },
                timeout: Duration = .seconds(90)) {
        self.local = local
        self.host = host
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.isThisMac = isThisMac
        self.timeout = timeout
    }

    /// Whether to try: not when a saved node's address is this Mac (whatever its pairing state: the person manages it),
    /// nor after the person removed this Mac's server. Cheap, and runs nothing, so it can be asked often.
    public static func decide(nodes: [Node], declined: Bool, isThisMac: (String) -> Bool) -> Decision {
        if let known = nodes.first(where: { isThisMac($0.endpoint.host) }) { return .known(known.id) }
        return declined ? .skip(.declined) : .pair
    }

    /// Sets the server up if ``decide(nodes:declined:isThisMac:)`` says so. `store` and `keys` must be the credential
    /// owner's; the node list is changed only through `store`.
    public func run(store: NodeStore, keys: DeviceKeys, declined: Bool) async -> Outcome {
        guard store.role == .owner, keys.role == .owner else { return .skipped(.notOwner) }
        let nodes: [Node]
        do {
            nodes = try store.reload()
        } catch {
            return .skipped(.unreadableRegistry)
        }
        switch Self.decide(nodes: nodes, declined: declined, isThisMac: isThisMac) {
        case .known(let id): return .alreadyKnown(id)
        case .skip(let skip): return .skipped(skip)
        case .pair: break
        }
        let attempt = self
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask { await attempt.attempt(store: store, keys: keys) }
            group.addTask {
                try? await Task.sleep(for: attempt.timeout)
                return .failed("this Mac's server didn't finish pairing in time.")
            }
            let first = await group.next() ?? .failed("pairing stopped.")
            // The attempt, if it is what timed out, cleans up before the group returns.
            group.cancelAll()
            return first
        }
    }

    // MARK: - Steps

    private func attempt(store: NodeStore, keys: DeviceKeys) async -> Outcome {
        let window: LocalPairing.Window
        do {
            window = try await local.openWindow()
        } catch {
            return .failed(error.description)
        }
        let outcome = await pair(through: window, store: store, keys: keys)
        // Even when the attempt was cancelled (timed out): the window would otherwise stay open for ten minutes.
        let local = local
        await Task.detached { await local.closeWindow() }.value
        return outcome
    }

    private func pair(through window: LocalPairing.Window, store: NodeStore, keys: DeviceKeys) async -> Outcome {
        // Saved under another address (a DNS name isThisMac can't tell): the server's install id gives it away.
        if let serverNodeID = window.nodeID,
           let known = try? store.load().first(where: { $0.serverNodeID == serverNodeID }) {
            return .alreadyKnown(known.id)
        }
        if window.listening == false {
            return .failed("its device listener isn't listening (device_server in its config.yaml).")
        }
        var node = Node(id: newNodeID(), displayName: "This Mac",
                        endpoint: NodeEndpoint(host: host, port: window.port))
        do {
            try store.add(node)
        } catch {
            return .failed(String(describing: error))
        }
        let outcome = await approve(&node, pinnedTo: window.serverSPKISHA256, store: store, keys: keys)
        if case .paired = outcome { return outcome }
        let id = node.id
        await Task.detached {
            _ = try? store.remove(id)
            try? await keys.deleteIdentity(for: id.rawValue)
        }.value
        return outcome
    }

    private func approve(_ node: inout Node, pinnedTo serverSPKI: Data?, store: NodeStore,
                         keys: DeviceKeys) async -> Outcome {
        let identity: DeviceIdentity
        do {
            identity = try await keys.identityForPairing(nodeTag: node.id.rawValue, deviceName: deviceName,
                                                         replacingExisting: false)
        } catch {
            return .failed("this Mac couldn't create its key: \(error)")
        }
        var configuration = PairingClient.Configuration(endpoint: node.endpoint, deviceName: deviceName,
                                                        appVersion: appVersion)
        configuration.expectedServerSPKI = serverSPKI
        let client = PairingClient(identity: identity, configuration: configuration)
        defer { client.cancel() }
        for await state in client.start() {
            switch state {
            case .connecting, .negotiated:
                continue
            case .awaitingApproval(let code):
                do throws(LocalPairing.Failure) {
                    try await local.approve(deviceID: identity.deviceID, code: code.digits)
                } catch {
                    return .failed(error.description)
                }
            case .approved(let serverNodeID, let serverName, let deviceID, let serverSPKI):
                node.pairing = .paired(serverSPKISHA256: serverSPKI, deviceID: deviceID, since: .now)
                node.serverNodeID = serverNodeID
                let name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { node.displayName = name }
                do {
                    try store.update(node)
                } catch {
                    return .failed(String(describing: error))
                }
                return .paired(node.id, name: node.displayName)
            case .denied:
                return .failed("the server declined the request.")
            case .expired:
                return .failed("the pairing request expired.")
            case .failed(let failure):
                return .failed(failure.message)
            }
        }
        return .failed(Task.isCancelled ? "this Mac's server didn't finish pairing in time." : "pairing stopped.")
    }
}
