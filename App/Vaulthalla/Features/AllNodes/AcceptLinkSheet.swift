import SwiftUI
import VHCore
import VHNodes

/// Accept a link request on a node where this Mac is a super admin, as the console's Accept a link: the node opens its
/// window (`peer.pairing.open`), lists the requests that reach it (`peer.pairing.pending`) with each requesting
/// server's key, and the person approves one by picking the code that server shows (`peer.pairing.approve`, accepting
/// only the key shown) or denies it. Closing the sheet closes the window.
struct AcceptLinkSheet: View {
    var node: NodeID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var linked: LinkedServersModel { model.linkedServers }
    private var name: String { model.node(withID: node)?.displayName ?? "This server" }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.accentText)
                    .frame(width: 38, height: 38)
                    .background(.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accept a Link Request")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                    Text("\(name) opens a window for another Vaulthalla server to ask. That server's admin starts the request there; you approve it here by picking the code it shows.")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let acceptance = linked.acceptance, acceptance.node == node {
                content(acceptance)
            } else {
                spinner("Opening a window for linking…")
            }

            HStack {
                Spacer()
                if case .busy? = linked.acceptance?.state {
                    Button("Try Again") { linked.openAcceptance(on: node) }
                } else if case .closed? = linked.acceptance?.state, !isLinked {
                    Button("Open Again") { linked.openAcceptance(on: node) }
                }
                Button(isLinked ? "Done" : "Close") {
                    linked.closeAcceptance()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 620)
        .onAppear { linked.openAcceptance(on: node) }
        .onDisappear { linked.closeAcceptance() }
    }

    private var isLinked: Bool {
        if case .linked? = linked.acceptance?.decision { true } else { false }
    }

    @ViewBuilder
    private func content(_ acceptance: LinkedServersModel.Acceptance) -> some View {
        switch acceptance.state {
        case .opening:
            spinner("Opening a window for linking…")
        case .busy:
            Callout(tone: .warn, systemImage: "exclamationmark.triangle") {
                Text("Another pairing window is open")
                    .fontWeight(.medium)
                Text("A device or a server is being paired on \(name), and only one window can be open at a time. Try again when it's done.")
                    .foregroundStyle(.fgMuted)
            }
        case .failed(let text):
            Callout(tone: .danger, systemImage: "xmark.octagon") {
                Text("\(name) didn't open a window for linking.")
                    .fontWeight(.medium)
                Text(text)
                    .foregroundStyle(.fgMuted)
                    .textSelection(.enabled)
            }
        case .closed:
            if case .linked(let other)? = acceptance.decision {
                Callout(tone: .ok, systemImage: "checkmark.circle") {
                    Text("Linked")
                        .fontWeight(.medium)
                    Text("\(other) is now linked with \(name). The two connect on their own.")
                        .foregroundStyle(.fgMuted)
                }
            } else {
                Callout(tone: .unknown, systemImage: "clock") {
                    Text("The window closed")
                        .fontWeight(.medium)
                    Text("Requests that weren't approved expired with it. Open it again to keep waiting.")
                        .foregroundStyle(.fgMuted)
                }
            }
        case .open(let window):
            open(window, acceptance)
        }
    }

    private func open(_ window: LinkAcceptance.Window, _ acceptance: LinkedServersModel.Acceptance) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                fact("This server") { Text(window.name).foregroundStyle(.fg) }
                fact("Key") {
                    Text(window.key.map { DeviceFormat.grouped(DeviceFormat.hex($0)) } ?? "unknown")
                        .font(.callout.monospaced())
                        .foregroundStyle(.fgMuted)
                        .textSelection(.enabled)
                }
                fact("Addresses") {
                    if window.addresses.isEmpty {
                        Text("\(name) advertises no address yet, so another server can reach it only by an address you give.")
                            .foregroundStyle(.fgSubtle)
                    } else {
                        Text(window.addresses.joined(separator: "\n"))
                            .font(.callout.monospaced())
                            .foregroundStyle(.fgMuted)
                            .textSelection(.enabled)
                    }
                }
                fact("Open until") {
                    Text(window.expiresAt.formatted(date: .omitted, time: .shortened)).foregroundStyle(.fgMuted)
                }
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                step(1, "On the other server, choose Linked servers › Link a server in its web console (or Request a Link in Vaulthalla Desktop) and give it one of the addresses above.")
                step(2, "It shows a six-digit code and its key. Check the key on its request below, then click the same code. A wrong code declines the request.")
            }
            .font(.callout)
            .foregroundStyle(.fgMuted)

            if let decision = acceptance.decision, let text = Self.text(decision) {
                Callout(tone: .warn, systemImage: "exclamationmark.triangle") { Text(text) }
            }
            if let problem = acceptance.problem {
                Callout(tone: .danger, systemImage: "xmark.octagon") { Text(problem).textSelection(.enabled) }
            }

            if acceptance.requests.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for another server to ask…")
                        .foregroundStyle(.fgSubtle)
                }
            } else {
                ForEach(acceptance.requests) { request in
                    requestRow(request, working: acceptance.working)
                }
            }
        }
    }

    private func requestRow(_ request: LinkAcceptance.Request, working: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(request.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(.fg)
                Text("from \(request.sourceIP)")
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                Spacer(minLength: 4)
                if working == request.id { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Key").font(.caption).foregroundStyle(.fgSubtle)
                Text(DeviceFormat.grouped(request.keyHex))
                    .font(.caption.monospaced())
                    .foregroundStyle(.fgMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Which code does the other server show?")
                .font(.callout)
                .foregroundStyle(.fgMuted)
            HStack(spacing: 8) {
                ForEach(request.codeChoices, id: \.self) { code in
                    Button {
                        linked.approve(request, code: code)
                    } label: {
                        Text(LinkRequest.spaced(code))
                            .font(.system(.title3, design: .monospaced).weight(.semibold))
                            .frame(minWidth: 110)
                            .padding(.vertical, 4)
                    }
                    .help("Approve if \(request.name) shows \(LinkRequest.spaced(code))")
                }
                Spacer(minLength: 8)
                Button("Deny", role: .destructive) { linked.deny(request) }
            }
            .disabled(working != nil)
        }
        .padding(12)
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusControl))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl).strokeBorder(.line))
    }

    private static func text(_ decision: LinkAcceptance.Decision) -> String? {
        switch decision {
        case .linked: nil
        case .wrongCode: "That code didn't match, so the request was declined. Start the link again on the other server."
        case .expired: "That request expired before it was approved. Start the link again on the other server."
        case .declined(let name): "Declined the request from \(name)."
        }
    }

    private func fact(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .foregroundStyle(.fgSubtle)
                .frame(width: 84, alignment: .trailing)
            value()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    private func spinner(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.fgSubtle)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }
}
