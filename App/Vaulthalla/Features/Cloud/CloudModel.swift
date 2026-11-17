import AppKit
import Foundation
import Observation
import VHCloud
import VHContract
import VHCore
import VHKeykit
import VHNodes
import VHTransport
import VHVault

/// The panes of the top-level "Vaulthalla Cloud" section (docs/cloud-storage.md, "The Vaulthalla Cloud section").
/// Storage (usage, each vault's switch, the offer, leaving) shows servers with `cloud.storage.managed_remotes` only.
enum CloudSection: String, CaseIterable, Identifiable, Hashable, Codable {
    case account
    case servers
    case vaults
    case storage
    case recoveryKey

    var id: Self { self }

    var title: String {
        switch self {
        case .account: "Account"
        case .servers: "Servers"
        case .vaults: "Vaults"
        case .storage: "Storage"
        case .recoveryKey: "Recovery Key"
        }
    }

    var systemImage: String {
        switch self {
        case .account: "person.crop.circle"
        case .servers: "server.rack"
        case .vaults: "archivebox"
        case .storage: "externaldrive.badge.icloud"
        case .recoveryKey: "key.horizontal"
        }
    }
}

/// Vaulthalla Cloud in the app: this Mac's link, the account's servers and vaults across nodes, the account recovery
/// key and the plan. Hidden until the service opens: `defaults write sh.vaulthalla.app cloud.enabled -bool YES` shows
/// the section (as Settings ▸ Cloud did); a Mac already linked shows it too. Only the app calls the cloud, while the
/// section is visible or after a hand-off; nothing else in Desktop waits on it.
@MainActor
@Observable
final class CloudModel {
    enum Phase: Equatable {
        case unlinked
        case pending(code: String, fingerprint: String, expires: Date)
        case linked
    }

    /// What a paired node told about its link and its pin of the account key.
    struct NodeFacts: Equatable {
        var link: NodeMapping.NodeLink = .unknown
        var key: WsModel.CloudKeyStatus?
        var vaults: [NodeMapping.NodeVault] = []
        /// `cloud.storage.status`, on a node with the `cloud.storage.managed_remotes` capability.
        var storage: WsModel.CloudStorageStatus?
        var storageError: String?
    }

    /// The flow the Recovery Key pane is in.
    enum KeyFlow: Equatable {
        case idle
        /// A new key's recovery code shown once, until the person confirms an offline copy.
        case showingNewKey(code: String, groups: [Int])
        case waitingForApproval(code: String, url: URL?)
        case waitingForTransfer(code: String)
    }

    static var isEnabledByDefaults: Bool { UserDefaults.standard.bool(forKey: "cloud.enabled") }

    let environment: CloudEnvironment
    private(set) var phase: Phase = .unlinked
    var macName = Host.current().localizedName ?? "This Mac"
    private(set) var busy = false
    private(set) var message: String?
    private(set) var messageIsError = false

    private(set) var installation: CloudInstallation?
    private(set) var deployments: [CloudDeployment] = []
    private(set) var vaults: [CloudVault] = []
    private(set) var labels: [String: String] = [:]
    private(set) var coverage: [String: CloudRecoveryCoverage] = [:]
    private(set) var billing: CloudBilling?
    /// `GET /v1/storage` (nil while the cloud serves no storage routes): for vaults a Mac holds (Desktop-only vaults),
    /// who holds each and the holding Mac's key, read-only. This Mac requests no bucket key here: nothing would use
    /// one until Desktop syncs these vaults (`DeviceAccess` is ready for that).
    private(set) var storage: CloudStorage?
    private(set) var keyStatus: CloudAccount.KeyStatus?
    private(set) var unlocks: CloudKeyUnlocks?
    private(set) var holders: [CloudKeyHolder] = []
    private(set) var transfers: [CloudAccount.DeliverableTransfer] = []
    private(set) var restores: [CloudClient.Restore] = []
    private(set) var nodeFacts: [NodeID: NodeFacts] = [:]
    /// Desktop-only vaults this Mac syncs; nil unless ``DesktopVaultsFeature`` is on (off by default).
    private(set) var desktopVaults: DesktopVaultsModel?
    private(set) var keyFlow: KeyFlow = .idle
    /// A request (offline copy) the person was sent to the portal for.
    private(set) var openRequestID: String?
    private(set) var lastRefresh: Date?

