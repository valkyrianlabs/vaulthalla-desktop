import SwiftUI
import VHCloud
import VHContract
import VHCore
import VHKeykit
import VHNodes
import VHVault

/// One pane of the Vaulthalla Cloud section, routed by `DetailView`.
struct CloudView: View {
    @Environment(AppModel.self) private var app
    var section: CloudSection

    var body: some View {
        if let cloud = app.cloud {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.stackSpacing + 8) {
                    SectionHeader(eyebrow: "Vaulthalla Cloud", title: section.title, subtitle: subtitle) {
                        if cloud.phase == .linked {
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await cloud.refresh() } }
                                .controlSize(.small)
                                .disabled(cloud.busy)
                        }
                    }
                    if let message = cloud.message {
                        Callout(tone: cloud.messageIsError ? .warn : .info,
                                systemImage: cloud.messageIsError ? "exclamationmark.triangle" : "info.circle") {
                            Text(message)
                        }
                    }
                    if cloud.phase != .linked {
                        CloudLinkPanel(cloud: cloud)
                    } else {
                        switch section {
                        case .account: CloudAccountPane(cloud: cloud)
                        case .servers: CloudServersPane(cloud: cloud)
                        case .vaults: CloudVaultsPane(cloud: cloud)
                        case .storage: CloudStoragePane(cloud: cloud)
                        case .recoveryKey: CloudRecoveryKeyPane(cloud: cloud)
                        }
                    }
                }
                .padding(Theme.pagePadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .task(id: section) {
                if cloud.phase == .linked, cloud.lastRefresh.map({ Date.now.timeIntervalSince($0) > 30 }) ?? true {
                    await cloud.refresh()
                }
            }
        }
    }

    private var subtitle: String {
        switch section {
        case .account: "This Mac's link and your plan."
        case .servers: "Every server of your account and every node this Mac is paired with."
        case .vaults: "Every vault on every server, by its identity in your account."
        case .storage: "Usage against your plan, and which vaults each server keeps in Vaulthalla Cloud."
        case .recoveryKey: "One recovery key for your whole account. Only your devices can unlock it."
        }
    }
}

/// Not linked yet, or waiting for the approval in the portal.
private struct CloudLinkPanel: View {
    @Bindable var cloud: CloudModel

