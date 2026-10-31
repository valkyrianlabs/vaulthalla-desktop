import AppKit
import SwiftUI
import VHCore
import VHNodes

/// Adds a node (discovered on the network, typed in, or from a `vaulthalla://pair` link), then explains pairing.
/// Opening it for an existing node goes straight to the pairing step.
struct AddNodeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step
    @State private var browser = BonjourBrowser()
    @State private var address = ""
    @State private var name = ""
    @State private var pickedServerID: DiscoveredServer.ID?
    /// The pairing link this sheet was opened from (untrusted), and what probing its endpoints found.
    @State private var link: PairLink?
    @State private var linkProbe: EndpointSelection?

    private enum Step: Equatable {
        case choose
        case pair(NodeID)
    }

    init(start: AppModel.Sheet) {
        switch start {
        case .addNode:
            _step = State(initialValue: .choose)
        case .addNodeFromLink(let link):
            _step = State(initialValue: .choose)
            _link = State(initialValue: link)
            _address = State(initialValue: link.endpoints.first?.description ?? "")
        case .pairing(let id):
            _step = State(initialValue: .pair(id))
        }
    }

    var body: some View {
        Group {
            switch step {
            case .choose:
                chooseStep
            case .pair(let id):
                if let node = model.node(withID: id) {
                    PairingStepView(node: node) { dismiss() }
                } else {
                    // The node was removed while the sheet was up.
                    EmptyState("This node is gone", systemImage: "questionmark.circle")
                        .toolbar { Button("Close") { dismiss() } }
                }
            }
        }
        .frame(width: 560)
        .background(Color.canvasRaised)
        .preferredColorScheme(.dark)
        .tint(.accentFill)
    }

    // MARK: - Choose

    private var chooseStep: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "server.rack",
                title: "Add a Node",
                subtitle: link == nil ? "Pick a Vaulthalla server on this network, or enter its address."
                    : "From a pairing link. Check the address, then pair with the code."
            )

            Form {
                if let link {
                    Section {
                        PairLinkSummary(link: link, probe: linkProbe)
                    } header: {
                        HStack {
                            Text("From the Pairing Link")
                            Spacer()
                            if linkProbe == nil {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                } else {
                    Section {
                        DiscoveredServerList(browser: browser, pickedID: pickedServerID,
                                             existingNode: existingNode(for:)) { server in
                            pick(server)
                        }
                    } header: {
                        HStack {
                            Text("On This Network")
                            Spacer()
                            if browser.status == .browsing {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                }

                Section {
                    TextField("Address", text: $address, prompt: Text("vh-storage.local or 10.0.0.33"))
                        .autocorrectionDisabled()
                        .onSubmit(continueIfValid)
                    TextField("Name", text: $name, prompt: Text(namePlaceholder))
                        .onSubmit(continueIfValid)
                } header: {
                    Text("Or Enter an Address")
                } footer: {
                    addressFooter
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            SheetFooter {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: continueIfValid)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(validation.endpoint == nil)
            }
        }
        .onAppear { if link == nil { browser.start() } }
        .onDisappear { browser.stop() }
        .task(id: link) {
            // Probe the link's endpoints with its server key and prefill the best verified one.
            guard let link else { return }
            let found = await link.probe()
            linkProbe = found
            if let best = found.chosen?.candidate.endpoint,
               address.isEmpty || address == link.endpoints.first?.description {
                address = best.description
            }
        }
        .onChange(of: address) { _, text in
            // Typing over a picked server's address makes it a manual entry.
            if let picked = pickedServer, picked.endpoint?.description != text { pickedServerID = nil }
        }
        .onChange(of: browser.servers) { _, servers in
            // A picked server that resolves after the click fills in then.
            if let id = pickedServerID, let server = servers.first(where: { $0.id == id }), let endpoint = server.endpoint,
               address.isEmpty {
                address = endpoint.description
            }
        }
    }

    @ViewBuilder
    private var addressFooter: some View {
        if let error = validation.error {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(StatusTone.danger.color)
                .font(.callout)
        } else {
            Text("Without a port, Desktop uses \(String(NodeEndpoint.defaultDevicePort)), the Vaulthalla device port.")
                .foregroundStyle(.fgSubtle)
                .font(.callout)
        }
    }

    private var pickedServer: DiscoveredServer? {
        pickedServerID.flatMap { id in browser.servers.first { $0.id == id } }
    }

    private var namePlaceholder: String {
        pickedServer?.displayName ?? validation.endpoint?.host ?? "Optional"
    }

    private func pick(_ server: DiscoveredServer) {
        pickedServerID = server.id
        address = server.endpoint?.description ?? ""
        if name.isEmpty || browser.servers.contains(where: { $0.displayName == name }) {
            name = server.displayName
        }
    }

    /// The saved node a discovered server already is: same address, or the same server install id (TXT `node_id`).
    private func existingNode(for server: DiscoveredServer) -> Node? {
        model.existingNode(at: server.endpoint, serverNodeID: server.nodeID)
    }

    private var validation: (endpoint: NodeEndpoint?, error: String?) {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, nil) }
        guard let endpoint = NodeEndpoint(parsing: text), !endpoint.host.contains(where: \.isWhitespace) else {
            return (nil, "Enter a host name or IP address, optionally with a port, like vh-storage.local:36972.")
        }
        if let existing = model.existingNode(at: endpoint, serverNodeID: pickedServer?.nodeID ?? link?.nodeID) {
            return (nil, "This Mac already has \(endpoint.description) as “\(existing.displayName)”.")
        }
        return (endpoint, nil)
    }

    private func continueIfValid() {
        guard let endpoint = validation.endpoint else { return }
        let displayName = name.isEmpty ? (pickedServer?.displayName ?? endpoint.host) : name
        // A name filled in from discovery is the server's own; only a typed one is kept over the paired server's.
        let typed = !name.isEmpty && !browser.servers.contains { $0.displayName == name }
        let hint = link.map { AppModel.PairingHint(serverSPKISHA256: $0.serverSPKISHA256, serverNodeID: $0.nodeID) }
        guard let node = model.addNode(displayName: displayName, endpoint: endpoint, namedByUser: typed,
                                       endpoints: link?.advertisedEndpoints ?? [], hint: hint)
        else { return }
        browser.stop()
        withAnimation(.snappy) { step = .pair(node.id) }
    }
}

// MARK: - Pairing link

/// What a pairing link carries and what probing its endpoints showed, in plain words.
private struct PairLinkSummary: View {
    var link: PairLink
    var probe: EndpointSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let probe {
                if let chosen = probe.chosen {
                    Label(verifiedLine(chosen), systemImage: "checkmark.seal")
                        .foregroundStyle(StatusTone.ok.color)
                } else if probe.reports.contains(where: { $0.outcome == .identityMismatch }) {
                    Label("A different server answered at the link's addresses. Pairing with it will be refused.",
                          systemImage: "exclamationmark.shield")
                        .foregroundStyle(StatusTone.danger.color)
                } else {
                    Label("None of the link's addresses answered from this Mac. Check the address below.",
                          systemImage: "wifi.exclamationmark")
                        .foregroundStyle(StatusTone.warn.color)
                }
            } else {
                Text("Checking the link's \(link.endpoints.count) address\(link.endpoints.count == 1 ? "" : "es")…")
                    .foregroundStyle(.fgMuted)
            }
            Text(link.serverSPKISHA256 == nil
                 ? "The link names no server key, so compare the code carefully when pairing."
                 : "Pairing will only talk to the server key the link names (\(link.serverSPKISHA256?.shortFingerprint ?? "")). The code still decides.")
                .font(.caption)
                .foregroundStyle(.fgSubtle)
        }
        .font(.callout)
        .padding(.vertical, 2)
    }

    private func verifiedLine(_ chosen: EndpointSelection.Report) -> String {
        let key = link.serverSPKISHA256 == nil ? "A Vaulthalla server answered" : "The server's key checks out"
        return "\(key) at \(chosen.candidate.endpoint.description) (\(chosen.transportClass.displayName))."
    }
}