    @ObservationIgnored private let items: LeasedAccountItems
    @ObservationIgnored private let client: CloudClient?
    @ObservationIgnored private let account: CloudAccount?
    @ObservationIgnored private var newKey: CloudAccount.NewKey?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let approvals: ApprovalKeys

    init(lease: CredentialLease?, environment: CloudEnvironment = .resolve(debug: CloudModel.isDebugBuild),
         items store: any AccountItemStore = KeychainAccountItemStore.standard(), transport: any CloudTransport = URLSessionCloudTransport()) {
        self.environment = environment
        let items = LeasedAccountItems(items: store, lease: lease)
        self.items = items
        approvals = ApprovalKeys(items: items)
        let client = try? CloudClient(endpoint: environment.api, store: AccountCloudLinkStore(items: items), transport: transport)
        self.client = client
        // Touch ID for every use of the key needs a signed build (an explicit access control); an unsigned
        // development build uses the enclave's default access instead.
        account = client.map {
            CloudAccount(client: $0, items: items,
                         holderKeys: HolderKeys(userPresence: AccountKeychain.accessGroup() != nil))
        }
        if DesktopVaultsFeature.isEnabled(), let client, let account {
            desktopVaults = DesktopVaultsModel(client: client, account: account, items: items)
        }
        if let link = try? client?.link() {
            macName = link.name
            phase = link.state == .linked ? .linked : .unlinked
        }
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Whether the section shows: the defaults switch, or a Mac already linked.
    var isVisible: Bool { Self.isEnabledByDefaults || phase == .linked }
    var isOwner: Bool { items.role == .owner }

    // MARK: - messages

    private func report(_ text: String?, error: Bool = false) {
        message = text
        messageIsError = error
    }

    private func report(_ error: any Error) {
        if let e = error as? CloudError {
            report(e.message, error: true)
        } else if let e = error as? CredentialOwnershipError {
            report(e.description, error: true)
        } else if let e = error as? WsError {
            report(e.message, error: true)
        } else if let e = error as? DeviceApprovalError {
            report(Self.describe(e), error: true)
        } else if let e = error as? KeykitError {
            report("The recovery key couldn't be used (\(e.name)).", error: true)
        } else {
            report("\(error.localizedDescription)", error: true)
        }
    }

    static func describe(_ e: DeviceApprovalError) -> String {
        switch e {
        case .payloadMismatch: "The server's approval request didn't match this Mac's records. Nothing was signed."
        case .consoleApprovalRequired: "Approve this in the server's web console."
        case .notApproved(let state): "The approval was \(state)."
        case .keyUnavailable: "This Mac's approval key isn't available."
        }
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await work() } catch { report(error) }
    }

    // MARK: - linking

    func link() async {
        guard let client else { return report("This build has no Vaulthalla Cloud address.", error: true) }
        await run {
            let started = try await client.startLink(name: macName)
            phase = .pending(code: started.userCode, fingerprint: started.fingerprint, expires: started.expiresAt)
            report(nil)
            _ = openInBrowser(environment.linkApproval)
            while case .pending = phase {
                try await Task.sleep(for: .seconds(3))
                switch try await client.claimLink() {
                case .pending: continue
                case .linked:
                    phase = .linked
                    report("This Mac is linked.")
                    await refresh()
                case .denied:
                    phase = .unlinked
                    report("The link was denied.", error: true)
                case .expired:
                    phase = .unlinked
                    report("The code expired. Link again.", error: true)
                }
            }
        }
        if case .pending = phase { phase = .unlinked }
    }

    func cancelLink() {
        try? AccountCloudLinkStore(items: items).delete()
        phase = .unlinked
    }

    /// Unlinks this Mac. It keeps the recovery key's local copy only when no offline copy is confirmed and no other
    /// holder or passkey has it (docs/cloud-storage.md, "Signing out": keys are never lost to a sign-out).
    func unlink() async {
        guard let client, let account else { return }
        await run {
            let status = try? await account.status()
            let others = holders.filter { $0.installationId != installation?.id }.count + (unlocks?.unlocks.count ?? 0)
            let safe = status?.held == nil || status?.offlineCopyConfirmedAt != nil || others > 0
            guard safe else {
                report("This Mac may be the only place your recovery key is. Save an offline copy first (Recovery Key ▸ Print or 1Password), then unlink.", error: true)
                return
            }
            try await client.unlink()
            // A bucket key this Mac kept for a vault it held is worthless once unlinked (the cloud revoked it).
            for v in storage?.vaults ?? [] { try? BucketKeyStore(items: items).delete(v.vaultUid) }
            try account.keys.deleteHeld()
            try? account.keys.deletePending()
            approvals.forgetAll()
            phase = .unlinked
            clear()
            report("This Mac is no longer linked.")
        }
    }

