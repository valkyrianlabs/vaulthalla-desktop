import SwiftUI

/// The content container: translucent fill with a faint rim light and a hairline border (the web's `.panel`).
struct Panel<Content: View, Actions: View>: View {
    enum Size {
        /// 14 pt corners: tiles, compact cards.
        case card
        /// 20 pt corners: page-level groups.
        case panel

        var radius: CGFloat { self == .card ? Theme.radiusCard : Theme.radiusPanel }
    }

    var title: String?
    var subtitle: String?
    var size: Size = .panel
    var padded = true
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || Actions.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.fg)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.fgSubtle)
                        }
                    }
                    Spacer(minLength: 0)
                    actions
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            content
                .padding(.horizontal, padded ? 20 : 0)
                .padding(.bottom, padded ? 20 : 0)
                .padding(.top, padded && title == nil ? 20 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(radius: size.radius)
    }
}

extension Panel where Actions == EmptyView {
    init(
        title: String? = nil,
        subtitle: String? = nil,
        size: Size = .panel,
        padded: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, size: size, padded: padded, content: content, actions: { EmptyView() })
    }
}

extension View {
    /// The panel fill, rim light and hairline, for custom containers that need the same surface.
    func panelSurface(radius: CGFloat = Theme.radiusPanel) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            shape.fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.035), Color.white.opacity(0.018)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .overlay {
            shape.strokeBorder(Color.line, lineWidth: 1)
        }
        .overlay(alignment: .top) {
            // Rim light: the web's `inset 0 1px 0 rgb(255 255 255 / 0.04)`.
            shape.inset(by: 1)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
                .mask(alignment: .top) { Rectangle().frame(height: 2) }
        }
    }
}

/// A two-column key/value list for detail views (the web's `DefinitionList`).
struct DefinitionList: View {
    var items: [(term: String, value: String)]
    var monospacedValues: Set<String> = []

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 10) {
            ForEach(items, id: \.term) { item in
                GridRow {
                    Text(item.term)
                        .foregroundStyle(.fgSubtle)
                        .gridColumnAlignment(.leading)
                    Text(item.value)
                        .foregroundStyle(.fg)
                        .fontDesign(monospacedValues.contains(item.term) ? .monospaced : .default)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.callout)
    }
}
