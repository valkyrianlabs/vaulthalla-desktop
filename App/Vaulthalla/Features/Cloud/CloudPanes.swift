import SwiftUI
import VHCloud
import VHContract
import VHCore
import VHKeykit
import VHNodes

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
            // Where each vault is stored and its storage switch come with the server's managed storage (cloud.storage.*).
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
