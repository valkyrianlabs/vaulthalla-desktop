import SwiftUI

/// Says plainly why there's nothing here and what to do about it.
struct EmptyState<Actions: View>: View {
    var title: String
    var systemImage: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.accentText)
                .frame(width: 48, height: 48)
                .background(.surface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.line, lineWidth: 1)
                }
                .padding(.bottom, 16)

            Text(title)
                .font(.headline)
                .foregroundStyle(.fg)

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.fgSubtle)
                    .frame(maxWidth: 420)
                    .padding(.top, 4)
            }

            if Actions.self != EmptyView.self {
                HStack(spacing: 10) { actions }
                    .padding(.top, 20)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: String, systemImage: String, message: String? = nil) {
        self.init(title: title, systemImage: systemImage, message: message, actions: { EmptyView() })
    }
}

extension EmptyState {
    init(_ title: String, systemImage: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, systemImage: systemImage, message: message, actions: actions)
    }
}
