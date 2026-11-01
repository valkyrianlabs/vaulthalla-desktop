import AppKit
import SwiftUI
import VHCore
import VHIdentity
import VHNodes
import VHTransport

/// Pairs this Mac with a node (docs/pairing.md §3): shows the six-digit code to approve on the server, waits for the
/// owner's decision, and explains every way it can end.
struct PairingStepView: View {
    var node: Node
    var done: () -> Void

    @Environment(AppModel.self) private var model
    @State private var flow = PairingFlow()
    /// This Mac's Vaulthalla server, when the node is it and `vh` is installed (desktop#7).
    @State private var localServer: LocalPairing?
    @State private var confirmingLocal = false
    @AppStorage(SignInPreferences.keepSignedInKey) private var keepSignedIn = true

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "lock.laptopcomputer",
                title: "Pair this Mac with \(node.displayName)",
                subtitle: "Pairing gives this Mac its own key on the node. No password is stored."
            )

            VStack(alignment: .leading, spacing: 16) {
                status
                if !flow.phase.isFinished {
                    if flow.approvingLocally {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text("Approving through Vaulthalla on this Mac…")
                                .font(.callout)
                                .foregroundStyle(.fgSubtle)
                        }
                    } else {
                        instructions
                    }
                }
                if let problem = flow.localProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(StatusTone.warn.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Keep me signed in on this Mac", isOn: $keepSignedIn)
                    .font(.callout)
                    .help(keepSignedIn ? "This Mac stays paired across quits, restarts and macOS logins."
                          : "Quitting Vaulthalla or logging out of macOS signs this Mac out of every node. Use this on a Mac that isn't yours.")
                if flow.backend == .software {
                    Label(KeyBackend.software.displayName, systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                        .help("This build can't use the Secure Enclave, so the key is a software key in the login keychain.")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            SheetFooter { buttons }
        }
        .task {
            localServer = PairingFlow.localServer(for: node)
            flow.start(node: node, model: model)
        }
        .onDisappear { flow.cancel() }
        .confirmationDialog("Pair using Vaulthalla on this Mac?", isPresented: $confirmingLocal, titleVisibility: .visible) {
            Button("Pair") {
                if let localServer { flow.pairLocally(localServer, node: node, model: model) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Vaulthalla runs vh device pair as \(NSUserName()) to open a pairing window, checks that the server shows this Mac's code, and approves it. The server decides which Vaulthalla user that is: the one linked to this macOS account. This Mac then appears under Devices, where it can be revoked.")
        }
    }

    /// Offers pairing through this Mac's own server, when there is one.
    @ViewBuilder
    private var localButton: some View {
        if localServer != nil, !flow.approvingLocally {
            Button("Pair Using Vaulthalla on This Mac…", systemImage: "laptopcomputer") { confirmingLocal = true }
                .padding(.top, 4)
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var status: some View {
        switch flow.phase {
        case .preparing, .connecting:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connecting to \(node.displayName)…")
                        .fontWeight(.medium)
                        .foregroundStyle(.fg)
                    Text(node.endpoint.description)
                        .font(.callout)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.fgSubtle)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .panelSurface(radius: Theme.radiusCard)

        case .awaitingApproval(let code):
            CodePanel(nodeName: node.displayName, code: code, serverRelease: flow.serverRelease)

        case .approved(let serverName):
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(StatusTone.ok.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paired with \(serverName)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                    Text("This Mac now connects to \(serverName) with its own key, pinned to the server's.")
                        .foregroundStyle(.fgMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .panelSurface(radius: Theme.radiusCard)

        case .denied:
            Callout(tone: .danger, systemImage: "xmark.octagon") {
                Text("Pairing was declined")
                    .fontWeight(.semibold)
                    .foregroundStyle(.fg)
                Text("The request wasn't approved on \(node.displayName). A wrong code declines it too. Try again for a new code.")
                    .foregroundStyle(.fgMuted)
            }

        case .expired:
            Callout(tone: .warn, systemImage: "clock.badge.exclamationmark") {
                Text("Pairing timed out")
                    .fontWeight(.semibold)
                    .foregroundStyle(.fg)
                Text("The request expired before it was approved (requests last five minutes, and closing the pairing window ends them). Try again for a new code.")
                    .foregroundStyle(.fgMuted)
            }

        case .failed(.noPairingWindow):
            Callout(tone: .warn, systemImage: "lock.open.display") {
                Text("Open a pairing window on \(node.displayName) first")
                    .fontWeight(.semibold)
                    .foregroundStyle(.fg)
                Text("In the web console go to Devices → Pair a device, or run this on the server, then try again:")
                    .foregroundStyle(.fgMuted)
                CommandText("vh device pair")
                    .padding(.top, 4)
                localButton
            }

        case .failed(.unreachable(let endpoint)):
            Callout(tone: .warn, systemImage: "bolt.horizontal.circle") {
                Text("Can't reach \(node.displayName)")
                    .fontWeight(.semibold)
                    .foregroundStyle(.fg)
                Text("Nothing answered at \(endpoint). Check the address, and that the server accepts devices from other machines:")
                    .foregroundStyle(.fgMuted)
                CommandText("vh device remote enable")
                    .padding(.top, 4)
            }

        case .failed(.incompatible(let mismatch)):
            Callout(tone: .danger, systemImage: "arrow.triangle.2.circlepath") {
                Text(mismatch.side == .desktopTooOld ? "Update Vaulthalla Desktop to pair"
                    : mismatch.side == .serverTooOld ? "Update Vaulthalla on \(node.displayName) to pair"
                    : "\(node.displayName) runs an incompatible Vaulthalla")
                    .fontWeight(.semibold)
                    .foregroundStyle(.fg)
                Text("\(mismatch.message) Nothing was requested; pair again once both sides share a protocol version.")
                    .foregroundStyle(.fgMuted)
            }

        case .failed(let failure):
            let stopped = failure == .serverIdentityChanged || failure == .unexpectedServerIdentity
            Callout(tone: stopped ? .danger : .warn, systemImage: "exclamationmark.triangle") {
                Text(stopped ? "Pairing stopped" : "Pairing didn't finish")
                    .fontWeight(.semibold)
                    .foregroundStyle(.fg)
                Text(failure.message)
                    .foregroundStyle(.fgMuted)
            }
        }
    }

    // MARK: - Instructions

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 14) {
            PairingInstruction(number: 1, title: "Open a pairing window on \(node.displayName)") {
                let command = Text("vh device pair").font(.callout.monospaced()).foregroundStyle(.fgMuted)
                Text("In the web console at \(node.endpoint.host), go to Devices → Pair a device. Or run \(command) on the server.")
            }
            PairingInstruction(number: 2, title: "Click the matching code") {
                if case .awaitingApproval(let code) = flow.phase {
                    let digits = Text(code.formatted).monospacedDigit().foregroundStyle(.accentText)
                    Text("The server lists “\(PairingFlow.deviceName)” with three codes. Click \(digits). A wrong pick declines the request.")
                } else {
                    Text("The server lists this Mac with three codes. Click the one shown here once it appears.")
                }
            }
            localButton
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(radius: Theme.radiusCard)
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        switch flow.phase {
        case .preparing, .connecting, .awaitingApproval:
            Button("Cancel", role: .cancel) {
                flow.cancel()
                done()
            }
            .keyboardShortcut(.cancelAction)
        case .approved:
            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .denied, .expired, .failed:
            Button("Close", role: .cancel, action: done)
                .keyboardShortcut(.cancelAction)
            Button("Try Again") { flow.start(node: node, model: model) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// The code to approve, large and calm.
private struct CodePanel: View {
    var nodeName: String
    var code: PairingCode
    /// What the server runs, when its `meta.hello` said.
    var serverRelease: String?

    var body: some View {
        VStack(spacing: 10) {
            Text("Approve on \(nodeName)")
                .font(.callout.weight(.medium))
                .foregroundStyle(.fgMuted)
            Text(code.formatted)
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .tracking(3)
                .foregroundStyle(.accentText)
                .textSelection(.enabled)
                .accessibilityLabel("Code \(code.digits.map(String.init).joined(separator: " "))")
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Waiting for approval…")
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
            }
            if let serverRelease {
                Text(serverRelease)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
            }
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(.accentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(.accentLine, lineWidth: 1)
        }
    }
}

/// A shell command to copy.
private struct CommandText: View {
    var command: String

    init(_ command: String) { self.command = command }

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.callout.monospaced())
                .foregroundStyle(.fg)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.surface2, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
    }
}

private struct PairingInstruction<Detail: View>: View {
    var number: Int
    var title: String
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.accentText)
                .frame(width: 24, height: 24)
                .background(.accentSoft, in: Circle())
                .overlay { Circle().strokeBorder(.accentLine, lineWidth: 1) }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.fg)
                detail
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#if DEBUG
#Preview("Pairing step") {
    PairingStepView(node: PreviewSamples.nodes[0]) {}
        .environment(PreviewSamples.model())
        .frame(width: 560)
        .background(Color.canvasRaised)
        .preferredColorScheme(.dark)
}
#endif
