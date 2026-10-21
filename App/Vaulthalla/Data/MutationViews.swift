import SwiftUI
import VHContract
import VHNodes
import VHTransport

extension View {
    /// Puts the daemon's confirmation question in front of the person when `mutation` was refused with
    /// `needsConfirmation`, and resends with the acceptance if they agree. Every screen that mutates uses this.
    func serverConfirmation<R: WsRequest>(
        _ mutation: NodeMutation<R>, title: String, confirmLabel: String = "Continue", role: ButtonRole? = nil
    ) -> some View {
        modifier(ServerConfirmation(mutation: mutation, title: title, confirmLabel: confirmLabel, role: role))
    }
}

private struct ServerConfirmation<R: WsRequest>: ViewModifier where R.Payload: Decodable {
    var mutation: NodeMutation<R>
    var title: String
    var confirmLabel: String
    var role: ButtonRole?

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: presented, titleVisibility: .visible,
                                   presenting: mutation.confirmation) { request in
            if request.isAcceptable {
                Button(confirmLabel, role: role) {
                    Task { await mutation.confirm(request) }
                }
            }
            Button(request.isAcceptable ? "Cancel" : "OK", role: .cancel) {}
        } message: { request in
            // The daemon's words; when no resend can accept it, the contract says what to do instead.
            Text(request.isAcceptable ? request.message : "\(request.message)\n\n\(request.confirmation?.summary ?? "")")
        }
    }

    private var presented: Binding<Bool> {
        Binding(get: { mutation.confirmation != nil }, set: { if !$0 { mutation.confirmation = nil } })
    }
}

/// A mutation's failure under a form, in the daemon's words.
struct MutationError: View {
    var error: WsError?

    var body: some View {
        if let error {
            Callout(tone: tone(error), systemImage: QueryProblem(error) == .noAnswerYet ? "hourglass" : "exclamationmark.circle") {
                Text(text(error))
            }
        }
    }

    private func tone(_ error: WsError) -> StatusTone {
        switch QueryProblem(error) {
        case .noAnswerYet, .offline: .info
        case .denied: .warn
        default: .danger
        }
    }

    private func text(_ error: WsError) -> String {
        switch QueryProblem(error) {
        case .noAnswerYet: "No answer yet. The node may still be working on it; check before trying again."
        case .offline: "Not connected to the node. Nothing was changed."
        case .denied(let message): "Not allowed: \(message)"
        default: error.message
        }
    }
}