    var body: some View {
        Panel(title: "Link this Mac") {
            switch cloud.phase {
            case .pending(let code, let fingerprint, _):
                VStack(alignment: .leading, spacing: 12) {
                    Text("In your browser, sign in to Vaulthalla Cloud, open Approvals, enter this code and check that it shows this Mac's key fingerprint before you approve.")
                        .foregroundStyle(.fgMuted)
                    DefinitionList(items: [("Code", code), ("Key fingerprint", fingerprint)], monospacedValues: ["Code", "Key fingerprint"])
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for approval…").foregroundStyle(.fgMuted)
                        Spacer()
                        Button("Open Approvals") { cloud.openInBrowser(cloud.environment.linkApproval) }
                        Button("Cancel") { cloud.cancelLink() }
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Optional. Linking lets this Mac hold your account's recovery key, see your account's servers and vaults, and deliver keys for restores. Nothing else in Vaulthalla needs it.")
                        .foregroundStyle(.fgMuted)
                    TextField("Name", text: $cloud.macName)
                        .frame(maxWidth: 320)
                    Button("Link This Mac") { Task { await cloud.link() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(cloud.busy || !cloud.isOwner)
                    if !cloud.isOwner {
                        Text("Another Vaulthalla process manages this Mac's keys.").font(.caption).foregroundStyle(.fgSubtle)
                    }
                }
            }
        }
    }
}

// MARK: - Account

private struct CloudAccountPane: View {
    var cloud: CloudModel
    @State private var confirmingUnlink = false

    var body: some View {
        Panel(title: "Account") {
            DefinitionList(items: [
                ("Linked as", cloud.installation?.name ?? cloud.macName),
                ("Servers", "\(cloud.deployments.count)"),
                ("Vaults", "\(cloud.vaults.count)"),
            ])
        } actions: {
            Button("Unlink This Mac…", role: .destructive) { confirmingUnlink = true }
                .controlSize(.small)
        }
        .confirmationDialog("Unlink this Mac from Vaulthalla Cloud?", isPresented: $confirmingUnlink, titleVisibility: .visible) {
            Button("Unlink", role: .destructive) { Task { await cloud.unlink() } }
        } message: {
            Text("This Mac stops holding your recovery key and seeing your account. Your servers and vaults are not changed. Link again any time.")
        }

        Panel(title: "Plan") {
            if let billing = cloud.billing {
                VStack(alignment: .leading, spacing: 10) {
                    Text(PlanWording.state(billing) { $0.formatted(date: .abbreviated, time: .omitted) })
                    DefinitionList(items: planItems(billing))
                    Button(actionTitle(billing)) { Task { await cloud.billingAction() } }
                        .disabled(cloud.busy)
                    Text("Plans and payment are handled in your browser.").font(.caption).foregroundStyle(.fgSubtle)
                }
            } else {
                Text("The plan couldn't be read.").foregroundStyle(.fgMuted)
            }
        }

        if !cloud.restores.isEmpty {
            CloudRestoresPanel(cloud: cloud)
        }
    }

    private func planItems(_ b: CloudBilling) -> [(term: String, value: String)] {
        var items: [(String, String)] = [("Plan", b.plan)]
        switch b.recoveryVaults.allowance {
        case .unlimited: items.append(("Vaults with cloud recovery", "Unlimited"))
        case .limited(let n): items.append(("Vaults with cloud recovery", "Up to \(n)"))
        }
        if let end = b.currentPeriodEnd {
            items.append((b.cancelAtPeriodEnd ? "Ends" : "Renews",
                          Date(timeIntervalSince1970: TimeInterval(end)).formatted(date: .abbreviated, time: .omitted)))
        }
        return items
    }

    private func actionTitle(_ b: CloudBilling) -> String {
        switch PlanWording.action(b) {
        case .choosePlan: "Choose a Plan…"
        case .updatePayment: "Update Payment…"
        case .manageBilling: "Manage Billing…"
        }
    }
}

/// Restores waiting for a device that holds the recovery key.
private struct CloudRestoresPanel: View {
    var cloud: CloudModel
    @State private var confirming: CloudClient.Restore?

    var body: some View {
        Panel(title: "Restores waiting for this Mac",
              subtitle: "Approved in your browser. Delivering re-wraps the vault's keys to the restoring server's temporary key; Vaulthalla Cloud can't open them.") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(cloud.restores, id: \.id) { restore in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cloud.labels[restore.vaultUid] ?? "Vault \(restore.vaultUid)").font(.headline)
                            Text("To \u{201C}\(restore.requesterName)\u{201D}").foregroundStyle(.fgMuted)
                        }
                        Spacer()
                        Text(restore.restoreCode).font(.body.monospaced()).textSelection(.enabled)
                        Button("Deliver…") { confirming = restore }
                            .disabled(cloud.busy || cloud.keyStatus?.holdsCurrent != true)
                    }
                }
            }
        }
        .confirmationDialog("Does the server show this restore code?", isPresented: .init(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { restore in
            Button("Yes, \(restore.restoreCode): Deliver") { Task { await cloud.deliver(restore) } }
            Button("No", role: .cancel) {}
        } message: { restore in
            Text("The server restoring this vault must show \(restore.restoreCode). If it shows anything else, don't deliver: someone may be trying to receive the keys instead.")
        }
    }
}

// MARK: - Servers

private struct CloudServersPane: View {
    @Environment(AppModel.self) private var app
    var cloud: CloudModel

