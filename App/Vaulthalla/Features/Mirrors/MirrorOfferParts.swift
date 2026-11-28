import SwiftUI
import VHContract
import VHCore
import VHNodes
import VHTransport

/// Runs the offer, held-change and link-setting commands of one surface, one at a time per item, and keeps what the
/// last one came to: a plain-sentence refusal (the server's own words, an approval this Mac can't give included) or
/// a short success note. Only ever started by a person's click.
@MainActor
@Observable
final class MirrorChange {
    struct Problem: Equatable {
        /// What didn't happen ("The offer was not accepted").
        var lead: String
        /// Why, as the server said it.
        var message: String
    }

    struct Notice: Equatable {
        var title: String
        var hint: String?
    }

    /// The item in flight (an offer id, a held change id, a setting).
    private(set) var working: String?
    var problem: Problem?
    var notice: Notice?

    @ObservationIgnored private let queries: NodeQueries

    init(queries: NodeQueries) {
        self.queries = queries
    }

    var isBusy: Bool { working != nil }

    /// Sends `request`; on success every mirror read is stale. A refusal is kept under `failed`.
    func run<R: WsRequest>(_ request: R.Type, _ payload: R.Payload, item: String, failed: String) async -> R.Response?
    where R.Payload: Decodable {
        guard working == nil else { return nil }
        working = item
        problem = nil
        notice = nil
        defer { working = nil }
        switch await queries.perform(R.self, payload, invalidating: ["mirror"]) {
        case .success(let response):
            return response
        case .needsConfirmation(let request):
            problem = Problem(lead: failed, message: request.message)
        case .failure(let error):
            problem = Problem(lead: failed, message: MirrorRefusal.sentence(error))
        }
        return nil
    }
}

/// The last refusal or success of a ``MirrorChange``, as a callout.
struct MirrorChangeNote: View {
    var change: MirrorChange

    var body: some View {
        if let problem = change.problem {
            Callout(tone: .danger, systemImage: "exclamationmark.octagon") {
                Text(problem.lead)
                    .fontWeight(.medium)
                    .foregroundStyle(.fg)
                Text(problem.message)
                    .foregroundStyle(.fgMuted)
                    .textSelection(.enabled)
            }
        } else if let notice = change.notice {
            Callout(tone: .ok, systemImage: "checkmark.circle") {
                Text(notice.title)
                    .fontWeight(.medium)
                    .foregroundStyle(.fg)
                if let hint = notice.hint {
                    Text(hint).foregroundStyle(.fgMuted)
                }
            }
        }
    }
}

/// One question before an action that changes what a server holds: what it does, in the console's words, and two
/// buttons. Neither is the default: Return does nothing, Escape cancels, and the action needs its own click.
struct MirrorQuestionSheet: View {
    var systemImage: String
    var title: String
    var message: String
    var confirmLabel: String
    var cancelLabel = "Cancel"
    var destructive = false
    var onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(destructive ? StatusTone.danger.color : Color.accentText)
                    .frame(width: 40, height: 40)
                    .background(destructive ? StatusTone.danger.soft : Color.accentSoft,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.fgMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            SheetFooter {
                Button(cancelLabel, role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, role: destructive ? .destructive : nil) {
                    dismiss()
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(destructive ? StatusTone.danger.color : Color.accentFill)
            }
        }
        .frame(width: 480)
    }
}

/// `-VHDebugMirrorSheet <name>` opens one of this folder's dialogs for a snapshot (DebugSnapshot): `add`, `accept`,
/// `decline`, `cancel`, `settings`, `settings-confirm`, `discard`; with PREVIEW DATA only, `settings-refuse` turns
/// mirror all on to show the refusal.
enum MirrorDebugSheet {
    static var requested: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "VHDebugMirrorSheet")
        #else
        nil
        #endif
    }
}
