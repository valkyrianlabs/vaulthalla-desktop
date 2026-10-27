#if DEBUG
import Foundation
import VHCore
import VHFinder
import VHIdentity
import VHNodes

/// Debug builds: `Vaulthalla.app/Contents/MacOS/Vaulthalla --developer <command>` runs one command headless and
/// exits, for scripted checks of the File Provider plumbing (the system only accepts domains from the app's own
/// executable). Not the background agent (docs/architecture.md §7); nothing here outlives the command.
///
///     registry                               open the registry as the app does at launch (migrating it), and say where
///     domains                                list this app's File Provider domains
///     add-domain <node id> <vault id> <name> add the vault's domain (the node's name comes from the registry)
///     remove-domain <identifier>             remove one domain (and its replica database)
///     remove-all-domains                     remove every domain of this app
///     pair <host:port> [name]                add a node and pair this Mac with it as the credential owner (the app
///                                            must be quit): prints the code to approve on the node, waits up to
///                                            five minutes, and saves the paired record
///     unpair <node id>                       remove a node from the registry and delete this Mac's key for it
///     signal <identifier>                    ask the domain's extension for the working set's changes (it lists the
///                                            folders Finder enumerated again); the agent's job later (desktop#5)
enum DeveloperCommands {
    static let flag = "--developer"

    static func run(_ arguments: [String]) -> Never {
        // Line by line even into a pipe or file: `pair` prints the code to approve and then waits.
        setvbuf(stdout, nil, _IOLBF, 0)
        let finished = DispatchSemaphore(value: 0)
        let status = ExitStatus()
        Task.detached {
            do {
                try await perform(arguments)
            } catch {
                print("error: \(error)")
                status.code = 1
            }
            finished.signal()
        }
        // The main thread waits; the command runs on the cooperative pool.
        finished.wait()
        exit(status.code)
    }

    /// Written by the command before it signals, read after the wait.
    private final class ExitStatus: @unchecked Sendable {
        nonisolated(unsafe) var code: Int32 = 0
    }

    private struct UsageError: Error, CustomStringConvertible {
        var description: String
    }

    nonisolated private static func perform(_ arguments: [String]) async throws {
        let domains = FileProviderDomains()
        switch arguments.first {
        case "registry":
            let opened = RegistryOwnership.open(in: .current(), holder: "developer")
            print("app group: \(AppGroup.entitledIdentifier() ?? "none")")
            print("registry: \(opened.location)")
            print("lease: \(opened.lease.isHeld ? "held" : "held by \(opened.lease.currentHolder()?.name ?? "another process")")")
            print("migration: \(opened.migration)")
            print("nodes: \((try? NodeStore(fileURL: opened.location.registryURL).load().count).map(String.init) ?? "unreadable")")
        case "domains":
            let all = try await domains.domains()
            print("domains: \(all.count)")
            for domain in all { print(describe(domain)) }
        case "add-domain":
            guard arguments.count == 4, let vaultID = Int64(arguments[2]) else {
                throw UsageError(description: "usage: add-domain <node id> <vault id> <vault name>")
            }
            let location = RegistryLocation.resolve(in: .current())
            let nodes = try NodeStore(fileURL: location.registryURL).load()
            guard let node = nodes.first(where: { $0.id.rawValue == arguments[1] }) else {
                throw UsageError(description: "no node \(arguments[1]) in \(location)")
            }
            guard let domain = VaultDomain(node: node, vaultID: vaultID, vaultName: arguments[3]) else {
                throw UsageError(description: "node id \(node.id) can't name a domain")
            }
            let added = try await domains.ensure(domain)
            print("added: \(added.map(describe) ?? domain.id.identifier)")
            if let root = try? await domains.rootURL(identifier: domain.id.identifier) {
                print("root: \(root.path(percentEncoded: false))")
            }
        case "remove-domain":
            guard arguments.count == 2 else { throw UsageError(description: "usage: remove-domain <identifier>") }
            try await domains.remove(identifier: arguments[1])
            print("removed \(arguments[1]); \(try await domains.domains().count) left")
        case "remove-all-domains":
            try await domains.removeAll()
            print("removed all; \(try await domains.domains().count) left")
        case "pair":
            guard (2...3).contains(arguments.count), let endpoint = NodeEndpoint(parsing: arguments[1]) else {
                throw UsageError(description: "usage: pair <host:port> [name]")
            }
            try await pair(endpoint, name: arguments.count == 3 ? arguments[2] : nil)
        case "unpair":
            guard arguments.count == 2 else { throw UsageError(description: "usage: unpair <node id>") }
            let (store, keys, _) = try owner()
            let id = NodeID(rawValue: arguments[1])
            _ = try store.remove(id)
            try await keys.deleteIdentity(for: id.rawValue)
            print("removed node \(id) and its key")
        case "signal":
            guard arguments.count == 2 else { throw UsageError(description: "usage: signal <identifier>") }
            try await domains.signal(identifier: arguments[1])
            print("signalled the working set of \(arguments[1])")
        default:
            throw UsageError(description: "commands: registry, domains, add-domain, remove-domain, remove-all-domains, "
                             + "pair, unpair, signal")
        }
    }