    var body: some View {
        let mapping = cloud.mapping
        if mapping.servers.isEmpty {
            Panel { EmptyState("No servers yet", systemImage: "server.rack", message: "Link a server with `vh cloud link` on it, or from its web console.") }
        }
        ForEach(mapping.servers) { server in
            Panel(title: title(server)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        StatusBadge(label: badge(server).0, tone: badge(server).1)
                        if let seen = server.deployment?.lastSeen {
                            Text("Last contact \(Date(timeIntervalSince1970: TimeInterval(seen)).formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.fgSubtle)
                        }
                    }
                    Text(explanation(server)).foregroundStyle(.fgMuted)
                    if case .linked(let id, _) = server, let node = app.node(withID: id) {
                        keyRow(node)
                    }
                    if case .unpaired = server {
                        Button("Pair This Mac with \(server.deployment?.name ?? "It")…") { app.presentAddNode() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyRow(_ node: Node) -> some View {
        let facts = cloud.nodeFacts[node.id]
        if let key = facts?.key {
            let advice = ServerKeyAdvice.advise(state: key.state, accountPublicID: key.accountPublicID, pinned: key.pinned?.fingerprint,
                                                waiting: key.waiting?.fingerprint, held: cloud.keyStatus?.fingerprint?.text,
                                                ourAccount: cloud.installation?.accountPublicId ?? "")
            switch advice {
            case .pinned:
                Label("Uses your account's recovery key", systemImage: "checkmark.seal").foregroundStyle(StatusTone.ok.color)
            case .confirm:
                HStack {
                    Button("Use This Account's Recovery Key on \(node.displayName)") { Task { await cloud.confirmKey(on: node) } }
                        .disabled(cloud.busy)
                    if !cloud.approvals.hasKey(node.id) {
                        Button("Set Up Approvals…") { Task { await cloud.setUpApprovals(on: node) } }
                            .disabled(cloud.busy)
                    }
                }
                Text("Confirming asks for Touch ID on this Mac. There are no digits to compare: this Mac holds the key.")
                    .font(.caption).foregroundStyle(.fgSubtle)
            case .mismatch(let waiting):
                Callout(tone: .danger, systemImage: "exclamationmark.octagon") {
                    Text("\(node.displayName) waits for a recovery key that isn't the one this Mac holds (\(waiting)). Don't confirm it there.")
                }
            case .pinnedOther(let fingerprint):
                Text("\(node.displayName) uses another recovery key (\(fingerprint)). It follows a signed rotation on its own.")
                    .foregroundStyle(.fgMuted)
            case .none(let why):
                Text(why).foregroundStyle(.fgMuted)
            }
        }
    }

    private func title(_ s: NodeMapping.Server) -> String {
        if let id = s.node, let node = app.node(withID: id) { return node.displayName }
        return s.deployment?.name ?? "Server"
    }

    private func badge(_ s: NodeMapping.Server) -> (String, StatusTone) {
        switch s {
        case .linked: ("Connected", .ok)
        case .likely: ("Likely this server", .info)
        case .unpaired: ("Not paired with this Mac", .unknown)
        case .notLinked: ("Not connected to Vaulthalla Cloud", .unknown)
        case .otherAccount: ("Different account", .warn)
        case .needsUpdate: ("Update needed", .warn)
        case .unknown: ("Not answered yet", .unknown)
        }
    }

    private func explanation(_ s: NodeMapping.Server) -> String {
        switch s {
        case .linked: "Paired with this Mac and linked to your account."
        case .likely: "Its server id matches; it confirms once this Mac reaches it."
        case .unpaired(let d): "\(d.name) is on your account. Pair this Mac with it to manage it here."
        case .notLinked: "Link it with `vh cloud link` on the server, or from its web console."
        case .otherAccount: "Connected to a different Vaulthalla Cloud account. It is shown, not managed, here."
        case .needsUpdate: "Update Vaulthalla on this server to see its link here."
        case .unknown: "Waiting for the server to answer."
        }
    }
}

// MARK: - Vaults

private struct CloudVaultsPane: View {
    @Environment(AppModel.self) private var app
    var cloud: CloudModel

    var body: some View {
        if cloud.vaults.isEmpty {
            Panel { EmptyState("No vaults yet", systemImage: "archivebox", message: "Vaults appear here once a linked server registers them.") }
        } else {
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(cloud.mapping.vaults) { vault in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name(vault)).font(.headline)
                                Text(places(vault)).font(.caption).foregroundStyle(.fgSubtle)
                            }
                            Spacer()
                            StatusBadge(label: backup(vault).0, tone: backup(vault).1)
                        }
                        if vault.placements.contains(where: \.uidMismatch) {
                            Text("The server reports a different identity for this vault. Nothing is changed until that is resolved on the server.")
                                .font(.caption).foregroundStyle(StatusTone.warn.color)
                        }
                    }
                }
            } actions: {
                if cloud.keyStatus?.holdsCurrent == true, cloud.vaults.contains(where: { $0.label != nil }), cloud.labels.isEmpty {
                    Button("Show Names") { Task { await cloud.openLabels() } }.controlSize(.small)
                }
            }
        }
    }

