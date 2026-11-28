import SwiftUI
import VHContract
import VHCore
import VHNodes

/// The mirrored vault whose detail shows on a node's Mirrored Vaults page.
struct MirrorFocus: Hashable {
    var node: NodeID
    var vaultID: Int64
}

extension AppModel {
    /// The node's sections, in order. Mirrored Vaults shows only when the node's command set (`meta.hello`) has
    /// `mirror.list`: a legacy or older node never lists it.
    func sections(for node: Node) -> [NodeSection] {
        NodeSection.allCases.filter {
            $0 != .mirroredVaults || nodeProtocol(for: node.id)?.supports(command: .mirrorList) == .yes
        }
    }

    /// Shows one mirrored vault's detail on the node's Mirrored Vaults page.
    func openMirror(_ vaultID: Int64, on node: NodeID) {
        mirrorFocus = MirrorFocus(node: node, vaultID: vaultID)
        selectNode(node, section: .mirroredVaults)
    }

    /// Back to the Mirrored Vaults list.
    func closeMirror() {
        mirrorFocus = nil
    }
}

// MARK: - Shared pieces

nonisolated extension MirrorTone {
    /// Neutral (ended, inert) and unknown both draw gray: neither is ever green.
    var statusTone: StatusTone {
        switch self {
        case .ok: .ok
        case .info: .info
        case .warn: .warn
        case .danger: .danger
        case .neutral, .unknown: .unknown
        }
    }
}

nonisolated extension MirrorLink {
    var text: String {
        switch self {
        case .up: MirrorCopy.linkUp
        case .down: MirrorCopy.linkDown
        case .unknown: MirrorCopy.linkUnknown
        case .unlinked: MirrorCopy.linkGone
        }
    }

    var tone: StatusTone {
        switch self {
        case .up: .ok
        case .down: .warn
        case .unknown, .unlinked: .unknown
        }
    }
}

nonisolated enum MirrorFormat {
    /// Purge dates and other moments the rules put in a sentence.
    static let date: @Sendable (Int64) -> String = { seconds in
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .shortened)
    }

    static func facts(_ row: MirroredVault) -> MirrorModel.Facts {
        .of(row, date: date)
    }

    /// "Nov 27, 2026 at 14:02 (3 min ago)".
    static func moment(_ seconds: Int64) -> String {
        "\(date(seconds)) (\(Format.relative(epoch: seconds)))"
    }
}

/// This server's role as a small tinted pill, without a dot (the dot belongs to states).
struct MirrorRoleBadge: View {
    var role: MirrorRole

    var body: some View {
        let text = MirrorModel.roleText(role)
        let tone = text.tone.statusTone
        Text(text.label)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(tone.soft, in: Capsule())
            .overlay { Capsule().strokeBorder(tone.line, lineWidth: 1) }
    }
}

/// The state as a badge and, unless `compact`, its sentence (with a reason code the rules have no words for).
struct MirrorStatusView: View {
    var status: MirrorModel.Status
    var compact = false
    var sentenceFont: Font = .caption

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            StatusBadge(label: status.label, tone: status.tone.statusTone)
                .help(compact ? status.sentence : "")
            if !compact {
                Text("\(status.sentence)\(Text(status.code.map { "  (\($0))" } ?? "").font(.caption.monospaced()))")
                    .font(sentenceFont)
                    .foregroundStyle(.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The link to the other server: a dot and a word.
struct MirrorLinkLabel: View {
    var link: MirrorLink

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(tone: link.tone, size: 7)
            Text(link.text)
                .foregroundStyle(link == .up ? Color.fgMuted : Color.fgSubtle)
        }
        .accessibilityElement(children: .combine)
    }
}
