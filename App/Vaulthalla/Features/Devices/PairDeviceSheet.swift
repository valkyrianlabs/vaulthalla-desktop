import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Approve another Mac by number matching (pairing.md §3), as the web console's PairDeviceDialog does. Opening the
/// sheet opens this account's pairing window on the node; requests from Vaulthalla Desktop appear with three codes,
/// one of them the code the other Mac shows. Clicking the matching one approves it, any other declines it (the
/// daemon decides; the real code never reaches this Mac). Closing the sheet closes the window.
struct PairDeviceSheet: View {
    var node: Node
    var queries: NodeQueries

    private enum Phase {
        case opening
        case open
        /// Another user's window is open.
        case conflict(String)
        case failed(WsError)
    }

    private struct Notice {
        var tone: StatusTone
        var text: String
    }

    private static let wrongCode = "That code didn't match, so the request was declined. Start pairing again on the Mac."
    private static let expiredRequest = "That request expired before it was approved. Start pairing again on the Mac."

    @State private var phase = Phase.opening
    @State private var window: Ws.Device.Pairing.Open.Response.Window?
    @State private var listener: (port: Int64, remote: Bool)?
    /// The node's clock minus this Mac's when the window was opened: the countdown never trusts the local clock.
    @State private var skew: TimeInterval = 0
    @State private var openedAt = Date.distantPast
    /// Whether this sheet opened the window it shows: only then does closing the sheet close it.
    @State private var owns = false
    @State private var paired: WsModel.Device?
    @State private var notice: Notice?
    @State private var busy: String?
    /// Requests this sheet approved, declined or saw expire: hidden at once, before the next poll drops them.
    @State private var handled: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let pending = queries.query(Ws.Device.Pairing.Pending.self)

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.accentText)
                    .frame(width: 38, height: 38)
                    .background(.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pair a Device")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                    Text("Approve Vaulthalla Desktop on another Mac by matching the code it shows. It pairs with the account this Mac acts for on \(node.displayName).")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content(pending)

            HStack {
                if case .open = phase, paired == nil, let window, !isExpired(window) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label {
                            Text("Pairing stays open for \(Text(remaining(window, now: context.date)).monospacedDigit().foregroundStyle(.fg))")
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                    }
                }
                Spacer()
                if paired == nil {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 620)
        .task { await open() }
        .task(id: isPolling) {
            guard isPolling else { return }
            await pending.observe(polling: .seconds(2))
        }
        .onChange(of: pending.updatedAt) { _, _ in
            // The poll carries the window too: a reopen from the CLI extends it, a super admin may close it.
            guard let answer = pending.value, let at = pending.updatedAt, at >= openedAt else { return }
            if let live = answer.window {
                window = .init(ownerID: live.ownerID, openedAt: live.openedAt, expiresAt: live.expiresAt)
            } else {
                window = nil
            }
            skew = TimeInterval(answer.serverTime) - at.timeIntervalSince1970
        }
        .onDisappear { close() }
    }

    private var isPolling: Bool {
        if case .open = phase, paired == nil { return true }
        return false
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ pending: NodeQuery<Ws.Device.Pairing.Pending>) -> some View {
        switch phase {
        case .opening:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Opening a pairing window…")
                    .foregroundStyle(.fgSubtle)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
        case .conflict(let detail):
            EmptyState("Someone else is pairing a device", systemImage: "clock",
                       message: "Another user on \(node.displayName) has pairing open, and only one window can be open at a time. Try again when they're done.\(detail.isEmpty ? "" : "\n\n\(detail)")") {
                Button("Try Again") { Task { await open() } }
            }
            .frame(maxWidth: .infinity)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 12) {
                if case .denied = error {
                    EmptyState("You can't pair devices on \(node.displayName)", systemImage: "lock",
                               message: "\(error.message) Pairing is managed on the node.")
                        .frame(maxWidth: .infinity)
                } else {
                    MutationError(error: error)
                    Button("Try Again") { Task { await open() } }
                }
            }
        case .open:
            if let paired {
                success(paired)
            } else if let window, !isExpired(window) {
                openWindow(pending)
            } else {
                EmptyState("The pairing window closed", systemImage: "clock",
                           message: "Requests that weren't approved expired with it. Open it again to keep pairing.") {
                    Button("Open Again") {
                        handled = []
                        notice = nil
                        Task { await open() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func openWindow(_ pending: NodeQuery<Ws.Device.Pairing.Pending>) -> some View {
        let fresh = (pending.updatedAt ?? .distantPast) >= openedAt ? pending.value : nil
        let requests = (fresh?.requests ?? []).filter { !handled.contains($0.requestID) }
        return VStack(alignment: .leading, spacing: 14) {
            instructions

            if let notice {
                Callout(tone: notice.tone, systemImage: notice.tone == .danger ? "exclamationmark.triangle" : "info.circle") {
                    Text(notice.text)
                }
            }
            if fresh == nil, let error = pending.error {
                InlineProblem(error: error, subject: "pairing requests")
            }

            if requests.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for a request from Vaulthalla Desktop…")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 22)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .strokeBorder(Color.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            } else {
                ForEach(requests, id: \.requestID) { request in
                    requestCard(request)
                }
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            step(1, "On the other Mac, add \(node.displayName) in Vaulthalla Desktop and choose Pair.",
                 detail: listener.map { "Server: \(host):\($0.port)" })
            step(2, "It shows a six-digit code. Click the same code on its request below.")
            step(3, "A wrong code declines the request, so compare before you click.")
            if let listener, !listener.remote, !isLoopback {
                Label("Remote connections are off, so only Vaulthalla Desktop on the server itself can pair. A super admin can turn them on under All Devices.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(StatusTone.warn.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(.line, lineWidth: 1)
        }
    }

    private func step(_ number: Int, _ text: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .foregroundStyle(.fgSubtle)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .foregroundStyle(number == 1 ? Color.fg : Color.fgMuted)
                if let detail {
                    Text(detail)
                        .font(.callout.monospaced())
                        .foregroundStyle(.fgMuted)
                        .textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func requestCard(_ request: Ws.Device.Pairing.Pending.Response.Request) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.name)
                        .font(.headline)
                        .foregroundStyle(.fg)
                        .lineLimit(1)
                    Text("\(DeviceFormat.platform(request.platform, appVersion: request.appVersion)) · from \(request.sourceIP) · device \(DeviceFormat.shortID(request.deviceID))")
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                        .help(request.deviceID)
                }
                Spacer()
                Button("Deny", systemImage: "xmark") { Task { await deny(request) } }
                    .controlSize(.small)
                    .disabled(busy != nil)
            }
            Text("Which code does the Mac show?")
                .font(.callout)
                .foregroundStyle(.fgMuted)
            HStack(spacing: 10) {
                ForEach(request.codeChoices, id: \.self) { code in
                    Button {
                        Task { await approve(request, code: code) }
                    } label: {
                        Text(DeviceFormat.code(code))
                            .font(.system(size: 26, weight: .medium, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(.fg)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CodeButtonStyle())
                    .disabled(busy != nil)
                    .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                }
            }
            if busy == request.requestID {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking…")
                }
                .font(.caption)
                .foregroundStyle(.fgSubtle)
            }
        }
        .padding(16)
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(.line, lineWidth: 1)
        }
    }

    private func success(_ device: WsModel.Device) -> some View {
        EmptyState("Paired", systemImage: "checkmark.circle",
                   message: "“\(DeviceFormat.label(device.name))” is now paired with your account. Vaulthalla Desktop on that Mac finishes connecting on its own.") {
            Button("Pair Another Device") { paired = nil }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private func open() async {
        phase = .opening
        let result = await queries.perform(Ws.Device.Pairing.Open.self, WsNoPayload())
        switch result {
        case .success(let opened):
            owns = true
            openedAt = .now
            skew = TimeInterval(opened.serverTime) - Date.now.timeIntervalSince1970
            listener = (opened.port, opened.remote)
            window = opened.window
            phase = .open
        case .failure(.conflict(let message)):
            phase = .conflict(message)
        case .failure(let error):
            phase = .failed(error)
        case .needsConfirmation(let request):
            phase = .failed(.error(request.message))
        }
    }

    private func close() {
        guard owns else { return }
        owns = false
        let queries = queries
        Task { _ = await queries.perform(Ws.Device.Pairing.Close.self, .init()) }
    }

    private func approve(_ request: Ws.Device.Pairing.Pending.Response.Request, code: String) async {
        busy = request.requestID
        notice = nil
        defer { busy = nil }
        let result = await queries.perform(Ws.Device.Pairing.Approve.self, .init(requestID: request.requestID, code: code),
                                           invalidating: ["device.list"])
        switch result {
        case .success(let answer):
            handled.insert(request.requestID)
            paired = answer.device
        case .failure(.invalid):
            handled.insert(request.requestID)
            notice = Notice(tone: .danger, text: Self.wrongCode)
        case .failure(.notFound):
            handled.insert(request.requestID)
            notice = Notice(tone: .danger, text: Self.expiredRequest)
        case .failure(let error):
            notice = Notice(tone: .danger, text: "The request was not approved: \(error.message)")
        case .needsConfirmation(let confirmation):
            notice = Notice(tone: .danger, text: confirmation.message)
        }
        await queries.query(Ws.Device.Pairing.Pending.self).refresh()
    }

    private func deny(_ request: Ws.Device.Pairing.Pending.Response.Request) async {
        busy = request.requestID
        notice = nil
        defer { busy = nil }
        switch await queries.perform(Ws.Device.Pairing.Deny.self, .init(requestID: request.requestID)) {
        case .success:
            handled.insert(request.requestID)
            notice = Notice(tone: .info, text: "Declined the request from \(request.name).")
        case .failure(.notFound):
            handled.insert(request.requestID)
        case .failure(let error):
            notice = Notice(tone: .danger, text: "The request was not declined: \(error.message)")
        case .needsConfirmation(let confirmation):
            notice = Notice(tone: .danger, text: confirmation.message)
        }
        await queries.query(Ws.Device.Pairing.Pending.self).refresh()
    }

    // MARK: Time

    private func isExpired(_ window: Ws.Device.Pairing.Open.Response.Window) -> Bool {
        TimeInterval(window.expiresAt) <= Date.now.timeIntervalSince1970 + skew
    }

    private func remaining(_ window: Ws.Device.Pairing.Open.Response.Window, now: Date) -> String {
        let seconds = max(0, Int(TimeInterval(window.expiresAt) - (now.timeIntervalSince1970 + skew)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Address

    /// The address this Mac reaches the node at: the one to type on the other Mac when it's on the same network.
    private var host: String {
        node.endpoint.host.contains(":") ? "[\(node.endpoint.host)]" : node.endpoint.host
    }

    private var isLoopback: Bool {
        ["localhost", "127.0.0.1", "::1"].contains(node.endpoint.host.lowercased())
    }
}

/// The large number-matching buttons: a quiet surface that lights up on hover.
private struct CodeButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentSoft : (hovering ? Color.surface3 : Color.surface2),
                        in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous)
                    .strokeBorder(hovering || configuration.isPressed ? Color.accentLine : Color.lineStrong, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
    }
}
