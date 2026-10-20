#if DEBUG
import SwiftUI

/// Every design-system piece on one canvas, for previews. Values shown here are swatches, not data.
struct DesignSystemGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SectionHeader(eyebrow: "Design system", title: "Vaulthalla", subtitle: "Tokens and components ported from the web console.") {
                    Button("Action") {}
                        .buttonStyle(.borderedProminent)
                }

                Panel(title: "Colors", subtitle: "Canvas, surfaces, lines, text and the one accent") {
                    swatches
                }

                Panel(title: "Status", subtitle: "Only the backend picks a tone; unknown is never green") {
                    HStack(spacing: 10) {
                        ForEach(StatusTone.allCases, id: \.self) { tone in
                            StatusBadge(label: tone.rawValue.capitalized, tone: tone)
                        }
                        StatusBadge(label: "Connecting…", tone: .info, pulse: true)
                    }
                    HStack(spacing: 14) {
                        ForEach(StatusTone.allCases, id: \.self) { tone in
                            StatusDot(tone: tone)
                        }
                    }
                }

                Panel(title: "Stat tiles", size: .panel) {
                    StatGrid {
                        StatTile(label: "Sample", value: "128", systemImage: "number", hint: "A swatch, not data")
                        StatTile(label: "Toned", value: "Warning", systemImage: "exclamationmark.triangle", tone: .warn)
                        StatTile(label: "Missing", value: nil, systemImage: "questionmark.circle")
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    Panel(title: "Card", subtitle: "14 pt corners", size: .card) {
                        DefinitionList(items: [("Term", "Value"), ("Address", "host.local:36971")], monospacedValues: ["Address"])
                    }
                    Panel(title: "Panel", subtitle: "20 pt corners") {
                        Callout(tone: .info, systemImage: "info.circle") {
                            Text("A soft-tone callout.")
                        }
                    }
                }

                Panel {
                    EmptyState("Empty state", systemImage: "tray", message: "Says why there's nothing here and what to do next.") {
                        Button("Do the thing") {}
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
        .vaulthallaCanvas()
        .preferredColorScheme(.dark)
        .tint(.accentFill)
    }

    private var swatches: some View {
        let colors: [(String, Color)] = [
            ("canvas", .canvas), ("raised", .canvasRaised), ("surface 1", .surface1), ("surface 2", .surface2),
            ("surface 3", .surface3), ("line", .line), ("line strong", .lineStrong), ("fg", .fg),
            ("fg muted", .fgMuted), ("fg subtle", .fgSubtle), ("fg faint", .fgFaint), ("accent", .accentFill),
            ("accent text", .accentText), ("accent soft", .accentSoft),
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
            ForEach(colors, id: \.0) { name, color in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                        .fill(color)
                        .frame(height: 40)
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(.line)
                        }
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.fgSubtle)
                }
            }
        }
    }
}

#Preview("Design system") {
    DesignSystemGallery()
        .frame(width: 900, height: 1100)
}
#endif
