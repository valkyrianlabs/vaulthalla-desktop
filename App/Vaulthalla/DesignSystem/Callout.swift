import SwiftUI

/// A tinted note (the web's soft-tone alert).
struct Callout<Content: View>: View {
    var tone: StatusTone
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tone.color)
            VStack(alignment: .leading, spacing: 3) { content }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(tone.soft, in: RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusControl + 2, style: .continuous).strokeBorder(tone.line, lineWidth: 1)
        }
    }
}