    private func name(_ v: NodeMapping.Vault) -> String {
        if let name = cloud.labels[v.uid] { return name }
        for p in v.placements {
            if let node = p.node, let id = p.nodeVaultID,
               let local = cloud.nodeFacts[node]?.vaults.first(where: { $0.id == id }) { return local.name }
        }
        return v.sealedLabel == nil ? "Vault \(v.uid.prefix(8))…" : "Name hidden until the recovery key is unlocked"
    }

    private func places(_ v: NodeMapping.Vault) -> String {
        let names = v.placements.map { p in
            if let node = p.node.flatMap({ app.node(withID: $0) }) { return node.displayName }
            return cloud.deployments.first { $0.id == p.deploymentID }?.name ?? "a removed server"
        }
        return names.isEmpty ? "On no server" : "On \(names.joined(separator: ", "))"
    }

    private func backup(_ v: NodeMapping.Vault) -> (String, StatusTone) {
        guard let c = cloud.coverage[v.uid] else { return ("Not backed up", .unknown) }
        if c.accountKey?.covered == true { return ("Protected by your recovery key", .ok) }
        return c.ready ? ("Backed up with another recipient", .info) : ("Not backed up yet", .warn)
    }
}

// MARK: - Recovery Key

private struct CloudRecoveryKeyPane: View {
    var cloud: CloudModel
    @State private var typedCode = ""
    @State private var typedGroups = ["", ""]
    @State private var deliveringTransfer: CloudAccount.DeliverableTransfer?

