import SwiftUI

/// A labelled value. A `nil` value renders "not available": never 0, never a healthy tone.
struct StatTile: View {
    var label: String
    var value: String?
    var systemImage: String?
    var hint: String?
    var tone: StatusTone?

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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surface1, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).strokeBorder(.line, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lays stat tiles out in as many columns as fit.
struct StatGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
            content
        }
    }
}
