import AppKit
import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// The devices paired with this node: the signed-in account's own (`device.list`), with this Mac marked and its own
/// key details on top; for super admins also every user's devices and the device listener's remote connections.
/// Any account can open a pairing window here and approve another Mac by number matching. The daemon decides who
/// may do what: the super-admin parts appear only once the node answers them.
struct DevicesView: View {
    var node: Node

    @Environment(AppModel.self) private var model

    var body: some View {
        if let queries = model.liveQueries(for: node) {
            DevicesScreen(node: node, queries: queries)
                .environment(queries)
        } else {
            PlaceholderSection(node: node, section: .devices)
        }
    }
}

private struct DevicesScreen: View {
    var node: Node
    var queries: NodeQueries

    enum Scope: String, Hashable {
        case mine
        case all
    }

    @Environment(AppModel.self) private var model
    @State private var scope = Scope.mine
    @State private var pairing = false

    var body: some View {
        // The listener's status is for super admins only (ops::devices requireSuperAdmin): its answer is how this
        // screen learns whether to offer every user's devices. A refusal just leaves them out.
        let remote = queries.query(Ws.Device.Remote.Status.self)
        let isSuperAdmin = remote.value != nil
        let shown = isSuperAdmin ? scope : .mine
        let list = queries.query(Ws.Device.List.self, .init(all: shown == .all ? true : nil))

        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(eyebrow: node.displayName, title: "Devices",
                          subtitle: "Vaulthalla Desktop on your Macs. A paired device acts as the account that paired it, with that account's permissions.") {
                HStack(spacing: 10) {
                    let status = model.status(for: node)
                    StatusBadge(label: status.label, tone: status.tone, pulse: status.isTransitional)
                    Button("Pair a Device…", systemImage: "plus") { pairing = true }
                        .buttonStyle(.borderedProminent)
                        .help("Open a pairing window on \(node.displayName) and approve another Mac")
                }
            }
            .padding([.horizontal, .top], Theme.pagePadding)
            .padding(.bottom, 16)

            if isSuperAdmin {
                Picker("Devices", selection: $scope) {
                    Text("Your Devices").tag(Scope.mine)
                    Text("All Devices").tag(Scope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 16)
            }

            switch shown {
            case .mine:
                ThisMacPanel(node: node, queries: queries)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 16)
            case .all:
                RemoteConnectionsPanel(query: remote, queries: queries)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.bottom, 16)
            }

            DeviceListContent(node: node, queries: queries, list: list, showsOwner: shown == .all)
        }
        .observing(remote, polling: .seconds(30))
        .observing(list)
        .sheet(isPresented: $pairing) {
            PairDeviceSheet(node: node, queries: queries)
        }
        #if DEBUG
        .task { await debugSetup() }
        #endif
    }

    #if DEBUG
    /// `-VHDebugDevicesScope all` shows every user's devices; `-VHDebugDevicesPair YES` opens the pairing sheet
    /// (DebugSnapshot).
    private func debugSetup() async {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "VHDebugDevicesScope") == "all" {
            let remote = queries.query(Ws.Device.Remote.Status.self)
            while remote.value == nil, remote.error == nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            scope = .all
        }
        if defaults.bool(forKey: "VHDebugDevicesPair") { pairing = true }
    }
    #endif
}

/// The device list in its query states.
private struct DeviceListContent: View {
    var node: Node
    var queries: NodeQueries
    var list: NodeQuery<Ws.Device.List>
    var showsOwner: Bool

    var body: some View {
        switch list.state {
        case .idle, .loading:
            LoadingPanel(subject: "devices")
                .padding(.horizontal, Theme.pagePadding)
            Spacer(minLength: 0)
        case .failed(let error):
            ProblemPanel(problem: QueryProblem(error), node: node, subject: showsOwner ? "every user's devices" : "devices") {
                Task { await list.refresh() }
            }
            .padding(.horizontal, Theme.pagePadding)
            Spacer(minLength: 0)
        case .loaded(let value, let at):
            StaleBanner(node: node, updatedAt: at, refreshError: list.refreshError, connected: queries.isConnected)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 12)
            if value.devices.isEmpty {
                Panel {
                    EmptyState(
                        showsOwner ? "No device is paired with \(node.displayName)" : "No paired devices",
                        systemImage: "laptopcomputer.and.iphone",
                        message: showsOwner
                            ? "Devices appear here once someone pairs Vaulthalla Desktop with this node."
                            : "The node lists no device for the account this Mac acts for."
                    )
                }
                .padding(.horizontal, Theme.pagePadding)
                Spacer(minLength: 0)
            } else {
                DeviceTable(node: node, queries: queries, devices: value.devices, showsOwner: showsOwner)
            }
        }
    }
}

// MARK: - Shared helpers

/// How the Devices screens name things, as the web console does (features/devices/model.ts).
nonisolated enum DeviceFormat {
    /// Copies `text` to the pasteboard.
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "482913" → "482 913", the way the Mac shows it (pairing.md §3). Anything else is shown as sent.
    static func code(_ code: String) -> String {
        guard code.count == 6, code.allSatisfy(\.isASCII), code.allSatisfy(\.isNumber) else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    /// The first 12 hex digits of a device id: enough to tell devices apart and to type into `vh device revoke`.
    static func shortID(_ deviceID: String) -> String {
        String(deviceID.prefix(12))
    }

    /// A key fingerprint in groups of four for comparing by eye.
    static func grouped(_ hex: String) -> String {
        var groups: [Substring] = []
        var rest = Substring(hex)
        while !rest.isEmpty {
            groups.append(rest.prefix(4))
            rest = rest.dropFirst(4)
        }
        return groups.joined(separator: " ")
    }

    /// The first 32 hex digits in groups, marked as cut when there is more.
    static func abbreviated(_ hex: String) -> String {
        hex.count > 32 ? grouped(String(hex.prefix(32))) + " …" : grouped(hex)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func label(_ name: String) -> String {
        name.isEmpty ? "Unnamed device" : name
    }

    /// Epoch seconds as a date and time.
    static func moment(epoch seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .shortened)
    }

    static func platform(_ platform: String, appVersion: String?) -> String {
        [platform.isEmpty ? "Unknown platform" : platform, appVersion.flatMap { $0.isEmpty ? nil : "Desktop \($0)" }]
            .compactMap(\.self).joined(separator: " · ")
    }
}


#if DEBUG
#Preview("Devices (preview data)") {
    let model = PreviewSamples.liveModel()
    DevicesView(node: PreviewSamples.nodes[1])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1100, height: 720)
}

#Preview("Not a super admin (preview data)") {
    let model = PreviewSamples.liveModel()
    DevicesView(node: PreviewSamples.nodes[3])
        .environment(model)
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .frame(width: 1000, height: 640)
}
#endif