    var body: some View {
        let status = cloud.keyStatus
        switch cloud.keyFlow {
        case .showingNewKey(let code, let groups):
            newKeyPanel(code: code, groups: groups)
        case .waitingForApproval(let code, let url):
            Panel(title: "Approve in your browser") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Compare this request code with the one your browser shows, then approve.").foregroundStyle(.fgMuted)
                    Text(code).font(.title2.monospaced()).textSelection(.enabled)
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Waiting for approval…").foregroundStyle(.fgMuted)
                        Spacer()
                        if let url { Button("Open in Browser") { cloud.openInBrowser(url) } }
                    }
                }
            }
        case .waitingForTransfer(let code):
            Panel(title: "Waiting for another device") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("On a device that holds your recovery key (another Mac, or Vaulthalla Cloud in your browser), choose to send it to this Mac and check it shows this code.")
                        .foregroundStyle(.fgMuted)
                    Text(code).font(.title2.monospaced()).textSelection(.enabled)
                    HStack {
                        ProgressView().controlSize(.small)
                        Spacer()
                        Button("Cancel") { Task { await cloud.cancelTransfer() } }
                    }
                }
            }
        case .idle:
            if status?.cloud == nil {
                Panel(title: "No recovery key yet") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your account has no recovery key. Create it here: this Mac makes it, shows it to you once, and keeps it sealed to its Secure Enclave.")
                            .foregroundStyle(.fgMuted)
                        Button("Create Recovery Key…") { Task { await cloud.startNewKey() } }
                            .buttonStyle(.borderedProminent).disabled(cloud.busy)
                    }
                }
            } else if status?.holdsCurrent == true {
                heldPanels(status!)
            } else {
                receivePanel(status)
            }
        }
    }

    private func newKeyPanel(code: String, groups: [Int]) -> some View {
        Panel(title: "Your recovery key") {
            VStack(alignment: .leading, spacing: 12) {
                Text("This is your recovery key. With it, your files can be recovered even if you lose every device and Vaulthalla Cloud is unavailable. Nobody else has a copy.")
                Text(code).font(.title2.monospaced()).textSelection(.enabled)
                Text("Write it down or print it and keep it like a house key. Then type back groups \(groups[0]) and \(groups[1]).")
                    .foregroundStyle(.fgMuted)
                HStack {
                    TextField("Group \(groups[0])", text: $typedGroups[0]).frame(width: 120)
                    TextField("Group \(groups[1])", text: $typedGroups[1]).frame(width: 120)
                }
                .font(.body.monospaced())
                HStack {
                    Button("Print…") { RecoveryCodePrinter.print(code: code, fingerprint: "") }
                    Spacer()
                    Button("Cancel") {
                        typedGroups = ["", ""]
                        cloud.discardNewKey()
                    }
                    Button("I Saved It: Continue") {
                        typedGroups = ["", ""]
                        Task { await cloud.submitNewKey() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!CloudModel.matches(typedGroups, groups: groups, of: code) || cloud.busy)
                }
            }
        }
    }

    @ViewBuilder
    private func heldPanels(_ status: CloudAccount.KeyStatus) -> some View {
        Panel(title: "This Mac holds your recovery key") {
            VStack(alignment: .leading, spacing: 10) {
                DefinitionList(items: [
                    ("Fingerprint", status.fingerprint?.text ?? ""),
                    ("Generation", "\(status.held?.generation ?? 0)"),
                    ("Kept in", status.held?.holderKind == .secureEnclave ? "This Mac's Secure Enclave" : "This Mac's keychain"),
                ], monospacedValues: ["Fingerprint"])
                if let at = status.offlineCopyConfirmedAt {
                    Label("Saved offline on \(at.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.circle")
                        .foregroundStyle(StatusTone.ok.color)
                } else {
                    Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                        Text("No offline copy yet. Vaulthalla Cloud storage starts once you save one.")
                        HStack {
                            Button("Print…") { Task { await cloud.printRecoveryCode() } }
                            Button("I Saved a Copy…") { Task { await cloud.recordOfflineCopy() } }
                        }
                        .controlSize(.small)
                    }
                }
            }
        } actions: {
            Menu("More") {
                Button("Print Recovery Key…") { Task { await cloud.printRecoveryCode() } }
                Button("Rotate Recovery Key…") { Task { await cloud.startNewKey(rotation: true) } }
            }
            .controlSize(.small)
            .fixedSize()
        }
        if let replacement = status.unsignedReplacement {
            Callout(tone: .danger, systemImage: "exclamationmark.octagon") {
                Text("Your account's recovery key was replaced by one this Mac's key didn't sign (\(replacement.text)). Servers keep using the old key until someone confirms the new one on each. If you didn't do this, check your account in the browser.")
            }
        }
        Panel(title: "Other ways to unlock it") {
            DefinitionList(items: [
                ("Devices holding it", "\(cloud.holders.count)"),
                ("Passkeys", "\(cloud.unlocks?.unlocks.filter(\.current).count ?? 0)"),
                ("Servers using it", "\(cloud.nodeFacts.values.filter { $0.key?.state == "pinned" }.count)"),
            ])
        }
        if !cloud.transfers.isEmpty {
            Panel(title: "Devices asking for your recovery key") {
                ForEach(cloud.transfers) { t in
                    HStack {
                        Text("\u{201C}\(t.transfer.requester.name)\u{201D}")
                        Spacer()
                        Text(t.code).font(.body.monospaced())
                        Button("Send…") { deliveringTransfer = t }.disabled(cloud.busy)
                    }
                }
            }
            .confirmationDialog("Does the other device show this code?",
                                isPresented: .init(get: { deliveringTransfer != nil }, set: { if !$0 { deliveringTransfer = nil } }),
                                titleVisibility: .visible, presenting: deliveringTransfer) { t in
                Button("Yes, \(t.code): Send") { Task { await cloud.deliver(t) } }
                Button("No", role: .cancel) {}
            } message: { t in
                Text("Send your recovery key only if \u{201C}\(t.transfer.requester.name)\u{201D} shows \(t.code). If it shows anything else, someone else asked for it.")
            }
        }
    }

    private func receivePanel(_ status: CloudAccount.KeyStatus?) -> some View {
        Panel(title: "Get your recovery key on this Mac") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your account has a recovery key\(status?.current.map { " (\($0.fingerprint.text))" } ?? ""). Send it to this Mac from a device that holds it, or type its recovery code.")
                    .foregroundStyle(.fgMuted)
                Button("Ask Another Device…") { Task { await cloud.requestTransfer() } }
                    .disabled(cloud.busy)
                HStack {
                    SecureField("Recovery code", text: $typedCode)
                        .font(.body.monospaced())
                        .frame(maxWidth: 360)
                    Button("Use Recovery Code") {
                        let code = typedCode
                        typedCode = ""
                        Task { await cloud.receive(recoveryCode: code) }
                    }
                    .disabled(typedCode.isEmpty || cloud.busy)
                }
                Text("Typing the code sends nothing: this Mac checks it against your account's key and keeps it sealed to its Secure Enclave.")
                    .font(.caption).foregroundStyle(.fgSubtle)
            }
        }
    }
}

