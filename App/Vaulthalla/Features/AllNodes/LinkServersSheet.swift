import SwiftUI
import VHCore
import VHNodes

/// Link two servers (the server's design/peers/link.md). Desktop makes a link easy to find and quick to do, and the two
/// servers still shake hands: trust never spreads by itself.
///
/// - This Mac a super admin on both: one confirmation, which first states the boundary (both servers by name, address
///   and the key this Mac pins, and per direction what the other server will hold, with its default role on mirrored
///   vaults, "No role" unless chosen); Desktop then brokers the handshake over its own sessions (``ServerLinking``) and
///   sets any chosen role on that side (`peer.policy.set`).
/// - A super admin on one only, or the other server isn't paired here: Request a Link. That server dials the other
///   (`peer.link.start`) and shows a code, read to the other server's admin, who approves it there.
/// - Neither: nothing to start from here.
///
/// The servers refuse every linking command unless the caller is a super admin there; their refusals are shown, never
/// worked around.
struct LinkServersSheet: View {
    /// Pre-filled from where it was opened (a node's row or a suggestion), else the first two.
    var preselected: NodeID?
    var other: NodeID?
    /// Open with "Another server, by address" picked.
    var byAddress = false

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var first: NodeID?
    @State private var second: Pick?
    @State private var address = ""
    /// The role each node gives the other, by node.
    @State private var roles: [NodeID: LinkRoles.Option] = [:]

    /// The second pick: one of this Mac's nodes, or a server given by its address.
    enum Pick: Hashable {
        case node(NodeID)
        case address
    }

    private var linked: LinkedServersModel { model.linkedServers }
    private var candidates: [Node] { linked.linkableNodes }

    private var secondNode: NodeID? {
        if case .node(let id)? = second { id } else { nil }
    }

    private var plan: LinkPlan? {
        guard let first, let second else { return nil }
        if case .node(let id) = second, id == first { return nil }
        return linked.plan(first, secondNode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.accentText)
                    .frame(width: 38, height: 38)
                    .background(.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Link Servers")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                    Text("A handshake between exactly two servers, approved by a super admin on each. Desktop makes it quick; trust goes no further than the two of them.")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let attempt = linked.attempt {
                progress(attempt)
            } else if let request = linked.request {
                requestProgress(request)
            } else {
                choose
            }

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(22)
        .frame(width: 680)
        .onAppear {
            linked.clearAttempt()
            linked.clearRequest()
            linked.clearRoleOptions()
            let ids = candidates.map(\.id)
            first = preselected.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first { linked.isPermitted($0) } ?? ids.first
            if byAddress {
                second = .address
            } else if let other, ids.contains(other), other != first {
                second = .node(other)
            } else {
                second = ids.first { $0 != first }.map(Pick.node) ?? .address
            }
        }
        .onDisappear { linked.clearRequest() }
        .task(id: plan) { await loadRoles() }
        #if DEBUG
        .task { await debugStart() }
        #endif
    }

    private func node(_ id: NodeID?) -> Node? { id.flatMap { model.node(withID: $0) } }

    private func name(_ id: NodeID?) -> String { node(id)?.displayName ?? "?" }

    // MARK: Choosing

