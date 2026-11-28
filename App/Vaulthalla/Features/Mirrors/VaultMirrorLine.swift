import SwiftUI
import VHContract
import VHCore
import VHNodes

/// In the vault inspector: "Mirrored with <server>" and the mirror's state, opening its detail. Shown only when the
/// node has `mirror.list` and lists this vault there (super admins); otherwise, and while loading or refused,
/// nothing.
struct VaultMirrorLine: View {
    var vaultID: Int64
    var node: Node
    var queries: NodeQueries

    var body: some View {
        if queries.supports(command: .mirrorList) == .yes {
            Line(vaultID: vaultID, node: node, list: queries.query(Ws.Mirror.List.self))
        }
    }

    private struct Line: View {
        var vaultID: Int64
        var node: Node
        var list: NodeQuery<Ws.Mirror.List>

        @Environment(AppModel.self) private var model

        var body: some View {
            // A stack, not a Group: the observing task must run while nothing shows yet.
            VStack(alignment: .leading, spacing: 0) {
                if let row = list.value.flatMap({ MirrorModel.mirror(of: vaultID, in: $0.vaults.map(MirroredVault.init)) }) {
                    let status = MirrorModel.status(row, MirrorFormat.facts(row))
                    Button {
                        model.openMirror(vaultID, on: node.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: NodeSection.mirroredVaults.systemImage)
                                .foregroundStyle(.accentText)
                            Text(MirrorCopy.mirroredWith(MirrorModel.peerName(row)))
                                .foregroundStyle(.fgMuted)
                            StatusDot(tone: status.tone.statusTone, size: 6)
                            Text(status.label)
                                .foregroundStyle(status.tone.statusTone.color)
                            Image(systemName: "chevron.forward")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.fgFaint)
                        }
                        .font(.caption)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .help("\(MirrorModel.roleSentence(row)) Show the mirror.")
                }
            }
            .observing(list)
        }
    }
}