// MARK: - Storage

/// Managed storage, per server that has it (`cloud.storage.managed_remotes`): usage, the plan's state, the offer for
/// vaults that existed before, the default for new vaults, each vault's switch and state, an ended plan's notice, and
/// leaving. Every change goes to the server over its own connection (no step-up); the server carries it out.
private struct CloudStoragePane: View {
    @Environment(AppModel.self) private var app
    var cloud: CloudModel
    @State private var turningOff: (vault: WsModel.CloudStorageVault, node: Node)?

    var body: some View {
        let nodes = app.nodes.filter { $0.pairing.isPaired && cloud.hasManagedStorage($0.id) }
        if !cloud.macHeldVaults.isEmpty || cloud.desktopVaults != nil { CloudMacVaultsPanel(cloud: cloud) }
        if nodes.isEmpty, cloud.macHeldVaults.isEmpty, cloud.desktopVaults == nil {
            Panel {
                EmptyState("No server keeps vaults here yet", systemImage: "externaldrive.badge.icloud",
                           message: "A paired server with a Vaulthalla version that supports it shows its vaults here.")
            }
        }
        ForEach(nodes) { node in
            if let status = cloud.nodeFacts[node.id]?.storage {
                serverPanels(status, node: node)
            } else {
                Panel(title: node.displayName) {
                    Text(cloud.nodeFacts[node.id]?.storageError ?? "Waiting for \(node.displayName) to answer.").foregroundStyle(.fgMuted)
                }
            }
        }
        .confirmationDialog("Make this vault local again?", isPresented: .init(get: { turningOff != nil }, set: { if !$0 { turningOff = nil } }),
                            titleVisibility: .visible, presenting: turningOff.map { [$0.vault.vaultID] }) { _ in
            Button("Make Local", role: .destructive) {
                if let t = turningOff { Task { await cloud.setStorage(t.vault, on: false, node: t.node) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            let server = turningOff?.node.displayName ?? "The server"
            Text("\(server) first downloads every file it doesn't have yet and checks it, which needs that much free space. Then the vault stops using its storage. Deleting the copy in Vaulthalla Cloud is a separate step, in your browser.")
        }
    }

    @ViewBuilder
    private func serverPanels(_ s: WsModel.CloudStorageStatus, node: Node) -> some View {
        if let ended = s.ended {
            Callout(tone: .danger, systemImage: "exclamationmark.octagon") {
                Text("Your plan ended. \(node.displayName)'s vaults in Vaulthalla Cloud stay attached without access until \(date(ended.convertsAt)), or until you confirm. Then they become local; files held only in their storage are listed as lost, and nothing on \(node.displayName) is deleted.")
                if ended.confirmedBy == nil {
                    Button("Make Them Local Now") { Task { await cloud.confirmEnded(node: node) } }
                        .controlSize(.small).disabled(cloud.busy)
                }
            }
        }
        Panel(title: node.displayName, subtitle: s.available ? nil
              : ManagedStorageWording.unavailable(linked: s.linked, accountKey: s.accountKey, entitlement: s.entitlement,
                                                  server: node.displayName)) {
            VStack(alignment: .leading, spacing: 10) {
                if let usage = ManagedStorageWording.usage(used: s.usedBytes, quota: s.quotaBytes, day: s.usageDay) {
                    if let used = s.usedBytes, let quota = s.quotaBytes, quota > 0 {
                        ProgressView(value: min(Double(used) / Double(quota), 1)).frame(maxWidth: 360)
                    }
                    Text(usage).font(.callout)
                }
                Text("\(ByteCountFormatter.string(fromByteCount: s.managedLocalBytes, countStyle: .decimal)) of it is also held on \(node.displayName). Usage is updated daily.")
                    .font(.caption).foregroundStyle(.fgSubtle)
                if s.available {
                    Toggle("Keep new vaults in Vaulthalla Cloud", isOn: .init(get: { s.newVaults },
                                                                            set: { v in Task { await cloud.setNewVaults(v, node: node) } }))
                        .disabled(cloud.busy)
                    Text("New vaults are stored once they hold their first file.").font(.caption).foregroundStyle(.fgSubtle)
                }
            }
        } actions: {
            Button("Leave Managed Storage…") { cloud.leaveManagedStorage(s) }.controlSize(.small)
        }
        if s.offerOpen, !s.offered.isEmpty {
            Panel(title: "\(s.offered.count) existing vault\(s.offered.count == 1 ? "" : "s") on \(node.displayName) can be stored in Vaulthalla Cloud",
                  subtitle: "Nothing is uploaded until you choose. Each vault keeps its own switch afterwards.") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(s.offered, id: \.vaultID) { v in
                        HStack {
                            Text(v.vaultName)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: v.localBytes, countStyle: .decimal)).foregroundStyle(.fgMuted)
                        }
                    }
                    HStack {
                        Button("Store All") { Task { await cloud.answerOffer(accept: true, node: node) } }
                            .buttonStyle(.borderedProminent)
                        Button("Keep Them Local") { Task { await cloud.answerOffer(accept: false, node: node) } }
                    }
                    .disabled(cloud.busy)
                }
            }
        }
        Panel(title: "Vaults on \(node.displayName)") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(s.vaults, id: \.vaultID) { v in
                    let line = ManagedStorageWording.line(wording(v), server: node.displayName)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.vaultName).font(.headline)
                            Text(line.text).font(.caption).foregroundStyle(tone(line.tone))
                            if let lost = v.lost, !lost.files.isEmpty {
                                Text(lost.files.prefix(3).map(\.path).joined(separator: ", ") + (lost.files.count > 3 ? ", …" : ""))
                                    .font(.caption2).foregroundStyle(.fgSubtle)
                            }
                        }
                        Spacer()
                        if v.storage != "own" {
                            Toggle("", isOn: .init(get: { v.switch == "on" }, set: { on in
                                if on { Task { await cloud.setStorage(v, on: true, node: node) } } else { turningOff = (v, node) }
                            }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(cloud.busy || !s.available && v.switch != "on")
                            .accessibilityLabel("Store \(v.vaultName) in Vaulthalla Cloud")
                        }
                    }
                }
            }
        }
    }

    private func wording(_ v: WsModel.CloudStorageVault) -> ManagedStorageWording.Vault {
        ManagedStorageWording.Vault(storage: v.storage, switchOn: v.switch.map { $0 == "on" }, state: v.state, reason: v.reason,
                                    access: v.access, bytesDone: v.progress?.bytesDone, bytesTotal: v.progress?.bytesTotal,
                                    etaSeconds: v.progress?.etaSeconds, lostFiles: v.lost?.files.count ?? 0, lastError: v.lastError)
    }

    private func tone(_ t: ManagedStorageWording.Tone) -> Color {
        switch t {
        case .ok: StatusTone.ok.color
        case .info: StatusTone.info.color
        case .warn: StatusTone.warn.color
        case .danger: StatusTone.danger.color
        case .neutral: .secondary
        }
    }

    private func date(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .shortened)
    }
}

