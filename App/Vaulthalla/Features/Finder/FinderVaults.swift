import AppKit
import Foundation
import Observation
import VHFinder

/// This Mac user's vaults in Finder (docs/architecture.md §7): the File Provider domains the system reports, and the
/// selections still waiting behind the consent gate (``ConsentGate``). The system keeps the domains per macOS user, so
/// they are the state; only the waiting selections are kept here, in the app's defaults. Changes run one at a time:
/// adding a domain twice would reset its replica.
@MainActor @Observable
final class FinderVaults {
    private(set) var domains: [DomainSnapshot] = []
    private(set) var pending: [VaultDomain] = []
    private(set) var problem: String?
    private(set) var loaded = false

    @ObservationIgnored private let registrar = FileProviderDomains()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tail: Task<Void, Never>?
    private static let pendingKey = "finder.pendingDomains"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pending = defaults.data(forKey: Self.pendingKey)
            .flatMap { try? JSONDecoder().decode([VaultDomain].self, from: $0) } ?? []
    }

    func snapshot(for id: VaultDomainID) -> DomainSnapshot? {
        domains.first { $0.identifier == id.identifier }
    }

    func isPending(_ id: VaultDomainID) -> Bool { pending.contains { $0.id == id } }

    func isShown(_ id: VaultDomainID) -> Bool { snapshot(for: id) != nil || isPending(id) }

    /// Domains exist and none is allowed: the operator still has to turn Vaulthalla on in System Settings.
    var awaitingApproval: Bool { ConsentGate.awaitingApproval(domains) }

    func isStuck(_ snapshot: DomainSnapshot) -> Bool {
        ConsentGate.stuck(domains).contains { $0.identifier == snapshot.identifier }
    }

    /// Reads the domains and adds the waiting selections the gate admits now.
    func refresh() async {
        await serially { await self.sync() }
    }

    /// Shows `domain` in Finder: added now, or once Vaulthalla is on in System Settings.
    func show(_ domain: VaultDomain) async {
        await serially {
            guard !self.isShown(domain.id) else { return }
            self.setPending(self.pending + [domain])
            await self.sync()
        }
    }

    /// Takes the vault out of Finder (its downloaded copies go with the domain) or drops its waiting selection.
    func hide(_ id: VaultDomainID) async {
        await remove(identifier: id.identifier)
    }

    func remove(identifier: String) async {
        await serially {
            self.setPending(self.pending.filter { $0.id.identifier != identifier })
            await self.change { try await self.registrar.remove(identifier: identifier) }
        }
    }

    /// The recovery for a domain stuck behind the consent gate: removed and added again, it comes up allowed.
    func addAgain(_ snapshot: DomainSnapshot) async {
        await serially {
            await self.change { try await self.registrar.addAgain(snapshot) }
        }
    }

    /// Opens the vault's folder (`~/Library/CloudStorage/Vaulthalla-<name>`) in Finder.
    func open(_ id: VaultDomainID) async {
        do {
            guard let url = try await registrar.rootURL(identifier: id.identifier) else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            NSWorkspace.shared.open(url)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func sync() async {
        do {
            var current = try await registrar.domains()
            // Twice at most: a first domain that starts allowed (the switch was on already) admits the rest at once.
            for _ in 0..<2 {
                let admitted = ConsentGate.admit(pending, existing: current)
                guard !admitted.isEmpty else { break }
                for domain in admitted { try await registrar.add(domain) }
                current = try await registrar.domains()
            }
            domains = current
            setPending(pending.filter { waiting in !current.contains { $0.identifier == waiting.id.identifier } })
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loaded = true
    }

    /// Runs `body`, then reads the domains again; a failure of `body` stays the problem shown.
    private func change(_ body: () async throws -> Void) async {
        var failure: String?
        do { try await body() } catch { failure = error.localizedDescription }
        await sync()
        if let failure { problem = failure }
    }

    private func serially(_ body: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let next = Task { @MainActor in
            await previous?.value
            await body()
        }
        tail = next
        await next.value
    }

    private func setPending(_ domains: [VaultDomain]) {
        guard domains != pending else { return }
        pending = domains
        defaults.set(try? JSONEncoder().encode(domains), forKey: Self.pendingKey)
    }
}