    private func clear() {
        installation = nil
        deployments = []
        vaults = []
        labels = [:]
        coverage = [:]
        billing = nil
        storage = nil
        keyStatus = nil
        unlocks = nil
        holders = []
        transfers = []
        restores = []
        keyFlow = .idle
    }

    // MARK: - reading

    /// Everything the panes show: the cloud's lists, the key's state, and each paired node's answers.
    func refresh() async {
        guard phase == .linked, let client, let account else { return }
        await run {
            installation = try await client.installation()
            async let d = client.deployments()
            async let v = client.vaults()
            async let b = client.billing()
            async let k = account.status()
            deployments = try await d
            vaults = try await v
            billing = try? await b
            storage = try? await client.storage()
            keyStatus = try await k
            unlocks = try? await client.unlocks()
            holders = (try? await client.holders()) ?? []
            coverage = Dictionary(((try? await client.coverage()) ?? []).map { ($0.vaultUid, $0) }) { a, _ in a }
            transfers = (try? await account.deliverableTransfers()) ?? []
            restores = (try? await client.deliverable()) ?? []
            lastRefresh = .now
            await refreshNodes()
            if keyStatus?.pending != nil { await checkPendingKey() }
            if keyStatus?.transfer != nil { await checkTransfer() }
        }
        await desktopVaults?.start()
    }

    /// Asks each paired, connected node about its link, its pin and its vaults' uids.
    func refreshNodes() async {
        guard let app else { return }
        for node in app.nodes where node.pairing.isPaired {
            guard let transport = app.cloudTransport(for: node.id) else {
                nodeFacts[node.id] = NodeFacts()
                continue
            }
            var facts = NodeFacts()
            if await transport.commandSupport(.cloudLinkStatus) == .no {
                facts.link = .unsupported
            } else {
                do {
                    let s = try await transport.send(Ws.Cloud.Link.Status.self, payload: WsEmpty())
                    facts.link = s.linked ? .linked(deploymentID: s.deploymentID?.wrapped,
                                                    accountPublicID: s.accountPublicID?.wrapped) : .notLinked
                    if s.linked { facts.key = try? await transport.send(Ws.Cloud.Key.Status.self, payload: WsEmpty()) }
                } catch where error.isUnknownCommand {
                    facts.link = .unsupported
                } catch {
                    facts.link = .unknown
                }
            }
            // Server 1.23 carries vault_uid on every vault a user can see.
            if let list = try? await transport.send(Ws.Storage.Vault.Accessible.List.self, payload: WsNoPayload()) {
                facts.vaults = list.vaults.map { NodeMapping.NodeVault(id: $0.id, name: $0.name, uid: $0.vaultUid) }
            }
            if hasManagedStorage(node.id) {
                do {
                    facts.storage = try await transport.send(Ws.Cloud.Storage.Status.self, payload: WsNoPayload())
                } catch {
                    facts.storageError = error.message
                }
            }
            nodeFacts[node.id] = facts
        }
    }

    var mapping: NodeMapping.Result {
        let nodes = (app?.nodes ?? []).filter(\.pairing.isPaired).map { node in
            let facts = nodeFacts[node.id] ?? NodeFacts()
            return NodeMapping.Node(id: node.id, name: node.displayName, serverNodeID: node.serverNodeID, link: facts.link,
                                    vaults: facts.vaults)
        }
        return NodeMapping.map(deployments: deployments, vaults: vaults, nodes: nodes,
                               accountPublicID: installation?.accountPublicId ?? "")
    }

    /// Opens the vaults' names with the recovery key (one Touch ID).
    func openLabels() async {
        guard let account else { return }
        await run { labels = try await account.openLabels(vaults) }
    }

    // MARK: - billing

    func billingAction() async {
        guard let client, let billing else { return }
        await run {
            let kind = PlanWording.action(billing) == .choosePlan ? "checkout" : "portal"
            let handoff = try await client.billingHandoff(kind: kind)
            guard let url = URL(string: handoff.url), openInBrowser(url) else {
                throw CloudError.invalid("Vaulthalla Cloud sent a link that isn't the portal's. It wasn't opened.")
            }
            report("Continue in your browser. This page updates when you're done.")
            poll { [weak self] in
                guard let self, let client = self.client else { return true }
                let fresh = try await client.billing()
                defer { self.billing = fresh }
                return fresh != billing
            }
        }
    }