    private var choose: some View {
        VStack(alignment: .leading, spacing: 16) {
            if candidates.isEmpty {
                Text("Linking needs a server this Mac is paired with as a super admin, running Vaulthalla \(ServerLinking.minimumVersion) or newer.")
                    .foregroundStyle(.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                pickers
                switch plan {
                case .handshake?:
                    if let first, let second = secondNode { confirm(first, second) }
                case .request(let from, let to)?:
                    requestForm(from: from, to: to)
                case .neither?:
                    Text(neitherText)
                        .foregroundStyle(.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                case nil:
                    EmptyView()
                }
            }
            if !linked.olderNodes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(linked.olderNodes) { node in
                        Text(ServerLinking.Failure.olderServer(node.displayName).description)
                    }
                }
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var neitherText: String {
        guard let first else { return "" }
        if let second = secondNode {
            return "This Mac isn't paired as a super admin on \(name(first)) or \(name(second)), so neither can start a link from here. A super admin of either server can start it there."
        }
        return "This Mac isn't paired as a super admin on \(name(first)), so it can't ask another server from here."
    }

    private var pickers: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Link").foregroundStyle(.fgSubtle)
                Picker("", selection: $first) {
                    ForEach(candidates) { node in
                        Text(node.displayName).tag(Optional(node.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
            }
            GridRow {
                Text("with").foregroundStyle(.fgSubtle)
                Picker("", selection: $second) {
                    ForEach(candidates.filter { $0.id != first }) { node in
                        Text(node.displayName).tag(Optional(Pick.node(node.id)))
                    }
                    Divider()
                    Text("Another server, by address").tag(Optional(Pick.address))
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
            }
        }
        .onChange(of: first) { _, now in
            if case .node(let id)? = second, id == now {
                second = candidates.first { $0.id != now }.map { Pick.node($0.id) } ?? .address
            }
        }
    }

    // MARK: The handshake's confirmation

    @ViewBuilder
    private func confirm(_ a: NodeID, _ b: NodeID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link \(name(a)) and \(name(b))?")
                .font(.headline)
                .foregroundStyle(.fg)
            HStack(alignment: .top, spacing: 12) {
                serverCard(a, other: b)
                serverCard(b, other: a)
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Both servers check each other against the keys above, which this Mac already trusts, and Desktop compares the pairing code for you. A third server gains nothing. One of the two must be able to reach the other.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One server: who it is, and what the other server will hold on it.
    private func serverCard(_ id: NodeID, other: NodeID) -> some View {
        let server = node(id)
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name(id))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.fg)
                    .lineLimit(1)
                Text(server.map(Self.address) ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.fgSubtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text("Key").foregroundStyle(.fgSubtle)
                    Text(server?.serverPin?.shortFingerprint ?? "not pinned")
                        .monospaced()
                        .foregroundStyle(.fgMuted)
                        .textSelection(.enabled)
                }
                .font(.caption)
            }
            Divider()
            Text("What \(name(other)) will hold here")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.fgMuted)
            VStack(alignment: .leading, spacing: 4) {
                bullet("Accounts: shared as identities only.")
                bullet("Vaults: none mirrored until one side offers and the other accepts.")
            }
            .font(.callout)
            .foregroundStyle(.fgMuted)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(name(other))'s default role on vaults mirrored with it")
                    .font(.callout)
                    .foregroundStyle(.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                rolePicker(id)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl).strokeBorder(.line))
    }

    @ViewBuilder
    private func rolePicker(_ id: NodeID) -> some View {
        switch linked.roleOptions[id] {
        case .success(let options)?:
            Picker("", selection: Binding(get: { roles[id] ?? .noRole }, set: { roles[id] = $0 })) {
                ForEach(options) { option in Text(option.name).tag(option) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failure(let error)?:
            Text("No role: \(name(id)) didn't list its vault roles (\(error.message)).")
                .font(.caption)
                .foregroundStyle(.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where this Mac reaches the node: its configured address unless that is this Mac, else what it advertises.
    static func address(_ node: Node) -> String {
        let configured = "\(node.endpoint.host):\(node.endpoint.port)"
        guard ServerLinking.isLoopback(node.endpoint.host) else { return configured }
        return node.endpoints.first { $0.kind != .loopback }.map { "\($0.host):\($0.port)" } ?? configured
    }

    private func loadRoles() async {
        guard case .handshake? = plan, let first, let second = secondNode else { return }
        async let a: Void = linked.loadRoleOptions(first)
        async let b: Void = linked.loadRoleOptions(second)
        _ = await (a, b)
        #if DEBUG
        // `-VHDebugLinkRole <name>`: that role on both sides, for a picture.
        if let wanted = UserDefaults.standard.string(forKey: "VHDebugLinkRole") {
            for id in [first, second] {
                if case .success(let options)? = linked.roleOptions[id], let option = options.first(where: { $0.name == wanted }) {
                    roles[id] = option
                }
            }
        }
        #endif
    }

    private var rolesReady: Bool {
        guard let first, let second = secondNode else { return false }
        return linked.roleOptions[first] != nil && linked.roleOptions[second] != nil
    }

    // MARK: Requesting a link

    @ViewBuilder
    private func requestForm(from: NodeID, to: NodeID?) -> some View {
        let other = to.map(name) ?? "the other server"
        VStack(alignment: .leading, spacing: 12) {
            Text("Request a link from \(name(from))")
                .font(.headline)
                .foregroundStyle(.fg)
            Text(to == nil
                 ? "\(name(from)) asks the other server, and that server's admin approves it there."
                 : "This Mac is a super admin on \(name(from)) only, so \(other)'s admin approves this link there.")
                .foregroundStyle(.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Ask an admin of \(other) to open Accept a link there: Linked servers in its web console, or Accept a Link Request in Vaulthalla Desktop.")
                VStack(alignment: .leading, spacing: 6) {
                    step(2, "Enter \(other)'s address, as that window lists it.")
                    TextField("Address", text: $address, prompt: Text("host or host:port"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .padding(.leading, 26)
                        .onSubmit { startRequest() }
                }
                step(3, "\(name(from)) dials it and shows a six-digit code. Read the code and \(name(from))'s key to that admin, who picks the same code to approve.")
            }
            .font(.callout)
            .foregroundStyle(.fgMuted)
            Text("Once linked, each server shares its accounts with the other as identities only, mirrors no vault until one side offers and the other accepts, and gives the other no role on mirrored vaults until a super admin sets one.")
                .font(.callout)
                .foregroundStyle(.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { prefillAddress(to) }
        .onChange(of: to) { _, now in prefillAddress(now) }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.accentText)
                .frame(width: 18, height: 18)
                .background(.accentSoft, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func prefillAddress(_ to: NodeID?) {
        address = node(to).map(Self.address) ?? ""
    }

    private var requestTarget: (from: NodeID, otherName: String, endpoint: NodeEndpoint, expect: Data?)? {
        guard case .request(let from, let to)? = plan, let endpoint = LinkRequest.endpoint(address) else { return nil }
        let other = node(to)
        return (from, other?.displayName ?? endpoint.host, endpoint, other?.serverPin)
    }

    private func startRequest() {
        guard let target = requestTarget else { return }
        linked.startRequest(from: target.from, otherName: target.otherName, endpoint: target.endpoint,
                            expect: target.expect)
    }

    @ViewBuilder
    private func requestProgress(_ request: LinkedServersModel.RequestAttempt) -> some View {
        let from = name(request.from)
        let other = request.otherName
        if let failure = request.failure {
            Callout(tone: .danger, systemImage: "xmark.octagon") {
                Text("\(from) didn't send the request.")
                    .fontWeight(.medium)
                Text(failure)
                    .foregroundStyle(.fgMuted)
                    .textSelection(.enabled)
            }
        } else {
            switch request.phase {
            case .connecting:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("\(from) is reaching \(other) at \(request.endpoint.host):\(request.endpoint.port)…")
                        .foregroundStyle(.fgSubtle)
                }
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            case .awaitingApproval(let code):
                waiting(code: code, from: request.from, other: other)
            case .linked:
                Callout(tone: .ok, systemImage: "checkmark.circle") {
                    Text("\(from) and \(other) are linked.")
                        .fontWeight(.medium)
                    Text("\(other)'s admin approved the code. The two connect on their own; the link shows under Linked servers in All Nodes.")
                        .foregroundStyle(.fgMuted)
                }
            case .noWindow:
                Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                    Text(ServerLinking.Failure.noWindow(other))
                }
            case .denied:
                outcome("\(other) declined the request, or a different code was picked there. Nothing was linked.")
            case .expired:
                outcome("The request expired before \(other) approved it. Nothing was linked.")
            case .cancelled:
                outcome("Cancelled. Nothing was linked.", tone: .unknown)
            case .failed(let text):
                outcome("\(from) couldn't link with \(other): \(text)")
            }
        }
    }

    private func outcome(_ text: String, tone: StatusTone = .danger) -> some View {
        Callout(tone: tone, systemImage: tone == .danger ? "xmark.octagon" : "info.circle") {
            Text(text).textSelection(.enabled)
        }
    }

    private func waiting(code: String, from: NodeID, other: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Read this to \(other)'s admin")
                .font(.headline)
                .foregroundStyle(.fg)
            VStack(alignment: .leading, spacing: 4) {
                Text("Code").font(.caption).foregroundStyle(.fgSubtle)
                Text(LinkRequest.spaced(code))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.fg)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(name(from))'s key").font(.caption).foregroundStyle(.fgSubtle)
                Text(node(from)?.serverPin.map { DeviceFormat.grouped(DeviceFormat.hex($0)) } ?? "not pinned")
                    .font(.callout.monospaced())
                    .foregroundStyle(.fgMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("On \(other), the admin finds the request from \(name(from)) under Accept a link, checks that its key matches, and picks this code. If no request there shows this code, they deny it.")
                .font(.callout)
                .foregroundStyle(.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for \(other)'s admin to approve…")
                    .foregroundStyle(.fgSubtle)
            }
        }
    }

    // MARK: Progress and result

    @ViewBuilder
    private func progress(_ attempt: LinkedServersModel.Attempt) -> some View {
        switch attempt.outcome {
        case nil:
            spinner(text(attempt.step))
        case .success(let done)?:
            VStack(alignment: .leading, spacing: 10) {
                Callout(tone: .ok, systemImage: "checkmark.circle") {
                    Text("\(name(done.dialler)) and \(name(done.acceptor)) are linked.")
                        .fontWeight(.medium)
                    Text("\(name(done.dialler)) dialled \(name(done.acceptor)). The connection shows under Linked servers in All Nodes.")
                        .foregroundStyle(.fgMuted)
                }
                if attempt.settingRoles {
                    spinner("Setting the default roles…")
                }
                ForEach(attempt.roles) { applied in
                    switch applied.outcome {
                    case .refused:
                        Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                            Text("The role wasn't set on \(applied.nodeName).")
                                .fontWeight(.medium)
                            Text(applied.description)
                                .foregroundStyle(.fgMuted)
                                .textSelection(.enabled)
                        }
                    default:
                        Callout(tone: .ok, systemImage: "person.badge.key") {
                            Text(applied.description)
                        }
                    }
                }
            }
        case .failure(.halfLinked(let half))?:
            Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                Text(half.description)
                Button("Unlink on \(half.nodeName)") { Task { await linked.unlink(half) } }
                    .controlSize(.small)
                    .disabled(linked.working.contains(half.id))
            }
        case .failure(let failure)?:
            Callout(tone: .danger, systemImage: "xmark.octagon") {
                Text("\(name(attempt.first)) and \(name(attempt.second)) weren't linked.")
                    .fontWeight(.medium)
                Text(markdown(failure.description))
                    .foregroundStyle(.fgMuted)
                    .textSelection(.enabled)
            }
        }
    }

    private func spinner(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
                .foregroundStyle(.fgSubtle)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }

    private func text(_ step: ServerLinking.Step) -> String {
        switch step {
        case .checking: "Checking both servers…"
        case .connecting(let dialler, let acceptor): "\(dialler) is reaching \(acceptor)…"
        case .approving: "Comparing the code and approving…"
        case .finishing: "Waiting for both servers to record the link…"
        case .cleaningUp: "Undoing what was started…"
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    @ViewBuilder
    private var buttons: some View {
        if let attempt = linked.attempt {
            if attempt.isRunning {
                Button("Cancel") { linked.cancelLinking() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(attempt.outcome != nil)
            } else {
                if case .failure(let failure)? = attempt.outcome, !isFinal(failure) {
                    Button("Try Again") { linked.clearAttempt() }
                }
                done
            }
        } else if let request = linked.request {
            if request.isRunning {
                Button("Cancel Request") { linked.cancelRequest() }
                    .keyboardShortcut(.cancelAction)
            } else {
                if request.phase != .linked {
                    Button("Try Again") { linked.clearRequest() }
                }
                done
            }
        } else {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            switch plan {
            case .request?:
                Button("Request a Link") { startRequest() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(requestTarget == nil)
            default:
                Button("Link") {
                    if let first, let second = secondNode { linked.startLinking(first, second, roles: roles) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(plan != .handshake || !rolesReady)
            }
        }
    }

    private var done: some View {
        Button("Done") {
            linked.clearAttempt()
            linked.clearRequest()
            dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
    }

    private func isFinal(_ failure: ServerLinking.Failure) -> Bool {
        switch failure {
        case .alreadyLinked, .sameServer: true
        default: false
        }
    }

    #if DEBUG
    /// `-VHDebugLinkStart YES`: press Link or Request a Link once the sheet is ready, for a picture of what follows.
    private func debugStart() async {
        guard UserDefaults.standard.bool(forKey: "VHDebugLinkStart") else { return }
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(100))
            switch plan {
            case .handshake? where rolesReady && (UserDefaults.standard.string(forKey: "VHDebugLinkRole") == nil || !roles.isEmpty):
                if let first, let second = secondNode { linked.startLinking(first, second, roles: roles) }
                return
            case .request? where requestTarget != nil:
                startRequest()
                return
            default: continue
            }
        }
    }
    #endif
}
