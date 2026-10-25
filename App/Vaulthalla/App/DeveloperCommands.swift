#if DEBUG
import Foundation
import VHCore
import VHFinder

/// Debug builds: `Vaulthalla.app/Contents/MacOS/Vaulthalla --developer <command>` runs one command headless and
/// exits, for scripted checks of the File Provider plumbing (the system only accepts domains from the app's own
/// executable). Not the background agent (docs/architecture.md §7); nothing here outlives the command.
///
///     registry                               open the registry as the app does at launch (migrating it), and say where
///     domains                                list this app's File Provider domains
///     add-domain <node id> <vault id> <name> add the vault's domain (the node's name comes from the registry)
///     remove-domain <identifier>             remove one domain
///     remove-all-domains                     remove every domain of this app
enum DeveloperCommands {
    static let flag = "--developer"

    static func run(_ arguments: [String]) -> Never {
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
        default:
            throw UsageError(description: "commands: registry, domains, add-domain, remove-domain, remove-all-domains")
        }
    }

    nonisolated private static func describe(_ domain: DomainSnapshot) -> String {
        "\(domain.identifier) '\(domain.displayName)' userEnabled=\(domain.userEnabled) state=\(domain.state.rawValue)"
    }
}
#endif
