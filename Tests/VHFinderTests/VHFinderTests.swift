import Foundation
import Synchronization
import Testing
import VHCore
import VHFinder
import VHIdentity
import VHNodes

/// Domain identity and naming: `<node id>.<vault id>`, never `/` or `:`, and `<vault> · <node>`.
@Suite struct VaultDomainTests {
    private func node(_ id: String, _ name: String) -> Node {
        Node(id: NodeID(rawValue: id), displayName: name, endpoint: NodeEndpoint(host: "h.local"))
    }

    @Test func identifierRoundTrips() throws {
        let id = try #require(VaultDomainID(nodeID: NodeID(rawValue: "local-5b0c7d3e-0f4a-4e6b-9c1d-2a3b4c5d6e7f"),
                                            vaultID: 42))
        #expect(id.identifier == "local-5b0c7d3e-0f4a-4e6b-9c1d-2a3b4c5d6e7f.42")
        #expect(VaultDomainID(identifier: id.identifier) == id)
        #expect(!id.identifier.contains("/") && !id.identifier.contains(":"))
        // Every id Desktop makes names a domain.
        #expect(VaultDomainID(nodeID: .local(), vaultID: 0) != nil)
    }

    @Test(arguments: ["", "node", "node.", ".7", "node.-1", "node.+7", "node.007", "node.7a", "no/de.7", "no:de.7",
                      "no de.7", "nø.7", "node.99999999999999999999", "a.b.7"])
    func rejectsWhatIdentifierNeverWrites(_ identifier: String) {
        #expect(VaultDomainID(identifier: identifier) == nil)
    }

    @Test func refusesNodeIdsAnIdentifierCantCarry() {
        for raw in ["a/b", "a:b", "a.b", "", String(repeating: "a", count: 129)] {
            #expect(VaultDomainID(nodeID: NodeID(rawValue: raw), vaultID: 1) == nil, "\(raw)")
        }
        #expect(VaultDomainID(nodeID: NodeID(rawValue: "ok_id-1"), vaultID: -1) == nil)
        #expect(VaultDomain(node: node("a/b", "x"), vaultID: 1, vaultName: "v") == nil)
    }

    @Test func displayNameIsVaultThenNode() throws {
        let domain = try #require(VaultDomain(node: node("n1", "vh-storage"), vaultID: 3, vaultName: "Photos"))
        #expect(domain.displayName == "Photos · vh-storage")
        #expect(domain.id.identifier == "n1.3")

        #expect(VaultDomain.displayName(vault: "  Team\nshare  ", node: " Home  lab ", vaultID: 1)
            == "Team share · Home lab")
        #expect(VaultDomain.displayName(vault: "a/b:c", node: "x:y", vaultID: 1) == "a-b-c · x-y")
        #expect(VaultDomain.displayName(vault: "  ", node: "lab", vaultID: 9) == "Vault 9 · lab")
        #expect(VaultDomain.displayName(vault: "Docs", node: "", vaultID: 9) == "Docs")
    }
}

/// Domain management against a fake `NSFileProviderManager`: list, add, remove, reconcile, and the approval state.
@Suite struct DomainRegistryTests {
    /// Records calls; domains start disallowed, as the system's do until the operator turns the provider on.
    final class FakeRegistrar: DomainRegistrar {
        let state = Mutex<(domains: [DomainSnapshot], calls: [String])>(([], []))

        init(_ domains: [DomainSnapshot] = []) {
            state.withLock { $0.domains = domains }
        }

        var calls: [String] { state.withLock { $0.calls } }

        func domains() async throws -> [DomainSnapshot] { state.withLock { $0.domains } }

        func add(_ domain: VaultDomain) async throws {
            state.withLock {
                $0.calls.append("add \(domain.id)")
                $0.domains.append(DomainSnapshot(identifier: domain.id.identifier, displayName: domain.displayName,
                                                 userEnabled: false))
            }
        }

        func remove(identifier: String) async throws {
            state.withLock {
                $0.calls.append("remove \(identifier)")
                $0.domains.removeAll { $0.identifier == identifier }
            }
        }
    }

