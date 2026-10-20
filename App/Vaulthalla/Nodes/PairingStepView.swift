import SwiftUI
import VHCore

/// Explains pairing (docs/architecture.md §4). The protocol isn't implemented yet, so this is the explanation and an
/// honest note, not a working flow.
struct PairingStepView: View {
    var node: Node
    var done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                systemImage: "lock.laptopcomputer",
                title: "Pair this Mac with \(node.displayName)",
                subtitle: "Pairing gives this Mac its own identity on the node. No password is stored."
            )

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    PairingStep(number: 1, title: "Open Vaulthalla on that server", detail: "Sign in to the web console at \(node.endpoint.host).")
                    PairingStep(number: 2, title: "Go to Devices → Pair a device", detail: "This opens a ten-minute pairing window for your account.")
                    PairingStep(number: 3, title: "Compare the code", detail: "This Mac and the server each show a six-digit code. Approve only if they match.")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelSurface(radius: Theme.radiusCard)

                Callout(tone: .info, systemImage: "info.circle") {
                    Text("Pairing will be available once the server supports it.")
                        .fontWeight(.medium)
                        .foregroundStyle(.fg)
                    Text("\(node.displayName) is saved in the sidebar. Pair it from its Overview when the server is updated.")
                        .foregroundStyle(.fgMuted)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            SheetFooter {
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct PairingStep: View {
    var number: Int
    var title: String
    var detail: String

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
                Text(detail)
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
        .frame(width: 560)
        .background(Color.canvasRaised)
        .preferredColorScheme(.dark)
}
#endif
