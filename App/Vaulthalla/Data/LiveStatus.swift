import SwiftUI
import VHContract
import VHNodes

/// When a live read last refreshed and whether the latest refresh failed, with a button to refresh it now. Says
/// nothing about health (the web's `LiveStatus`).
struct LiveStatus<R: WsRequest>: View {
    var query: NodeQuery<R>

    var body: some View {
        HStack(spacing: 6) {
            if let updated = query.updatedAt {
                if let error = query.refreshError {
                    StatusBadge(label: "Stale · \(Self.time(updated))", tone: .warn)
                        .help(QueryProblem(error).sentence)
                } else {
                    HStack(spacing: 5) {
                        if query.isFetching {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle().fill(Color.accentFill.opacity(0.7)).frame(width: 5, height: 5)
                        }
                        Text(query.isFetching ? "Updating…" : "Updated \(Self.time(updated))")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.fgSubtle)
                    .help("Refreshes on its own while this page is open. \(updated.formatted(date: .abbreviated, time: .standard))")
                }
            }
            Button {
                Task { await query.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.fgSubtle)
            .disabled(query.isFetching)
            .help("Refresh now")
            .accessibilityLabel("Refresh")
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

extension QueryProblem {
    /// The problem as one sentence, for a tooltip.
    var sentence: String {
        switch self {
        case .denied(let message): "Refused: \(message)"
        case .notFound(let message), .failed(let message): message
        case .offline: "Not connected."
        case .noAnswerYet: "No answer yet."
        case .mismatch: "The answer wasn't readable by this version."
        }
    }
}
