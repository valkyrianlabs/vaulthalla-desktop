import FileProvider
import Foundation
import os
import ServiceManagement
import VHContract
import VHCore
import VHFinder
import VHIdentity
import VHNodes

/// The per-user background agent (valkyrianlabs/vaulthalla-desktop#5, docs/architecture.md §7): the app's own executable
/// in a headless mode, `Vaulthalla --agent`, started by launchd at login through `SMAppService.agent` while any vault is
/// in Finder. It keeps Finder fresh with Desktop closed and fails closed, all as a read-only credential consumer like the
/// extension: it never takes the lease, rotates or writes anything.
///
/// Every minute it asks each node with a domain for the vaults the account may browse, signals the working set of each
/// domain still listed, and removes a domain on a definite answer (a revocation, an unpaired or deleted node, a vault
/// no longer listed), preserving edits not yet uploaded (``FreshnessPlan``). Removals are recorded for the Finder tab
/// (``RemovalLog``). With no domain left it exits, and the app unregisters it.
nonisolated enum BackgroundAgent {
    static let flag = "--agent"
    static let plistName = "sh.vaulthalla.app.agent.plist"
    static let interval: Duration = .seconds(60)
    static let log = Logger(subsystem: "sh.vaulthalla.app", category: "agent")

    static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    /// The App Group's defaults, which the agent and the app share; nil in a build without the group.
    static var sharedDefaults: UserDefaults? {
        AppGroup.entitledIdentifier().flatMap(UserDefaults.init(suiteName:))
    }

    /// Registers the agent while vaults are in Finder and unregisters it when none is. Called by the app; a failure
    /// is logged, since Finder works without the agent while Desktop is open.
    @MainActor
    static func update(hasDomains: Bool) {
        let service = service
        do {
            switch (hasDomains, service.status) {
            case (true, .notRegistered):
                try service.register()
                log.notice("registered")
            case (false, .enabled), (false, .requiresApproval):
                try service.unregister()
                log.notice("unregistered")
            default:
                break
            }
        } catch {
            log.error("\(hasDomains ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The headless entry point: runs the loop and never returns.
    static func run() -> Never {
        log.notice("starting")
        Task.detached {
            await AgentLoop().run()
            log.notice("no vault in Finder: exiting")
            exit(0)
        }
        dispatchMain()
    }
}

/// The agent's work, one tick per ``BackgroundAgent/interval``.
private actor AgentLoop {
    private let registry = RegistryLocation.appGroup(in: .current())
    private let reader: CredentialReader
    private let domains = FileProviderDomains()
    private var links: [NodeID: NodeLink] = [:]

    init() {
        // Read-only, as the extension: only the data protection keychain, where the owner keeps the shared keys.
        reader = CredentialReader(registry: registry.map { NodeStore(fileURL: $0.registryURL) },
                                  keys: DeviceKeys(primary: DeviceIdentityStore(), development: nil))
    }

    /// Ticks until no domain is left.
    func run() async {
        while true {
            let current: [DomainSnapshot]
            do {
                current = try await domains.domains()
            } catch {
                BackgroundAgent.log.error("domains: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: BackgroundAgent.interval)
                continue
            }
            if current.isEmpty { return }
            await tick(current)
            try? await Task.sleep(for: BackgroundAgent.interval)
        }
    }

    private func tick(_ current: [DomainSnapshot]) async {
        guard let nodes = try? reader.registry?.load() else {
            // No registry to read (yet): nothing is decided from silence.
            BackgroundAgent.log.error("registry unreadable; skipping")
            return
        }
        let wanted = Set(current.compactMap(\.vault?.nodeID))
        var checks: [NodeID: NodeCheck] = [:]
        for node in nodes where wanted.contains(node.id) {
            checks[node.id] = await check(node)
        }
        let plan = FreshnessPlan.make(domains: current, checks: checks)
        var removed: [RemovedDomain] = []
        for removal in plan.remove {
            do {
                let kept = try await domains.remove(identifier: removal.identifier, preservingUnsyncedChanges: true)
                var reason = removal.reason
                if let kept { reason += " Changes that hadn't uploaded were kept in \(kept.path(percentEncoded: false))." }
                removed.append(RemovedDomain(identifier: removal.identifier, displayName: removal.displayName,
                                             reason: reason, at: .now))
                BackgroundAgent.log.notice("removed \(removal.identifier, privacy: .public): \(removal.reason, privacy: .public)")
            } catch {
                BackgroundAgent.log.error("remove \(removal.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if let defaults = BackgroundAgent.sharedDefaults { RemovalLog.append(removed, to: defaults) }
        for identifier in plan.signal {
            do {
                try await domains.signal(identifier: identifier)
            } catch {
                BackgroundAgent.log.error("signal \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // Links of nodes without domains, or that failed closed, are dropped; a later pairing gets a fresh one.
        for (id, link) in links where !wanted.contains(id) || checks[id].map({ if case .closed = $0 { true } else { false } }) == true {
            await link.close()
            links[id] = nil
        }
    }

    private func check(_ node: Node) async -> NodeCheck {
        guard case .paired = node.pairing else {
            return .closed(node.pairing == .unpaired ? "This Mac was unpaired from the node."
                           : "The node no longer accepts this Mac. Pair it again in Vaulthalla.")
        }
        let link = links[node.id] ?? NodeLink(nodeID: node.id, reader: reader)
        links[node.id] = link
        do {
            let answer = try await link.send(Ws.Storage.Vault.Accessible.List.self, payload: WsNoPayload(),
                                             during: .read)
            return .browsable(Set(answer.vaults.filter(\.browse).map(\.id)))
        } catch {
            if let closed = await link.closedReason, case .notAuthenticated(let why) = closed { return .closed(why) }
            return .unknown
        }
    }
}