    /// The registry and the keys as the credential owner: the app must not be running (it holds the lease).
    nonisolated private static func owner() throws -> (NodeStore, DeviceKeys, RegistryOwnership) {
        let opened = RegistryOwnership.open(in: .current(), holder: "developer")
        guard opened.lease.isHeld else {
            throw UsageError(description: "\(opened.lease.currentHolder()?.name ?? "another process") holds the "
                             + "credential lease; quit Vaulthalla first")
        }
        return (NodeStore(fileURL: opened.location.registryURL, lease: opened.lease),
                DeviceKeys.standard(lease: opened.lease), opened)
    }

    nonisolated private static func pair(_ endpoint: NodeEndpoint, name: String?) async throws {
        let (store, keys, opened) = try owner()
        let deviceName = Host.current().localizedName ?? "Mac"
        var node = Node(id: .local(), displayName: name ?? endpoint.host, endpoint: endpoint,
                        isNamedByUser: name != nil)
        _ = try store.add(node)
        print("node: \(node.id) at \(endpoint) in \(opened.location)")
        let identity = try await keys.identityForPairing(nodeTag: node.id.rawValue, deviceName: deviceName,
                                                         replacingExisting: false)
        print("key: \(identity.backend.rawValue), device \(identity.deviceID)")
        let client = PairingClient(identity: identity, configuration: .init(
            endpoint: endpoint, deviceName: deviceName,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"))
        let deadline = Task {
            try? await Task.sleep(for: .seconds(300))
            client.cancel()
        }
        defer { deadline.cancel() }
        for await state in client.start() {
            switch state {
            case .connecting:
                print("connecting")
            case .awaitingApproval(let code):
                print("approve on the node: \(code.formatted)")
            case .approved(let serverNodeID, let serverName, let deviceID, let serverSPKI):
                node.pairing = .paired(serverSPKISHA256: serverSPKI, deviceID: deviceID, since: .now)
                node.serverNodeID = serverNodeID
                if name == nil, !serverName.isEmpty { node.displayName = serverName }
                _ = try store.update(node)
                print("paired: node \(node.id) '\(node.displayName)', device \(deviceID)")
                return
            case .denied, .expired, .failed:
                _ = try? store.remove(node.id)
                try? await keys.deleteIdentity(for: node.id.rawValue)
                throw UsageError(description: "pairing ended: \(state)")
            }
        }
        throw UsageError(description: "pairing ended without an answer")
    }

    nonisolated private static func describe(_ domain: DomainSnapshot) -> String {
        "\(domain.identifier) '\(domain.displayName)' userEnabled=\(domain.userEnabled) state=\(domain.state.rawValue)"
    }
}
#endif