/// Vaults a Mac holds with no server (Desktop-only vaults), from `GET /v1/storage`: who holds each, its storage, and
/// the holding Mac's key and its renewal in words (DeviceAccessWording), read-only. This build doesn't sync these
/// vaults, so it never asks for a key and says so; the only action is to stop holding one, which narrows access.
private struct CloudMacVaultsPanel: View {
    var cloud: CloudModel
    @State private var releasing: CloudStorage.Vault?
    @State private var creating = false

    var body: some View {
        let me = cloud.installation?.id ?? ""
        Panel(title: "Vaults kept by a Mac", subtitle: "A vault with no server, held by one Mac of your account.") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(cloud.macHeldVaults) { v in
                    let mine = v.desktop?.installationId == me
                    let holder = DeviceAccessWording.holder(v, thisMac: me, server: cloud.serverHolding(v.vaultUid))
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cloud.labels[v.vaultUid] ?? "Vault \(v.vaultUid.prefix(8))…").font(.headline)
                            Text(holder.text).font(.caption).foregroundStyle(tone(holder.tone))
                            if v.movedTo == nil, v.released == nil || v.desktop?.installationId == me {
                                let bucket = DeviceAccessWording.bucket(v)
                                Text(bucket.text).font(.caption).foregroundStyle(tone(bucket.tone))
                                let key = DeviceAccessWording.key(mine ? v.credential : v.desktop?.credential, now: .now, mine: mine)
                                Text(key.text).font(.caption).foregroundStyle(tone(key.tone))
                            }
                        }
                        Spacer()
                        if mine, let desktop = cloud.desktopVaults, desktop.holds(v.vaultUid) {
                            Toggle("Show in Finder", isOn: .init(get: { desktop.inFinder.contains(v.vaultUid) },
                                                                 set: { on in Task { await desktop.setShownInFinder(v.vaultUid, on) } }))
                                .toggleStyle(.switch).controlSize(.small)
                        }
                        if mine, let desktop = cloud.desktopVaults, desktop.adoptable.contains(v.vaultUid) {
                            Button("Sync on This Mac") {
                                Task { await desktop.adopt(v.vaultUid, name: cloud.labels[v.vaultUid] ?? "Vault \(v.vaultUid.prefix(8))") }
                            }.controlSize(.small)
                        }
                        if mine {
                            Button("Stop Holding…") { releasing = v }.controlSize(.small).disabled(cloud.busy)
                        }
                    }
                    if mine, let line = cloud.desktopVaults?.sentence(v.vaultUid) {
                        Text(line).font(.caption).foregroundStyle(.fgMuted)
                    }
                }
                if let desktop = cloud.desktopVaults {
                    if let problem = desktop.problem { Text(problem).font(.caption).foregroundStyle(StatusTone.danger.color) }
                    Button("New Vault in Managed Storage\u{2026}") { creating = true }
                        .disabled(desktop.creating != nil)
                } else {
                    Text("This version of Vaulthalla doesn't sync vaults kept by a Mac yet: nothing is uploaded or downloaded from this Mac, and it asks for no storage key.")
                        .font(.caption).foregroundStyle(.fgSubtle)
                }
            }
        }
        .sheet(isPresented: $creating) {
            if let desktop = cloud.desktopVaults { NewDesktopVaultSheet(desktop: desktop) }
        }
        .confirmationDialog("Stop holding this vault on this Mac?", isPresented: .init(get: { releasing != nil }, set: { if !$0 { releasing = nil } }),
                            titleVisibility: .visible, presenting: releasing) { v in
            Button("Stop Holding", role: .destructive) { Task { await cloud.release(v) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Vaulthalla Cloud revokes this Mac's storage key, and the vault waits, held by no device, until you place it on a Mac or a server in the portal. Nothing on this Mac is deleted.")
        }
    }

    private func tone(_ t: ManagedStorageWording.Tone) -> Color {
        switch t {
        case .ok: StatusTone.ok.color
        case .info: StatusTone.info.color
        case .warn: StatusTone.warn.color
        case .danger: StatusTone.danger.color
        case .neutral: .secondary
        }
    }
}