    /// Polls every few seconds for a few minutes (until `check` says done), then leaves Refresh to the person.
    private func poll(every interval: Duration = .seconds(4), for total: Duration = .seconds(300),
                      _ check: @escaping @MainActor () async throws -> Bool) {
        polling?.cancel()
        polling = Task { @MainActor in
            let deadline = ContinuousClock.now + total
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: interval)
                if (try? await check()) == true { return }
            }
        }
    }

    @discardableResult
    func openInBrowser(_ url: URL) -> Bool {
        guard environment.mayOpen(url) else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - the recovery key

    /// The recovery code typed in.
    func receive(recoveryCode: String) async {
        guard let account else { return }
        await run {
            let fingerprint = try await account.receive(recoveryCode: SecretBytes(Array(recoveryCode.utf8)))
            report("This Mac holds your recovery key (\(fingerprint.text)).")
            keyStatus = try await account.status()
        }
    }

    func requestTransfer() async {
        guard let account else { return }
        await run {
            let pending = try await account.requestTransfer()
            keyFlow = .waitingForTransfer(code: pending.code)
            report(nil)
            poll { [weak self] in
                guard let self else { return true }
                await self.checkTransfer()
                if case .waitingForTransfer = self.keyFlow { return false }
                return true
            }
        }
    }

    func checkTransfer() async {
        guard let account else { return }
        do {
            switch try await account.checkTransfer() {
            case .waiting:
                if let t = try await account.status().transfer { keyFlow = .waitingForTransfer(code: t.code) }
            case .received(let fingerprint):
                keyFlow = .idle
                report("This Mac holds your recovery key (\(fingerprint.text)).")
                keyStatus = try await account.status()
            case .closed(let status):
                keyFlow = .idle
                if status != "none" { report("The transfer was \(status). Ask again.", error: true) }
            }
        } catch {
            report(error)
        }
    }

    func cancelTransfer() async {
        guard let account else { return }
        await run {
            try await account.cancelTransfer()
            keyFlow = .idle
        }
    }

    /// Delivers a transfer after the person confirmed that the other device shows the same code.
    func deliver(_ transfer: CloudAccount.DeliverableTransfer) async {
        guard let account else { return }
        await run {
            try await account.deliver(transfer)
            report("Your recovery key was sent to \u{201C}\(transfer.transfer.requester.name)\u{201D}.")
            transfers = (try? await account.deliverableTransfers()) ?? []
        }
    }

    /// Delivers a restore with the account key after the person confirmed the restore code.
    func deliver(_ restore: CloudClient.Restore) async {
        guard let account, let client else { return }
        await run {
            let d = try await account.deliver(restore)
            let missing = d.missing.isEmpty ? "" : " Versions \(d.missing.map(String.init).joined(separator: ", ")) aren't covered by your recovery key."
            report("Delivered \(d.versions.count) key version(s) to \u{201C}\(restore.requesterName)\u{201D}.\(missing)")
            restores = (try? await client.deliverable()) ?? []
        }
    }

    /// Onboarding: a new key for an account without one, its code shown once.
    func startNewKey(rotation: Bool = false) async {
        guard let account else { return }
        await run {
            let new = rotation ? try await account.prepareRotation() : try await account.prepareFirstKey()
            let code = try new.recoveryCode()
            newKey = new
            // Shown once, to be written down: the only place the code exists as text.
            let text = code.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
            keyFlow = .showingNewKey(code: Self.grouped(text), groups: Self.checkGroups())
        }
    }

    /// The person saved the code (and typed back two of its groups): send the request and open the portal.
    func submitNewKey() async {
        guard let account, let new = newKey else { return }
        await run {
            let open = try await account.submit(new, offlineCopyConfirmed: true)
            newKey = nil
            let url = environment.keyRequest(open.request.id)
            keyFlow = .waitingForApproval(code: open.code, url: url)
            if let url { openInBrowser(url) }
            poll { [weak self] in
                guard let self else { return true }
                await self.checkPendingKey()
                if case .waitingForApproval = self.keyFlow { return false }
                return true
            }
        }
    }

    func discardNewKey() {
        newKey = nil
        keyFlow = .idle
    }

    func checkPendingKey() async {
        guard let account else { return }
        do {
            switch try await account.checkPendingKey() {
            case .waiting(let code)?:
                let id = try account.keys.pending()?.pendingRequestID
                keyFlow = .waitingForApproval(code: code, url: id.flatMap(environment.keyRequest))
            case .applied?:
                keyFlow = .idle
                report("Your recovery key is set up on this Mac.")
                keyStatus = try await account.status()
            case .closed(let status)?:
                keyFlow = .idle
                report("The request was \(status) in the portal.", error: true)
            case nil:
                break
            }
        } catch {
            report(error)
        }
    }

    /// Records an offline copy made after the key was created (printed, or saved to 1Password).
    func recordOfflineCopy() async {
        guard let account else { return }
        await run {
            let open = try await account.requestOfflineCopy()
            openRequestID = open.request.id
            if let url = environment.keyRequest(open.request.id) { openInBrowser(url) }
            report("Approve in your browser. Request code: \(open.code)")
        }
    }

    /// The recovery code, printed (one Touch ID). Printing is the offline copy this build offers besides writing it
    /// down; the 1Password copy waits for its helper operation.
    func printRecoveryCode() async {
        guard let account else { return }
        await run {
            let code = try await account.exportRecoveryCode()
            let text = code.withUnsafeBytes { Self.grouped(String(decoding: $0, as: UTF8.self)) }
            let fingerprint = keyStatus?.fingerprint?.text ?? ""
            RecoveryCodePrinter.print(code: text, fingerprint: fingerprint)
        }
    }

    // MARK: - servers: the pin of the account key

    /// "Use this account's recovery key on *nas*": `cloud.key.confirm` with this Mac's fingerprint, its `keys`
    /// step-up answered by the approval key. No digits are compared.
    func confirmKey(on node: Node) async {
        guard let app, let transport = app.cloudTransport(for: node.id), let fingerprint = keyStatus?.fingerprint else { return }
        await run {
            guard let context = ApprovalKeys.context(for: node) else {
                throw DeviceApprovalError.keyUnavailable
            }
            let signer = try approvals.signer(for: node.id)
            _ = try await DeviceApproval.send(Ws.Cloud.Key.Confirm.self, payload: .init(fingerprint: fingerprint.text),
                                              signer: signer, context: context, via: transport)
            report("\(node.displayName) now uses your account's recovery key.")
            await refreshNodes()
        }
    }

    /// Registers this Mac's approval key with a node (once): a person approves it in the node's web console.
    func setUpApprovals(on node: Node) async {
        guard let app, let transport = app.cloudTransport(for: node.id) else { return }
        await run {
            let signer = try approvals.signer(for: node.id, create: true)
            switch try await DeviceApproval.register(signer, via: transport) {
            case .registered:
                approvals.markRegistered(node.id)
                report("Approvals are set up on \(node.displayName).")
            case .waitingForConsole(let id):
                report("Approve \u{201C}Register this Mac's approval key\u{201D} in \(node.displayName)'s web console.")
                poll(every: .seconds(2)) { [weak self] in
                    guard let self else { return true }
                    switch try await DeviceApproval.finishRegistration(id, signer: signer, via: transport) {
                    case .registered:
                        self.approvals.markRegistered(node.id)
                        self.report("Approvals are set up on \(node.displayName).")
                        return true
                    case .waitingForConsole: return false
                    }
                }
            }
        }
    }

    // MARK: - managed storage (per server, `cloud.storage.*`)

    func hasManagedStorage(_ id: NodeID) -> Bool {
        app?.nodeProtocols[id]?.capabilities?.contains("cloud.storage.managed_remotes") == true
    }

    private func storageCall(_ node: Node, _ work: (any NodeTransport) async throws -> Void) async {
        guard let transport = app?.cloudTransport(for: node.id) else { return report("\(node.displayName) isn't connected.", error: true) }
        await run {
            try await work(transport)
            if let fresh = try? await transport.send(Ws.Cloud.Storage.Status.self, payload: WsNoPayload()) {
                nodeFacts[node.id, default: NodeFacts()].storage = fresh
            }
        }
    }

    /// A vault's switch. Off with a bucket needs the vault's name as confirmation (the server fetches every file first).
    func setStorage(_ vault: WsModel.CloudStorageVault, on: Bool, node: Node) async {
        await storageCall(node) { t in
            _ = try await t.send(Ws.Cloud.Storage.Switch.self,
                                 payload: .init(vaultID: vault.vaultID, enabled: on, confirm: on ? nil : .value(vault.vaultName)))
        }
    }

    func answerOffer(accept: Bool, node: Node) async {
        await storageCall(node) { t in
            if accept {
                _ = try await t.send(Ws.Cloud.Storage.Offer.Accept.self, payload: .init())
            } else {
                _ = try await t.send(Ws.Cloud.Storage.Offer.Decline.self, payload: .init())
            }
        }
    }

    func setNewVaults(_ enabled: Bool, node: Node) async {
        await storageCall(node) { t in _ = try await t.send(Ws.Cloud.Storage.NewVaults.self, payload: .init(enabled: enabled)) }
    }

    func confirmEnded(node: Node) async {
        await storageCall(node) { t in _ = try await t.send(Ws.Cloud.Storage.Ended.Confirm.self, payload: WsNoPayload()) }
    }

    /// "Leave managed storage": the portal address the server returned (its ejection), else the portal itself;
    /// either is opened only on the portal's origin.
    func leaveManagedStorage(_ status: WsModel.CloudStorageStatus) {
        if case .string(let text)? = status.ejection?["portal_url"], let url = URL(string: text) {
            if !openInBrowser(url) { report("The server's address isn't the Vaulthalla Cloud portal's. It wasn't opened.", error: true) }
        } else {
            openInBrowser(environment.portal)
        }
    }

    // MARK: - Desktop-only vaults (a vault a Mac holds, wave 4)

    /// The vaults of the account that a Mac holds, or that this Mac lost (released, taken off, given to another Mac,
    /// moved to a server: `released`, `moved_to`), as `GET /v1/storage` shows them.
    var macHeldVaults: [CloudStorage.Vault] {
        (storage?.vaults ?? []).filter { $0.desktop != nil || $0.movedTo != nil || $0.released != nil }
    }

    /// A vault's name: the one this Mac gave a Desktop-only vault it holds (its own record), else its sealed label
    /// opened with the recovery key (``openLabels()``); nil while neither is known.
    func vaultName(_ uid: String) -> String? { desktopVaults?.name(uid) ?? labels[uid] }

    /// Whether some vault has a sealed name this Mac hasn't opened yet (another installation's, or one from before).
    var hasUnopenedLabels: Bool {
        keyStatus?.holdsCurrent == true && vaults.contains { $0.label != nil && labels[$0.vaultUid] == nil }
    }

    /// The server holding `uid`, by name, from `GET /v1/vaults`' replicas.
    func serverHolding(_ uid: String) -> String? {
        guard let id = vaults.first(where: { $0.vaultUid == uid })?.replicas.first?.deploymentId else { return nil }
        return deployments.first { $0.id == id }?.name ?? "a server"
    }

    /// This Mac stops holding the vault (`DELETE /v1/vaults/{uid}/replica`): the cloud revokes its key and the vault
    /// waits, held by nobody, until the account holder places it again. Nothing on this Mac is deleted.
    func release(_ vault: CloudStorage.Vault) async {
        guard let client else { return }
        if let desktop = desktopVaults, desktop.holds(vault.vaultUid) {
            // A vault this Mac syncs: its session closes with the release (local files, state and keys stay).
            if let problem = await desktop.stopHolding(vault.vaultUid) { return report(problem, error: true) }
            report("This Mac no longer holds the vault. The account holder can place it again in the portal.")
            storage = try? await client.storage()
            return
        }
        await run {
            do {
                try await client.releaseDesktopVault(vault.vaultUid)
            } catch {
                throw CloudError.invalid(DeviceAccessError.from(error).message)
            }
            try? BucketKeyStore(items: items).delete(vault.vaultUid)
            report("This Mac no longer holds the vault. The account holder can place it again in the portal.")
            storage = try? await client.storage()
        }
    }

    // MARK: - helpers

    static func grouped(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 5).map { i in
            let start = code.index(code.startIndex, offsetBy: i)
            return String(code[start ..< (code.index(start, offsetBy: 5, limitedBy: code.endIndex) ?? code.endIndex)])
        }.joined(separator: "-").uppercased()
    }

    /// Two group numbers (1-based) the person types back before the key is sent.
    static func checkGroups() -> [Int] {
        Array((1 ... 6).shuffled().prefix(2)).sorted()
    }

    /// Whether `typed` matches groups `groups` of `code` (case and spacing ignored).
    static func matches(_ typed: [String], groups: [Int], of code: String) -> Bool {
        let parts = code.split(separator: "-").map { String($0).lowercased() }
        return zip(groups, typed).allSatisfy { group, text in
            group - 1 < parts.count && text.lowercased().filter { !$0.isWhitespace } == parts[group - 1]
        }
    }
}
