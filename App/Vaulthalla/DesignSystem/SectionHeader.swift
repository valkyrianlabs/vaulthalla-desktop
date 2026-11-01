import SwiftUI

/// The top of a detail page: an optional cyan eyebrow, the title, a line of context, and trailing actions.
struct SectionHeader<Accessory: View>: View {
    var eyebrow: String?
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.caption.weight(.medium))
                        .tracking(0.8)
                        .foregroundStyle(Color.accentText.opacity(0.8))
                }
                Text(title)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.fg)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.fgSubtle)
                        .frame(maxWidth: Theme.proseWidth, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(eyebrow: String? = nil, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle, accessory: { EmptyView() })
    }
}