/// "New Vault in Managed Storage": a vault this Mac keeps in Vaulthalla Cloud's managed storage with no server. Gated
/// on the account (linked, the recovery key held, its offline copy confirmed, a plan with storage); the limits are said
/// here, before anything is made.
private struct NewDesktopVaultSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var desktop: DesktopVaultsModel
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Vault in Managed Storage").font(.title2.bold())
            Text("A vault with no server: this Mac encrypts every file and keeps it in your Vaulthalla Cloud storage. Its key is made on this Mac and wrapped to your account's recovery key before anything is stored.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("For now").font(.headline)
                ForEach(DesktopVaultsModel.limits, id: \.self) { line in
                    Label(line, systemImage: "info.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            switch desktop.readiness {
            case .ready?:
                TextField("Vault name", text: $name).textFieldStyle(.roundedBorder)
            case .offlineCopyNeeded?, .noAccountKey?:
                Text(desktop.readiness!.sentence).foregroundStyle(StatusTone.warn.color).fixedSize(horizontal: false, vertical: true)
                Button("Go to Recovery Key") {
                    app.cloudSection = .recoveryKey
                    dismiss()
                }
            case let r?:
                Text(r.sentence).foregroundStyle(StatusTone.warn.color).fixedSize(horizontal: false, vertical: true)
            case nil:
                ProgressView().controlSize(.small)
            }
            if let step = desktop.creating { Text(DesktopVaultsModel.words(step)).font(.callout).foregroundStyle(.fgMuted) }
            if let problem = desktop.problem { Text(problem).foregroundStyle(StatusTone.danger.color) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create Vault") {
                    Task { if await desktop.create(name: name) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(desktop.readiness != .ready || desktop.creating != nil
                          || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await desktop.refresh() }
    }
}
