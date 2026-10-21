import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Super admins: where the device listener (Vaulthalla Desktop's mutual-TLS endpoint) listens. Off = loopback only;
/// on = every interface. The port comes from the daemon (`device_server.port`), never from here.
struct RemoteConnectionsPanel: View {
    var query: NodeQuery<Ws.Device.Remote.Status>
    var queries: NodeQueries

    typealias Status = Ws.Device.Remote.Status.Response.Status

    @State private var asking: Bool?
    @State private var enable: NodeMutation<Ws.Device.Remote.Enable>
    @State private var disable: NodeMutation<Ws.Device.Remote.Disable>

    init(query: NodeQuery<Ws.Device.Remote.Status>, queries: NodeQueries) {
        self.query = query
        self.queries = queries
        _enable = State(initialValue: NodeMutation(Ws.Device.Remote.Enable.self, on: queries,
                                                   invalidating: ["device.remote.status"]))
        _disable = State(initialValue: NodeMutation(Ws.Device.Remote.Disable.self, on: queries,
                                                    invalidating: ["device.remote.status"]))
    }

    var body: some View {
        Panel(title: "Remote connections",
              subtitle: "Whether Vaulthalla Desktop on other machines can reach this server to pair and connect.") {
            InlineQuery(query: query, subject: "the device listener") { response in
                content(response.status)
            }
        } actions: {
            if let status = query.value?.status {
                listenerBadge(status)
            }
        }
        .confirmationDialog(asking == true ? "Allow remote connections?" : "Turn off remote connections?",
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible, presenting: asking) { on in
            if on {
                Button("Allow") { Task { await enable.run(WsNoPayload()) } }
            } else {
                Button("Turn Off", role: .destructive) { Task { await disable.run(WsNoPayload()) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { on in
            if on {
                Text("Macs on your network can pair and reconnect over port \(query.value.map { String($0.status.port) } ?? "the listener's port")/tcp. Every connection still needs a paired key, but make sure that port is reachable only from networks you trust.")
            } else {
                Text("Only this machine can pair and connect. Devices connected from other machines disconnect now, this Mac too if it is one of them; they reconnect when you turn this back on.")
            }
        }
    }

    private func content(_ status: Status) -> some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { status.remote }, set: { asking = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow remote connections")
                            .foregroundStyle(.fg)
                        Text(status.remote ? "On: Macs on your network can pair and reconnect." : "Off: only this machine can pair and connect.")
                            .font(.caption)
                            .foregroundStyle(.fgSubtle)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!status.enabled || enable.isRunning || disable.isRunning)

                MutationError(error: enable.error ?? disable.error)

                if let error = status.error, !error.isEmpty {
                    Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                        Text("\(error). The daemon retries every 30 seconds; nothing else is affected.")
                    }
                }

                Text("The server key fingerprint is what Desktop pins when it pairs. If it ever changes, every device has to pair again.\(status.enabled ? "" : " The listener is turned off in config.yaml (device_server.enabled).")")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .lineLimit(3)
            }
            .frame(width: 340, alignment: .leading)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Bind address", status.address ?? (status.remote ? "All interfaces" : "Loopback only"), mono: true)
                row("Port", String(status.port))
                row("Connections", String(status.connections))
                GridRow {
                    Text("Server key")
                        .foregroundStyle(.fgSubtle)
                    if let key = status.serverSpkiSha256 {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(DeviceFormat.abbreviated(key))
                                .fontDesign(.monospaced)
                                .foregroundStyle(.fg)
                                .lineLimit(1)
                                .help(DeviceFormat.grouped(key))
                            Button("Copy fingerprint", systemImage: "doc.on.doc") { DeviceFormat.copy(key) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Copy the full fingerprint")
                        }
                    } else {
                        Text("Not created yet")
                            .foregroundStyle(.fgSubtle)
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ term: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(term)
                .foregroundStyle(.fgSubtle)
            Text(value)
                .fontDesign(mono ? .monospaced : .default)
                .foregroundStyle(.fg)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func listenerBadge(_ status: Status) -> some View {
        if !status.enabled {
            StatusBadge(label: "Turned off", tone: .unknown)
        } else if status.listening {
            StatusBadge(label: "Listening", tone: .ok)
        } else {
            StatusBadge(label: "Not listening", tone: .danger)
        }
    }
}