// MARK: - Discovery list

private struct DiscoveredServerList: View {
    var browser: BonjourBrowser
    var pickedID: DiscoveredServer.ID?
    var existingNode: (DiscoveredServer) -> Node?
    var pick: (DiscoveredServer) -> Void

    var body: some View {
        switch browser.status {
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Label("Vaulthalla can't see your local network", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(StatusTone.warn.color)
                    .font(.callout.weight(.medium))
                Text("Allow it in System Settings → Privacy & Security → Local Network, or enter the server's address below.")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                Button("Open Privacy Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        case .failed(let message):
            Label("Discovery isn't working: \(message)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.fgSubtle)
                .font(.callout)
        case .idle, .browsing:
            if browser.servers.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "bonjour")
                        .foregroundStyle(.accentText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Looking for Vaulthalla servers…")
                            .foregroundStyle(.fgMuted)
                        Text("Servers that advertise themselves on this network appear here.")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }
                .padding(.vertical, 2)
            } else {
                ForEach(browser.servers) { server in
                    row(server)
                }
            }
        }
    }

    private func row(_ server: DiscoveredServer) -> some View {
        let existing = existingNode(server)
        return Button {
            pick(server)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.accentText)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.displayName)
                        .foregroundStyle(.fg)
                    Text(hostLine(server))
                        .font(.caption)
                        .fontDesign(server.endpoint == nil ? .default : .monospaced)
                        .foregroundStyle(.fgSubtle)
                }
                Spacer()
                if let existing {
                    Text("Added as \(existing.displayName)")
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                } else if pickedID == server.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.accentFill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(existing != nil)
    }

    private func hostLine(_ server: DiscoveredServer) -> String {
        if let endpoint = server.endpoint { return endpoint.description }
        return server.isResolving ? "Resolving address…" : "Address unavailable; enter it below"
    }
}

// MARK: - Sheet chrome

struct SheetHeader: View {
    var systemImage: String
    var title: String
    var subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(.accentText)
                .frame(width: 40, height: 40)
                .background(.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.accentLine, lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.fg)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 6)
    }
}

struct SheetFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            content
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Divider().overlay(Color.line) }
    }
}

#if DEBUG
#Preview("Add node") {
    AddNodeSheet(start: .addNode)
        .environment(PreviewSamples.model())
}
#endif
