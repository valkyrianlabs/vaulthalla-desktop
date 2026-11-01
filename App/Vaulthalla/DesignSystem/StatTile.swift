import SwiftUI

/// A labelled value. A `nil` value renders "not available": never 0, never a healthy tone.
struct StatTile: View {
    var label: String
    var value: String?
    var systemImage: String?
    var hint: String?
    var tone: StatusTone?
    /// Set when the tile is the subject of a warning the person followed here: an outline in `tone` (or warn).
    var highlighted = false

    @Environment(\.statTilesReserveHint) private var reservesHint

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                        .foregroundStyle(.accentText)
                }
                Text(label.uppercased())
                    .lineLimit(1)
            }
            .font(.caption2.weight(.medium))
            .tracking(0.6)
            .foregroundStyle(.fgSubtle)

            if let value {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tone?.color ?? .fg)
                    .lineLimit(1)
            } else {
                Text("not available")
                    .font(.body)
                    .foregroundStyle(.fgFaint)
                    .frame(minHeight: 24, alignment: .leading)
            }

            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .lineLimit(1)
            } else if reservesHint {
                Text(" ").font(.caption).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(highlighted ? (tone ?? .warn).line : Color.line, lineWidth: highlighted ? 1.5 : 1)
        }
        .help(hint ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// Lays stat tiles out in as many columns as fit.
struct StatGrid<Content: View>: View {
    /// The narrowest a tile gets before the grid drops a column.
    var minimum: CGFloat = 170
    /// Every tile keeps a line for its hint, so a row of tiles with and without hints lines up.
    var uniformHeight = false
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 10)], spacing: 10) {
            content
        }
        .environment(\.statTilesReserveHint, uniformHeight)
    }
}

extension EnvironmentValues {
    @Entry var statTilesReserveHint = false
}
