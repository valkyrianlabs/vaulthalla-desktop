import SwiftUI
import VHCore
import VHNodes

/// Link two servers this Mac is paired with (the server's design/peers/link.md, "Desktop-brokered"): pick them, confirm
/// once, and Desktop does the rest over its own sessions with both, comparing the pairing code itself against the keys
/// it already pins. No number is shown and no key is trusted on first use. Always offered: a node too old to link
/// servers is named with the Vaulthalla it needs, and Link stays off until two nodes can.
struct LinkServersSheet: View {
    /// Pre-filled from where it was opened (a node's row), else the first two.
    var preselected: NodeID?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var first: NodeID?
    @State private var second: NodeID?

    private var linked: LinkedServersModel { model.linkedServers }
    private var candidates: [Node] { linked.linkableNodes }

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
                    Text("A handshake between exactly two servers this Mac is paired with. A super admin on each side approves it, so this Mac must be paired as a super admin on both.")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let attempt = linked.attempt {
                progress(attempt)
            } else {
                choose
            }

            HStack {
                Spacer()
                buttons
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            linked.clearAttempt()
            let ids = candidates.map(\.id)
            first = preselected.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
            second = ids.first { $0 != first }
        }
    }

    private func name(_ id: NodeID?) -> String {
        id.flatMap { model.node(withID: $0)?.displayName } ?? "?"
    }

    // MARK: Choosing

    private var choose: some View {
        VStack(alignment: .leading, spacing: 14) {
            if linked.canLink {
                pickers
            } else {
                Text("Linking needs two servers this Mac is paired with, each running Vaulthalla \(ServerLinking.minimumVersion) or newer.")
                    .foregroundStyle(.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var pickers: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Link").foregroundStyle(.fgSubtle)
                    picker($first, excluding: second)
                }
                GridRow {
                    Text("with").foregroundStyle(.fgSubtle)
                    picker($second, excluding: first)
                }
            }
            if let first, let second, first != second {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Link \(name(first)) and \(name(second))?")
                        .font(.headline)
                        .foregroundStyle(.fg)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Self.grants, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•")
                                Text(line)
                            }
                        }
                    }
                    .foregroundStyle(.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    Text("Vaulthalla compares the pairing code for you against the keys this Mac already trusts. One of the two servers must be able to reach the other.")
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What a link does and doesn't grant, as the server defines it (design/peers/link.md, identity.md, mirror.md).
    private static let grants = [
        "Each server records the other's key, and a super admin on each side approves.",
        "Accounts are shared as identities only.",
        "No vault is mirrored until one server offers it and the other accepts.",
        "On mirrored vaults the linked server gets only the role chosen for it: none by default.",
        "Trust goes no further: a third server gains nothing.",
    ]

    private func picker(_ selection: Binding<NodeID?>, excluding other: NodeID?) -> some View {
        Picker("", selection: selection) {
            ForEach(candidates.filter { $0.id != other }) { node in
                Text(node.displayName).tag(Optional(node.id))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 260, alignment: .leading)
    }

    // MARK: Progress and result

    @ViewBuilder
    private func progress(_ attempt: LinkedServersModel.Attempt) -> some View {
        switch attempt.outcome {
        case nil:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text(attempt.step))
                    .foregroundStyle(.fgSubtle)
            }
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        case .success(let done)?:
            Callout(tone: .ok, systemImage: "checkmark.circle") {
                Text("\(name(done.dialler)) and \(name(done.acceptor)) are linked.")
                    .fontWeight(.medium)
                Text("\(name(done.dialler)) dialled \(name(done.acceptor)). The connection shows under Linked servers in All Nodes.")
                    .foregroundStyle(.fgMuted)
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
        switch linked.attempt {
        case let attempt? where attempt.isRunning:
            Button("Cancel") { linked.cancelLinking() }
                .keyboardShortcut(.cancelAction)
        case .some(let attempt):
            if case .failure(let failure)? = attempt.outcome, !isFinal(failure) {
                Button("Try Again") { linked.clearAttempt() }
            }
            Button("Done") {
                linked.clearAttempt()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        case nil:
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Link") {
                if let first, let second { linked.startLinking(first, second) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!linked.canLink || first == nil || second == nil || first == second)
        }
    }

    private func isFinal(_ failure: ServerLinking.Failure) -> Bool {
        switch failure {
        case .alreadyLinked, .sameServer: true
        default: false
        }
    }
}