    private func domain(_ node: String, _ vault: Int64, _ name: String) -> VaultDomain {
        VaultDomain(id: VaultDomainID(nodeID: NodeID(rawValue: node), vaultID: vault)!, displayName: name)
    }

    private func snapshot(_ domain: VaultDomain, enabled: Bool = true) -> DomainSnapshot {
        DomainSnapshot(identifier: domain.id.identifier, displayName: domain.displayName, userEnabled: enabled)
    }

    @Test func reconcileAddsRemovesAndRenames() {
        let photos = domain("n1", 1, "Photos · lab")
        let docs = domain("n1", 2, "Docs · lab")
        let renamed = domain("n2", 5, "Media · new name")
        let existing = [
            snapshot(docs),
            DomainSnapshot(identifier: "n2.5", displayName: "Media · old name", userEnabled: true),
            DomainSnapshot(identifier: "n3.9", displayName: "Gone · old", userEnabled: true),
            DomainSnapshot(identifier: "spike-domain", displayName: "Leftover", userEnabled: false),
        ]
        let plan = DomainPlan.reconcile(wanted: [photos, docs, renamed, photos], existing: existing)
        #expect(plan.add == [photos])
        #expect(plan.rename == [renamed])
        #expect(plan.remove == ["n3.9", "spike-domain"])
        #expect(DomainPlan.reconcile(wanted: [docs], existing: [snapshot(docs)]).isEmpty)
    }

    @Test func applyRemovesBeforeAdding() async throws {
        let keep = domain("n1", 1, "Keep · lab")
        let fresh = domain("n1", 2, "New · lab")
        let registrar = FakeRegistrar([snapshot(keep), DomainSnapshot(identifier: "n9.9", displayName: "Old",
                                                                      userEnabled: true)])
        let plan = DomainPlan.reconcile(wanted: [keep, fresh], existing: try await registrar.domains())
        try await registrar.apply(plan)
        #expect(registrar.calls == ["remove n9.9", "add n1.2"])
        #expect(try await registrar.domains().map(\.identifier) == ["n1.1", "n1.2"])
    }

    @Test func ensureAddsOnceAndReportsTheApprovalGate() async throws {
        let registrar = FakeRegistrar()
        let photos = domain("n1", 1, "Photos · lab")
        let added = try await registrar.ensure(photos)
        #expect(added?.state == .needsUserApproval)
        #expect(added?.vault == photos.id)
        _ = try await registrar.ensure(photos)
        #expect(registrar.calls == ["add n1.1"], "an existing domain isn't added twice")
        #expect(FileProviderSettings.needsApproval(try await registrar.domains()))
    }

    @Test func statesInPriorityOrder() {
        #expect(DomainSnapshot(identifier: "a.1", displayName: "", userEnabled: false, isDisconnected: true).state
            == .needsUserApproval)
        #expect(DomainSnapshot(identifier: "a.1", displayName: "", userEnabled: true, isDisconnected: true,
                               isHidden: true).state == .disconnected)
        #expect(DomainSnapshot(identifier: "a.1", displayName: "", userEnabled: true, isHidden: true).state == .hidden)
        #expect(DomainSnapshot(identifier: "a.1", displayName: "", userEnabled: true).state == .active)
        #expect(!FileProviderSettings.needsApproval([DomainSnapshot(identifier: "a.1", displayName: "",
                                                                    userEnabled: true)]))
    }

    @Test func consentGateAddsOneDomainUntilTheProviderIsOn() {
        let photos = domain("n1", 1, "Photos · lab")
        let docs = domain("n1", 2, "Docs · lab")
        let media = domain("n2", 3, "Media · vps")
        // No domain yet: the first one goes in alone, since it either starts allowed or asks for the switch.
        #expect(ConsentGate.admit([photos, docs, photos], existing: []) == [photos])
        // It waits for approval: nothing more is added, so no second domain gets stuck behind the gate.
        let waiting = [snapshot(photos, enabled: false)]
        #expect(ConsentGate.awaitingApproval(waiting))
        #expect(ConsentGate.admit([photos, docs], existing: waiting).isEmpty)
        // Allowed: everything pending goes in, minus what exists, each once.
        let allowed = [snapshot(photos)]
        #expect(!ConsentGate.awaitingApproval(allowed))
        #expect(ConsentGate.admit([photos, docs, media, docs], existing: allowed) == [docs, media])
        #expect(!ConsentGate.awaitingApproval([]))
    }

    @Test func consentGateFindsDomainsStuckBehindTheSwitch() {
        let photos = domain("n1", 1, "Photos · lab")
        let docs = domain("n1", 2, "Docs · lab")
        let leftover = DomainSnapshot(identifier: "spike-domain", displayName: "Leftover", userEnabled: false)
        #expect(ConsentGate.stuck([snapshot(photos), snapshot(docs, enabled: false), leftover])
            == [snapshot(docs, enabled: false)])
        #expect(ConsentGate.stuck([snapshot(photos, enabled: false), snapshot(docs, enabled: false)]).isEmpty,
                "with no domain allowed, the switch itself is what's missing")
    }

    @Test func addAgainKeepsIdentifierAndName() async throws {
        let docs = domain("n1", 2, "Docs · lab")
        let registrar = FakeRegistrar([snapshot(docs, enabled: false)])
        try await registrar.addAgain(snapshot(docs, enabled: false))
        #expect(registrar.calls == ["remove n1.2", "add n1.2"])
        #expect(try await registrar.domains().map(\.displayName) == ["Docs · lab"])
        try await registrar.addAgain(DomainSnapshot(identifier: "spike-domain", displayName: "", userEnabled: false))
        #expect(registrar.calls.count == 2, "a domain Desktop didn't make isn't added again")
    }

    @Test func settingsLinksOpenSystemSettings() {
        #expect(FileProviderSettings.fileProvidersURL.scheme == "x-apple.systempreferences")
        #expect(FileProviderSettings.fileProvidersURL.absoluteString.contains("com.apple.fileprovider-nonui"))
        #expect(FileProviderSettings.loginItemsURL.scheme == "x-apple.systempreferences")
    }
}

/// The extension's readiness as a read-only consumer: what it reports for each registry state, without the Keychain
/// for the cases the registry decides.
@Suite struct ExtensionReadinessTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "ExtensionReadinessTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var registryURL: URL { directory.appending(path: "nodes.json") }

    /// A consumer's reader; its key store is never queried in these cases (the registry decides first).
    private var reader: CredentialReader {
        CredentialReader(
            registry: NodeStore(fileURL: registryURL),
            keys: DeviceKeys(primary: DeviceIdentityStore(configuration: .init(
                namespace: "sh.vaulthalla.app.test.readiness", keychain: .fileBased)), development: nil))
    }

    private func seed(_ nodes: [Node]) throws {
        let lease = CredentialLease(forRegistry: registryURL, holder: "owner")
        try lease.acquire()
        defer { lease.release() }
        let store = NodeStore(fileURL: registryURL, lease: lease)
        for node in nodes { try store.add(node) }
    }

    private func check(_ identifier: String, registry: Bool = true) async -> ExtensionReadiness {
        await ExtensionReadiness.check(
            domainIdentifier: identifier,
            registry: registry ? RegistryLocation(registryURL: registryURL, source: .appGroup) : nil,
            reader: reader)
    }

    @Test func reportsEachRegistryState() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await check("not-a-domain").state == .notAVaultDomain)
        #expect(await check("n1.1", registry: false).state == .noAppGroup)
        #expect(await check("n1.1").state == .registryMissing)

        let revoked = Node(id: NodeID(rawValue: "n2"), displayName: "old", endpoint: NodeEndpoint(host: "o.local"),
                           pairing: .revoked(at: .now))
        try seed([Node(id: NodeID(rawValue: "n1"), displayName: "lab", endpoint: NodeEndpoint(host: "l.local")), revoked])
        #expect(await check("n1.1").state == .credentials(.notPaired))
        #expect(await check("n2.4").state == .credentials(.revoked))
        let unknown = await check("n9.4")
        #expect(unknown.state == .credentials(.unknownNode(NodeID(rawValue: "n9"))))
        #expect(!unknown.isReady)
        #expect(unknown.description.hasPrefix("not ready: node n9, vault 4"))
        // A consumer never writes: the registry is as the owner left it.
        #expect(try NodeStore(fileURL: registryURL).load().count == 2)
    }
}
